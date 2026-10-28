#!/system/bin/sh
# ============================================================
# 开机最早期（post-fs-data）：只做三件必须在 system_server 之前完成的事
#   1) 把运行期目录整理好（run/），清空重写日志
#   2) 清掉上一轮可能残留的临时文件
#   3) 若开启了温控屏蔽，提前把空配置 bind 上去
# 只 source paths.sh（纯路径常量 + run/ 迁移），不碰 lib 里的功能实现。
# ============================================================
MODDIR=${0%/*}
. "$MODDIR/paths.sh"
LOG_FILE="$RUN_DIR/REDMAGIC.log"

plog() {
    printf '[%s] %s\n' "$(date '+%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$LOG_FILE" 2>/dev/null
}

# 日志只保留最新：每次开机直接清空重写，不再保留上一次的副本
: > "$LOG_FILE" 2>/dev/null

# 上一轮被强杀时留下的临时文件，统一在开机时清掉，不留垃圾
rm -f "$RUN_DIR"/*.tmp "$RUN_DIR"/state.txt.?????? \
      "$RUN_DIR/webui_cmd" "$RUN_DIR/webui_cmd.pending" \
      "$RUN_DIR/webui_status" "$RUN_DIR/webui_status.tmp" \
      "$RUN_DIR/.webui_hb" "$RUN_DIR/.hb_seen" \
      "$RUN_DIR/.svc_pid" "$RUN_DIR/.svc_lock" "$RUN_DIR/.bright_na" \
      "$RUN_DIR/.sep_state" "$RUN_DIR/.rate_cur" \
      "$RUN_DIR/.rate_state" "$RUN_DIR/.fast_state" "$RUN_DIR/.touch_state" \
      "$RUN_DIR/.cpu_state" "$RUN_DIR/.gpu_state" 2>/dev/null

want=0
v=$(grep -o '^温控移除=.*' "$STATE_FILE" 2>/dev/null | cut -d= -f2- | tail -n 1)
case "$v" in 0|1) want=$v;; esac
if [ "$want" != "1" ]; then
    v=$(grep -o '^温控移除=.*' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tail -n 1)
    case "$v" in 0|1) want=$v;; esac
fi

if [ "$want" = "1" ] && [ -e "$THERMAL_TARGET" ]; then
    mkdir -p "$MODDIR/conf" 2>/dev/null
    : > "$MODDIR/conf/empty.conf" 2>/dev/null
    mount --bind "$MODDIR/conf/empty.conf" "$THERMAL_TARGET" 2>/dev/null || plog "[FAIL] 温控屏蔽: 开机 bind 空配置失败"
fi
exit 0
