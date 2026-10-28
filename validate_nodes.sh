#!/system/bin/sh
# ============================================================
# 安装前节点校验：逐行读 nodes.req，任何一行全缺失 = 安装中止。
# 只由 customize.sh 调用。文件名不能叫 install.sh：KernelSU 会把 install.sh
# 当旧式安装器直接执行，此时 MODPATH 里还没有 nodes.req 和 lib/，安装必失败。
#
# 以前 nodes.req 的注释声称"安装时会硬校验"，但仓库里并没有这个文件，
# 结果是机型不符也能装上去，然后坏在运行时（reconcile 静默跳过、按钮点了没反应）。
# ============================================================
# KernelSU 用绝对路径调用，${0%/*} 就是模块目录；本地自测用相对路径时会得到文件名本身
MODDIR=${MODDIR:-}
if [ -z "$MODDIR" ]; then
    MODDIR=${0%/*}
    case "$MODDIR" in
        "$0"|'') MODDIR=$(pwd);;   # 不带斜杠：$0 就是文件名，退到当前目录
    esac
fi
[ -f "$MODDIR/nodes.req" ] || { echo "! 缺少 nodes.req，无法校验机型"; exit 1; }

fails=0
total=0

# 候选路径可能含通配符（cpu*/cpufreq），逐条展开判定，任一命中即通过
_req_hit() {   # 逗号分隔的候选路径
    local list="$1" one
    local IFS=,
    for one in $list; do
        case "$one" in
            '') continue;;
            *[*?]*)   # 含通配符：展开后看有没有实际存在的
                for _p in $one; do [ -e "$_p" ] && return 0; done
                ;;
            *) [ -e "$one" ] && return 0;;
        esac
    done
    return 1
}

echo "- 校验机型节点"
while IFS='|' read -r name paths; do
    case "$name" in ''|'#'*) continue;; esac
    total=$((total + 1))
    if _req_hit "$paths"; then
        echo "  [ OK ] $name"
    else
        echo "  [FAIL] $name  (缺: $paths)"
        fails=$((fails + 1))
    fi
done < "$MODDIR/nodes.req"

if [ "$fails" -gt 0 ]; then
    echo "! $fails/$total 项节点缺失，本机型不受支持，安装已中止。"
    echo "! 若确认机型兼容，请在 nodes.req 里补齐该行的候选路径后重试。"
    exit 1
fi

echo "- $total 项节点全部通过"

# ---------------- 版本号单一来源 ----------------
# module.prop 的 version 是唯一真源。webroot 是静态资源，读不到 module.prop，
# 所以安装时把版本落到 webroot/version.txt，前端 fetch 它，避免三处手工对齐走样。
_v=$(grep "^version=" "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
if [ -n "$_v" ]; then
    if printf "%s\n" "$_v" > "$MODDIR/webroot/version.txt" 2>/dev/null && [ -s "$MODDIR/webroot/version.txt" ]; then
        echo "- 版本 $_v 已写入 webroot/version.txt"
    else
        echo "! 无法写入 webroot/version.txt，模块目录结构不完整"
        exit 1
    fi
else
    echo "! module.prop 缺少 version"
    exit 1
fi
unset _v

exit 0
