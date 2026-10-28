#!/system/bin/sh
# ============================================================
# 卸载：还原所有被改过的节点与系统设置，再清运行产物。
# 数据全部在模块目录内，卸载即随目录删除。
# ============================================================
MODDIR=${0%/*}
. "$MODDIR/paths.sh"
. "$MODDIR/common.sh"
for _f in system thermal fanpump charge touch bright state commands status teardown; do
    . "$MODDIR/lib/$_f.sh"
done

teardown_all uninstall
exit 0
