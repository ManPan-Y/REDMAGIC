#!/system/bin/sh
# ============================================================
# WebUI 主循环：命令分发 + 状态对账 + 快照节流。
# 节流：前端心跳新鲜 -> FAST；没人看 -> ECO（省电）。
# 每一轮都按「目标周期 - 本轮耗时」补睡，绝不空转。
# ============================================================

HB_TTL=3
FAST_MS=500
ECO_MS=2000
FAST_STATUS_MS=500
ECO_STATUS_MS=3000
MIN_SLEEP_MS=20
RECONCILE_MS=3000
RS_T=0

ms_now() {
    local t frac
    read -r t _ < /proc/uptime 2>/dev/null || t="0.000"
    case "$t" in *.*) ;; *) t="$t.000";; esac
    frac=$(printf '%s' "${t#*.}000" | cut -c1-3)
    t=${t%%.*}
    # 必须去掉前导零：mksh/ash 会把 08 当八进制作数直接报错
    t=$(printf '%s' "$t" | sed 's/^0*//')
    frac=$(printf '%s' "$frac" | sed 's/^0*//')
    [ -n "$t" ] || t=0
    [ -n "$frac" ] || frac=0
    printf '%s' $(( t * 1000 + frac ))
}

sleep_ms() {
    local ms="$1"
    case "$ms" in ''|*[!0-9]*) ms=$MIN_SLEEP_MS;; esac
    [ "$ms" -ge "$MIN_SLEEP_MS" ] || ms=$MIN_SLEEP_MS
    # 毫秒余数不能丢：以前 1000ms 以上只睡整数秒，1500ms 会被截成 1s。
    # 但 sleep 未必支持小数（toybox 多数支持，busybox 视编译选项），
    # 所以小数失败就退回整秒——至少 1 秒，不做 0.000 的空转。
    if [ "$ms" -ge 1000 ]; then
        sleep "$(( ms / 1000 )).$(printf '%03d' $(( ms % 1000 )))" 2>/dev/null && return 0
        sleep "$(( ms / 1000 ))" 2>/dev/null && return 0
        sleep 1
    else
        sleep "0.$(printf '%03d' "$ms")" 2>/dev/null && return 0
        sleep 1
    fi
}

hb_fresh() {
    local m now
    [ -f "$WEBUI_HB" ] || return 1
    m=$(stat -c %Y "$WEBUI_HB" 2>/dev/null) || return 1
    now=$(date +%s 2>/dev/null) || return 1
    case "$m$now" in *[!0-9]*) return 1;; esac
    [ $(( now - m )) -le "$HB_TTL" ]
}

json_pick() {   # LINE KEY —— 只解析 {"action":"x","value":"y"} 这种一行的格式
    printf '%s' "$1" | sed -n 's/.*"'"$2"'"[ ]*:[ ]*"\([^"]*\)".*/\1/p' | head -n 1
}

# 状态对账：把真实节点拉回记忆值；只在必要的时候动手
HW_LAST=""
reconcile() {
    local now hw_tok
    now=$(ms_now)
    [ $(( now - RS_T )) -lt "$RECONCILE_MS" ] && return 0
    RS_T=$now

    # 温控先于充电加速：加速的前置条件就是温控屏蔽有效
    if [ -f "$F_THERMAL" ] && ! thermal_effective; then
        thermal_on || { rm -f "$F_THERMAL"; cfg_set '温控移除' 0; }
    fi
    if [ -f "$F_BOOST" ]; then
        if thermal_effective; then
            if boost_guard; then
                boost_apply || errlog "充电加速: 应用失败，下一轮重试"
            else
                boost_release
            fi
        else
            boost_release; rm -f "$F_BOOST"; cfg_set '充电加速' 0
            mlog "充电加速: 温控失效，已停止"
        fi
    elif [ -f "$SNAP_BOOST" ]; then
        boost_release
    fi
    if [ -f "$F_BOOST_HEAT" ]; then
        heat_apply || { rm -f "$F_BOOST_HEAT"; cfg_set '解除热降流' 0; mlog "解除热降流: 本机无可用降温设备，已关闭"; }
    fi

    # 熄屏提速：守卫不过（息屏/拔电/超温/分离）时 fast_apply 内部会立刻还原真实状态
    if [ -f "$F_FAST" ] || [ -f "$FAST_MARK" ]; then
        fast_apply || true
    fi

    # CPU / GPU 频率：读节点便宜，每轮核对；只有锁定档才主动把被系统改掉的值拉回
    if cpu_active; then
        cpu_verify || cpu_apply || true
    elif [ -f "$SNAP_CPU" ]; then
        cpu_release || true
    fi
    if gpu_active; then
        gpu_paused   # 息屏/游戏空间接管期间 kgsl 拒写，等亮屏再补
        if [ -z "$GPU_PAUSE" ]; then gpu_verify || gpu_apply || true; fi
    elif [ -f "$SNAP_GPU" ]; then
        gpu_release || true
    fi

    # 触控/采样率：息屏挂起与游戏空间接管期间一律让行；
    # 只在「让行 -> 可写」的切换点补写一次，清醒状态下不反复 fork 读节点。
    if [ -f "$F_TOUCH" ] || [ -f "$F_RATE" ] || [ -f "$RATE_SNAPSHOT" ] || [ -s "$TOUCH_SNAPSHOT" ]; then
        hw_write_paused
        if [ -z "$HW_PAUSE" ]; then hw_tok="ready"; else hw_tok="pause:$HW_PAUSE"; fi
        if [ "$hw_tok" != "$HW_LAST" ]; then
            HW_LAST=$hw_tok
            if [ "$hw_tok" = "ready" ]; then
                if [ -f "$F_TOUCH" ] && ! touch_verify; then touch_apply; fi
                if [ -f "$F_RATE" ]; then
                    rate_boost_on
                elif [ -f "$RATE_SNAPSHOT" ]; then
                    rate_boost_off || true
                fi
            else
                # 进入让行只在切换点记一次，避免每轮刷日志
                rate_mark "$hw_tok" "采样率: $(hw_pause_label "$HW_PAUSE")期间让行，条件解除后自动补写"
            fi
        fi
    fi

    # 风扇：系统关着就不碰（记住用户的选择，等系统开）；息屏保持才去动 enable
    if [ -f "$F_FAN" ]; then
        if [ -f "$F_FAN_KEEP" ] && [ "$(screen_state)" = "asleep" ]; then
            fan_keep_set 1
        fi
        if fan_sys_on; then
            if [ "$(screen_state)" = "awake" ] && [ -f "$SNAP_FAN_KEEP" ]; then
                fan_keep_stop   # 亮屏了：把强行开的风扇还给系统
            fi
            if [ -f "$F_FAN_TEMP" ]; then fan_level_write "$(fan_temp_target)"
            else fan_level_write "$(stq '风扇档位')"; fi
        fi
    else
        if [ -f "$SNAP_FAN_KEEP" ] && [ "$(rdv "$FAN_ENABLE")" = "0" ]; then fan_keep_stop; fi
        if [ -f "$SNAP_FAN" ]; then fan_release; fi
    fi

    if [ -f "$F_PUMP" ]; then
        if [ -f "$F_PUMP_KEEP" ] && [ "$(screen_state)" = "asleep" ]; then pump_keep_set 1; fi
        if pump_sys_on; then
            if [ "$(screen_state)" = "awake" ] && [ -f "$SNAP_PUMP_KEEP" ]; then pump_keep_stop; fi
            if [ -f "$F_PUMP_TEMP" ]; then pump_speed_write "$(pump_speed_of "$(pump_temp_target)")"
            else pump_speed_write "$(pump_speed_of "$(stq '液冷档位')")"; fi
        fi
    else
        if [ -f "$SNAP_PUMP_KEEP" ] && [ "$(rdv "$PUMP_ENABLE")" = "0" ]; then pump_keep_stop; fi
        if [ -f "$SNAP_PUMP" ]; then pump_release; fi
    fi
    return 0
}

# 前端每次打开 WebUI 都会刷新 .webui_hb；打开那一刻若触控参数被 ROM 重置过，
# 前端只看得到「记忆值」，看不到「节点实际值」。所以一发现心跳从无到有，就先核对再出快照。
webui_open_hook() {
    if [ -f "$F_TOUCH" ] && [ "$(touch_missing_nodes)" = "0" ]; then
        # 驱动晚就绪时先撤销已恢复项的置灰；这些项接下来会以「不符」被发现并重写。
        # 只在打开界面/看门狗这类低频入口做，verify 内部绝不动 NA，否则刚撤销就判不符，来回空转。
        touch_na_prune
        touch_verify || { mlog "WebUI 打开: 触控节点与记忆不符，重新写入"; touch_apply; }
    fi
    if [ -f "$F_RATE" ]; then
        rate_verify || rate_boost_on
    fi
}

webui_loop() {
    local line act val tick status_ms last_status start spent n=0 hb_seen=0
    : > "$WEBUI_HB_SEEN" 2>/dev/null
    : > "$WEBUI_CMD" 2>/dev/null
    last_status=0
    while :; do
        # 父进程被 kill -9 后本循环会被 reparent 到 1：自己退出，别留孤儿写快照
        [ -d "/proc/$SVC_SELF" ] || exit 0
        start=$(ms_now)
        if hb_fresh; then
            tick=$FAST_MS; status_ms=$FAST_STATUS_MS
            if [ "$hb_seen" = "0" ]; then hb_seen=1; webui_open_hook; fi
        else
            tick=$ECO_MS; status_ms=$ECO_STATUS_MS
            hb_seen=0
        fi

        # 命令队列：先 mv 走再逐行处理，处理期间前端追加的新命令不会丢
        if [ -s "$WEBUI_CMD" ]; then
            mv -f "$WEBUI_CMD" "$WEBUI_CMD.pending" 2>/dev/null
            if [ -s "$WEBUI_CMD.pending" ]; then
                while IFS= read -r line; do
                    [ -n "$line" ] || continue
                    act=$(json_pick "$line" action)
                    val=$(json_pick "$line" value)
                    if [ -n "$act" ]; then
                        mlog "命令: $act=$val"
                        webui_handle_cmd "$act" "$val" || errlog "命令 $act 执行失败"
                    else
                        errlog "命令队列里有无法解析的行: $line"
                    fi
                done < "$WEBUI_CMD.pending"
                rm -f "$WEBUI_CMD.pending" 2>/dev/null   # 处理完就删，不留空文件
                last_status=0    # 命令来了立刻出快照，前端不用等下一个周期
            fi
        fi

        n=$(( n + 1 ))
        [ $(( n % 30 )) -eq 0 ] && state_sync

        reconcile

        spent=$(ms_now)
        if [ "$last_status" = "0" ] || [ $(( spent - last_status )) -ge "$status_ms" ]; then
            status_write || errlog "快照写入失败"
            last_status=$(ms_now)
        fi

        spent=$(ms_now)
        sleep_ms "$(( tick - (spent - start) ))"
    done
}
