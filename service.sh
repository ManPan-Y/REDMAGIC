#!/system/bin/sh
# ============================================================
# REDMAGIC 主服务。开机由 KernelSU 以 root 拉起，只允许跑一份。
# 失败一律落日志 + 回滚记忆，绝不让界面显示一个不成立的状态。
# ============================================================
MODDIR=${0%/*}
[ -d "$MODDIR" ] || exit 1
cd "$MODDIR" 2>/dev/null || true

. "$MODDIR/paths.sh"
. "$MODDIR/common.sh"
for _f in system thermal fanpump charge touch cpufreq gpufreq bright state commands status loop teardown; do
    . "$MODDIR/lib/$_f.sh"
done

WEBUI_STALE_MAX=45
DAEMONS=""
CLEANED=""
SVC_SELF=$$
BRIGHT_PID=""
WEBUI_PID=""

# ---------------- 单实例 ----------------
svc_alive() {
    [ -n "$1" ] || return 1
    [ -d "/proc/$1" ] || return 1
    tr -d '\000' < "/proc/$1/cmdline" 2>/dev/null | grep -q "$SVC_CMDLINE_PAT"
}

if [ -f "$SVC_LOCK_FILE" ]; then
    _lock=$(cat "$SVC_LOCK_FILE" 2>/dev/null)
    if svc_alive "$_lock"; then
        printf '%s\n' "$(date '+%m-%d %H:%M:%S') 已有实例 $_lock 在跑" >> "$LOG_FILE" 2>/dev/null
        exit 0
    fi
fi
( set -C; printf '%s\n' "$$" > "$SVC_LOCK_FILE" ) 2>/dev/null || {
    _lock=$(cat "$SVC_LOCK_FILE" 2>/dev/null)
    svc_alive "$_lock" && exit 0
    rm -f "$SVC_LOCK_FILE" 2>/dev/null
    printf '%s\n' "$$" > "$SVC_LOCK_FILE"
}
printf '%s\n' "$$" > "$SVC_PID_FILE"
# trap 必须在拿到锁之后再挂：否则「第二个实例发现已有实例在跑」直接 exit 时，
# EXIT 也会走 cleanup，把正在跑的实例的伪装状态和采样率一起还原掉。
trap on_term TERM INT HUP
trap cleanup EXIT

cleanup() {
    # 只清理一次：TERM 和 EXIT 都会进来，靠标记防重入
    [ -n "$CLEANED" ] && return 0
    CLEANED=1
    local p
    for p in $DAEMONS; do kill "$p" 2>/dev/null; done
    sleep 1 2>/dev/null
    for p in $DAEMONS; do kill -9 "$p" 2>/dev/null; done
    # 服务没了就没人核对，伪装状态绝不能留在系统里：
    # 还给充电模组真实亮屏状态；采样率按快照硬还原（挂起导致的失败会保留快照）
    fast_release 2>/dev/null
    rate_force_restore 2>/dev/null
    cpu_release 2>/dev/null
    gpu_release 2>/dev/null
    rm -f "$SVC_PID_FILE" "$SVC_LOCK_FILE" 2>/dev/null
    mlog "服务退出: 伪装状态与频率设置已还原"
}
# 旧写法在 cleanup 里 trap '' TERM，TERM 处理完后又回到主循环，
# 进程从此无视 TERM 只能 kill -9。这里处理完必须真正退出。
on_term() { cleanup; exit 0; }

# ---------------- 初始化 ----------------
# 兜底：本进程及子进程的 stderr 一律进主日志，不让报错悄悄消失
exec 2>>"$LOG_FILE"
: > "$WEBUI_HB_SEEN" 2>/dev/null
# 清理上一轮可能残留的临时文件（运行期文件全部在 run/，根目录保持干净）
rm -f "$BRIGHT_NA" "$WEBUI_HB" "$WEBUI_STATUS" \
      "$WEBUI_STATUS.tmp" "$WEBUI_CMD.pending" "$LOG_FILE.tmp" \
      "$SEP_CACHE" "$RATE_CACHE" 2>/dev/null
rm -f "$RUN_DIR"/*.tmp "$RUN_DIR"/state.txt.?????? 2>/dev/null

state_repair
state_restore_flags
seed_values

mlog "===== 开机 $(grep '^version=' module.prop 2>/dev/null | cut -d= -f2) ====="
mlog "机型 $(getprop ro.product.model 2>/dev/null) / Android $(getprop ro.build.version.release 2>/dev/null) / 内核 $(uname -r 2>/dev/null)"
# 功能说明直接写进主日志，不额外生成说明文件
mlog "采样率: 写驱动 $TOUCH_REPORT，档位 0..4 = 120/180/300/360/720Hz；上限默认 720，关闭按快照还原"
mlog "采样率同步: 同时把系统 settings touch_sampling_rate 写成本机最高显示值（${RATE_SETTING_MAX}），仅影响系统界面显示，不改亮度与功耗"
mlog "熄屏提速: 仅对充电模组伪装 $CHG_SCREEN_ON=0（驱动按 screenon=0 重算 FCC），显示亮度不变"
mlog "让行规则: 息屏(Dozing)/挂起(suspend=1)/游戏空间(play_game=1) 期间不写触控与采样率节点"
mlog "CPU/GPU: 频率来自系统频率表（scaling_available_frequencies / gpu_available_frequencies），选定即可固定（min=max）；只压上限时绝不抬系统已压低的频率"
mlog "GPU 让行: 息屏与游戏空间接管（play_game=1）期间 kgsl 拒写，条件解除后自动补写"
mlog "温度联动: 取电池 $BAT_DIR/temp 与皮肤 ${SKIN_TEMP:-无} 中较高者"
mlog "触控新增: rotation_limit_level 握持防误触 0..3 / tp_palm_mode 手掌抑制 / pen_only 手写笔模式"

# 采样率：直接写驱动 tp_report_rate。触控驱动可能还没就绪 / 屏幕还锁着，
# rate_boost_boot 会重试 8 次，所以放后台，绝不阻塞开机主链
if [ -f "$F_RATE" ]; then
    ( rate_boost_boot; sleep 15 ) &
fi

# 温控屏蔽：必须在充电加速之前
# 注意标记是 F_THERMAL。以前这里写的是 F_CHARGE（充电分离），
# 结果只勾「充电分离」也会去 bind 空 thermal-engine.conf 并 chmod 全部 cpufreq。
if [ -f "$F_THERMAL" ]; then
    thermal_on || { errlog "温控屏蔽: 开机启用失败，已回退记忆"; rm -f "$F_THERMAL"; cfg_set '温控移除' 0; }
fi
if [ -f "$F_BOOST" ] && ! thermal_effective; then
    rm -f "$F_BOOST"; cfg_set '充电加速' 0
    mlog "充电加速: 温控未生效，本次开机不开加速"
fi
if [ -f "$F_BOOST" ]; then
    # 开机也必须过守卫：以前直接 boost_apply，温度/分离条件没检查就解限流
    if boost_guard; then
        boost_apply || errlog "充电加速: 开机应用失败，交给 reconcile 重试"
    else
        mlog "充电加速: 开机条件未满足，等待自动生效"
    fi
fi
[ -f "$F_BOOST_HEAT" ] && { heat_apply || { errlog "解除热降流: 开机应用失败，已回退记忆"; rm -f "$F_BOOST_HEAT"; cfg_set '解除热降流' 0; }; }

# 熄屏提速：开机通常还锁着屏，守卫不过就等亮屏后 reconcile 自动生效
if [ -f "$F_FAST" ]; then
    fast_apply || mlog "熄屏提速: 开机条件未满足，等待自动生效"
fi

# CPU / GPU：开机通常是锁屏状态，GPU 会等亮屏后由对账补写
cpu_apply || true
gpu_apply || true

# 触控：节点可能还没就绪，放后台等（不阻塞主链）
if [ -f "$F_TOUCH" ]; then
    ( TOUCH_WAIT_MAX=20; touch_apply || errlog "触控: 开机写入失败（节点可能未就绪）"; sleep 15 ) &
fi

# 亮度：同样后台等背光节点
if [ -f "$F_BRIGHT" ]; then
    bright_daemon &
    BRIGHT_PID=$!
fi

# 风扇 / 液冷：按记忆接管；系统没开就等它开（reconcile 会补）
if [ -f "$F_FAN" ]; then
    if fan_sys_on; then fan_level_write "$(stq '风扇档位')" || errlog "风扇: 开机写档位失败"; else mlog "风扇: 系统开关为关，等待"; fi
fi
if [ -f "$F_PUMP" ]; then
    if pump_sys_on; then pump_speed_write "$(pump_speed_of "$(stq '液冷档位')")" || errlog "液冷: 开机写转速失败"; else mlog "液冷: 系统开关为关，等待"; fi
fi

# ---------------- 守护 ----------------
# 充电分离巡逻：插电且电量达到阈值 -> 系统开关置 1，否则置 0
charge_sep_patrol() {
    local last="" want cap
    while :; do
        # $$ 在 mksh 后台函数里仍是 service 的 PID，service 没了就自行退出
        [ -d "/proc/$SVC_SELF" ] || exit 0
        if [ -f "$F_CHARGE" ]; then
            want=0
            if [ "$(rdv "$AC_ONLINE" 2>/dev/null)" = "1" ]; then
                cap=$(battery_capacity) || cap=0
                [ "$cap" -ge "$(sep_limit)" ] 2>/dev/null && want=1
            fi
            # 除了目标变化，系统开关被外部改掉（或手动关开太快）也要拉回目标值
            if [ "$want" != "$last" ] || [ "$(sep_now)" != "$want" ]; then
                if charge_sep_set "$want"; then
                    mlog "充电分离: $([ "$want" = 1 ] && echo 开启 || echo 关闭)（电量 ${cap}% / 阈值 $(sep_limit)%）"
                else
                    errlog "充电分离: 系统开关写入失败（目标 $want）"
                fi
                last=$want
            fi
        elif [ "$last" != "0" ]; then
            [ "$(sep_now)" = "1" ] && stg put global charge_separation_switch 0 >/dev/null 2>&1
            sep_store 0
            sep_init
            last="0"
        fi
        sleep 3
    done
}

charge_sep_patrol &
SEP_PID=$!
webui_loop &
WEBUI_PID=$!
# 只登记常驻进程。一次性的初始化子进程（触控首写/亮度守护/采样率重试）不登记，
# 否则它们跑完退出后再来一次 TERM 就会撞上被复用的 PID，误杀无关进程。
DAEMONS="$SEP_PID $WEBUI_PID"

mlog "开机完成: 风扇=$(f_on "$F_FAN" && echo 1 || echo 0) 液冷=$(f_on "$F_PUMP" && echo 1 || echo 0) 分离=$(f_on "$F_CHARGE" && echo 1 || echo 0) 温控=$(f_on "$F_THERMAL" && echo 1 || echo 0) 屏蔽=$(thermal_effective && echo 1 || echo 0) 加速=$(f_on "$F_BOOST" && echo 1 || echo 0) 触控=$(f_on "$F_TOUCH" && echo 1 || echo 0) 采样率=$(f_on "$F_RATE" && echo 1 || echo 0) 亮度=$(f_on "$F_BRIGHT" && echo 1 || echo 0) 熄屏提速=$(f_on "$F_FAST" && echo 1 || echo 0) 小核=$(stq 'CPU小核频率') 大核=$(stq 'CPU大核频率') GPU=$(stq 'GPU频率') 锁定=$(stq '频率锁定')"

# ---------------- 看门狗 ----------------
# mksh 会等前台子进程结束后才处理 trap；整段 sleep 15 会让 TERM 延迟 15 秒，
# 拆成 1 秒一片，优雅停止最多等 1 秒。
svc_sleep() {
    local n="$1"
    while [ "$n" -gt 0 ]; do
        sleep 1 2>/dev/null
        n=$((n - 1))
    done
}

while :; do
    svc_sleep 15
    mlog_trim   # 单次运行内也只留最新的一段，日志不会无限长
    if [ -f "$F_TOUCH" ]; then
        touch_na_prune   # 驱动晚就绪：撤销已恢复项的置灰，让下面的 verify 发现并回写；NA 为空时零开销
        if ! touch_verify; then
            mlog "看门狗: 触控参数被改动，重新写入"
            touch_apply || errlog "看门狗: 触控重新写入失败"
        fi
    fi
    if [ -f "$F_RATE" ]; then
        rate_verify || { mlog "看门狗: 采样率被改动，重新写入"; rate_boost_on || errlog "看门狗: 采样率重写失败"; }
    elif [ -f "$RATE_SNAPSHOT" ]; then
        # 关闭功能时正处于息屏/游戏让行：亮屏后由看门狗补还
        rate_boost_off || true
    fi
    if [ -f "$F_FAST" ] || [ -f "$FAST_MARK" ]; then
        fast_apply || true
    fi
    # CPU/GPU 频率：锁定档需要看门狗把被系统改掉的值拉回
    if cpu_active; then cpu_verify || { mlog "看门狗: CPU 频率被改动，重新写入"; cpu_apply || true; }; fi
    if gpu_active; then
        gpu_paused
        if [ -z "$GPU_PAUSE" ]; then gpu_verify || { mlog "看门狗: GPU 频率被改动，重新写入"; gpu_apply || true; }; fi
    fi
    # 亮度守护是一次性长驻子进程。运行期才打开功能时 BRIGHT_PID 为空，
    # 也必须在这里拉起；否则界面显示已开，但没有任何进程写亮度节点。
    if [ -f "$F_BRIGHT" ] && [ ! -f "$BRIGHT_NA" ]; then
        if [ -z "$BRIGHT_PID" ] || ! kill -0 "$BRIGHT_PID" 2>/dev/null; then
            bright_daemon &
            BRIGHT_PID=$!
            mlog "看门狗: 亮度守护已启动"
        fi
    fi
    if [ -z "$WEBUI_PID" ] || ! kill -0 "$WEBUI_PID" 2>/dev/null; then
        webui_loop &
        WEBUI_PID=$!
        DAEMONS="$SEP_PID $WEBUI_PID"
        mlog "看门狗: WebUI 循环已重启"
        continue
    fi
    _age=$(stat_age)
    if [ "$_age" -gt "$WEBUI_STALE_MAX" ] 2>/dev/null; then
        mlog "看门狗: 快照 ${_age}s 未更新，重启 WebUI 循环"
        kill "$WEBUI_PID" 2>/dev/null; sleep 1 2>/dev/null; kill -9 "$WEBUI_PID" 2>/dev/null
        webui_loop &
        WEBUI_PID=$!
        DAEMONS="$SEP_PID $WEBUI_PID"
    fi
done
