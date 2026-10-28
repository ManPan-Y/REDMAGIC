#!/system/bin/sh
# ============================================================
# 充电三件事：分离阈值、充电加速、解除热降流。
# 铁律：先快照后改写，释放时精确还原；每次改写前都过守卫。
# ============================================================

# 温度上限：文件 -> 记忆 -> 42。越界视为文件被写坏，回落默认而不是夹边界
# （夹边界会把交还系统的门槛悄悄抬到 70℃，等于替用户做了危险决定）
BOOST_LIMIT_DEF=42
_in_range() {
    # 空串或非纯数字一律判否：不依赖调用方先过滤，[ "" -ge 20 ] 在部分 shell 下是 UB
    case "$1" in ''|*[!0-9]*) return 1;; esac
    [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null
}
boost_limit() {
    local v
    if [ -f "$BOOST_LIMIT" ]; then
        rd "$BOOST_LIMIT"; v="$RD"
        case "$v" in
            ''|*[!0-9]*) : ;;
            *) _in_range "$v" 20 70 && { printf '%s' "$v"; return 0; } ;;
        esac
    fi
    v=$(stq '充电加速温度上限')
    case "$v" in
        ''|*[!0-9]*) : ;;
        *) _in_range "$v" 20 70 && { printf '%s' "$v"; return 0; } ;;
    esac
    printf '%s' "$BOOST_LIMIT_DEF"
}

# 分离阈值：文件 -> 记忆 -> 100
sep_limit() {
    local v
    if [ -f "$SEP_LIMIT" ]; then
        rd "$SEP_LIMIT"; v="$RD"
        case "$v" in
            ''|*[!0-9]*) : ;;
            *) _in_range "$v" 20 100 && { printf '%s' "$v"; return 0; } ;;
        esac
    fi
    v=$(stq '充电分离阈值')
    case "$v" in
        ''|*[!0-9]*) : ;;
        *) _in_range "$v" 20 100 && { printf '%s' "$v"; return 0; } ;;
    esac
    printf '100'
}

# 系统分离开关（同一秒内复用，sep_init 清缓存）
SEP_AT=""
SEP_VAL=""
sep_init() { SEP_AT=""; SEP_VAL=""; }
sep_store() { case "$1" in 0|1) printf '%s\n' "$1" > "$SEP_CACHE" 2>/dev/null ;; esac; }
sep_now() {
    local t
    t=$(date +%s 2>/dev/null)
    if [ "$SEP_AT" = "$t" ] && [ -n "$SEP_VAL" ]; then
        printf '%s' "$SEP_VAL"
        return 0
    fi
    SEP_AT="$t"
    SEP_VAL=$(stgq get global charge_separation_switch 2>/dev/null)
    case "$SEP_VAL" in 0|1) ;; *) SEP_VAL="0";; esac
    sep_store "$SEP_VAL"
    printf '%s' "$SEP_VAL"
}

# 当前应该处于的分离状态：功能开着、插着电、且电量到阈值才是 1。
# 巡逻和前端命令共用这一处判定，避免两边口径漂移。
charge_sep_want() {
    local cap=0
    [ -f "$F_CHARGE" ] || { printf '0'; return 0; }
    [ "$(rdv "$AC_ONLINE" 2>/dev/null)" = "1" ] || { printf '0'; return 0; }
    cap=$(battery_capacity) || cap=0
    if [ "$cap" -ge "$(sep_limit)" ] 2>/dev/null; then printf '1'; else printf '0'; fi
}

# 写系统开关并立刻更新快照缓存，前端下一轮不用等巡逻。
# settings 写失败返回非 0，调用方据此 errlog，不让失败静默。
charge_sep_set() {
    local rc=0
    stg put global charge_separation_switch "$1" >/dev/null 2>&1 || rc=1
    sep_store "$1"
    sep_init
    return "$rc"
}

# 写充电节点。成功时静默返回 0；失败才把原因吐出来（调用点常用 a && b，成功不该冒出文字）
chg_set() {  # chg_set NODE VALUE
    local n="$CHG_DIR/$1"
    [ -e "$n" ] || { echo "节点不存在: $n"; return 1; }
    printf '%s\n' "$2" > "$n" 2>/dev/null && return 0
    su 2000 -c "printf '%s\n' '$2' > '$n'" 2>/dev/null && return 0
    echo "写入失败: $n = $2"
    return 1
}
CHG_RD=""
# chg_rd 只写全局 CHG_RD（不在 stdout 冒值，否则会混进状态快照）；
# 需要取值的调用方用 chg_val。
chg_rd() { CHG_RD=""; rd "$CHG_DIR/$1" || return 1; CHG_RD="$RD"; return 0; }
chg_val() { chg_rd "$1" && printf '%s' "$CHG_RD"; }

# ---------------- 充电加速 ----------------
# 守卫：全过才允许解除限流
boost_guard() {
    local t lim end cap
    [ -e "$CHG_DIR/restrict_cur" ] || return 1
    thermal_effective || return 1
    # 没插电就没有“充电加速”这回事，别在电池供电时白解除限流
    [ "$(rdv "$AC_ONLINE")" = "1" ] || return 1
    [ "$(sep_now)" = "1" ] && return 1
    chg_rd charging_enabled; [ "$CHG_RD" = "0" ] && return 1
    chg_rd battery_charging_enabled; [ "$CHG_RD" = "0" ] && return 1
    t=$(battery_temp_deg) || return 1
    lim=$(boost_limit)
    [ "$t" -ge "$lim" ] 2>/dev/null && return 1
    chg_rd charge_control_en
    if [ "$CHG_RD" = "1" ]; then
        end=$(chg_val charge_control_end_threshold)
        cap=$(battery_capacity) || cap=""
        [ -n "$end" ] && [ -n "$cap" ] && [ "$cap" -ge "$end" ] 2>/dev/null && return 1
    fi
    return 0
}

# 加速是否真的生效：不只看开关，还要看节点确实被写成了 0。
# 前端 boost_ready 和自检都按这个口径，避免“开关开着但限流还在”。
boost_effective() {
    [ -f "$F_BOOST" ] || return 1
    thermal_effective || return 1
    chg_rd restrict_cur || return 1
    [ "$CHG_RD" = "0" ] || return 1
    chg_rd restrict_chg || return 1
    [ "$CHG_RD" = "0" ] || return 1
    return 0
}

boost_apply() {
    local v
    if [ ! -f "$SNAP_BOOST" ]; then
        : > "$SNAP_BOOST" 2>/dev/null || { errlog "充电加速: 无法创建快照"; return 1; }
        snap_node "$SNAP_BOOST" b_rc "$CHG_DIR/restrict_cur"
        snap_node "$SNAP_BOOST" b_rg "$CHG_DIR/restrict_chg"
        snap_node "$SNAP_BOOST" b_ch "$CHG_DIR/charging_enabled"
        snap_node "$SNAP_BOOST" b_ce "$CHG_DIR/charge_control_en"
        snap_node "$SNAP_BOOST" b_bc "$CHG_DIR/battery_charging_enabled"
        snap_node "$SNAP_BOOST" b_sc "$CHG_DIR/step_charging_enable"
    fi
    # reconcile 每 3 秒会再进来一次，已经是目标值就不重复写
    chg_rd restrict_cur
    if [ "$CHG_RD" != "0" ] && ! chg_set restrict_cur 0; then
        errlog "充电加速: restrict_cur 写入失败"; return 1
    fi
    chg_rd restrict_chg
    if [ "$CHG_RD" != "0" ] && ! chg_set restrict_chg 0; then
        errlog "充电加速: restrict_chg 写入失败"; return 1
    fi
    chg_rd charging_enabled
    if [ "$CHG_RD" != "1" ] && ! chg_set charging_enabled 1; then
        errlog "充电加速: charging_enabled 写入失败"; return 1
    fi
    # 个别固件解除限流时会顺手关掉这个开关，发现关着就补开；
    # 原值原权限在快照里，释放时精确写回，不和 1/644 绑定。
    chg_rd battery_charging_enabled
    if [ "$CHG_RD" = "0" ]; then
        chg_set battery_charging_enabled 1 || { errlog "充电加速: battery_charging_enabled 写入失败"; return 1; }
    fi
    boost_effective || { errlog "充电加速: 写入后回读未生效"; return 1; }
    mlog "充电加速: 解除限流（上限 $(boost_limit)℃）"
    return 0
}

# 还原不能只看写入命令的退出码：su 回退链里 chmod 成功会掩盖写失败。
# 写完必须回读，值不一致就保留快照，下一轮还能继续还原。
_restore_num() {   # NODE VALUE MODE
    node_write_su "$1" "$2" "$3" || return 1
    rd "$1" || return 1
    [ "$RD" = "$2" ]
}

boost_release() {
    local v m rc=0
    [ -f "$SNAP_BOOST" ] || return 0
    # 逐项按快照精确还原：值、权限都取接管前的原始状态。
    # 这里不再调用 heat_release —— 解除热降流是独立功能，关加速不能连带关掉它。
    v=$(snap_get "$SNAP_BOOST" b_rc_v); m=$(snap_get "$SNAP_BOOST" b_rc_mode)
    case "$v" in ''|*[!0-9]*) [ -e "$CHG_DIR/restrict_cur" ] && rc=1 ;; *) _restore_num "$CHG_DIR/restrict_cur" "$v" "$m" || rc=1 ;; esac
    v=$(snap_get "$SNAP_BOOST" b_rg_v); m=$(snap_get "$SNAP_BOOST" b_rg_mode)
    case "$v" in ''|*[!0-9]*) [ -e "$CHG_DIR/restrict_chg" ] && rc=1 ;; *) _restore_num "$CHG_DIR/restrict_chg" "$v" "$m" || rc=1 ;; esac
    v=$(snap_get "$SNAP_BOOST" b_ch_v); m=$(snap_get "$SNAP_BOOST" b_ch_mode)
    case "$v" in 0|1) _restore_num "$CHG_DIR/charging_enabled" "$v" "$m" || rc=1 ;; '') [ -e "$CHG_DIR/charging_enabled" ] && rc=1 ;; *) rc=1 ;; esac
    v=$(snap_get "$SNAP_BOOST" b_bc_v); m=$(snap_get "$SNAP_BOOST" b_bc_mode)
    case "$v" in 0|1) _restore_num "$CHG_DIR/battery_charging_enabled" "$v" "$m" || rc=1 ;; '') [ -e "$CHG_DIR/battery_charging_enabled" ] && rc=1 ;; *) rc=1 ;; esac
    v=$(snap_get "$SNAP_BOOST" b_ce_v); m=$(snap_get "$SNAP_BOOST" b_ce_mode)
    case "$v" in 0|1) _restore_num "$CHG_DIR/charge_control_en" "$v" "$m" || rc=1 ;; '') [ -e "$CHG_DIR/charge_control_en" ] && rc=1 ;; *) rc=1 ;; esac
    v=$(snap_get "$SNAP_BOOST" b_sc_v); m=$(snap_get "$SNAP_BOOST" b_sc_mode)
    case "$v" in 0|1) _restore_num "$CHG_DIR/step_charging_enable" "$v" "$m" || rc=1 ;; '') [ -e "$CHG_DIR/step_charging_enable" ] && rc=1 ;; *) rc=1 ;; esac
    if [ "$rc" -ne 0 ]; then
        errlog "充电加速: 还原失败，保留快照供下轮重试"
        return 1
    fi
    rm -f "$SNAP_BOOST" 2>/dev/null
    mlog "充电加速: 已还原限流"
    return 0
}

# ---------------- 熄屏提速（亮屏充电伪装熄屏） ----------------
# 亮屏充电时充电模组会按“亮屏”收紧输入功率；这里只在给充电模组看的状态上
# 写成 0（熄屏），系统亮度、显示、电源管理完全不变。
# 条件一旦失效（息屏、拔电、充电分离、超温）立刻写回真实亮屏状态。
fast_guard() {
    local t
    [ -e "$CHG_SCREEN_ON" ] || return 1
    [ -f "$F_FAST" ] || return 1
    [ "$(screen_state)" = "awake" ] || return 1
    [ "$(rdv "$AC_ONLINE" 2>/dev/null)" = "1" ] || return 1
    [ "$(sep_now)" = "1" ] && return 1
    t=$(battery_temp_deg) || return 1
    [ "$t" -ge "$(boost_limit)" ] 2>/dev/null && return 1
    return 0
}
fast_read_sio() {
    local v
    v=$(rdv "$CHG_SCREEN_ON" 2>/dev/null)
    case "$v" in 0|1) printf '%s' "$v"; return 0;; esac
    return 1
}
# 只在状态真正切换时写日志，reconcile 每 3 秒调用也不会刷屏
fast_mark() {
    [ "$(cat "$FAST_MARK" 2>/dev/null)" = "$1" ] && return 0
    printf '%s\n' "$1" > "$FAST_MARK" 2>/dev/null
    [ -n "$2" ] && mlog "$2"
    return 0
}
fast_effective() {
    [ -f "$F_FAST" ] || return 1
    [ "$(fast_read_sio 2>/dev/null)" = "0" ] || return 1
    [ "$(screen_state)" = "awake" ] || return 1
    return 0
}
fast_apply() {
    local cur
    [ -e "$CHG_SCREEN_ON" ] || return 1
    if ! fast_guard; then
        fast_release
        return 1
    fi
    cur=$(fast_read_sio) || return 1
    if [ "$cur" != "0" ]; then
        chg_set screen_is_on 0 >/dev/null 2>&1 || { errlog "熄屏提速: screen_is_on 写入失败"; return 1; }
        [ "$(fast_read_sio 2>/dev/null)" = "0" ] || { errlog "熄屏提速: screen_is_on 回读不符"; return 1; }
    fi
    fast_mark on "熄屏提速: 充电模组已按熄屏处理（screen_is_on=0），显示亮度不变"
    return 0
}
# 还原真实亮屏状态。没开过提速（标记文件不存在）就不碰节点，避免开机多写一次。
fast_release() {
    local real cur prev
    [ -e "$CHG_SCREEN_ON" ] || return 0
    prev=$(cat "$FAST_MARK" 2>/dev/null)
    [ -n "$prev" ] || [ -f "$F_FAST" ] || return 0
    # 电源状态读不到时宁可不写：猜错会把“亮屏”写给熄屏中的充电模组
    case "$(screen_state)" in
        asleep) real=0 ;;
        awake)  real=1 ;;
        *) return 0 ;;
    esac
    cur=$(fast_read_sio 2>/dev/null) || return 0
    if [ "$cur" != "$real" ]; then
        chg_set screen_is_on "$real" >/dev/null 2>&1 || { errlog "熄屏提速: 还原真实亮屏状态失败"; return 1; }
        [ "$(fast_read_sio 2>/dev/null)" = "$real" ] || { errlog "熄屏提速: 还原回读不符"; return 1; }
    fi
    # 已与真实状态一致：删掉标记，reconcile 之后不再白跑；只在从“生效中”退回时记一行
    rm -f "$FAST_MARK" 2>/dev/null
    [ "$prev" = "on" ] && mlog "熄屏提速: 已还原真实亮屏状态"
    return 0
}

# ---------------- 解除热降流 ----------------
heat_find() {
    local d
    if [ -n "$CHG_HEAT_CDEV" ]; then printf '%s' "$CHG_HEAT_CDEV"; return 0; fi
    [ -n "$CHG_HEAT_NOCDEV" ] && return 1
    for d in "$CDEV_DIR"/cooling_device*; do
        [ -e "$d/type" ] || continue
        rd "$d/type" || continue
        case "$RD" in
            *battery*|*BATTERY*|*Batt*) [ -e "$d/cur_state" ] && { CHG_HEAT_CDEV="$d"; printf '%s' "$d"; return 0; } ;;
        esac
    done
    CHG_HEAT_NOCDEV=1
    return 1
}
heat_apply() {
    local d cur
    d=$(heat_find) || return 1
    if [ ! -f "$SNAP_HEAT" ]; then
        : > "$SNAP_HEAT" 2>/dev/null
        snap_node "$SNAP_HEAT" h_cs "$d/cur_state"
    fi
    cur=$(rdv "$d/cur_state" 2>/dev/null)
    [ "$cur" = "0" ] && return 0
    node_write_su "$d/cur_state" 0 "$(snap_get "$SNAP_HEAT" h_cs_mode)"
}
heat_release() {
    local d v m
    [ -f "$SNAP_HEAT" ] || return 0
    d=$(heat_find)
    if [ -n "$d" ]; then
        v=$(snap_get "$SNAP_HEAT" h_cs_v)
        m=$(snap_get "$SNAP_HEAT" h_cs_mode)
        case "$v" in
            ''|*[!0-9]*)
                errlog "解除热降流: 快照值无效，保留快照"
                return 1
                ;;
            *)
                _restore_num "$d/cur_state" "$v" "$m" || {
                    errlog "解除热降流: 还原失败，保留快照供下轮重试"
                    return 1
                }
                ;;
        esac
    fi
    rm -f "$SNAP_HEAT" 2>/dev/null
    return 0
}
