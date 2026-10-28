#!/system/bin/sh
# ============================================================
# 风扇 / 液冷。
# 分工（历次踩坑后固化的规则）：
#   · 开关（fan_enable / micropump enable）归系统管，模块只在系统已开时写档位。
#   · 唯一例外是「息屏保持」：它必须改 enable，所以先记原值原权限，释放时精确写回；
#     权限只放宽一瞬间，写完立刻收回。
#   · 系统关掉开关时模块暂停接管但保留记忆（state.txt），前端据此显示记忆档位，
#     避免用户设的档位被节点值悄悄抹掉。
# ============================================================

pump_speed_of() {   # 档位 1-4 -> 转速 40/60/80/90
    case "$1" in 1) echo 40;; 2) echo 60;; 3) echo 80;; 4) echo 90;; *) echo "";; esac
}
# 注意：这两个谓词常被写在 $( ) 里（子 shell），所以自己读、不依赖全局 RD
fan_sys_on()  { local v; v=$(rdv "$FAN_ENABLE")  || return 1; [ "$v" = "1" ]; }
pump_sys_on() { local v; v=$(rdv "$PUMP_ENABLE") || return 1; [ "$v" = "1" ]; }

# ---------------- 风扇档位 ----------------
fan_level_write() { # LEVEL
    local lv="$1" m cur
    case "$lv" in 1|2|3|4|5) ;; *) return 1;; esac
    fan_sys_on || return 1
    rd "$FAN_LEVEL"; cur="$RD"
    [ "$cur" = "$lv" ] && return 0
    if [ ! -f "$SNAP_FAN" ]; then
        : > "$SNAP_FAN" 2>/dev/null
        snap_node "$SNAP_FAN" f_lv "$FAN_LEVEL"
    fi
    m=$(snap_get "$SNAP_FAN" f_lv_mode)
    node_write_su "$FAN_LEVEL" "$lv" "$m"
}

fan_level_now() {
    rd "$FAN_LEVEL" || return 1
    case "$RD" in ''|*[!0-9]*) return 1;; esac
    printf '%s' "$RD"
}

# ---------------- 液冷转速 ----------------
pump_speed_write() { # 40|60|80|90
    local sp="$1" m cur
    [ -e "$PUMP_SPEED" ] || return 1
    pump_sys_on || return 1
    rd "$PUMP_SPEED"; cur="$RD"
    [ "$cur" = "$sp" ] && return 0
    if [ ! -f "$SNAP_PUMP" ]; then
        : > "$SNAP_PUMP" 2>/dev/null
        snap_node "$SNAP_PUMP" p_fq "$PUMP_FREQ"
        snap_node "$SNAP_PUMP" p_sp "$PUMP_SPEED"
    fi
    m=$(snap_get "$SNAP_PUMP" p_sp_mode)
    node_write_su "$PUMP_SPEED" "$sp" "$m"
}

pump_level_now() {
    rd "$PUMP_SPEED" || return 1
    case "$RD" in 40) echo 1;; 60) echo 2;; 80) echo 3;; 90) echo 4;; *) echo "";; esac
}

# ---------------- 息屏保持：唯一会写 enable 的路径 ----------------
fan_keep_set() { # 0|1
    local m cur
    rd "$FAN_ENABLE"; cur="$RD"
    [ "$cur" = "$1" ] && return 0
    [ -f "$SNAP_FAN_KEEP" ] || { : > "$SNAP_FAN_KEEP" 2>/dev/null; snap_node "$SNAP_FAN_KEEP" en "$FAN_ENABLE"; }
    m=$(snap_get "$SNAP_FAN_KEEP" en_mode)
    node_write_su "$FAN_ENABLE" "$1" "$m"
}
pump_keep_set() { # 0|1
    local m cur
    rd "$PUMP_ENABLE"; cur="$RD"
    [ "$cur" = "$1" ] && return 0
    [ -f "$SNAP_PUMP_KEEP" ] || { : > "$SNAP_PUMP_KEEP" 2>/dev/null; snap_node "$SNAP_PUMP_KEEP" en "$PUMP_ENABLE"; }
    m=$(snap_get "$SNAP_PUMP_KEEP" en_mode)
    node_write_su "$PUMP_ENABLE" "$1" "$m"
}

# 释放：把 enable 写回接管前的原值，删快照
fan_keep_stop() {
    local v m
    [ -f "$SNAP_FAN_KEEP" ] || return 0
    v=$(snap_get "$SNAP_FAN_KEEP" en_v)
    m=$(snap_get "$SNAP_FAN_KEEP" en_mode)
    case "$v" in 0|1) node_write_su "$FAN_ENABLE" "$v" "$m" ;; esac
    rm -f "$SNAP_FAN_KEEP" 2>/dev/null
    return 0
}
pump_keep_stop() {
    local v m
    [ -f "$SNAP_PUMP_KEEP" ] || return 0
    v=$(snap_get "$SNAP_PUMP_KEEP" en_v)
    m=$(snap_get "$SNAP_PUMP_KEEP" en_mode)
    case "$v" in 0|1) node_write_su "$PUMP_ENABLE" "$v" "$m" ;; esac
    rm -f "$SNAP_PUMP_KEEP" 2>/dev/null
    return 0
}

fan_release() {
    local v m
    fan_keep_stop
    if [ -f "$SNAP_FAN" ]; then
        v=$(snap_get "$SNAP_FAN" f_lv_v)
        m=$(snap_get "$SNAP_FAN" f_lv_mode)
        case "$v" in ''|*[!0-9]*) ;; *) node_write_su "$FAN_LEVEL" "$v" "$m" ;; esac
        rm -f "$SNAP_FAN" 2>/dev/null
    fi
    return 0
}
pump_release() {
    local v m fq fm
    pump_keep_stop
    if [ -f "$SNAP_PUMP" ]; then
        v=$(snap_get "$SNAP_PUMP" p_sp_v)
        m=$(snap_get "$SNAP_PUMP" p_sp_mode)
        fq=$(snap_get "$SNAP_PUMP" p_fq_v)
        fm=$(snap_get "$SNAP_PUMP" p_fq_mode)
        [ -n "$fq" ] && node_write_su "$PUMP_FREQ" "$fq" "$fm"
        case "$v" in ''|*[!0-9]*) ;; *) node_write_su "$PUMP_SPEED" "$v" "$m" ;; esac
        rm -f "$SNAP_PUMP" 2>/dev/null
    fi
    return 0
}

# ---------------- 温度联动曲线 ----------------
fan_temp_target() {
    local t thr
    # 控制温度 = 电池与皮肤温度取较高者；皮肤更贴近手感，电池更贴近发热源
    t=$(control_temp_deg) || return 1
    case "$t" in ''|*[!0-9-]*) return 1;; esac
    if [ "$(stq '温度联动模式')" = "custom" ]; then
        thr=$(stq '风扇触发温度')
        case "$thr" in ''|*[!0-9]*) thr=40;; esac
        if [ "$t" -ge "$thr" ]; then echo 5; else echo 1; fi
        return 0
    fi
    if [ "$t" -ge 40 ]; then echo 5
    elif [ "$t" -ge 35 ]; then echo 4
    elif [ "$t" -ge 30 ]; then echo 3
    else echo 1; fi
}
pump_temp_target() {
    local t thr
    t=$(control_temp_deg) || return 1
    case "$t" in ''|*[!0-9-]*) return 1;; esac
    if [ "$(stq '液冷联动模式')" = "custom" ]; then
        thr=$(stq '液冷触发温度')
        case "$thr" in ''|*[!0-9]*) thr=40;; esac
        if [ "$t" -ge "$thr" ]; then echo 4; else echo 1; fi
        return 0
    fi
    if [ "$t" -ge 40 ]; then echo 4
    elif [ "$t" -ge 35 ]; then echo 3
    elif [ "$t" -ge 30 ]; then echo 2
    else echo 1; fi
}
