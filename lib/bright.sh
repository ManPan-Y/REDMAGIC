#!/system/bin/sh
# ============================================================
# 亮度解锁：系统把亮度顶到自己上限（7030）时，自动顶到目标值（8190）。
# 只在面板允许的 max_brightness 内写；没有余量就写 BRIGHT_NA 标记，
# 让看门狗别反复重启这个守护。
# ============================================================

bright_nodes() {
    local d
    if [ -n "$BL_BRIGHT" ] && [ -e "$BL_BRIGHT" ]; then return 0; fi
    for d in "$BL_DIR"/*/brightness; do
        [ -e "$d" ] || continue
        BL_BRIGHT="$d"
        case "$d" in
            "$BL_DIR/panel0-backlight/brightness") BL_MAX="$BL_DIR/panel0-backlight/max_brightness" ;;
            *) BL_MAX="${d%/brightness}/max_brightness" ;;
        esac
        return 0
    done
    BL_BRIGHT=""
    BL_MAX=""
    return 1
}

# NX809J 系统亮度上限（节点 max_brightness=8190，系统 UI 只到 7030）
BRIGHT_SYS_DEF=7030

# 系统亮度上限：优先读用户记忆，空则由 bright_daemon 在节点就绪后自适应。
# 会被写在 $( ) 里，所以在子 shell 里自己查，不用全局 CFGV/STV。
bright_limit() { stq '亮度系统上限'; }
bright_goal() {
    local g mx
    g=$(stq '亮度解锁目标')
    case "$g" in ''|*[!0-9]*) g=8190;; esac
    if [ -n "$BL_MAX" ] && [ -e "$BL_MAX" ]; then
        rd "$BL_MAX"
        case "$RD" in
            ''|*[!0-9]*) : ;;
            *) mx="$RD"; [ "$g" -gt "$mx" ] 2>/dev/null && g=$mx ;;
        esac
    fi
    printf '%s' "$g"
}

# 返回 0 表示这一步做了写入
# 最近一次 bright_step 是否真的写了节点（守护只用来记日志，不参与退出判断）
_BS_WROTE=0

bright_step() {
    local lim cur goal
    bright_nodes || return 1
    lim=$(bright_limit)
    case "$lim" in ''|*[!0-9]*) lim=7030;; esac
    rd "$BL_BRIGHT"; cur="$RD"
    case "$cur" in ''|*[!0-9]*) return 1;; esac
    [ "$cur" -ge "$lim" ] || return 1
    goal=$(bright_goal)
    [ "$cur" = "$goal" ] && return 1
    # 返回值只表示"这一步写没写"，不能拿它当循环退出信号（父进程活着时它照样返回 0）
    if printf '%s\n' "$goal" > "$BL_BRIGHT" 2>/dev/null; then _BS_WROTE=1; return 0; fi
    su 2000 -c "printf '%s\\n' '$goal' > '$BL_BRIGHT'" 2>/dev/null && _BS_WROTE=1
}

# 守护：后台跑，绝不阻塞 service.sh 主链；节点最多等 60 秒
bright_daemon() {
    local i=0 lim g
    while [ "$i" -lt 30 ]; do
        bright_nodes && break
        sleep 2
        i=$((i + 1))
    done
    if [ -z "$BL_BRIGHT" ]; then
        : > "$BRIGHT_NA" 2>/dev/null
        mlog "亮度解锁: 60 秒内未出现背光节点，功能不可用"
        return 1
    fi
    # 系统上限空着就用 NX809J 的已知上限。
    # 以前拿「开机时的当前亮度」当上限，结果用户把亮度调过那个值就会直接跳到满亮度。
    lim=$(bright_limit)
    case "$lim" in
        ''|*[!0-9]*)
            lim=$BRIGHT_SYS_DEF
            cfg_set '亮度系统上限' "$lim"
            ;;
    esac
    g=$(bright_goal)
    if [ "$g" -le "$lim" ] 2>/dev/null; then
        : > "$BRIGHT_NA" 2>/dev/null
        mlog "亮度解锁: 面板无余量（$g <= $lim），功能不适用"
        return 1
    fi
    mlog "亮度解锁: 已启动（$lim -> $g）"
    # $$ 在 mksh 后台函数里仍是 service 的 PID；service 被 kill 后 /proc/$$ 消失，据此退出。
    # 以前用 while true 没有出口，service.sh 一死这里就成了孤儿，继续每秒写亮度节点。
    while true; do
        [ -d "/proc/$$" ] || break
        [ -f "$F_BRIGHT" ] || { sleep 2; continue; }
        # 用户可随时在界面里改目标；state.txt 变了就重算一次余量
        g=$(bright_goal)
        _BS_WROTE=0
        bright_step
        sleep 1
    done
    mlog "亮度解锁: 守护退出（父进程已结束）"
    return 0
}
