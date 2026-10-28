#!/system/bin/sh
# ============================================================
# 状态快照：每行一条 key=value，前端 500ms 读一次。
# 只读不写模块以外的东西；外部读到的字符串一律过 kv_safe。
# 约定：字段缺失 = 前端保留上一份，字段为 0/空 = 明确不可用。
# 值里绝不允许出现换行（前端按行切），所以所有外部字符串都过一遍清洗。
# ============================================================

HB_FRESH=30

# 单行化 + 去掉大写标记字符（前端解析键名时不区分大小写，容易撞）；过长直接截断
kv_safe() {   # VALUE DEFAULT
    local v d
    v=$(printf '%s' "$1" | tr -d '\r\n' | tr -d '"\\')
    d=$(printf '%s' "$2" | tr -d '\r\n' | tr -d '"\\')
    [ ${#v} -le 200 ] || v="$d"
    printf '%s' "$v"
}
kv_num() {    # VALUE DEFAULT —— 只留整数
    case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
# 带一位小数的数值（百分号以外的字符一律剔除）
kv_dec() {    # VALUE DEFAULT
    case "$1" in '') printf '%s' "$2" ;; esac
    case "$1" in ''|*[!0-9.]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
flag_int() { [ -f "$1" ] && printf '1' || printf '0'; }
bool_int() { [ -n "$1" ] && [ "$1" != "0" ] && printf '1' || printf '0'; }

stat_age() {
    local m now
    [ -f "$WEBUI_STATUS" ] || { printf '999999'; return 0; }
    m=$(stat -c %Y "$WEBUI_STATUS" 2>/dev/null)
    now=$(date +%s 2>/dev/null)
    case "$m" in ''|*[!0-9]*) printf '999999'; return 0;; esac
    case "$now" in ''|*[!0-9]*) printf '999999'; return 0;; esac
    printf '%s' $((now - m))
}

hb_state() {
    local age
    age=$(stat_age)
    if [ "$age" -le "$HB_FRESH" ] 2>/dev/null; then printf '1'; else printf '0'; fi
}

# 模块健康：状态码 2=正常 1=部分功能挂 0=核心挂
# load 只写全局；module_state 保留原来的 "状态码 失效项" 输出接口。
MODULE_STATE=""
MODULE_STATE_FAIL=""
module_state_load() {
    local fail="" pid
    # 先把两个动态项拍成普通变量，后面只做字符串判断：
    # 直接写 "cmd && ! cmd2 && fail=..." 会踩 set -e 与 && 链的坑，且不容易读。
    local te=0 tm=""
    thermal_effective && te=1
    tm=$(touch_missing_nodes 2>/dev/null)
    if [ -f "$SVC_PID_FILE" ]; then
        pid=$(cat "$SVC_PID_FILE" 2>/dev/null)
        case "$pid" in ''|*[!0-9]*) fail="svc";; *) [ -d "/proc/$pid" ] || fail="svc";; esac
    else
        fail="svc"
    fi
    if [ -n "$fail" ]; then MODULE_STATE=0; MODULE_STATE_FAIL="$fail"; return 0; fi
    # 核心还活着，才继续看各功能有没有失效（失效只算"部分异常"）
    if [ -f "$F_BOOST" ] && [ "$te" = "0" ]; then fail="$fail thermal"; fi
    if [ -f "$F_TOUCH" ] && [ "$tm" != "0" ]; then fail="$fail touch"; fi
    # 风扇开关为 0 是"已开启、等系统打开"的正常等待态，不算故障。
    case "$fail" in
        "") MODULE_STATE=2; MODULE_STATE_FAIL="" ;;
        *) MODULE_STATE=1; MODULE_STATE_FAIL="${fail# }" ;;
    esac
    return 0
}
module_state() {
    module_state_load
    printf '%s %s' "$MODULE_STATE" "$MODULE_STATE_FAIL"
}

# 触控序列化只保留 lib/touch.sh 里的一份实现。
# status.sh 在 touch.sh 之后 source，以前这里重复定义把修好的版本又盖回去了。

# 生成快照（调用方负责写到 .tmp 再 mv）
status_body() {
    local cap="" t="" cur="" vol="" power="0" fan_en=0 charge_on=0
    local cs="0" thr="" fan_lv="" fan_saved="" fan_avail=0 pump_lv="" pump_saved="" pump_avail=0 bl="" blm="" blg=""
    local tm="" tmiss="" tpreset="" tvals="" blgs=""
    local rate_v="0" rate_cap="" rate_tgt="0" be=0 mf te=0 i rate_pause=0 rate_ok=0
    local fan_on=0 pump_on=0 fan_keep=0 pump_keep=0 fan_temp=0 pump_temp=0
    local thermal_on=0 boost_on=0 boost_heat=0 bright_on=0 bright_avail=1 touch_on=0 rate_on=0
    local fast_on=0 fast_ready=0 fast_avail=0 fast_sio=""
    local freq_lock=0 cpusel="0" cpubsel="0" gsel="0" c_ok=0 g_ok=0 g_pause=0
    local cpu0_list="" cpu1_list="" cpu0_cur="" cpu1_cur="" gpu_list=""
    local tna="" trb="" town=""
    local ftthr=40 ptthr=40 boost_thr=42 bl_cur=0 bl_max=0 bl_goal=0
    local soh="" cycle="" full_mah="" design_mah="" res_mohm=""
    # 一次读完 state.txt：下面十几项记忆值都从变量取，不再逐项 fork grep
    state_load

    # ---- 电池 ----
    rd "$BAT_DIR/capacity"; cap="$RD"
    case "$cap" in ''|*[!0-9]*) cap=0;; esac
    rd "$BAT_DIR/temp"; t="$RD"
    case "$t" in ''|*[!0-9-]*) t=0;; esac
    rd "$BAT_DIR/current_now"; cur="$RD"
    rd "$BAT_DIR/voltage_now"; vol="$RD"
    case "$cur" in ''|*[!0-9-]*) cur="";; esac
    case "$vol" in ''|*[!0-9-]*) vol="";; esac
    if [ -n "$cur" ] && [ -n "$vol" ]; then
        # uA * uV = pW；/1e11 → 0.1W 单位，再拼出一位小数
        cur=${cur#-}; vol=${vol#-}
        i=$(( cur * vol / 100000000000 ))
        power="$(( i / 10 )).$(( i % 10 ))"
    fi

    # ---- 电池健康（只读，读不到就留空，前端据此省略显示）----
    if soh=$(battery_soh_pct 2>/dev/null); then case "$soh" in ''|*[!0-9]*) soh="";; esac; else soh=""; fi
    if cycle=$(battery_cycle 2>/dev/null); then case "$cycle" in ''|*[!0-9]*) cycle="";; esac; else cycle=""; fi
    if full_mah=$(battery_full_mah 2>/dev/null); then case "$full_mah" in ''|*[!0-9]*) full_mah="";; esac; else full_mah=""; fi
    if design_mah=$(battery_full_design_mah 2>/dev/null); then case "$design_mah" in ''|*[!0-9]*) design_mah="";; esac; else design_mah=""; fi
    if res_mohm=$(battery_resistance_mohm 2>/dev/null); then case "$res_mohm" in ''|*[!0-9.]*) res_mohm="";; esac; else res_mohm=""; fi

    # ---- 充电分离 ----
    # 分离开关由 patrol 维护并落缓存，状态快照读缓存，避免每轮 fork settings
    rd "$SEP_CACHE"; cs="$RD"
    case "$cs" in 0|1) ;; *) cs=$(sep_now);; esac
    thr=$ST_SEP_THR
    case "$thr" in ''|*[!0-9]*) thr=100;; esac
    { [ "$thr" -ge 20 ] && [ "$thr" -le 100 ]; } 2>/dev/null || thr=100

    # ---- 风扇 / 液冷 ----
    if [ -e "$FAN_LEVEL" ]; then
        fan_avail=1
        rd "$FAN_LEVEL"
        case "$RD" in ''|*[!0-9]*) ;; *) fan_lv="$RD" ;; esac
    fi
    fan_saved=$ST_FAN
    case "$fan_saved" in 1|2|3|4|5) ;; *) fan_saved="";; esac
    if [ -e "$PUMP_SPEED" ]; then
        pump_avail=1
        rd "$PUMP_SPEED"
        case "$RD" in 40) pump_lv=1;; 60) pump_lv=2;; 80) pump_lv=3;; 90) pump_lv=4;; esac
    fi
    pump_saved=$ST_PUMP
    case "$pump_saved" in 1|2|3|4) ;; *) pump_saved="";; esac
    rd "$FAN_ENABLE"; fan_en=$(bool_int "$RD")

    # ---- 采样率（硬件档位） ----
    # 直接读 tp_report_rate 档位换算 Hz；节点缺失时给 0，前端显示 --
    if rate_level_hz "$(rate_hw_level 2>/dev/null)" 2>/dev/null; then
        rate_v=$RATE_LEVEL_HZ
    else
        rate_v="0"
    fi
    rate_cap=$ST_RCAP
    case "$rate_cap" in ''|*[!0-9]*) rate_cap="";; esac
    { [ -n "$rate_cap" ] && [ "$rate_cap" -ge 120 ] && [ "$rate_cap" -le 720 ]; } 2>/dev/null || rate_cap=""
    # 目标 = 不超过上限的最高硬件档；不 fork，直接在本地算
    rate_tgt=720
    if [ -n "$rate_cap" ]; then
        rate_level_of "$rate_cap"
        rate_level_hz "$RATE_LEVEL_OF" && rate_tgt=$RATE_LEVEL_HZ
    fi
    # 读回值可能只是驱动缓存（挂起时写入被拒但值照样变），所以“已生效”必须两者都对上
    rate_ok=0
    [ "$rate_v" = "$rate_tgt" ] && [ "$(cat "$RATE_APPLIED" 2>/dev/null)" = "$(rate_target_level)" ] && rate_ok=1
    # 息屏/挂起/游戏空间接管时模块让行，前端提示“暂缓”。
    # 只有功能开着才判，避免空闲时每轮多 fork 两次读节点
    if [ -f "$F_RATE" ] || [ -f "$F_TOUCH" ]; then
        hw_write_paused && rate_pause=1
    fi

    # ---- 熄屏提速 ----
    # 只看节点确实被写成 0 且屏幕是亮的，才算生效；开关开着但条件不满足显示待机
    [ -e "$CHG_SCREEN_ON" ] && fast_avail=1
    [ -f "$F_FAST" ] && fast_on=1
    fast_sio=$(fast_read_sio 2>/dev/null)
    [ "$fast_on" = "1" ] && [ "$fast_sio" = "0" ] && [ "$(screen_state)" = "awake" ] && fast_ready=1

    # ---- CPU / GPU 频率（表直接给前端，单位统一 MHz）----
    [ "$ST_LOCK" = "1" ] && freq_lock=1
    case "$ST_CPUS" in ''|*[!0-9]*) cpusel=0 ;; *) cpusel=$ST_CPUS ;; esac
    case "$ST_CPUB" in ''|*[!0-9]*) cpubsel=0 ;; *) cpubsel=$ST_CPUB ;; esac
    case "$ST_GPU" in ''|*[!0-9]*) gsel=0 ;; *) gsel=$ST_GPU ;; esac
    if cpu_policy_at 0; then
        cpu0_list=$(cpu_list_mhz "$CPU_P")
        cpu_read_node "$CPU_P" scaling_max_freq && cpu0_cur=$(( CPU_CUR / 1000 ))
    fi
    if cpu_policy_at 1; then
        cpu1_list=$(cpu_list_mhz "$CPU_P")
        cpu_read_node "$CPU_P" scaling_max_freq && cpu1_cur=$(( CPU_CUR / 1000 ))
    fi
    cpu_active && cpu_verify && c_ok=1
    if gpu_table; then
        gpu_list=$GPU_LIST
    fi
    if gpu_active; then
        gpu_paused && g_pause=1
        gpu_verify && g_ok=1
    fi

    # ---- 皮肤温度（体感，只读）----
    skin=$(skin_temp_deg 2>/dev/null) || skin=""

    # ---- 温控（只问一次，它有 1 秒缓存）----
    thermal_effective && te=1

    # ---- 亮度 ----
    if bright_nodes 2>/dev/null; then
        rd "$BL_BRIGHT"; bl="$RD"
        [ -n "$BL_MAX" ] && [ -e "$BL_MAX" ] && { rd "$BL_MAX"; blm="$RD"; }
    fi
    case "$bl" in ''|*[!0-9]*) bl="";; esac
    case "$blm" in ''|*[!0-9]*) blm="";; esac
    if [ -n "$bl" ]; then
        blg=$ST_BGOAL
        case "$blg" in ''|*[!0-9]*) blg=8190;; esac
        [ -n "$blm" ] && [ "$blg" -gt "$blm" ] 2>/dev/null && blg=$blm
    else
        blg=""
    fi
    blgs=$ST_BGOAL
    case "$blgs" in ''|*[!0-9]*) blgs="";; esac

    # ---- 触控 ----
    touch_missing_nodes >/dev/null
    tmiss=$TOUCH_MISSING
    touch_vals_build
    tvals=$TOUCH_VALS
    # 不可用项 / 上次被驱动退回的项：前端据此置灰和提示
    [ -s "$TOUCH_NA" ] && tna=$(tr '\n' ',' < "$TOUCH_NA" 2>/dev/null | sed 's/,$//')
    # 采样率接管期间 tp_report_rate 归采样率所有：触控的「上报频率」置灰，
    # 但这属于「被别的功能接管」，不是驱动不支持，必须用独立字段区分，避免误报
    touch_rate_owned && town='上报频率'
    [ -s "$TOUCH_RB" ] && trb=$(tr '\n' ';' < "$TOUCH_RB" 2>/dev/null | sed 's/;$//')
    tpreset=$ST_TP
    case "$tpreset" in official_gaming|official_daily) ;; *) tpreset="official_gaming";; esac
    # 与所选预设的定义逐项比对：全一致才算 preset，否则算用户手调 manual
    tm="manual"
    touch_preset_build "$tpreset"
    if [ -n "$tvals" ] && [ "$tvals" = "$TOUCH_PRESET_VALS" ]; then tm="preset"; fi

    # ---- 模块健康 ----
    module_state_load
    mf=$MODULE_STATE_FAIL
    [ -f "$F_BOOST" ] && boost_effective && be=1

    # ---- 开关与输出：echo 是 mksh 内建，printf 在 Android 上会 fork toybox ----
    [ -f "$F_FAN" ] && fan_on=1
    [ -f "$F_PUMP" ] && pump_on=1
    [ -f "$F_CHARGE" ] && charge_on=1
    [ -f "$F_FAN_KEEP" ] && fan_keep=1
    [ -f "$F_PUMP_KEEP" ] && pump_keep=1
    [ -f "$F_FAN_TEMP" ] && fan_temp=1
    [ -f "$F_PUMP_TEMP" ] && pump_temp=1
    [ -f "$F_THERMAL" ] && thermal_on=1
    [ -f "$F_BOOST" ] && boost_on=1
    [ -f "$F_BOOST_HEAT" ] && boost_heat=1
    [ -f "$F_BRIGHT" ] && bright_on=1
    [ -f "$BRIGHT_NA" ] && bright_avail=0
    [ -f "$F_TOUCH" ] && touch_on=1
    [ -f "$F_RATE" ] && rate_on=1
    case "$ST_FAN_THR" in ''|*[!0-9]*) ;; *) ftthr=$ST_FAN_THR ;; esac
    case "$ST_PUMP_THR" in ''|*[!0-9]*) ;; *) ptthr=$ST_PUMP_THR ;; esac
    case "$bl" in ''|*[!0-9]*) ;; *) bl_cur=$bl ;; esac
    case "$blm" in ''|*[!0-9]*) ;; *) bl_max=$blm ;; esac
    case "$blg" in ''|*[!0-9]*) ;; *) bl_goal=$blg ;; esac
    boost_thr=$ST_BOOST_THR
    case "$boost_thr" in ''|*[!0-9]*) boost_thr=42;; esac
    { [ "$boost_thr" -ge 20 ] && [ "$boost_thr" -le 70 ]; } 2>/dev/null || boost_thr=42

    # ---- 输出 ----
    echo "battery=$cap"
    echo "temp_deg=$(( t / 10 )).$(( (t % 10 + 10) % 10 ))"
    echo "power=$power"
    echo "soh=$soh"
    echo "cycle=$cycle"
    echo "full_mah=$full_mah"
    echo "design_mah=$design_mah"
    echo "res_mohm=$res_mohm"
    echo "cs=$cs"
    echo "charge_on=$charge_on"
    echo "threshold=$thr"
    echo "fan_available=$fan_avail"
    echo "fan_level=$fan_lv"
    echo "fan_level_saved=$fan_saved"
    echo "fan_on=$fan_on"
    echo "fan_enabled=$fan_en"
    echo "pump_available=$pump_avail"
    echo "pump_level=$pump_lv"
    echo "pump_level_saved=$pump_saved"
    echo "pump_on=$pump_on"
    echo "fan_keep=$fan_keep"
    echo "pump_keep=$pump_keep"
    echo "fan_temp_ctrl=$fan_temp"
    echo "fan_temp_mode=$ST_FAN_MODE"
    echo "fan_temp_thr=$ftthr"
    echo "pump_temp_ctrl=$pump_temp"
    echo "pump_temp_mode=$ST_PUMP_MODE"
    echo "pump_temp_thr=$ptthr"
    echo "thermal_on=$thermal_on"
    echo "thermal_effective=$te"
    echo "boost_on=$boost_on"
    echo "boost_ready=$be"
    echo "boost_thr=$boost_thr"
    echo "boost_heat=$boost_heat"
    echo "bright_on=$bright_on"
    echo "bright_available=$bright_avail"
    echo "bright_cur=$bl_cur"
    echo "bright_max=$bl_max"
    echo "bright_goal=$bl_goal"
    echo "bright_goal_set=$blgs"
    echo "touch_on=$touch_on"
    echo "touch_missing=$tmiss"
    echo "touch_mode=$tm"
    echo "touch_vals=$tvals"
    echo "touch_na=$tna"
    echo "touch_owned=$town"
    echo "touch_rb=$trb"
    echo "fast_on=$fast_on"
    echo "fast_ready=$fast_ready"
    echo "fast_avail=$fast_avail"
    echo "freq_lock=$freq_lock"
    echo "cpu0_list=$cpu0_list"
    echo "cpu1_list=$cpu1_list"
    echo "cpu0_sel=$cpusel"
    echo "cpu1_sel=$cpubsel"
    echo "cpu0_cur=$cpu0_cur"
    echo "cpu1_cur=$cpu1_cur"
    echo "cpu_ok=$c_ok"
    echo "gpu_list=$gpu_list"
    echo "gpu_sel=$gsel"
    echo "gpu_ok=$g_ok"
    echo "gpu_paused=$g_pause"
    echo "temp_skin=$skin"
    echo "rate_on=$rate_on"
    echo "rate_value=$rate_v"
    echo "rate_max=$rate_cap"
    echo "rate_target=$rate_tgt"
    echo "rate_ok=$rate_ok"
    [ -e "$TOUCH_REPORT" ] && echo "rate_avail=1" || echo "rate_avail=0"
    echo "rate_paused=$rate_pause"
    echo "module_state=$MODULE_STATE"
    echo "module_fail=$mf"
}

# 写快照：先 .tmp 再 mv（前端永远读不到半份），并落下心跳门控标记。
# 失败时把 .tmp 删掉，模块目录里不留半份文件。
status_write() {
    if ! status_body > "$WEBUI_STATUS.tmp" 2>/dev/null || [ ! -s "$WEBUI_STATUS.tmp" ]; then
        rm -f "$WEBUI_STATUS.tmp" 2>/dev/null
        return 1
    fi
    if ! mv -f "$WEBUI_STATUS.tmp" "$WEBUI_STATUS" 2>/dev/null; then
        rm -f "$WEBUI_STATUS.tmp" 2>/dev/null
        return 1
    fi
    : > "$WEBUI_HB_SEEN" 2>/dev/null
    return 0
}
