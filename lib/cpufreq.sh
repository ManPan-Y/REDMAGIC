#!/system/bin/sh
# ============================================================
# CPU 频率：按系统频率表（scaling_available_frequencies）逐簇选择频率。
#   0 = 不接管；其它值必须是该簇频率表里的 MHz 值。
#   锁定关：只压 scaling_max_freq（上限），比目标低的系统值一律不动，
#           绝不把系统为省电压下来的频率抬回去；
#   锁定开：max = min = 目标，真正钉在选定频率（看门狗会拉回被系统改掉的值）。
# 读写一律换算成 kHz（节点单位）；记忆与前端用 MHz，避免 6~7 位数字手输出错。
# 关闭/停服/卸载：max 写回该簇最高频、min 写回最低频，交回系统。
# ============================================================

CPU_ALL=""
CPU_TAB=""
CPU_HWMIN=""
CPU_HWMAX=""
CPU_SEL_MHZ=""
CPU_P=""

cpu_log() { [ "$SILENT" = "1" ] && return 0; mlog "CPU: $*"; }

cpu_mark() {   # STATE MESSAGE
    [ "$(cat "$CPU_MARK" 2>/dev/null)" = "$1" ] && return 0
    printf '%s\n' "$1" > "$CPU_MARK" 2>/dev/null
    cpu_log "$2"
}

# 第 i 个 policy 目录（NX809J: 0=小核簇 policy0 / 1=大核簇 policy6）
cpu_policy_at() {   # INDEX -> CPU_P
    local want="$1" n=0 p
    CPU_P=""
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$p" ] || continue
        if [ "$n" = "$want" ]; then CPU_P=$p; return 0; fi
        n=$((n + 1))
    done
    return 1
}

# 整段读节点：可用频率列表比 64 字节长，rd 会截断在数字中间（实测出现 132480/17）
cpu_read_all() {   # PATH -> CPU_ALL
    CPU_ALL=""
    [ -r "$1" ] || return 1
    IFS= read -rN 1024 CPU_ALL 2>/dev/null < "$1"
    case "$CPU_ALL" in *'
'*) CPU_ALL=${CPU_ALL%%'
'*};; esac
    [ -n "$CPU_ALL" ]
}

# 频率表：CPU_TAB（空格分隔 kHz）/ CPU_HWMIN（最低）/ CPU_HWMAX（最高）
cpu_table() {   # POLICY
    local f
    CPU_TAB=""; CPU_HWMIN=""; CPU_HWMAX=""
    cpu_read_all "$1/scaling_available_frequencies" || return 1
    for f in $CPU_ALL; do
        case "$f" in ''|*[!0-9]*) continue;; esac
        CPU_TAB="${CPU_TAB}${CPU_TAB:+ }$f"
        [ -n "$CPU_HWMIN" ] || CPU_HWMIN=$f
        CPU_HWMAX=$f
    done
    [ -n "$CPU_HWMAX" ]
}

# 频率表换算成前端用的 MHz，逗号分隔（状态快照单行传输）
cpu_list_mhz() {   # POLICY -> echo
    local f out=""
    cpu_table "$1" || return 0
    for f in $CPU_TAB; do
        out="${out}${out:+,}$(( f / 1000 ))"
    done
    printf '%s' "$out"
}

# 选定 MHz -> 该簇频率表里的精确 kHz（表里的值不一定能整除 1000，
# 例如 1785600kHz 显示成 1785MHz；再乘回 1000 会变成表里没有的 1785000）。
cpu_khz_of() {   # POLICY MHZ -> CPU_KHZ
    local f
    CPU_KHZ=""
    cpu_table "$1" || return 1
    for f in $CPU_TAB; do
        if [ "$(( f / 1000 ))" = "$2" ]; then CPU_KHZ=$f; return 0; fi
    done
    return 1
}

# 第 i 簇的记忆值（MHz），写进 CPU_SEL_MHZ
cpu_sel_of() {   # INDEX
    CPU_SEL_MHZ=""
    case "$1" in
        0) CPU_SEL_MHZ=$(stq 'CPU小核频率') ;;
        1) CPU_SEL_MHZ=$(stq 'CPU大核频率') ;;
    esac
    case "$CPU_SEL_MHZ" in ''|*[!0-9]*) CPU_SEL_MHZ=0 ;; esac
    return 0
}

cpu_read_node() {   # POLICY FIELD -> CPU_CUR
    CPU_CUR=$(rdv "$1/$2" 2>/dev/null) || CPU_CUR=""
    case "$CPU_CUR" in ''|*[!0-9]*) CPU_CUR=""; return 1 ;; esac
    return 0
}

cpu_write_node() {   # POLICY FIELD VALUE
    local m
    m=$(stat -c %a "$1/$2" 2>/dev/null)
    node_write "$1/$2" "$3" "$m"
}

# 单簇写入：先保证 min <= max，再按锁定与否落值
cpu_write_one() {   # POLICY TARGET_KHZ LOCK
    local p="$1" tgt="$2" lock="$3" curmin curmax
    cpu_read_node "$p" scaling_min_freq || return 1
    curmin=$CPU_CUR
    cpu_read_node "$p" scaling_max_freq || return 1
    curmax=$CPU_CUR
    if [ "$lock" = "1" ]; then
        # 锁定时先放松下限，避免「min > 目标」导致写入被驱动拒绝
        [ "$curmin" -gt "$tgt" ] 2>/dev/null && cpu_write_node "$p" scaling_min_freq "$tgt"
        cpu_write_node "$p" scaling_max_freq "$tgt" || return 1
        cpu_write_node "$p" scaling_min_freq "$tgt" || return 1
        # 驱动/电源 HAL 会把超出当前允许范围的值钳低：只要回读后 min=max（真正钉住）
        # 就视为成功，界面另外显示实际值，不谎报成用户选的那个数
        cpu_read_node "$p" scaling_max_freq || return 1
        curmax=$CPU_CUR
        cpu_read_node "$p" scaling_min_freq || return 1
        [ "$curmax" = "$CPU_CUR" ] && [ "$curmax" -le "$tgt" ] 2>/dev/null
        return $?
    fi
    # 只压上限：当前 min 高于目标时先把 min 降到硬件最低，否则 max 写不进去
    if [ "$curmin" -gt "$tgt" ] 2>/dev/null; then
        cpu_table "$p" || return 1
        cpu_write_node "$p" scaling_min_freq "$CPU_HWMIN" || return 1
    fi
    [ "$curmax" = "$tgt" ] && return 0
    cpu_write_node "$p" scaling_max_freq "$tgt" || return 1
    cpu_read_node "$p" scaling_max_freq || return 1
    # 电源 HAL 可能立刻把上限压得更低（更严格），这也算成功；
    # 只有回读高于目标才说明 cap 没落住
    [ "$CPU_CUR" -le "$tgt" ] 2>/dev/null
}

# 接管标记 + 快照（记各簇硬件上下限，还原与诊断都要用）
cpu_snapshot_save() {
    [ -f "$SNAP_CPU" ] && return 0
    local i=0 p tmp="${SNAP_CPU}.tmp"
    : > "$tmp" 2>/dev/null || return 1
    while cpu_policy_at "$i"; do
        p=$CPU_P
        if cpu_table "$p"; then
            printf '%s|%s|%s\n' "$p" "$CPU_HWMIN" "$CPU_HWMAX" >> "$tmp" 2>/dev/null
        fi
        i=$((i + 1))
    done
    [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv -f "$tmp" "$SNAP_CPU" 2>/dev/null
}

# 应用：0 成功 / 1 有失败或未配置
cpu_apply() {
    local i=0 p tgt lock ok=1 any=0
    lock=$(stq '频率锁定')
    case "$lock" in 1) ;; *) lock=0 ;; esac
    while cpu_policy_at "$i"; do
        p=$CPU_P
        cpu_sel_of "$i"
        i=$((i + 1))
        if [ "$CPU_SEL_MHZ" -le 0 ] 2>/dev/null; then
            # 这一簇不接管：必要时把上下限放回硬件范围
            cpu_restore_one "$p"
            continue
        fi
        any=1
        if ! cpu_khz_of "$p" "$CPU_SEL_MHZ"; then
            cpu_log "选定频率 ${CPU_SEL_MHZ}MHz 不在 ${p##*/} 的频率表里，跳过"
            ok=0
            continue
        fi
        tgt=$CPU_KHZ
        cpu_write_one "$p" "$tgt" "$lock" || { ok=0; cpu_log "${p##*/} 写入 ${CPU_SEL_MHZ}MHz 失败"; }
    done
    [ "$any" = "1" ] || return 1
    cpu_snapshot_save || true
    [ "$ok" = "1" ] || return 1
    if [ "$lock" = "1" ]; then
        cpu_mark "lock" "CPU: 已按选定频率锁定（min=max）"
    else
        cpu_mark "cap" "CPU: 已按选定频率压上限"
    fi
    return 0
}

# 单簇回到硬件范围（只在该簇不再接管、且快照存在时做）
cpu_restore_one() {   # POLICY
    local p="$1" hmin hmax line v1 v2
    [ -f "$SNAP_CPU" ] || return 0
    while IFS='|' read -r line v1 v2; do
        [ "$line" = "$p" ] || continue
        case "$v1$v2" in ''|*[!0-9]*) return 0 ;; esac
        hmin=$v1; hmax=$v2
        cpu_write_node "$p" scaling_max_freq "$hmax"
        cpu_write_node "$p" scaling_min_freq "$hmin"
        return 0
    done < "$SNAP_CPU"
    return 0
}

# 放开：每簇 max 回到最高频、min 回到最低频，然后删快照交给系统
cpu_release() {
    local p hmin hmax ok=1 line
    if [ -f "$SNAP_CPU" ]; then
        while IFS='|' read -r p hmin hmax; do
            [ -n "$p" ] || continue
            case "$hmin$hmax" in ''|*[!0-9]*) continue;; esac
            cpu_write_node "$p" scaling_max_freq "$hmax" || ok=0
            cpu_write_node "$p" scaling_min_freq "$hmin" || ok=0
        done < "$SNAP_CPU"
    fi
    if [ "$ok" = "1" ]; then
        rm -f "$SNAP_CPU" 2>/dev/null
        printf 'off\n' > "$CPU_MARK" 2>/dev/null
        cpu_log "已放开频率，交回系统"
    else
        cpu_log "还原失败，保留快照下次再试"
        return 1
    fi
    return 0
}

# 核对：锁定档要求 min=max=目标；只压上限时要求 max 不高于目标
cpu_verify() {
    local i=0 p tgt lock curmax
    lock=$(stq '频率锁定')
    case "$lock" in 1) ;; *) lock=0 ;; esac
    while cpu_policy_at "$i"; do
        p=$CPU_P
        cpu_sel_of "$i"
        i=$((i + 1))
        [ "$CPU_SEL_MHZ" -gt 0 ] 2>/dev/null || continue
        cpu_khz_of "$p" "$CPU_SEL_MHZ" || return 1
        tgt=$CPU_KHZ
        cpu_read_node "$p" scaling_max_freq || return 1
        if [ "$lock" = "1" ]; then
            # 锁定：min 与 max 必须相等（被钳到更低也算钉住），且不高于选定值
            [ "$CPU_CUR" -le "$tgt" ] 2>/dev/null || return 1
            curmax=$CPU_CUR
            cpu_read_node "$p" scaling_min_freq || return 1
            [ "$CPU_CUR" = "$curmax" ] || return 1
        else
            [ "$CPU_CUR" -le "$tgt" ] 2>/dev/null || return 1
        fi
    done
    return 0
}

# 是否有任何簇被接管（给状态/看门狗一个便宜的前置判断）
cpu_active() {
    cpu_sel_of 0; [ "$CPU_SEL_MHZ" -gt 0 ] 2>/dev/null && return 0
    cpu_sel_of 1; [ "$CPU_SEL_MHZ" -gt 0 ] 2>/dev/null && return 0
    return 1
}
