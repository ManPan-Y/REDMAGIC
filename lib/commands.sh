#!/system/bin/sh
# ============================================================
# 前端命令的唯一入口。每个 action 的规矩：
#   1) 先校验值（非法值直接丢，绝不写半截状态）
#   2) 再写记忆（state.txt / 标记）
#   3) 最后才动节点；节点写失败必须回滚记忆，否则 reconcile 会反复重放
# ============================================================

# 数值校验：整型且落在 [lo,hi]
num_ok() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null; }

# 前端传来非法值：记一条日志后丢弃，绝不写半截状态
bad_cmd() { errlog "命令 $1 的值非法: ${2:-空}"; }

# 单开关：on/off -> 标记 + 记忆；sup 里给的功能实际不成立就回滚
set_flag() {   # set_flag KEY on|off
    local k="$1" v="$2" f
    f=$(flag_file "$k")
    if [ "$v" = "on" ]; then : > "$f" 2>/dev/null; else rm -f "$f" 2>/dev/null; fi
    cfg_set "$(flag_key "$k")" "$([ "$v" = "on" ] && echo 1 || echo 0)"
}

webui_handle_cmd() {
    local action="$1" v="$2" lv sp
    case "$action" in
        hb)
            : > "$WEBUI_HB" 2>/dev/null
            ;;
        # ---------- 风扇 ----------
        fan_on)
            set_flag fan "$v"
            if [ "$v" = "on" ]; then
                if ! fan_sys_on; then
                    mlog "风扇: 系统开关为关，已记为开但暂不接管"
                else
                    lv=$(stq '风扇档位')
                    case "$lv" in 1|2|3|4|5) fan_level_write "$lv" || { mlog "风扇: 写档位失败"; rm -f "$F_FAN"; cfg_set '风扇极速' 0; };; esac
                fi
            else
                fan_release
            fi
            ;;
        fan_level)
            num_ok "$v" 1 5 || { bad_cmd fan_level "$v"; return 0; }
            cfg_set '风扇档位' "$v"
            [ -f "$F_FAN" ] && fan_level_write "$v"
            ;;
        fan_keep)  # on|off 息屏保持
            if [ "$v" = "on" ]; then
                : > "$F_FAN_KEEP"; cfg_set '风扇息屏保持' 1
            else
                rm -f "$F_FAN_KEEP"; cfg_set '风扇息屏保持' 0; fan_keep_stop
            fi
            ;;
        fan_temp)  # off|auto|custom
            case "$v" in
                off) rm -f "$F_FAN_TEMP"; cfg_set '风扇温度联动' 0;;
                auto|custom) : > "$F_FAN_TEMP"; cfg_set '风扇温度联动' 1; cfg_set '温度联动模式' "$v"; set_flag fan on;;
                *) return 0;;
            esac
            ;;
        fan_temp_thr)
            num_ok "$v" 20 70 || { bad_cmd fan_temp_thr "$v"; return 0; }
            cfg_set '风扇触发温度' "$v"
            ;;
        # ---------- 液冷 ----------
        pump_on)
            set_flag pump "$v"
            if [ "$v" = "on" ]; then
                if ! pump_sys_on; then
                    mlog "液冷: 系统开关为关，已记为开但暂不接管"
                else
                    lv=$(stq '液冷档位')
                    case "$lv" in 1|2|3|4) pump_speed_write "$(pump_speed_of "$lv")" || { mlog "液冷: 写转速失败"; rm -f "$F_PUMP"; cfg_set '液冷控制' 0; };; esac
                fi
            else
                pump_release
            fi
            ;;
        pump_level)
            num_ok "$v" 1 4 || { bad_cmd pump_level "$v"; return 0; }
            cfg_set '液冷档位' "$v"
            [ -f "$F_PUMP" ] && pump_speed_write "$(pump_speed_of "$v")"
            ;;
        pump_keep)  # on|off 息屏保持
            if [ "$v" = "on" ]; then : > "$F_PUMP_KEEP"; cfg_set '液冷息屏保持' 1; else rm -f "$F_PUMP_KEEP"; cfg_set '液冷息屏保持' 0; pump_keep_stop; fi
            ;;
        pump_temp)  # off|auto|custom
            case "$v" in
                off) rm -f "$F_PUMP_TEMP"; cfg_set '液冷温度联动' 0;;
                auto|custom) : > "$F_PUMP_TEMP"; cfg_set '液冷温度联动' 1; cfg_set '液冷联动模式' "$v"; set_flag pump on;;
                *) return 0;;
            esac
            ;;
        pump_temp_thr)
            num_ok "$v" 20 70 || { bad_cmd pump_temp_thr "$v"; return 0; }
            cfg_set '液冷触发温度' "$v"
            ;;
        # ---------- 充电分离 ----------
        charge_on)
            set_flag charge "$v"
            # 开关一落就同步系统分离开关和快照缓存，不等 3 秒巡逻
            if [ "$v" = "on" ]; then
                charge_sep_set "$(charge_sep_want)"
            else
                charge_sep_set 0
            fi
            ;;
        charge_thr)
            num_ok "$v" 20 100 || { bad_cmd charge_thr "$v"; return 0; }
            printf '%s\n' "$v" > "$SEP_LIMIT" 2>/dev/null
            cfg_set '充电分离阈值' "$v"
            ;;
        # ---------- 温控 ----------
        thermal_on)
            if [ "$v" = "on" ]; then
                if thermal_on; then
                    : > "$F_THERMAL"; cfg_set '温控移除' 1
                    # 解除热降流依赖温控：温控重新开起来就顺带恢复
                    [ -f "$F_BOOST_HEAT" ] && heat_apply
                else
                    mlog "温控屏蔽: 开启失败"
                    rm -f "$F_THERMAL"; cfg_set '温控移除' 0
                fi
            else
                thermal_off
                rm -f "$F_THERMAL"; cfg_set '温控移除' 0
                # 温控关掉后充电加速失去前置条件，必须一起关
                if [ -f "$F_BOOST" ]; then
                    boost_release
                    rm -f "$F_BOOST"; cfg_set '充电加速' 0
                    mlog "充电加速: 温控已关闭，连带停止加速"
                fi
            fi
            ;;
        # ---------- 充电加速 ----------
        boost_on)
            if [ "$v" = "on" ]; then
                if ! thermal_effective; then
                    mlog "充电加速: 需先开启温控屏蔽"
                    rm -f "$F_BOOST"; cfg_set '充电加速' 0
                    return 0
                fi
                if boost_guard; then
                    : > "$F_BOOST"; cfg_set '充电加速' 1
                    # 写失败就回滚开关，绝不让界面显示“加速中”而节点没动
                    boost_apply || {
                        boost_release || errlog "充电加速: 回滚还原失败，快照已保留"
                        rm -f "$F_BOOST"; cfg_set '充电加速' 0
                        mlog "充电加速: 写入失败，已回滚开关"
                    }
                else
                    mlog "充电加速: 守卫未通过（温度/电量/分离），记为开，条件满足后自动生效"
                    : > "$F_BOOST"; cfg_set '充电加速' 1
                fi
            else
                rm -f "$F_BOOST"; cfg_set '充电加速' 0
                boost_release
            fi
            ;;
        release)   # 前端侧滑返回时发的收尾命令：把「息屏保持」这类临时接管还回去
            [ -f "$SNAP_FAN_KEEP" ] && fan_keep_stop
            [ -f "$SNAP_PUMP_KEEP" ] && pump_keep_stop
            ;;
        boost_thr)
            num_ok "$v" 20 70 || { bad_cmd boost_thr "$v"; return 0; }
            printf '%s\n' "$v" > "$BOOST_LIMIT" 2>/dev/null
            cfg_set '充电加速温度上限' "$v"
            ;;
        boost_heat)
            if [ "$v" = "on" ]; then
                if heat_apply; then : > "$F_BOOST_HEAT"; cfg_set '解除热降流' 1
                else mlog "解除热降流: 本机无 battery 降温设备"; rm -f "$F_BOOST_HEAT"; cfg_set '解除热降流' 0; fi
            else
                rm -f "$F_BOOST_HEAT"; cfg_set '解除热降流' 0; heat_release
            fi
            ;;
        # ---------- 亮度 ----------
        bright_on)
            set_flag brightness "$v"
            if [ "$v" = "on" ] && [ -e "$BRIGHT_NA" ]; then
                # 目标值可能刚改过，清除旧的“不可用”结论，让守护重试一次
                rm -f "$BRIGHT_NA"
            fi
            ;;
        bright_goal)
            num_ok "$v" 1 20000 || { bad_cmd bright_goal "$v"; return 0; }
            cfg_set '亮度解锁目标' "$v"
            rm -f "$BRIGHT_NA" 2>/dev/null
            ;;
        # ---------- 触控 ----------
        touch_on)
            set_flag touch "$v"
            if [ "$v" = "on" ]; then
                if [ "$(touch_missing_nodes)" != "0" ]; then
                    mlog "触控: 节点缺失，无法开启"
                    rm -f "$F_TOUCH"; cfg_set '触控优化' 0
                else
                    rm -f "$TOUCH_DEFER" 2>/dev/null   # 显式开启：此前暂缓的项全部重试
                    touch_apply
                fi
            else
                TOUCH_WAIT_MAX=15 touch_restore >/dev/null 2>&1 || true
            fi
            ;;
        touch_param)  # 名=值
            local k="${v%%=*}" val="${v#*=}"
            [ "$k" != "$v" ] || { bad_cmd touch_param "$v"; return 0; }
            case "$val" in ''|*[!0-9,]*) bad_cmd touch_param "$v"; return 0;; esac
            val=$(printf '%s' "$val" | cut -c1-64)
            # 只允许触控表里已有的项，防止任意 key 被写进 state.txt
            grep -q "^$k|" "$TOUCH_TABLE" 2>/dev/null || { bad_cmd touch_param "$v"; return 0; }
            cfg_set "$k" "$val"
            ;;
        touch_apply)
            if [ -f "$F_TOUCH" ]; then
                # 用户点了「应用」= 明确的重新应用请求：暂缓项全部再试一次
                rm -f "$TOUCH_DEFER" 2>/dev/null
                touch_apply
            fi
            ;;
        # ---------- 熄屏提速 ----------
        fast_on)
            if [ "$v" = "on" ]; then
                : > "$F_FAST"; cfg_set '熄屏提速' 1
                if fast_guard; then
                    # 写失败就回滚开关，不让界面显示“生效中”而节点没动
                    fast_apply || {
                        fast_release || true
                        rm -f "$F_FAST"; cfg_set '熄屏提速' 0
                        mlog "熄屏提速: 写入失败，已回滚开关"
                    }
                else
                    mlog "熄屏提速: 守卫未通过（亮屏/插电/温度/分离），条件满足后自动生效"
                fi
            else
                rm -f "$F_FAST"; cfg_set '熄屏提速' 0
                fast_release
            fi
            ;;
        # ---------- 采样率 ----------
        rate_on)
            if [ "$v" = "on" ]; then
                : > "$F_RATE"; cfg_set '采样率接管' 1
                rate_boost_on
                case $? in
                    0|2) ;;   # 2 = 让行（息屏/游戏空间接管），亮屏后自动补写
                    *) rm -f "$F_RATE"; cfg_set '采样率接管' 0; mlog "采样率: 写入失败，已回滚开关" ;;
                esac
            else
                rm -f "$F_RATE"; cfg_set '采样率接管' 0
                rate_boost_off
            fi
            ;;
        rate_max)
            num_ok "$v" 120 720 || { bad_cmd rate_max "$v"; return 0; }
            cfg_set '采样率上限' "$v"
            [ -f "$F_RATE" ] && rate_boost_on
            ;;
        # ---------- CPU / GPU 频率 ----------
        cpu_freq)   # 簇序号=MHz（0 = 不接管）
            local idx="${v%%=*}" mhz="${v#*=}" key
            [ "$idx" != "$v" ] || { bad_cmd cpu_freq "$v"; return 0; }
            case "$idx" in 0) key='CPU小核频率' ;; 1) key='CPU大核频率' ;;
                *) bad_cmd cpu_freq "$v"; return 0 ;; esac
            num_ok "$mhz" 0 6000 || { bad_cmd cpu_freq "$v"; return 0; }
            if [ "$mhz" = "0" ]; then
                cfg_set "$key" 0
                cpu_apply || cpu_release
                return 0
            fi
            cpu_policy_at "$idx" || { mlog "CPU: 本机没有第 $((idx + 1)) 簇"; return 0; }
            if ! cpu_khz_of "$CPU_P" "$mhz"; then
                bad_cmd cpu_freq "$v"
                return 0
            fi
            cfg_set "$key" "$mhz"
            cpu_apply || mlog "CPU: 写入失败，交给对账重试"
            ;;
        gpu_freq)   # MHz（0 = 不接管）
            num_ok "$v" 0 3000 || { bad_cmd gpu_freq "$v"; return 0; }
            if [ "$v" = "0" ]; then
                cfg_set 'GPU频率' 0
                gpu_release
                return 0
            fi
            if ! gpu_index_of "$v"; then bad_cmd gpu_freq "$v"; return 0; fi
            cfg_set 'GPU频率' "$v"
            case $(gpu_apply; echo $?) in
                0|2) ;;
                *) mlog "GPU: 写入失败，交给对账重试" ;;
            esac
            ;;
        freq_lock)   # on|off：锁定后 min=max
            case "$v" in
                on) cfg_set '频率锁定' 1 ;;
                off) cfg_set '频率锁定' 0 ;;
                *) bad_cmd freq_lock "$v"; return 0 ;;
            esac
            cpu_apply || true
            gpu_apply || true
            ;;
        *) mlog "未知命令: $action" ;;
    esac
    return 0
}
