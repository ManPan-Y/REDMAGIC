#!/system/bin/sh
# ============================================================
# 触控 15 项：由 lib/touch_table.txt 驱动，写后必回读核对。
# 前 5 个节点缺一即本机不支持（安装校验会直接让安装失败）；
# 后 3 项（握持防误触/手掌抑制/手写笔模式）缺节点时自动置灰，不影响其它项。
# ============================================================

TOUCH_WAIT_MAX=15

touch_log() { [ "$SILENT" = "1" ] && return 0; mlog "触控: $*"; }

# 归一化：把 "1, 2,3" 这类差异压成 "1 2 3"，用来比对人可读的差异
touch_norm() { printf '%s' "$1" | tr -s ', ' '  ' | sed -e 's/^ *//' -e 's/ *$//'; }

touch_missing_nodes() {
    local n=0 f
    for f in follow_hand_level stability_level sensibility tp_report_rate edge_report_limit; do
        [ -e "$TP_DIR/$f" ] || n=$((n + 1))
    done
    TOUCH_MISSING=$n
    printf '%s' "$n"
}
touch_supported() { [ "$(touch_missing_nodes)" = "0" ]; }

# 某项节点当前是否可读。用来区分两种失败：
#   - 读不出 = 驱动还没就绪（开机早期），只是暂时状态，绝不能动记忆
#   - 读得出但写进去回读不符 = 驱动真的不接受这个值，记忆保留、记入 defer
touch_field_readable() {   # NODE SUB
    if [ -z "$2" ]; then
        touch_read_node "$TP_DIR/$1"
    else
        touch_read_field "$2"
    fi
}

# 让行：息屏挂起时驱动拒绝写入，游戏空间接管时会自己改 tp_report_rate。
# 这两种情况不写节点，等亮屏/退出游戏后由 reconcile 补写。
# 只在让行原因变化时记一行日志，避免看门狗每 15 秒刷屏。
touch_paused_log() {
    local m="pause:$HW_PAUSE"
    [ "$(cat "$TOUCH_MARK" 2>/dev/null)" = "$m" ] && return 0
    printf '%s\n' "$m" > "$TOUCH_MARK" 2>/dev/null
    touch_log "$(hw_pause_label "$HW_PAUSE")期间让行，触控参数暂不写入"
}

# 采样率功能与触控的「上报频率」写的是同一个节点 tp_report_rate。
# 采样率接管期间由采样率独占，触控这一项不写、不校验、不还原，
# 否则两个功能会互相覆盖，看门狗每轮都把对方的写入判成「被改动」。
touch_rate_owned() { [ -f "$F_RATE" ] || [ -f "$RATE_SNAPSHOT" ]; }
touch_item_owned() {   # NAME
    case "$1" in
        '上报频率') touch_rate_owned ;;
        *) return 1 ;;
    esac
}

touch_wait_ready() {
    local i=0
    while [ "$i" -lt "$TOUCH_WAIT_MAX" ]; do
        # 节点存在 ≠ 驱动就绪：edge_report_limit 初始化前内容为空，
        # 此时写入必然回读不符，会被误判成「驱动不接受」而冲掉用户的记忆值。
        touch_supported && touch_read_node "$TP_DIR/edge_report_limit" && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

touch_write() {   # PATH VALUE
    local p="$1"
    [ -e "$p" ] || return 1
    printf '%s\n' "$2" > "$p" 2>/dev/null && return 0
    su 2000 -c "printf '%s\\n' '$2' > '$p'" 2>/dev/null
}

# 读取节点全文。rd 只读 64 字节，而 edge_report_limit 有近 1KB，
# 以前拿截断的 64 字节当整行再回写，会直接冲掉后面的配置。
touch_read_node() {   # PATH -> TOUCH_RD
    TOUCH_RD=$(cat "$1" 2>/dev/null | tr -d '\000\r')
    [ -n "$TOUCH_RD" ]
}

# 读回 edge_report_limit 的某个子字段。
# 字段名可能带空格（pixel limit level），值也可能带空格（20 20 20 20），
# 所以匹配到冒号后取整行剩余部分，交给 touch_norm 做归一化比较。
TOUCH_RD=""
touch_read_field() {   # FIELD
    local n
    TOUCH_RD=""
    [ -e "$TP_DIR/edge_report_limit" ] || return 1
    touch_read_node "$TP_DIR/edge_report_limit" || return 1
    n=$(printf '%s\n' "$TOUCH_RD" | sed -n "s/^ *$1 *: *//p" | tail -n 1)
    [ -n "$n" ] || return 1
    TOUCH_RD="$n"
    return 0
}

# 写一项并回读核对。
# sub 为空 = 直写整节点；否则按驱动文档的单字段语法写 "字段:值"，
# 绝不整行回写。第四列 bare = 该字段只接受裸数字（pixel limit level）。
touch_apply_one() {   # NODE SUB VALUE [MODE]
    local node="$1" sub="$2" val="$3" mode="$4" w
    if [ -z "$sub" ]; then
        touch_write "$TP_DIR/$node" "$val" || return 1
        touch_read_node "$TP_DIR/$node" || return 1
    else
        [ -e "$TP_DIR/$node" ] || return 1
        case "$mode" in
            bare) w="$val" ;;
            *) w="$sub:$val" ;;
        esac
        touch_write "$TP_DIR/$node" "$w" || return 1
        touch_read_field "$sub" || return 1
    fi
    [ "$(touch_norm "$TOUCH_RD")" = "$(touch_norm "$val")" ]
}

# 第一次接管前把节点里的原始值落到 TOUCH_SNAPSHOT，关闭或卸载时按它还原。
# 没有快照就不写节点，避免出现“能改不能还”的状态。
# 读不出原始值的项写进 TOUCH_NA：这些项不写、不校验，前端置灰。
touch_na_rebuild() {
    [ -f "$TOUCH_NA" ] && return 0
    [ -s "$TOUCH_SNAPSHOT" ] || return 0
    local name node sub mode t="${TOUCH_NA}.tmp"
    : > "$t" 2>/dev/null || return 0
    while IFS='|' read -r name node sub mode; do
        case "$name" in ''|'#'*) continue;; esac
        grep -q "^$name=" "$TOUCH_SNAPSHOT" 2>/dev/null || printf '%s\n' "$name" >> "$t"
    done < "$TOUCH_TABLE"
    mv -f "$t" "$TOUCH_NA" 2>/dev/null
}

touch_snapshot_save() {
    touch_na_rebuild
    if [ -s "$TOUCH_SNAPSHOT" ]; then
        touch_snapshot_merge
        return 0
    fi
    touch_supported || return 1
    local name node sub mode v tmp="${TOUCH_SNAPSHOT}.tmp" nat="${TOUCH_NA}.tmp"
    : > "$tmp" 2>/dev/null || return 1
    : > "$nat" 2>/dev/null || return 1
    while IFS='|' read -r name node sub mode; do
        case "$name" in ''|'#'*) continue;; esac
        v=""
        if [ -z "$sub" ]; then
            touch_read_node "$TP_DIR/$node" && v=$(printf '%s' "$TOUCH_RD" | tr -d ' \r\n')
        else
            touch_read_field "$sub" && v=$(touch_norm "$TOUCH_RD" | tr ' ' ',')
        fi
        case "$v" in ''|*[!0-9,]*) printf '%s\n' "$name" >> "$nat"; continue;; esac
        printf '%s=%s\n' "$name" "$v" >> "$tmp"
    done < "$TOUCH_TABLE"
    mv -f "$nat" "$TOUCH_NA" 2>/dev/null
    if [ -s "$tmp" ]; then
        mv -f "$tmp" "$TOUCH_SNAPSHOT" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    [ -s "$TOUCH_SNAPSHOT" ]
}

# 升级后旧快照可能缺新增项（v3.3.0 的 3 项）：补读原值追加进去，
# 否则新项「能改不能还」——关闭功能时会停留在用户设的值上。
touch_snapshot_merge() {
    [ -s "$TOUCH_SNAPSHOT" ] || return 0
    touch_supported || return 0
    local name node sub mode v tmp="${TOUCH_SNAPSHOT}.tmp" added=0
    cp -f "$TOUCH_SNAPSHOT" "$tmp" 2>/dev/null || return 0
    while IFS='|' read -r name node sub mode; do
        case "$name" in ''|'#'*) continue;; esac
        grep -q "^$name=" "$tmp" 2>/dev/null && continue
        v=""
        if [ -z "$sub" ]; then
            touch_read_node "$TP_DIR/$node" && v=$(printf '%s' "$TOUCH_RD" | tr -d ' \r\n')
        else
            touch_read_field "$sub" && v=$(touch_norm "$TOUCH_RD" | tr ' ' ',')
        fi
        case "$v" in ''|*[!0-9,]*) continue;; esac
        printf '%s=%s\n' "$name" "$v" >> "$tmp"
        added=$((added + 1))
    done < "$TOUCH_TABLE"
    if [ "$added" -gt 0 ]; then
        mv -f "$tmp" "$TOUCH_SNAPSHOT" 2>/dev/null
        touch_log "快照补齐 $added 项（新增参数已记录原值）"
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# 不可用项不参与校验，避免 verify 永远不符、看门狗空转。
# 注意这里只做「本轮不写不校验」，绝不删用户的记忆值：
# 以前这里 cfg_set "$n" ""，驱动开机没就绪时会把用户填的自定义数值整项抹掉，
# 用户看到的就是「重启后参数变回默认、界面读不到」。
touch_na_has() { [ -s "$TOUCH_NA" ] && grep -qx "$1" "$TOUCH_NA" 2>/dev/null; }

# 不可用项现在能读了（驱动重新就绪 / 换了机型）就撤掉标记，恢复可用。
touch_na_prune() {
    [ -s "$TOUCH_NA" ] || return 0
    local name node sub mode t="${TOUCH_NA}.tmp" keep=0
    : > "$t" 2>/dev/null || return 0
    while IFS='|' read -r name node sub mode; do
        case "$name" in ''|'#'*) continue;; esac
        grep -qx "$name" "$TOUCH_NA" 2>/dev/null || continue
        if touch_field_readable "$node" "$sub"; then
            touch_log "$name 节点已就绪，恢复可用"
        else
            printf '%s\n' "$name" >> "$t"
            keep=$((keep + 1))
        fi
    done < "$TOUCH_TABLE"
    if [ "$keep" -gt 0 ]; then
        mv -f "$t" "$TOUCH_NA" 2>/dev/null
    else
        rm -f "$t" "$TOUCH_NA" 2>/dev/null
    fi
    return 0
}

# 暂缓项：驱动确实不接受这个值，但记忆必须保留（用户下次还能看到自己填的数）。
# verify 跳过这些项，否则看门狗每 15 秒重写一次同一项。
touch_defer_has() { [ -s "$TOUCH_DEFER" ] && grep -qx "$1" "$TOUCH_DEFER" 2>/dev/null; }
touch_defer_add() {
    [ -n "$1" ] || return 0
    touch_defer_has "$1" && return 0
    printf '%s\n' "$1" >> "$TOUCH_DEFER" 2>/dev/null
}
touch_defer_del() {
    [ -s "$TOUCH_DEFER" ] || return 0
    grep -vx "$1" "$TOUCH_DEFER" > "${TOUCH_DEFER}.tmp" 2>/dev/null
    if [ -s "${TOUCH_DEFER}.tmp" ]; then
        mv -f "${TOUCH_DEFER}.tmp" "$TOUCH_DEFER" 2>/dev/null
    else
        rm -f "${TOUCH_DEFER}.tmp" "$TOUCH_DEFER" 2>/dev/null
    fi
}

touch_apply() {
    local name node sub mode ok=0 fail=0 v sv na skip=0 want=0
    touch_na_prune
    if hw_write_paused; then
        touch_paused_log
        return 0
    fi
    touch_wait_ready || { touch_log "节点未就绪(缺失 $(touch_missing_nodes)/5)，跳过"; return 1; }
    # 等待期间可能已经息屏，再判一次，避免和挂起流程抢节点
    if hw_write_paused; then
        touch_paused_log
        return 0
    fi
    touch_snapshot_save || { touch_log "原始参数快照失败，取消写入"; return 1; }
    rm -f "$TOUCH_RB" 2>/dev/null
    na=$(tr '\n' ' ' < "$TOUCH_NA" 2>/dev/null)
    while IFS='|' read -r name node sub mode; do
        case "$name" in ''|'#'*) continue;; esac
        v=$(stq "$name")
        [ -n "$v" ] || continue
        touch_item_owned "$name" && continue
        want=$((want + 1))
        case " $na " in
            *" $name "*) skip=$((skip + 1)); continue ;;   # 不可用项：不写不校验，记忆保留
        esac
        if touch_apply_one "$node" "$sub" "$v" "$mode"; then
            ok=$((ok + 1))
            touch_defer_del "$name"
            continue
        fi
        fail=$((fail + 1))
        touch_log "$name 写入/回读不符"
        # 节点读不出来 = 驱动还没就绪，本轮放弃这一项，记忆原样保留，稍后重试
        if ! touch_field_readable "$node" "$sub"; then
            touch_log "$name 节点暂不可读，稍后重试"
            continue
        fi
        # 驱动读得出但不接受这个值：节点退回快照值，记忆绝不改写
        sv=$(grep "^$name=" "$TOUCH_SNAPSHOT" 2>/dev/null | head -n 1 | cut -d= -f2-)
        if [ -n "$sv" ] && touch_apply_one "$node" "$sub" "$sv" "$mode"; then
            # 记录「填的值>退回的值」：前端提示更清楚，不同失败尝试也不会被去重吞掉
            printf '%s=%s>%s\n' "$name" "$v" "$sv" >> "$TOUCH_RB" 2>/dev/null
            touch_log "$name 退回快照 $sv"
        fi
        # 值留在记忆里，只把它记进 defer；看门狗不再反复重写同一项
        touch_defer_add "$name"
    done < "$TOUCH_TABLE"
    # 全部有值的项都读不出 = 驱动还没就绪，一项没写。不能报成功，也不能动记忆。
    if [ "$ok" -eq 0 ] && [ "$skip" -gt 0 ] && [ "$skip" -eq "$want" ]; then
        touch_log "驱动未就绪: $skip/$want 项不可读，保留记忆稍后重试"
        return 1
    fi
    touch_log "写入完成: 通过 $ok 项 / 失败 $fail 项"
    printf 'on\n' > "$TOUCH_MARK" 2>/dev/null
    [ "$fail" -eq 0 ]
}

touch_restore() {
    touch_supported || return 1
    # 挂起/游戏接管时先不还原：保留快照，亮屏后 reconcile 会继续
    if [ -s "$TOUCH_SNAPSHOT" ] && hw_write_paused; then
        touch_paused_log
        return 0
    fi
    if [ ! -s "$TOUCH_SNAPSHOT" ]; then
        rm -f "$TOUCH_NA" "$TOUCH_RB" "$TOUCH_DEFER" 2>/dev/null
        return 0
    fi
    local name node sub mode v ok=0 fail=0
    while IFS='|' read -r name node sub mode; do
        case "$name" in ''|'#'*) continue;; esac
        v=$(grep "^$name=" "$TOUCH_SNAPSHOT" 2>/dev/null | head -n 1 | cut -d= -f2-)
        [ -n "$v" ] || continue
        touch_item_owned "$name" && continue
        if touch_apply_one "$node" "$sub" "$v" "$mode"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            touch_log "$name 还原失败"
        fi
    done < "$TOUCH_TABLE"
    touch_log "还原完成: 通过 $ok 项 / 失败 $fail 项"
    [ "$fail" -eq 0 ] && rm -f "$TOUCH_SNAPSHOT" "$TOUCH_NA" "$TOUCH_RB" "$TOUCH_DEFER" 2>/dev/null
    [ "$fail" -eq 0 ]
}

touch_verify() {
    local name node sub mode ok=0 fail=0 v
    touch_supported || return 1
    # 让行期间不核对：此时驱动会拒绝写入，核对只会造成看门狗空转
    hw_write_paused && return 0
    while IFS='|' read -r name node sub mode; do
        case "$name" in ''|'#'*) continue;; esac
        v=$(stq "$name")
        [ -n "$v" ] || continue
        touch_item_owned "$name" && continue
        # 不可用项(快照缺项)/已知暂缓项不校验：记忆保留着，节点写不进去不是故障
        touch_na_has "$name" && continue
        touch_defer_has "$name" && continue
        if [ -z "$sub" ]; then touch_read_node "$TP_DIR/$node" || { fail=$((fail + 1)); continue; }; else touch_read_field "$sub" || { fail=$((fail + 1)); continue; }; fi
        if [ "$(touch_norm "$TOUCH_RD")" = "$(touch_norm "$v")" ]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    done < "$TOUCH_TABLE"
    [ "$fail" -eq 0 ]
}

touch_preset() {   # official_gaming | official_daily
    case "$1" in
        official_daily)
            printf '%s\n' '跟手速度=2' '稳定程度=2' '灵敏程度=2' '上报频率=2' \
                '边缘防抖=1' '防抖像素=10' '防抖时间=100' '点击容错=10' \
                '长按识别=1' '长按时长=500' '长按范围=10,10,20,20' '边缘防误触=5' \
                '握持防误触=2' '手掌抑制=1' '手写笔模式=0' ;;
        *)
            printf '%s\n' '跟手速度=4' '稳定程度=0' '灵敏程度=4' '上报频率=4' \
                '边缘防抖=0' '防抖像素=0' '防抖时间=0' '点击容错=0' \
                '长按识别=0' '长按时长=0' '长按范围=0,0,0,0' '边缘防误触=0' \
                '握持防误触=0' '手掌抑制=0' '手写笔模式=0' ;;
    esac
}

TOUCH_KEY=""
# 中文项名 -> 前端使用的英文短名（写全局，调用方不再 $( )，省 12 次 fork）
touch_key() {
    TOUCH_KEY=""
    case "$1" in
        '跟手速度')          TOUCH_KEY=follow ;;
        '稳定程度')          TOUCH_KEY=stability ;;
        '灵敏程度')          TOUCH_KEY=sensibility ;;
        '上报频率')          TOUCH_KEY=report ;;
        '边缘防抖')          TOUCH_KEY=edge_deb ;;
        '防抖像素')          TOUCH_KEY=edge_px ;;
        '防抖时间')          TOUCH_KEY=edge_ms ;;
        '点击容错')          TOUCH_KEY=click_tol ;;
        '长按识别')          TOUCH_KEY=long_on ;;
        '长按时长')          TOUCH_KEY=long_ms ;;
        '长按范围')          TOUCH_KEY=long_range ;;
        '边缘防误触')        TOUCH_KEY=edge_anti ;;
        '握持防误触')        TOUCH_KEY=edge_grip ;;
        '手掌抑制')          TOUCH_KEY=palm ;;
        '手写笔模式')        TOUCH_KEY=pen ;;
        *) TOUCH_KEY=$1 ;;
    esac
    return 0
}

# 按 touch_table 顺序序列化成前端格式：follow=4;stability=0;...;
# 注意不能删逗号：长按范围的值本身就是 "10,10,20,20"。
# build 只写全局，状态快照直接取；string 版本保留给命令/自测。
touch_vals_build() {
    local name node sub mode v out="" k
    [ -n "$ST_LOADED" ] || state_load
    while IFS='|' read -r name node sub mode; do
        case "$name" in ''|'#'*) continue;; esac
        state_val "$name"; v="$STATE_V"
        [ -n "$v" ] || continue
        case "$v" in *[' ;']*) v=$(printf '%s' "$v" | tr -d ' ;\r\n') ;; esac
        [ -n "$v" ] || continue
        touch_key "$name"; k=$TOUCH_KEY
        out="${out}${k}=${v};"
    done < "$TOUCH_TABLE"
    TOUCH_VALS="$out"
}
touch_vals_string() {
    touch_vals_build
    printf '%s' "$TOUCH_VALS"
}

# 预设单项取值：纯 case，不 fork。状态快照每轮都要拿它和当前值比对，
# 以前每次 12 组 grep/head/cut（约 0.5 秒），是快照慢的大头。
PRESET_V=""
preset_val() {   # PRESET NAME -> PRESET_V
    PRESET_V=""
    case "$1" in
        official_daily)
            case "$2" in
                '跟手速度')   PRESET_V=2 ;;
                '稳定程度')   PRESET_V=2 ;;
                '灵敏程度')   PRESET_V=2 ;;
                '上报频率')   PRESET_V=2 ;;
                '边缘防抖')   PRESET_V=1 ;;
                '防抖像素')   PRESET_V=10 ;;
                '防抖时间')   PRESET_V=100 ;;
                '点击容错')   PRESET_V=10 ;;
                '长按识别')   PRESET_V=1 ;;
                '长按时长')   PRESET_V=500 ;;
                '长按范围')   PRESET_V="10,10,20,20" ;;
                '边缘防误触') PRESET_V=5 ;;
                '握持防误触') PRESET_V=2 ;;
                '手掌抑制')   PRESET_V=1 ;;
                '手写笔模式') PRESET_V=0 ;;
            esac
            ;;
        *)
            case "$2" in
                '跟手速度')   PRESET_V=4 ;;
                '稳定程度')   PRESET_V=0 ;;
                '灵敏程度')   PRESET_V=4 ;;
                '上报频率')   PRESET_V=4 ;;
                '边缘防抖')   PRESET_V=0 ;;
                '防抖像素')   PRESET_V=0 ;;
                '防抖时间')   PRESET_V=0 ;;
                '点击容错')   PRESET_V=0 ;;
                '长按识别')   PRESET_V=0 ;;
                '长按时长')   PRESET_V=0 ;;
                '长按范围')   PRESET_V="0,0,0,0" ;;
                '边缘防误触') PRESET_V=0 ;;
                '握持防误触') PRESET_V=0 ;;
                '手掌抑制')   PRESET_V=0 ;;
                '手写笔模式') PRESET_V=0 ;;
            esac
            ;;
    esac
    return 0
}

# 预设定义序列化（不落盘），必须和 touch_vals_string 逐字节同格式
touch_preset_build() {   # NAME
    local name node sub mode out="" k
    while IFS='|' read -r name node sub mode; do
        case "$name" in ''|'#'*) continue;; esac
        preset_val "$1" "$name"
        [ -n "$PRESET_V" ] || continue
        touch_key "$name"; k=$TOUCH_KEY
        out="${out}${k}=${PRESET_V};"
    done < "$TOUCH_TABLE"
    TOUCH_PRESET_VALS="$out"
}
touch_preset_vals() {   # NAME
    touch_preset_build "$1"
    printf '%s' "$TOUCH_PRESET_VALS"
}

touch_preset_to_state() {   # 只写记忆，不写节点
    local kv k v na=""
    [ -s "$TOUCH_NA" ] && na=$(tr '\n' ' ' < "$TOUCH_NA" 2>/dev/null)
    for kv in $(touch_preset "$1"); do
        k=${kv%%=*}; v=${kv#*=}
        case " $na " in *" $k "*) continue;; esac   # 不可用项不写记忆
        cfg_set "$k" "$v"
    done
    cfg_set '触控预设' "$1"
}
