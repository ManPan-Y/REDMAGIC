#!/system/bin/sh
# ============================================================
# 全部路径常量的唯一来源。改动节点位置只需改这里。
# 被 service.sh / uninstall.sh / lib/*.sh 共同 source。
# ============================================================

MODDIR=${MODDIR:-/data/adb/modules/REDMAGIC}
NL='
'
TAB='	'

# ---------------- 运行期目录 ----------------
# 运行期产生的一切（记忆、开关、快照、队列、日志、PID）都收进 run/，
# 模块根目录只留代码 / 配置 / 前端。这样目录永远整洁，卸载时删一个目录即可。
RUN_DIR="$MODDIR/run"
[ -d "$RUN_DIR" ] || mkdir -p "$RUN_DIR" 2>/dev/null

# ---------------- WebUI 数据契约 ----------------
# 命令队列：每行一个 {"action":"...","value":"..."}，由 webui 前端追加、loop.sh 消费
WEBUI_CMD="$RUN_DIR/webui_cmd"
# 状态快照：一份扁平 JSON，前端每 500ms 读一次
WEBUI_STATUS="$RUN_DIR/webui_status"
# 前端心跳：ksu 一打开 WebUI 就会 touch，进程退出后自然变旧
WEBUI_HB="$RUN_DIR/.webui_hb"
# 「本进程确实产出过快照」的门控标记：没有它就不判心跳，避免开机首轮误报
WEBUI_HB_SEEN="$RUN_DIR/.hb_seen"

# ---------------- 用户记忆 ----------------
STATE_FILE="$RUN_DIR/state.txt"
# config.txt 是随模块分发的默认值模板，留在根目录（只读，不写）
CONFIG_FILE="$MODDIR/config.txt"

# ---------------- 功能开关（标记文件存在 = 开）----------------
F_FAN="$RUN_DIR/auto_fan"
F_PUMP="$RUN_DIR/auto_pump"
F_CHARGE="$RUN_DIR/auto_charge"
# 温控屏蔽自己的标记：以前错用 auto_charge，把「充电分离」和「温控屏蔽」绑死在同一面旗上
F_THERMAL="$RUN_DIR/auto_thermal"
F_TOUCH="$RUN_DIR/auto_touch"
F_BOOST="$RUN_DIR/auto_chargeboost"
F_BRIGHT="$RUN_DIR/auto_brightness"
F_RATE="$RUN_DIR/auto_rate"
# 熄屏充电提速：亮屏充电时把 screen_is_on 伪装成 0，让充电模组按熄屏策略放行功率
F_FAST="$RUN_DIR/auto_fastcharge"
# 子选项
F_BOOST_HEAT="$RUN_DIR/auto_chargeboost_heat"
F_FAN_KEEP="$RUN_DIR/auto_fan_screen_off"
F_PUMP_KEEP="$RUN_DIR/auto_pump_screen_off"
F_FAN_TEMP="$RUN_DIR/auto_fan_temp"
F_PUMP_TEMP="$RUN_DIR/auto_pump_temp"

# ---------------- 用户数值 ----------------
# 充电分离阈值（%）：达到即把系统充电分离开关置 1
SEP_LIMIT="$RUN_DIR/sep_limit"
# 充电加速温度上限（℃）：到此温度就恢复限流
BOOST_LIMIT="$RUN_DIR/boost_limit"
# 触控自定义快照（manual|k=v;k=v;...）：目前只由 teardown 在卸载时清理
TOUCH_SNAPSHOT="$RUN_DIR/touch_snapshot.txt"
# 触控可用性：读不出原始值（快照缺项）的项按行列出；回滚明细 name=value 按行列出
TOUCH_NA="$RUN_DIR/touch_na.txt"
TOUCH_RB="$RUN_DIR/touch_rollback.txt"
# 暂缓项：写入/回读不符、但记忆值必须保留的项；verify 跳过它们，避免看门狗空转
TOUCH_DEFER="$RUN_DIR/touch_defer.txt"

# ---------------- 接管快照（存在 = 接管中，内含原值原权限）----------------
SNAP_FAN="$RUN_DIR/.snap_fan"
SNAP_PUMP="$RUN_DIR/.snap_pump"
SNAP_BOOST="$RUN_DIR/.snap_boost"
SNAP_CFREQ="$RUN_DIR/.snap_cfreq"
SNAP_HEAT="$RUN_DIR/.snap_heat"
# 息屏保持接管 enable 时的原值原权限
SNAP_FAN_KEEP="$RUN_DIR/.snap_fan_keep"
SNAP_PUMP_KEEP="$RUN_DIR/.snap_pump_keep"
# 采样率接管前的驱动档位与触摸高性能原值（level=/perf= 两行）
RATE_SNAPSHOT="$RUN_DIR/.rate_orig"
# 驱动确认过的已生效档位：回读值在挂起时会“假装”变化，核对必须看这一份
RATE_APPLIED="$RUN_DIR/.rate_applied"
# 状态变化标记：只在状态真正切换时写日志，避免每轮刷屏
RATE_MARK="$RUN_DIR/.rate_state"
FAST_MARK="$RUN_DIR/.fast_state"
TOUCH_MARK="$RUN_DIR/.touch_state"
# CPU 频率接管前的各簇上下限（路径|最低|最高 按行）
SNAP_CPU="$RUN_DIR/.snap_cpu"
# GPU 接管前的 max_pwrlevel / min_pwrlevel
SNAP_GPU="$RUN_DIR/.snap_gpu"
# 状态变化标记：只在真正切换时记日志
CPU_MARK="$RUN_DIR/.cpu_state"
GPU_MARK="$RUN_DIR/.gpu_state"
# 运行期缓存：避免状态快照每次都 fork settings
SEP_CACHE="$RUN_DIR/.sep_state"
RATE_CACHE="$RUN_DIR/.rate_cur"

# ---------------- 运行期 ----------------
# 日志只有一份：每次开机重写，运行期超限从尾部截断（不再有 .prev / .last_error）
LOG_FILE="$RUN_DIR/REDMAGIC.log"
SVC_PID_FILE="$RUN_DIR/.svc_pid"
SVC_LOCK_FILE="$RUN_DIR/.svc_lock"
BRIGHT_NA="$RUN_DIR/.bright_na"

# ---------------- 旧布局迁移 ----------------
# v3.0.8 之前运行期文件散在模块根目录。这里一次性搬进 run/，再清掉瞬态文件。
# 用 run/.migrated 门控，之后每次启动只剩一次文件存在性判断。
_legacy_migrate() {
    [ -f "$RUN_DIR/.migrated" ] && return 0
    local n src
    # 用户状态：搬到 run/（目标已存在时以 run/ 为准，删掉旧的）
    for n in state.txt sep_limit boost_limit touch_snapshot.txt touch_na.txt \
             touch_rollback.txt touch_defer.txt .snap_fan .snap_pump .snap_boost \
             .snap_cfreq .snap_heat .snap_fan_keep .snap_pump_keep .rate_orig \
             .snap_cpu .snap_gpu; do
        src="$MODDIR/$n"
        [ -f "$src" ] || continue
        if [ -e "$RUN_DIR/$n" ]; then
            rm -f "$src" 2>/dev/null
        else
            mv -f "$src" "$RUN_DIR/$n" 2>/dev/null
        fi
    done
    for src in "$MODDIR"/auto_*; do
        [ -f "$src" ] || continue
        n=${src##*/}
        if [ -e "$RUN_DIR/$n" ]; then
            rm -f "$src" 2>/dev/null
        else
            mv -f "$src" "$RUN_DIR/$n" 2>/dev/null
        fi
    done
    # 瞬态文件：旧日志、PID、队列、缓存一律不迁移，直接删
    rm -f "$MODDIR"/REDMAGIC.log "$MODDIR"/REDMAGIC.log.prev "$MODDIR/.last_error" \
          "$MODDIR"/webui_* "$MODDIR"/.webui_* \
          "$MODDIR"/.hb_seen "$MODDIR"/.svc_* "$MODDIR"/.bright_na \
          "$MODDIR"/.sep_* "$MODDIR"/.rate_cur \
          "$MODDIR"/*.tmp "$MODDIR"/state.txt.?????? 2>/dev/null
    : > "$RUN_DIR/.migrated" 2>/dev/null
    return 0
}
_legacy_migrate

# 判活/清理匹配串：各模块入口同名且 PID 会复用，必须匹配模块绝对路径
SVC_DIR="$MODDIR"
case "$SVC_DIR" in
    /*) ;;
    *) SVC_DIR=$( (cd "$MODDIR" 2>/dev/null && pwd) ) ;;
esac
[ -n "$SVC_DIR" ] || SVC_DIR=/data/adb/modules/REDMAGIC
SVC_CMDLINE_PAT="$SVC_DIR/service\.sh"

# ---------------- 内核节点（validate_nodes.sh 逐项强校验）----------------
# 下面这些都能被环境变量覆盖，只为离线自测：测试时把根指到假目录，
# 不会碰真机节点。真机上环境里没有这些变量，取值就是右边的默认值。
# 风扇
FAN_ENABLE=${FAN_ENABLE:-/sys/kernel/fan/fan_enable}
FAN_LEVEL=${FAN_LEVEL:-/sys/kernel/fan/fan_speed_level}
[ -e "$FAN_LEVEL" ] || FAN_LEVEL=/sys/kernel/fan_speed_level
# 液冷
PUMP_DIR=${PUMP_DIR:-/proc/driver/micropump}
PUMP_ENABLE="$PUMP_DIR/enable"
PUMP_FREQ="$PUMP_DIR/freq"
PUMP_SPEED="$PUMP_DIR/speed"
# 触控（procfs 虚拟节点，只在触控驱动就绪后出现）
TP_DIR=${TP_DIR:-/proc/touchscreen}
TOUCH_TABLE="$MODDIR/lib/touch_table.txt"
# 触摸高性能模式开关（0/1）：驱动实测可写，采样率拉满时顺带打开
TOUCH_HIGH_PERF="$TP_DIR/touch_high_perf_en"
# 驱动上报频率档位（0..4 = 120/180/300/360/720Hz；实测写 settings 无效）
TOUCH_REPORT="$TP_DIR/tp_report_rate"
# 系统 settings 里的「触控采样率」显示值（本机默认 1440，表示界面上的最高档）。
# 模块只在采样率接管期间把它同步成最高显示值，不改任何硬件行为，关闭时还原原值。
RATE_SETTING_KEY="touch_sampling_rate"
RATE_SETTING_MAX="1440"
# 触控新增参数（实测可写且回读一致）：
#   rotation_limit_level = 握持/边缘防误触等级 0..3（4 以上被驱动钳到 3）
#   tp_palm_mode         = 手掌抑制 0/1
#   pen_only             = 手写笔模式 0/1
TOUCH_GRIP="$TP_DIR/rotation_limit_level"
TOUCH_PALM="$TP_DIR/tp_palm_mode"
TOUCH_PEN="$TP_DIR/pen_only"
# 只读诊断：IC 型号 / 固件 / 配置版本
TOUCH_INFO="$TP_DIR/ts_information"
# 充电
CHG_DIR=${CHG_DIR:-/sys/class/qcom-battery}
BAT_DIR=${BAT_DIR:-/sys/class/power_supply/battery}
# 充电模组看到的亮屏状态（0/1）：亮屏充电时写 0，充电策略按熄屏放行
CHG_SCREEN_ON="$CHG_DIR/screen_is_on"
# 电池健康（内核直接暴露，只读）：
#   soh          = 健康度 ×100（8900 = 89.00%），qcom 充电 IC 内部维护
#   cycle_count  = 循环次数（power_supply 口径）
#   charge_full / charge_full_design = 当前满充 / 设计满充（μAh），可另算健康度
#   health       = Good/Overheat/Dead…，驱动判定
#   resistance   = 电池内阻（μΩ，73534 = 73.5 mΩ）
BAT_SOH="$CHG_DIR/soh"
BAT_CYCLE="$BAT_DIR/cycle_count"
BAT_FULL="$BAT_DIR/charge_full"
BAT_FULL_DESIGN="$BAT_DIR/charge_full_design"
BAT_RES="$CHG_DIR/resistance"
# 充电器在线：Android 13+ 的 UCSI/PD 架构没有 ac 节点，逐级回退
# （NX809J / Android 16 实测：无 ac，只有 usb/policy/ucsi-source-psy-*）
# 注意：绝不能用 $BAT_DIR/../xxx 这种写法。BAT_DIR 是符号链接，
# shell 的 .. 会沿链接目标解析，落到 .../power_supply/battery-charger/power_supply/ 下，
# 那里没有 ac/policy/ucsi —— 实测三个候选全部 miss，最后只是被兜底救回来。
# 用绝对路径 /sys/class/power_supply/ 才是 class 目录本身。
AC_ONLINE=${AC_ONLINE:-}
if [ -z "$AC_ONLINE" ]; then
    for _c in /sys/class/power_supply/ac/online \
              /sys/class/power_supply/ucsi-source-psy-*/online \
              /sys/class/power_supply/policy/online \
              /sys/class/power_supply/usb/online; do
        for _p in $_c; do
            [ -e "$_p" ] && { AC_ONLINE="$_p"; break 2; }
        done
    done
    [ -n "$AC_ONLINE" ] || AC_ONLINE=/sys/class/power_supply/usb/online
    unset _c _p
fi
# 温控（锁定时用 conf/empty.conf 顶替）
THERMAL_TARGET=${THERMAL_TARGET:-/vendor/etc/thermal-engine.conf}
# 亮度
BL_DIR=${BL_DIR:-/sys/class/backlight}
# 降温设备（解除热降流：把 type=battery 的 cooling_device cur_state 钉 0）
CDEV_DIR=${CDEV_DIR:-/sys/class/thermal}
# GPU 频率（Adreno/KGSL）：频率表在 gpu_available_frequencies（Hz，从高到低），
# 实际由 max_pwrlevel / min_pwrlevel 控制（0 = 最高频）
GPU_DIR=${GPU_DIR:-/sys/class/kgsl/kgsl-3d0}
GPU_AVAIL="$GPU_DIR/gpu_available_frequencies"

# ---------------- 亮度节点（面板名各机型不同）----------------
BL_BRIGHT="$BL_DIR/panel0-backlight/brightness"
BL_MAX="$BL_DIR/panel0-backlight/max_brightness"

# ---------------- 皮肤温度（体感）----------------
# 温区编号各机型不同，按 type 找一次写进常量；读不到就留空，风扇/液冷回退电池温度。
# 用内建 read 代替 cat，95 个温区只花几毫秒。
SKIN_TEMP=""
for _z in /sys/class/thermal/thermal_zone*; do
    [ -r "$_z/type" ] || continue
    _t=""
    IFS= read -r _t 2>/dev/null < "$_z/type"
    [ "$_t" = "skin-msm-therm" ] || continue
    SKIN_TEMP="$_z/temp"
    break
done
unset _z _t
