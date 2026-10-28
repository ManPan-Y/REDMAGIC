#!/system/bin/sh
# ============================================================
# 收尾：停服务、还原节点、清标记。
#   teardown_all uninstall = 卸载（连记忆和子选项一起清）
#   teardown_all service   = 仅停服务（记忆保留，下次开机继续）
# ============================================================

# 先 TERM 再 KILL：service.sh 的 trap cleanup 只认 TERM/INT/HUP/EXIT，
# 直接 kill -9 会让子进程收尾（包括日志落盘）全部作废。
td_kill_tree() {
    local f p
    for f in /proc/[0-9]*/cmdline; do
        [ -r "$f" ] || continue
        tr -d '\000' < "$f" 2>/dev/null | grep -q "$SVC_CMDLINE_PAT" || continue
        p=${f#/proc/}
        p=${p%/cmdline}
        [ "$p" = "$$" ] && continue
        kill -TERM "$p" 2>/dev/null
    done
}

td_stop_service() {
    local pid i=0
    if [ -f "$SVC_PID_FILE" ]; then
        pid=$(cat "$SVC_PID_FILE" 2>/dev/null)
        case "$pid" in ''|*[!0-9]*) ;; *) [ -d "/proc/$pid" ] && kill -TERM "$pid" 2>/dev/null;; esac
    fi
    # 父进程被 TERM 后子 shell 可能残留，先按 cmdline 认亲补一次 TERM
    td_kill_tree
    # 给 trap cleanup 最多 3 秒收子进程
    while [ "$i" -lt 3 ]; do
        [ -f "$SVC_LOCK_FILE" ] || break
        sleep 1
        i=$((i + 1))
    done
    # 还在的就硬杀
    if [ -f "$SVC_PID_FILE" ]; then
        pid=$(cat "$SVC_PID_FILE" 2>/dev/null)
        case "$pid" in ''|*[!0-9]*) ;; *) [ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null;; esac
    fi
    td_kill_tree
    i=0
    while [ "$i" -lt 2 ]; do
        sleep 1
        i=$((i + 1))
    done
    for f in /proc/[0-9]*/cmdline; do
        [ -r "$f" ] || continue
        tr -d '\000' < "$f" 2>/dev/null | grep -q "$SVC_CMDLINE_PAT" || continue
        p=${f#/proc/}
        p=${p%/cmdline}
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null
    done
    rm -f "$SVC_PID_FILE" "$SVC_LOCK_FILE" 2>/dev/null
    return 0
}

td_nodes() {
    # 先还给充电模组真实亮屏状态，再做其它还原
    fast_release   2>/dev/null
    boost_release  2>/dev/null
    # 解除热降流是独立功能，boost_release 不再连带处理它
    heat_release   2>/dev/null
    if thermal_effective; then thermal_off 2>/dev/null; fi
    fan_keep_stop  2>/dev/null
    pump_keep_stop 2>/dev/null
    fan_release    2>/dev/null
    pump_release   2>/dev/null
    # 触控必须还原到接管前的原始值，再清快照
    TOUCH_WAIT_MAX=5 touch_restore 2>/dev/null
    return 0
}

td_settings() {
    # 采样率还原到接管前的驱动档位（没接管过就不动节点）
    rate_boost_off >/dev/null 2>&1
    # 让行期间 rate_boost_off 会保留快照；收尾不能留尾巴，按快照硬写一次
    rate_force_restore 2>/dev/null
    # 采样率还原时会顺带把系统 settings 显示值写回原样
    cpu_release 2>/dev/null
    gpu_release 2>/dev/null
    stg put global charge_separation_switch 0 >/dev/null 2>&1
    sep_store 0
    return 0
}

td_markers() {
    rm -f "$F_FAN" "$F_PUMP" "$F_CHARGE" "$F_THERMAL" "$F_TOUCH" "$F_BOOST" \
          "$F_BRIGHT" "$F_RATE" "$F_FAST" 2>/dev/null
    return 0
}

td_runtime() {   # $1 = uninstall | service
    rm -f "$WEBUI_CMD" "$WEBUI_CMD.pending" "$WEBUI_STATUS" "$WEBUI_STATUS.tmp" \
          "$WEBUI_HB" "$WEBUI_HB_SEEN" "$BRIGHT_NA" "$LOG_FILE.tmp" 2>/dev/null
    [ "$1" = "uninstall" ] || return 0
    rm -f "$F_BOOST_HEAT" "$F_FAN_KEEP" "$F_PUMP_KEEP" "$F_FAN_TEMP" "$F_PUMP_TEMP" 2>/dev/null
    rm -f "$SNAP_FAN" "$SNAP_PUMP" "$SNAP_BOOST" "$SNAP_CFREQ" "$SNAP_HEAT" \
          "$SNAP_FAN_KEEP" "$SNAP_PUMP_KEEP" "$RATE_SNAPSHOT" "$RATE_APPLIED" \
          "$RATE_MARK" "$FAST_MARK" "$TOUCH_MARK" \
          "$SNAP_CPU" "$SNAP_GPU" "$CPU_MARK" "$GPU_MARK" \
          "$SEP_CACHE" "$RATE_CACHE" \
          "$TOUCH_SNAPSHOT" "$TOUCH_NA" "$TOUCH_RB" "$TOUCH_DEFER" "$SEP_LIMIT" "$BOOST_LIMIT" 2>/dev/null
    return 0
}

teardown_all() {
    local mode="${1:-service}"
    mlog "收尾开始: $mode"
    td_stop_service
    td_nodes
    td_settings
    td_markers
    td_runtime "$mode"
    mlog "收尾完成: $mode"
    # 卸载：正文写完后整个 run/ 一起删掉，模块目录里不留运行残留
    [ "$mode" = "uninstall" ] && rm -rf "$RUN_DIR" 2>/dev/null
    return 0
}
