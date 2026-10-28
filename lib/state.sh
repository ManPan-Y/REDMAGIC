#!/system/bin/sh
# ============================================================
# 记忆与标记的一致性：state.txt 是唯一真相，标记文件是它的投影。
# 开关用标记文件表示（存在=开），数值用 state.txt。
# ============================================================

# 开关名 -> 标记文件路径
flag_file() {
    case "$1" in
        fan) printf '%s' "$F_FAN";;
        pump) printf '%s' "$F_PUMP";;
        charge) printf '%s' "$F_CHARGE";;
        touch) printf '%s' "$F_TOUCH";;
        boost) printf '%s' "$F_BOOST";;
        brightness) printf '%s' "$F_BRIGHT";;
        rate) printf '%s' "$F_RATE";;
        fast) printf '%s' "$F_FAST";;
        thermal) printf '%s' "$F_THERMAL";;
    esac
}

# 开关名 -> state.txt 键
flag_key() {
    case "$1" in
        fan) printf '风扇极速';;
        pump) printf '液冷控制';;
        charge) printf '充电分离';;
        touch) printf '触控优化';;
        boost) printf '充电加速';;
        brightness) printf '亮度解锁';;
        rate) printf '触控采样率';;
        fast) printf '熄屏提速';;
        thermal) printf '温控移除';;
    esac
}

# 标记 -> 记忆（值没变就不写，省 IO）
state_sync() {
    local k v cur f
    for k in fan pump charge thermal touch boost brightness rate fast; do
        f=$(flag_file "$k") || continue
        if [ -f "$f" ]; then v=1; else v=0; fi
        cur=$(stq "$(flag_key "$k")")
        [ "$cur" = "$v" ] || cfg_set "$(flag_key "$k")" "$v"
    done
    return 0
}

# 开机：按记忆把标记建回来（用户上次的选择要延续）
state_restore_flags() {
    local k f
    for k in fan pump charge thermal touch boost brightness rate fast; do
        f=$(flag_file "$k") || continue
        kk=$(flag_key "$k") || continue
        if [ "$(stq "$kk")" = "1" ]; then : > "$f" 2>/dev/null; else rm -f "$f" 2>/dev/null; fi
    done
    return 0
}

# 数值文件从记忆播种（文件为空才写，之后以文件为准）
seed_values() {
    local v
    if [ ! -s "$SEP_LIMIT" ]; then
        v=$(stq '充电分离阈值')
        case "$v" in ''|*[!0-9]*) v=100;; esac
        printf '%s\n' "$v" > "$SEP_LIMIT" 2>/dev/null
    fi
    if [ ! -s "$BOOST_LIMIT" ]; then
        v=$(stq '充电加速温度上限')
        case "$v" in ''|*[!0-9]*) v=42;; esac
        printf '%s\n' "$v" > "$BOOST_LIMIT" 2>/dev/null
    fi
}

# ---------------- 状态一次性装载 ----------------
# status_body 每次要取十几项记忆值，逐项 stq 就是十几次 grep fork（实测 600ms+）。
# 这里一次读完 state.txt 落到变量里，subshell 里再取就是纯内存操作。
ST_LOADED=""
ST_FAN=""; ST_PUMP=""
ST_FAN_MODE=""; ST_FAN_THR=""; ST_PUMP_MODE=""; ST_PUMP_THR=""
ST_TP=""; ST_BGOAL=""; ST_RCAP=""
ST_SEP_THR=""; ST_BOOST_THR=""
ST_FOLLOW=""; ST_STAB=""; ST_SENS=""; ST_REPORT=""
ST_EDGE_DEB=""; ST_EDGE_PX=""; ST_EDGE_MS=""; ST_CLICK=""
ST_LONG_ON=""; ST_LONG_MS=""; ST_LONG_RANGE=""; ST_EDGE_ANTI=""
ST_EDGE_GRIP=""; ST_PALM=""; ST_PEN=""
ST_CPUS=""; ST_CPUB=""; ST_GPU=""; ST_LOCK=""
STATE_V=""

state_load() {
    ST_FAN=""; ST_PUMP=""
    ST_FAN_MODE=""; ST_FAN_THR=""; ST_PUMP_MODE=""; ST_PUMP_THR=""
    ST_TP=""; ST_BGOAL=""; ST_RCAP=""
    ST_SEP_THR=""; ST_BOOST_THR=""
    ST_FOLLOW=""; ST_STAB=""; ST_SENS=""; ST_REPORT=""
    ST_EDGE_DEB=""; ST_EDGE_PX=""; ST_EDGE_MS=""; ST_CLICK=""
    ST_LONG_ON=""; ST_LONG_MS=""; ST_LONG_RANGE=""; ST_EDGE_ANTI=""
    ST_EDGE_GRIP=""; ST_PALM=""; ST_PEN=""
    ST_CPUS=""; ST_CPUB=""; ST_GPU=""; ST_LOCK=""
    if [ -f "$STATE_FILE" ]; then
        local k v
        while IFS='=' read -r k v; do
            case "$k" in
                '风扇档位')       ST_FAN=$v ;;
                '液冷档位')       ST_PUMP=$v ;;
                '温度联动模式')   ST_FAN_MODE=$v ;;
                '风扇触发温度')   ST_FAN_THR=$v ;;
                '液冷联动模式')   ST_PUMP_MODE=$v ;;
                '液冷触发温度')   ST_PUMP_THR=$v ;;
                '触控预设')       ST_TP=$v ;;
                '亮度解锁目标')   ST_BGOAL=$v ;;
                '采样率上限')     ST_RCAP=$v ;;
                '充电分离阈值')   ST_SEP_THR=$v ;;
                '充电加速温度上限') ST_BOOST_THR=$v ;;
                'CPU小核频率')    ST_CPUS=$v ;;
                'CPU大核频率')    ST_CPUB=$v ;;
                'GPU频率')        ST_GPU=$v ;;
                '频率锁定')       ST_LOCK=$v ;;
                '跟手速度')       ST_FOLLOW=$v ;;
                '稳定程度')       ST_STAB=$v ;;
                '灵敏程度')       ST_SENS=$v ;;
                '上报频率')       ST_REPORT=$v ;;
                '边缘防抖')       ST_EDGE_DEB=$v ;;
                '防抖像素')       ST_EDGE_PX=$v ;;
                '防抖时间')       ST_EDGE_MS=$v ;;
                '点击容错')       ST_CLICK=$v ;;
                '长按识别')       ST_LONG_ON=$v ;;
                '长按时长')       ST_LONG_MS=$v ;;
                '长按范围')       ST_LONG_RANGE=$v ;;
                '边缘防误触')     ST_EDGE_ANTI=$v ;;
                '握持防误触')     ST_EDGE_GRIP=$v ;;
                '手掌抑制')       ST_PALM=$v ;;
                '手写笔模式')     ST_PEN=$v ;;
            esac
        done < "$STATE_FILE"
    fi
    ST_LOADED=1
    return 0
}

# 中文项名 -> STATE_V（不 fork）
state_val() {   # NAME
    STATE_V=""
    case "$1" in
        '跟手速度')   STATE_V=$ST_FOLLOW ;;
        '稳定程度')   STATE_V=$ST_STAB ;;
        '灵敏程度')   STATE_V=$ST_SENS ;;
        '上报频率')   STATE_V=$ST_REPORT ;;
        '边缘防抖')   STATE_V=$ST_EDGE_DEB ;;
        '防抖像素')   STATE_V=$ST_EDGE_PX ;;
        '防抖时间')   STATE_V=$ST_EDGE_MS ;;
        '点击容错')   STATE_V=$ST_CLICK ;;
        '长按识别')   STATE_V=$ST_LONG_ON ;;
        '长按时长')   STATE_V=$ST_LONG_MS ;;
        '长按范围')   STATE_V=$ST_LONG_RANGE ;;
        '边缘防误触') STATE_V=$ST_EDGE_ANTI ;;
        '握持防误触') STATE_V=$ST_EDGE_GRIP ;;
        '手掌抑制')   STATE_V=$ST_PALM ;;
        '手写笔模式') STATE_V=$ST_PEN ;;
    esac
    return 0
}
