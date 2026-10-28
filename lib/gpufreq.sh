#!/system/bin/sh
# ============================================================
# GPU 频率：Adreno 的频率表在 kgsl-3d0/gpu_available_frequencies（Hz，从高到低），
# 实际控制用 max_pwrlevel / min_pwrlevel（0 = 最高频，数字越小越快）。
#   锁定关：只写 max_pwrlevel = 目标索引（压上限）；
#   锁定开：max_pwrlevel = min_pwrlevel = 目标索引（真正固定频率）。
# 实测：息屏时 kgsl 拒绝写入（值不变），所以和触控一样做「让行」，亮屏后补写。
# 关闭/停服/卸载：按快照把两个 pwrlevel 原值写回。
# ============================================================

GPU_LIST=""
GPU_IDX=""
GPU_SEL_MHZ=""
GPU_PAUSE=""

gpu_log() { [ "$SILENT" = "1" ] && return 0; mlog "GPU: $*"; }

gpu_mark() {   # STATE MESSAGE
    [ "$(cat "$GPU_MARK" 2>/dev/null)" = "$1" ] && return 0
    printf '%s\n' "$1" > "$GPU_MARK" 2>/dev/null
    gpu_log "$2"
}

# 频率表（MHz，保持节点原顺序：从高到低）
gpu_table() {
    local v out=""
    GPU_LIST=""
    [ -r "$GPU_AVAIL" ] || return 1
    IFS= read -rN 1024 v 2>/dev/null < "$GPU_AVAIL"
    case "$v" in *'
'*) v=${v%%'
'*};; esac
    for f in $v; do
        case "$f" in ''|*[!0-9]*) continue;; esac
        out="${out}${out:+,}$(( f / 1000000 ))"
    done
    [ -n "$out" ] || return 1
    GPU_LIST=$out
}

gpu_sel_of() {   # -> GPU_SEL_MHZ
    GPU_SEL_MHZ=$(stq 'GPU频率')
    case "$GPU_SEL_MHZ" in ''|*[!0-9]*) GPU_SEL_MHZ=0 ;; esac
    return 0
}

# MHz -> pwrlevel 索引（在频率表里从前往后找）
gpu_index_of() {   # MHZ -> GPU_IDX
    local want="$1" i=0 f
    GPU_IDX=""
    gpu_table || return 1
    for f in $(printf '%s' "$GPU_LIST" | tr ',' ' '); do
        if [ "$f" = "$want" ]; then GPU_IDX=$i; return 0; fi
        i=$((i + 1))
    done
    return 1
}

gpu_read() {   # FIELD -> GPU_CUR
    GPU_CUR=$(rdv "$GPU_DIR/$1" 2>/dev/null) || GPU_CUR=""
    case "$GPU_CUR" in ''|*[!0-9]*) GPU_CUR=""; return 1 ;; esac
    return 0
}

gpu_write() {   # FIELD VALUE
    local m
    m=$(stat -c %a "$GPU_DIR/$1" 2>/dev/null)
    node_write "$GPU_DIR/$1" "$2" "$m"
}

# 让行：息屏时 kgsl 拒绝写入；游戏空间接管时也不抢
gpu_paused() {
    local s g
    GPU_PAUSE=""
    s=$(screen_state)
    [ "$s" = "awake" ] || { GPU_PAUSE="screen"; return 0; }
    g=$(rdv "$TP_DIR/play_game" 2>/dev/null)
    [ "$g" = "1" ] && { GPU_PAUSE="game"; return 0; }
    return 1
}

gpu_snapshot_save() {
    [ -f "$SNAP_GPU" ] && return 0
    local mp mn tmp="${SNAP_GPU}.tmp"
    gpu_read max_pwrlevel || return 1
    mp=$GPU_CUR
    gpu_read min_pwrlevel || return 1
    mn=$GPU_CUR
    printf 'maxp=%s\nminp=%s\n' "$mp" "$mn" > "$tmp" 2>/dev/null || return 1
    mv -f "$tmp" "$SNAP_GPU" 2>/dev/null
}

# 应用：0 成功 / 1 失败 / 2 让行
gpu_apply() {
    local lock idx mp mn
    gpu_sel_of
    [ "$GPU_SEL_MHZ" -gt 0 ] 2>/dev/null || return 1
    if gpu_paused; then
        gpu_mark "pause:$GPU_PAUSE" "GPU: 息屏/游戏空间接管期间让行，条件解除后自动补写"
        return 2
    fi
    if ! gpu_index_of "$GPU_SEL_MHZ"; then
        gpu_log "选定频率 ${GPU_SEL_MHZ}MHz 不在频率表里"
        return 1
    fi
    idx=$GPU_IDX
    lock=$(stq '频率锁定')
    case "$lock" in 1) ;; *) lock=0 ;; esac
    gpu_snapshot_save || { gpu_log "原值读取失败，取消写入"; return 1; }
    gpu_read min_pwrlevel || return 1
    mn=$GPU_CUR
    if [ "$lock" = "1" ]; then
        # 先把上限放开到目标（数字更小=更快）；已比目标更快就不用改
        if [ "$mn" -lt "$idx" ] 2>/dev/null; then
            gpu_write min_pwrlevel "$idx" || return 1
            mn=$idx
        fi
        gpu_write max_pwrlevel "$idx" || { gpu_log "max_pwrlevel 写入失败"; return 1; }
        gpu_write min_pwrlevel "$idx" || { gpu_log "min_pwrlevel 写入失败"; return 1; }
        gpu_read max_pwrlevel && [ "$GPU_CUR" = "$idx" ] || { gpu_log "max_pwrlevel 回读不符"; return 1; }
        gpu_read min_pwrlevel && [ "$GPU_CUR" = "$idx" ] || { gpu_log "min_pwrlevel 回读不符"; return 1; }
        gpu_mark "lock:$idx" "GPU: 已锁定 ${GPU_SEL_MHZ}MHz（pwrlevel $idx）"
        return 0
    fi
    if [ "$mn" -lt "$idx" ] 2>/dev/null; then
        gpu_write min_pwrlevel "$idx" || return 1
    fi
    gpu_write max_pwrlevel "$idx" || { gpu_log "max_pwrlevel 写入失败"; return 1; }
    gpu_read max_pwrlevel && [ "$GPU_CUR" = "$idx" ] || { gpu_log "max_pwrlevel 回读不符"; return 1; }
    gpu_mark "cap:$idx" "GPU: 已压上限到 ${GPU_SEL_MHZ}MHz（pwrlevel $idx）"
    return 0
}

# 还原：两个 pwrlevel 按快照写回（先 min 后 max 与驱动方向一致，不会出现 min<max 的非法态）
gpu_release() {
    local mp mn ok=1
    if [ ! -f "$SNAP_GPU" ]; then
        rm -f "$GPU_MARK" 2>/dev/null
        return 0
    fi
    mn=$(grep -o '^minp=.*' "$SNAP_GPU" 2>/dev/null | tail -n 1 | cut -d= -f2-)
    mp=$(grep -o '^maxp=.*' "$SNAP_GPU" 2>/dev/null | tail -n 1 | cut -d= -f2-)
    case "$mn$mp" in ''|*[!0-9]*) gpu_log "快照无效，无法还原"; return 1 ;; esac
    gpu_write max_pwrlevel "$mp" || ok=0
    gpu_write min_pwrlevel "$mn" || ok=0
    if [ "$ok" = "1" ]; then
        rm -f "$SNAP_GPU" 2>/dev/null
        printf 'off\n' > "$GPU_MARK" 2>/dev/null
        gpu_log "已还原 GPU 频率档位"
    else
        gpu_log "还原失败，保留快照下次再试"
        return 1
    fi
    return 0
}

gpu_verify() {
    local lock idx
    gpu_sel_of
    [ "$GPU_SEL_MHZ" -gt 0 ] 2>/dev/null || return 1
    gpu_index_of "$GPU_SEL_MHZ" || return 1
    idx=$GPU_IDX
    lock=$(stq '频率锁定')
    case "$lock" in 1) ;; *) lock=0 ;; esac
    gpu_read max_pwrlevel || return 1
    if [ "$lock" = "1" ]; then
        [ "$GPU_CUR" = "$idx" ] || return 1
        gpu_read min_pwrlevel || return 1
        [ "$GPU_CUR" = "$idx" ] || return 1
    else
        # 只压上限：系统把 maxp 调得更严（数字更大）是允许的
        [ "$GPU_CUR" -ge "$idx" ] 2>/dev/null || return 1
    fi
    return 0
}

gpu_active() { gpu_sel_of; [ "$GPU_SEL_MHZ" -gt 0 ] 2>/dev/null; }
