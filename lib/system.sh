#!/system/bin/sh
# ============================================================
# 系统级原语：写受保护节点并精确还原权限、屏幕状态、电池读数。
# 铁律：任何一次放宽权限，必须在同一个函数里立刻收回。
# ============================================================

# 快照一个节点的原值与原权限，追加到快照文件
# 注意：不能在函数里用 local 声明叫 v/m 之外的通用名，但更不能把 printf 拆成多行 ——
# printf 的参数必须和格式串在同一条语句里，跨行写会只输出半行（踩过）。
snap_node() {   # snap_node SNAPFILE KEY NODE
    local f="$1" k="$2" n="$3" val md
    [ -e "$n" ] || return 0
    rd "$n"; val="$RD"
    md=$(stat -c %a "$n" 2>/dev/null)
    printf '%s_v=%s\n%s_mode=%s\n' "$k" "$val" "$k" "$md" >> "$f" 2>/dev/null
}

# 从快照取一个字段
snap_get() {    # snap_get SNAPFILE KEY
    local f="$1" k="$2"
    [ -f "$f" ] || return 1
    grep -o "^$k=.*" "$f" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

# 写节点：若当前权限挡住写入就临时 644，写完无条件还原原权限。
# 返回写入的退出码（不是 chmod 的）。
node_write() {  # node_write NODE VALUE ORIG_MODE
    local n="$1" v="$2" om="$3"
    [ -e "$n" ] || return 1
    case "$om" in ''|*[!0-7]*) om=$(stat -c %a "$n" 2>/dev/null);; esac
    case "$om" in ''|*[!0-7]*) om=444;; esac
    chmod 644 "$n" 2>/dev/null
    printf '%s\n' "$v" > "$n" 2>/dev/null
    local rc=$?
    chmod "$om" "$n" 2>/dev/null
    return $rc
}

# 同上，但节点属 system（风扇 enable 等）：先自己写，不行再 su 2000 代写。
# 无论 su 是否跑完，外层 root 都会按原权限再收一次（双保险）。
node_write_su() {   # node_write_su NODE VALUE ORIG_MODE
    local n="$1" v="$2" om="$3" cur
    [ -e "$n" ] || return 1
    case "$om" in ''|*[!0-7]*) om=$(stat -c %a "$n" 2>/dev/null);; esac
    case "$om" in ''|*[!0-7]*) om=444;; esac
    node_write "$n" "$v" "$om" && return 0
    su 2000 -c "chmod 644 '$n' 2>/dev/null; printf '%s\\n' '$v' > '$n' 2>/dev/null; chmod $om '$n' 2>/dev/null" 2>/dev/null
    local rc=$?
    cur=$(stat -c %a "$n" 2>/dev/null)
    [ "$cur" = "$om" ] || chmod "$om" "$n" 2>/dev/null
    return $rc
}

# ---------------- 屏幕 ----------------
# 每轮只查一次，结果缓存到 SCREEN_AT/SCREEN_VAL
SCREEN_AT=""
SCREEN_VAL=""
screen_state() {
    local t o f
    t=$(date +%s 2>/dev/null)
    if [ -n "$SCREEN_AT" ] && [ "$t" = "$SCREEN_AT" ] && [ -n "$SCREEN_VAL" ]; then
        printf '%s' "$SCREEN_VAL"
        return 0
    fi
    SCREEN_AT="$t"
    SCREEN_VAL=""
    o=$(dumpsys power 2>/dev/null | grep -m1 -E 'mWakefulness=|mScreenOn=')
    case "$o" in
        *mWakefulness=Awake*) SCREEN_VAL="awake" ;;
        *mWakefulness=Asleep*|*mWakefulness=Dozing*) SCREEN_VAL="asleep" ;;
        *mScreenOn=true*) SCREEN_VAL="awake" ;;
        *mScreenOn=false*) SCREEN_VAL="asleep" ;;
    esac
    if [ -z "$SCREEN_VAL" ]; then
        for f in /sys/class/backlight/*/brightness; do
            [ -e "$f" ] || continue
            rd "$f"
            case "$RD" in
                ''|*[!0-9]*) ;;
                0) SCREEN_VAL="asleep" ;;
                *) SCREEN_VAL="awake" ;;
            esac
            [ -z "$SCREEN_VAL" ] || break
        done
    fi
    [ -n "$SCREEN_VAL" ] || SCREEN_VAL="unknown"
    printf '%s' "$SCREEN_VAL"
}

# ---------------- 电池 ----------------
battery_temp_deg() {
    rd "$BAT_DIR/temp" || return 1
    case "$RD" in ''|*[!0-9-]*) return 1;; esac
    echo $((RD / 10))
}

# 皮肤温度（体感）：温区路径由 paths.sh 按 type 找好；读不到就返回 1。
# 温区单位是毫摄氏度（27166 = 27.1℃），和 battery/temp 的 0.1℃ 不同，必须 /1000。
skin_temp_deg() {
    [ -n "$SKIN_TEMP" ] || return 1
    rd "$SKIN_TEMP" || return 1
    case "$RD" in ''|*[!0-9-]*) return 1;; esac
    echo $((RD / 1000))
}

# 温度联动用的控制温度：电池与皮肤取较高者，谁读不到就只用另一个。
# 只散热不动节点，纯粹是选择依据，不参与任何写入。
control_temp_deg() {
    local b="" s=""
    b=$(battery_temp_deg 2>/dev/null) || b=""
    s=$(skin_temp_deg 2>/dev/null) || s=""
    case "$b" in ''|*[!0-9]*) b="" ;; esac
    case "$s" in ''|*[!0-9]*) s="" ;; esac
    if [ -n "$b" ] && [ -n "$s" ]; then
        [ "$s" -gt "$b" ] && printf '%s' "$s" || printf '%s' "$b"
        return 0
    fi
    [ -n "$b" ] && { printf '%s' "$b"; return 0; }
    [ -n "$s" ] && { printf '%s' "$s"; return 0; }
    return 1
}
# ---------------- 写节点让行 ----------------
# 驱动在息屏挂起期间会拒绝参数写入；游戏空间接管时也会改 tp_report_rate。
# 这两种情况下模块一律不写，避免与系统/游戏空间互相覆盖。
# 结果写全局 HW_PAUSE（空 = 可写），返回 0 表示「应该让行」。
HW_PAUSE=""
hw_write_paused() {
    local s us g
    HW_PAUSE=""
    s=$(screen_state)
    [ "$s" = "awake" ] || { HW_PAUSE="screen"; return 0; }
    # suspend 节点的格式是文本 "tp suspend is: 0"，只取最后一个词判断
    us=$(rdv "$TP_DIR/suspend" 2>/dev/null)
    us=${us##* }
    [ "$us" = "1" ] && { HW_PAUSE="suspend"; return 0; }
    g=$(rdv "$TP_DIR/play_game" 2>/dev/null)
    [ "$g" = "1" ] && { HW_PAUSE="game"; return 0; }
    return 1
}
# 让行原因的中文标签，日志与界面统一用它
hw_pause_label() {
    case "$1" in
        screen)  printf '息屏' ;;
        suspend) printf '触控挂起' ;;
        game)    printf '游戏空间接管' ;;
        *)       printf '%s' "$1" ;;
    esac
}

# ---------------- 采样率（硬件节点） ----------------
# NX809J 实测：tp_report_rate 档位 0..4 = 120/180/300/360/720Hz。
# 系统 settings 的 touch_sampling_rate 只是给游戏空间记录的值，改它不会改变硬件，
# 所以这里直接写驱动节点，并快照原档位与 touch_high_perf_en 原值。
RATE_LEVELS="120 180 300 360 720"
RATE_MAX_HZ=720
RATE_FALLBACK=720

RATE_LEVEL_HZ=""
rate_level_hz() {   # LEVEL -> RATE_LEVEL_HZ
    local i=0 hz
    RATE_LEVEL_HZ=""
    for hz in $RATE_LEVELS; do
        [ "$i" = "$1" ] && { RATE_LEVEL_HZ=$hz; return 0; }
        i=$((i + 1))
    done
    return 1
}
# HZ -> 不超过 HZ 的最高档位（0..4）
RATE_LEVEL_OF=0
rate_level_of() {
    local i=0 lv=0 hz
    RATE_LEVEL_OF=0
    for hz in $RATE_LEVELS; do
        [ "$hz" -le "$1" ] 2>/dev/null && lv=$i
        i=$((i + 1))
    done
    RATE_LEVEL_OF=$lv
}
rate_hw_level() {   # echo 0..4；节点缺失/值非法返回 1
    local v
    v=$(rdv "$TOUCH_REPORT" 2>/dev/null)
    case "$v" in 0|1|2|3|4) printf '%s' "$v"; return 0;; esac
    return 1
}
rate_current() {   # Hz
    local lv hz
    lv=$(rate_hw_level) || { printf '0'; return 0; }
    rate_level_hz "$lv" || { printf '0'; return 0; }
    hz=$RATE_LEVEL_HZ
    printf '%s' "$hz"
    printf '%s\n' "$hz" > "$RATE_CACHE" 2>/dev/null
    return 0
}
# 目标上限：用户填的 120..720 优先，否则取硬件最高档 720。
rate_target_calc() {
    local u cap
    # 状态已装载时直接用内存值，避免每次核对都 fork grep
    if [ -n "$ST_LOADED" ]; then u=$ST_RCAP; else u=$(stq '采样率上限'); fi
    case "$u" in ''|*[!0-9]*) u="";; esac
    if [ -n "$u" ] && [ "$u" -ge 120 ] 2>/dev/null && [ "$u" -le "$RATE_MAX_HZ" ] 2>/dev/null; then
        cap=$u
    else
        cap=$RATE_MAX_HZ
    fi
    rate_level_of "$cap"
    rate_level_hz "$RATE_LEVEL_OF" || { printf '%s' "$RATE_FALLBACK"; return 0; }
    printf '%s' "$RATE_LEVEL_HZ"
}
rate_target() { rate_target_calc; }
rate_target_level() {
    local t
    t=$(rate_target_calc)
    rate_level_of "$t"
    printf '%s' "$RATE_LEVEL_OF"
}

# 只在状态真正切换时落一行日志，避免看门狗每 15 秒刷屏
rate_mark() {   # MARK LOGTEXT
    [ "$(cat "$RATE_MARK" 2>/dev/null)" = "$1" ] && return 0
    printf '%s\n' "$1" > "$RATE_MARK" 2>/dev/null
    [ -n "$2" ] && mlog "$2"
    return 0
}

_rate_perf_orig() {   # echo 快照里的触摸高性能原值（0/1/-）
    local v
    v=$(grep '^perf=' "$RATE_SNAPSHOT" 2>/dev/null | tail -n 1 | cut -d= -f2-)
    case "$v" in 0|1) printf '%s' "$v";; *) printf '-';; esac
}
_rate_snapshot_save() {
    # 旧版本这里存的是 settings 原值（单行数字/null），升级后直接覆盖成驱动档位
    local lv hp sv snul=""
    if [ -s "$RATE_SNAPSHOT" ] && grep -q '^level=' "$RATE_SNAPSHOT" 2>/dev/null; then
        # 老快照没有 settings 行：补记一次，保证关闭时能把显示值还回去
        if ! grep -q '^samp' "$RATE_SNAPSHOT" 2>/dev/null; then
            _rate_setting_value
            case "$RATE_SET_V" in
                ''|null|Null|NULL) printf 'samp_null=1\n' >> "$RATE_SNAPSHOT" 2>/dev/null ;;
                *[!0-9.]*) ;;
                *) printf 'samp=%s\n' "${RATE_SET_V%%.*}" >> "$RATE_SNAPSHOT" 2>/dev/null ;;
            esac
        fi
        return 0
    fi
    lv=$(rate_hw_level) || return 1
    hp=$(rdv "$TOUCH_HIGH_PERF" 2>/dev/null)
    case "$hp" in 0|1) ;; *) hp=- ;; esac
    _rate_setting_value
    case "$RATE_SET_V" in
        ''|null|Null|NULL) snul=1 ;;
        *[!0-9.]*) snul=1 ;;
        *) sv=${RATE_SET_V%%.*} ;;
    esac
    { printf 'level=%s\nperf=%s\n' "$lv" "$hp"
      if [ -n "$snul" ]; then printf 'samp_null=1\n'; else printf 'samp=%s\n' "$sv"; fi
    } > "$RATE_SNAPSHOT" 2>/dev/null
    [ -s "$RATE_SNAPSHOT" ]
}

# 读系统 settings 里的采样率显示值（只用于显示同步与原值还原）
RATE_SET_V=""
_rate_setting_value() {
    RATE_SET_V=""
    RATE_SET_V=$(stgq get system "$RATE_SETTING_KEY" 2>/dev/null) || return 1
    return 0
}

# 把系统界面显示的采样率同步成最高档。只改显示，不影响驱动档位/功耗。
rate_setting_sync() {
    _rate_setting_value || { errlog "采样率: 读取系统显示值失败"; return 1; }
    [ "$RATE_SET_V" = "$RATE_SETTING_MAX" ] && return 0
    $SETTINGS_TO settings put system "$RATE_SETTING_KEY" "$RATE_SETTING_MAX" >/dev/null 2>&1 || {
        errlog "采样率: 系统显示值写入失败"; return 1; }
    _rate_setting_value
    [ "$RATE_SET_V" = "$RATE_SETTING_MAX" ] || { errlog "采样率: 系统显示值回读不符"; return 1; }
    return 0
}

# 关闭/停服/卸载：把系统显示值还原成接管前的样子（原本 null 就删键）
rate_setting_restore() {
    local nul v
    [ -f "$RATE_SNAPSHOT" ] || return 0
    nul=$(grep -o '^samp_null=1' "$RATE_SNAPSHOT" 2>/dev/null | tail -n 1)
    if [ -n "$nul" ]; then
        $SETTINGS_TO settings delete system "$RATE_SETTING_KEY" >/dev/null 2>&1
        return 0
    fi
    v=$(grep -o '^samp=.*' "$RATE_SNAPSHOT" 2>/dev/null | tail -n 1 | cut -d= -f2-)
    case "$v" in ''|*[!0-9]*) return 0 ;; esac
    $SETTINGS_TO settings put system "$RATE_SETTING_KEY" "$v" >/dev/null 2>&1
    return 0
}

# 触摸高性能模式：驱动层面的额外开关（实测可写 0/1），采样率拉满时一并打开
rate_high_perf_on() {
    [ -e "$TOUCH_HIGH_PERF" ] || return 0
    [ "$(rdv "$TOUCH_HIGH_PERF" 2>/dev/null)" = "1" ] && return 0
    printf '1\n' > "$TOUCH_HIGH_PERF" 2>/dev/null || { errlog "采样率: touch_high_perf_en 写入失败"; return 1; }
    [ "$(rdv "$TOUCH_HIGH_PERF" 2>/dev/null)" = "1" ] || { errlog "采样率: touch_high_perf_en 回读不符"; return 1; }
    return 0
}

# 硬件是否真的吃下了这次写入：回读只是驱动缓存的变量，
# 挂起状态下写入会被拒绝但回读照样变成新值，所以还要看驱动日志。
rate_confirm() {   # LEVEL -> 0 驱动确认 / 1 驱动明确拒绝 / 2 无法判断
    local last
    last=$(dmesg 2>/dev/null | grep -E 'tpd_set_tp_report_rate|syna_dev_set_tp_report_rate' | tail -n 1)
    case "$last" in
        *'success in'*) return 0 ;;
        *'suspend'*) return 1 ;;
    esac
    return 2
}
# 真正写一次档位并核对；成功记下已生效档位供 rate_verify 比对
rate_write_level() {   # LEVEL -> 0 生效 / 1 失败 / 2 驱动暂拒（挂起）
    local lv="$1" rc
    printf '%s\n' "$lv" > "$TOUCH_REPORT" 2>/dev/null || return 1
    [ "$(rate_hw_level 2>/dev/null)" = "$lv" ] || return 1
    rate_confirm
    rc=$?
    [ "$rc" = "1" ] && return 2
    # rc=2（读不到 dmesg）时退回信任回读值
    printf '%s\n' "$lv" > "$RATE_APPLIED" 2>/dev/null
    return 0
}
_rate_applied() { cat "$RATE_APPLIED" 2>/dev/null; }

rate_boost_on() {
    local tgt cur rc
    [ -e "$TOUCH_REPORT" ] || { errlog "采样率: tp_report_rate 不存在"; return 1; }
    if hw_write_paused; then
        rate_mark "pause:$HW_PAUSE" "采样率: $(hw_pause_label "$HW_PAUSE")期间让行，不写驱动（避免与系统/游戏空间冲突）"
        return 2
    fi
    _rate_snapshot_save || { errlog "采样率: 读取原始档位失败"; return 1; }
    tgt=$(rate_target_level)
    cur=$(rate_hw_level) || cur=""
    if [ "$cur" != "$tgt" ] || [ "$(_rate_applied)" != "$tgt" ]; then
        rate_write_level "$tgt"
        rc=$?
        if [ "$rc" = "1" ]; then
            errlog "采样率: 写入档位 $tgt 失败"
            return 1
        elif [ "$rc" = "2" ]; then
            # 驱动认为在挂起中：不报错也不回滚，交给下一步的核对重试
            rate_mark "defer:$tgt" "采样率: 驱动暂拒写入（挂起中），稍后自动重试"
            return 2
        fi
        rate_level_hz "$tgt"
        rate_mark "on:$tgt" "采样率: 驱动档位 $tgt → ${RATE_LEVEL_HZ}Hz"
    fi
    rate_high_perf_on || return 1
    # 系统界面上的「全局采样率」同步成最高档（只改显示；失败不阻断硬件档位）
    rate_setting_sync || true
    return 0
}

# 开机时触控驱动可能还没就绪，重试若干次（放后台，不阻塞开机）
rate_boost_boot() {
    local i=1 rc
    while [ "$i" -le 8 ]; do
        rate_boost_on
        rc=$?
        [ "$rc" = "0" ] && return 0
        sleep 2
        i=$((i + 1))
    done
    return 1
}

rate_boost_off() {
    local lv hp rc
    [ -f "$RATE_SNAPSHOT" ] || return 0
    lv=$(grep '^level=' "$RATE_SNAPSHOT" 2>/dev/null | tail -n 1 | cut -d= -f2-)
    case "$lv" in 0|1|2|3|4) ;; *) rm -f "$RATE_SNAPSHOT" 2>/dev/null; return 0;; esac
    # 息屏挂起时驱动拒绝写入：保留快照，等亮屏后 reconcile 继续还原
    if hw_write_paused; then
        mlog "采样率: $(hw_pause_label "$HW_PAUSE")期间，还原将延后"
        return 2
    fi
    rate_write_level "$lv"
    rc=$?
    [ "$rc" = "1" ] && { errlog "采样率: 还原档位失败，保留快照"; return 1; }
    [ "$rc" = "2" ] && { mlog "采样率: 驱动暂拒还原，稍后重试"; return 2; }
    hp=$(_rate_perf_orig)
    case "$hp" in
        0|1) [ "$(rdv "$TOUCH_HIGH_PERF" 2>/dev/null)" = "$hp" ] || printf '%s\n' "$hp" > "$TOUCH_HIGH_PERF" 2>/dev/null ;;
    esac
    rate_setting_restore
    rm -f "$RATE_SNAPSHOT" "$RATE_APPLIED" 2>/dev/null
    rate_mark "off" "采样率: 已还原驱动原档位"
    rate_current >/dev/null 2>&1
    return 0
}

# 停服/卸载专用：这是最后一次还原机会，没人会再来补，
# 所以无视让行硬写一次；写不进去（驱动挂起拒绝）就保留快照，绝不丢原始基线。
rate_force_restore() {
    local lv hp
    [ -f "$RATE_SNAPSHOT" ] || return 0
    lv=$(grep '^level=' "$RATE_SNAPSHOT" 2>/dev/null | tail -n 1 | cut -d= -f2-)
    case "$lv" in
        ''|*[!0-9]*) rm -f "$RATE_SNAPSHOT" 2>/dev/null; return 0 ;;
    esac
    if [ -e "$TOUCH_REPORT" ]; then
        rate_write_level "$lv" || return 1
    fi
    hp=$(_rate_perf_orig)
    case "$hp" in
        0|1) [ -e "$TOUCH_HIGH_PERF" ] && printf '%s\n' "$hp" > "$TOUCH_HIGH_PERF" 2>/dev/null ;;
    esac
    rate_setting_restore
    rm -f "$RATE_SNAPSHOT" "$RATE_APPLIED" 2>/dev/null
    return 0
}

rate_verify() {
    local tgt cur
    hw_write_paused && return 0   # 让行期间不做核对，亮屏/退出游戏后 reconcile 会补
    [ -e "$TOUCH_REPORT" ] || return 1
    tgt=$(rate_target_level)
    cur=$(rate_hw_level) || return 1
    [ "$cur" = "$tgt" ] || return 1
    # 回读只代表驱动缓存：必须还有一次驱动确认过的写入记录
    [ "$(_rate_applied)" = "$tgt" ] || return 1
    if [ -e "$TOUCH_HIGH_PERF" ] && [ "$(rdv "$TOUCH_HIGH_PERF" 2>/dev/null)" != "1" ]; then
        return 1
    fi
    return 0
}

battery_capacity() {
    rd "$BAT_DIR/capacity" || return 1
    case "$RD" in ''|*[!0-9]*) return 1;; esac
    printf '%s' "$RD"
}

# ---------------- 电池健康 ----------------
# 全部只读；读不到就返回非 0，状态快照据此省略对应字段，绝不猜值。

# 健康度百分比（soh 单位是 0.01%，8900 → 89%）
battery_soh_pct() {
    rd "$BAT_SOH" || return 1
    case "$RD" in ''|*[!0-9]*) return 1;; esac
    printf '%s' $(( RD / 100 ))
}

# 循环次数
battery_cycle() {
    rd "$BAT_CYCLE" || return 1
    case "$RD" in ''|*[!0-9]*) return 1;; esac
    printf '%s' "$RD"
}

# 当前满充容量（μAh → mAh）
battery_full_mah() {
    rd "$BAT_FULL" || return 1
    case "$RD" in ''|*[!0-9]*) return 1;; esac
    printf '%s' $(( RD / 1000 ))
}

# 设计满充容量（μAh → mAh）
battery_full_design_mah() {
    rd "$BAT_FULL_DESIGN" || return 1
    case "$RD" in ''|*[!0-9]*) return 1;; esac
    printf '%s' $(( RD / 1000 ))
}

# 内阻（μΩ → mΩ，一位小数）：73534 μΩ = 73.5 mΩ
battery_resistance_mohm() {
    rd "$BAT_RES" || return 1
    case "$RD" in ''|*[!0-9]*) return 1;; esac
    local t
    t=$(( RD / 100 ))   # 0.1 mΩ 单位
    printf '%s.%s' "$(( t / 10 ))" "$(( t % 10 ))"
}
