#!/system/bin/sh
# ============================================================
# KernelSU / Magisk 模块安装入口。
# 唯一安装入口。校验脚本特意不叫 install.sh：KernelSU 会把 install.sh
# 当旧式安装器直接跑，而那个阶段 MODPATH 里还没有 nodes.req/lib。
#
# 安装完成后只留运行时真正需要的文件：开发/打包产物、上一版本的运行残留
# 一律清掉，模块目录里不留垃圾。用户记忆（state.txt / config.txt）保留。
# ============================================================
MODDIR="${MODPATH:-$PWD}"
export MODDIR

if ! sh "$MODDIR/validate_nodes.sh"; then
    abort "! 机型节点校验失败，安装中止"
fi

# 模块脚本统一可执行，省得安装器按 umask 解包后权限不一致
for _f in "$MODDIR"/*.sh "$MODDIR"/lib/*.sh; do
    [ -f "$_f" ] && chmod 755 "$_f" 2>/dev/null
done

# 1) 开发/打包专用，装完即无用（校验已经跑过，节点清单也可以不要了）
rm -rf "$MODDIR/tools" "$MODDIR/dist" 2>/dev/null
rm -f "$MODDIR/README.md" "$MODDIR/CHANGELOG.md" "$MODDIR/FILES.md" "$MODDIR/.gitattributes" \
      "$MODDIR/validate_nodes.sh" "$MODDIR/nodes.req" 2>/dev/null

# 2) 只清瞬态文件。run/ 里放的是用户记忆( state.txt / auto_* / sep_limit …)
#    和接管快照，升级时整目录删除会让用户配置与“可还原”基线一起丢失。
rm -f "$MODDIR/run/REDMAGIC.log" "$MODDIR/run/REDMAGIC.log.prev" \
      "$MODDIR/run/.last_error" "$MODDIR/run"/webui_* "$MODDIR/run"/.webui_* \
      "$MODDIR/run/.hb_seen" "$MODDIR/run/.svc_pid" "$MODDIR/run/.svc_lock" \
      "$MODDIR/run/.bright_na" "$MODDIR/run/.sep_state" "$MODDIR/run/.rate_cur" \
      "$MODDIR/run/.rate_state" "$MODDIR/run/.fast_state" "$MODDIR/run/.touch_state" \
      "$MODDIR/run/.cpu_state" "$MODDIR/run/.gpu_state" \
      "$MODDIR/run/touch_rollback.txt" 2>/dev/null
rm -f "$MODDIR/run"/*.tmp "$MODDIR/run"/state.txt.?????? 2>/dev/null
# 旧布局散在根目录的瞬态文件（用户记忆由 paths.sh 的迁移逻辑搬进 run/）
rm -f "$MODDIR/REDMAGIC.log" "$MODDIR/REDMAGIC.log.prev" "$MODDIR/.last_error" \
      "$MODDIR"/webui_* "$MODDIR"/.webui_* \
      "$MODDIR/.hb_seen" "$MODDIR/.svc_*" "$MODDIR/.bright_na" \
      "$MODDIR/.sep_*" "$MODDIR/.rate_cur" 2>/dev/null
rm -f "$MODDIR"/*.tmp "$MODDIR/state.txt.??????" 2>/dev/null

# 3) 空目录也不留
rmdir "$MODDIR/tools" "$MODDIR/dist" 2>/dev/null
