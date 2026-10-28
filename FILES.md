# 模块文件说明

本文件是**开发用文档**，随仓库保存，不进入安装包（`customize.sh` 安装时会删除）。
内容按「入口 → 基础库 → 功能模块 → 前端 → 工具 → 运行期文件」顺序说明每个文件做什么。

## 根目录

| 文件 | 作用 |
|---|---|
| `module.prop` | KernelSU 模块描述：id / 版本 / versionCode / 简介 / `updateJson`（指向 CDN 上的 `update.json`，管理器据此检测更新）。版本号与 `webroot/version.txt` 必须一致（`check.ps1` 会校验）。 |
| `customize.sh` | 安装入口。先跑 `validate_nodes.sh` 硬校验机型节点，任一缺失即中止；再给脚本加执行权限、删掉开发文件、只清 `run/` 里的瞬态文件，保留用户记忆与接管快照。 |
| `post-fs-data.sh` | 开机最早期（system_server 之前）。清空重写日志、删上一轮残留临时文件、按记忆提前 bind 温控空配置。只 source `paths.sh`，不碰功能库。 |
| `service.sh` | 主服务。单实例锁、trap 收尾、开机按记忆恢复各功能、写功能说明进日志，然后常驻：命令分发（`webui_loop`）、充电分离巡逻（`charge_sep_patrol`）、15 秒看门狗。 |
| `uninstall.sh` | 卸载入口。调用 `teardown_all uninstall`：停服务、还原全部节点与 settings、清标记与快照，最后整目录删除 `run/`。 |
| `common.sh` | 基础设施原语：读节点（`rd` / `rdv`，定长读取不 fork）、记忆读写（`cfg` / `st` / `cfg_set` / `state_repair`）、日志（`mlog` / `errlog` / `mlog_trim`）、settings 包装（`stg` / `stgq`）、标记文件（`f_on` / `f_set` / `f_del`）。不含业务判断。 |
| `paths.sh` | 全部路径常量的唯一来源：运行期目录 `run/`、命令队列、状态快照、开关标记、接管快照、各机型节点路径（风扇、液冷、触控、充电、温控、亮度、GPU、皮肤温度）。还负责旧布局（≤v3.0.8）一次性迁移进 `run/`。 |
| `validate_nodes.sh` | 按 `nodes.req` 逐行校验候选路径，任一行为零命中即让安装失败。 |
| `nodes.req` | 节点需求表：`显示名|候选路径(逗号分隔)`。只放**必需**节点；可选节点（如新增触控项）不列，缺了会自动置灰。 |
| `config.txt` | 默认值模板（只读）。`state_repair` 会用它补齐 `state.txt` 缺失键，升级不会被旧记忆冲掉新键。 |
| `LICENSE` | PolyForm Noncommercial 1.0.0。 |
| `update.json` | 管理器更新清单（`version` / `versionCode` / `zipUrl` / `changelog`）。由 `build.ps1` 按 `module.prop` 自动生成，随提交推到 `main` 分支，供 jsDelivr CDN 读取；不进入安装包。 |
| `README.md` | 面向使用者的说明（安装、功能、还原、限制）。不进入安装包。 |
| `FILES.md` | 本文件：面向开发者的逐文件说明。不进入安装包。 |

## lib/（按 `service.sh` 的 source 顺序）

| 文件 | 作用 |
|---|---|
| `system.sh` | 系统级原语：节点写入与权限精确还原（`node_write` / `node_write_su`）、快照读写（`snap_node` / `snap_get`）、屏幕状态（`screen_state`）、电池读数（容量/温度/健康度/循环/内阻）、皮肤温度与「控制温度」（电池与皮肤取较高者）、**让行闸门** `hw_write_paused`（息屏 / `tp suspend=1` / `play_game=1`），以及采样率引擎：驱动档位写入 + 驱动确认、`touch_high_perf_en`、系统 `settings` 显示值同步（`rate_setting_sync` / `rate_setting_restore`）。 |
| `thermal.sh` | 温控屏蔽：用空文件 bind 顶替 `/vendor/etc/thermal-engine.conf`，并临时放宽 cpufreq 节点权限（`SNAP_CFREQ` 记录，解除时按原权限还原）。`thermal_effective()` 是唯一生效判定。 |
| `fanpump.sh` | 风扇 / 液冷。开关归系统，模块只在系统已开时写档位；「息屏保持」是唯一会动 enable 的路径，先记原值原权限再写。温度联动按 `control_temp_deg` 的输出分档。 |
| `charge.sh` | 充电分离（读系统 `charge_separation_switch`，按阈值维护）、充电加速（`restrict_cur` / `charging_enabled` / `battery_charging_enabled`，带温度与分离守卫）、解除热降流（battery 降温设备 cur_state 钉 0）、以及**熄屏提速**（亮屏充电时只把 `screen_is_on` 伪装 0，条件失效立刻写回真实值）。 |
| `touch.sh` | 触控参数引擎。由 `touch_table.txt` 驱动逐项写节点并回读核对；维护原始值快照（`touch_snapshot.txt`）、不可用项（`touch_na.txt`，驱动读不出原值）、暂缓项（`touch_defer.txt`，驱动拒收但记忆必须保留）与回滚明细；`touch_verify` 供看门狗核对；「上报频率」在采样率接管期间跳过。 |
| `cpufreq.sh` | CPU 频率。按 `scaling_available_frequencies` 逐簇选择（前端用 MHz，节点用 kHz）；不接管时只压 `scaling_max_freq`，锁定（`频率锁定=1`）时写 `min=max`；`cpu_verify` 判定上限/锁定是否成立；关闭时按快照把上下限放回硬件范围。 |
| `gpufreq.sh` | GPU 频率。频率表取自 `gpu_available_frequencies`（Hz，从高到低），实际控制 `max_pwrlevel` / `min_pwrlevel`（0=最高频）；息屏、游戏空间接管时让行；快照 `.snap_gpu` 记录接管前两个 pwrlevel。 |
| `bright.sh` | 亮度解锁：系统把亮度顶到自身上限时，继续写到面板物理上限（长驻守护进程）。 |
| `state.sh` | 记忆一致性：`flag_file` / `flag_key`（开关名 → 标记文件 / `state.txt` 键）、`state_sync`、`state_restore_flags`、`seed_values`，以及 `state_load`（一次性读入 state.txt 供状态快照使用，避免十几次 grep fork）。 |
| `commands.sh` | WebUI 命令唯一入口。每个 action 的固定顺序：校验值 → 写记忆 → 动节点；节点写失败必须回滚记忆，避免对账反复重放。 |
| `status.sh` | 状态快照（`run/webui_status`，key=value 单行）。只读模块外的东西一律清洗（`kv_safe`），计算各功能显示值、模块健康（2 正常 / 1 部分异常 / 0 未运行）与让行状态。 |
| `loop.sh` | WebUI 主循环：心跳节流（500ms / 2000ms 两档）、命令队列消费、每 3 秒对账（`reconcile`，把节点拉回记忆值，只在让行切换点补写）、按需产出状态快照。 |
| `teardown.sh` | 收尾：`teardown_all service`（停服务但保留记忆）／`teardown_all uninstall`（连记忆一起清）。先 TERM 再 KILL，然后依次还原充电伪装、采样率（含 settings 显示值）、CPU、GPU、温控、风扇/液冷、触控。 |
| `diag.sh` | 自检：只读地把各功能现状、频率表、让行原因、近期日志写进 `REDMAGIC_debug.log`，前端「运行自检」按钮调用。 |
| `touch_table.txt` | 触控表（数据文件）：`显示名|节点|子字段|写模式`。15 项；前三列改动即改变写哪些节点，`bare` 表示只写裸数字。 |

## webroot/（WebUI）

| 文件 | 作用 |
|---|---|
| `index.html` | 单页骨架：顶部电池/温度/功率、导航、各功能卡（风扇/液冷/充电/温控/触控/采样率/性能/亮度/状态/日志）。静态文案带 `data-i18n`。 |
| `css/style.css` | 扁平样式（无渐变/阴影/过渡/动效，`check.ps1` 会校验）。 |
| `version.txt` | 版本号镜像，前端标题栏显示；与 `module.prop` 必须一致。 |
| `js/i18n.js` | 中英词条与切换逻辑，缺译文回落中文。 |
| `js/core.js` | 与 KernelSU 的桥接：`window.ksu.exec` 写命令队列 / 读状态快照 / 读日志 / 跑自检，以及轮询封装。 |
| `js/cards.js` | 通用控件（开关、滑杆、分段按钮、数字、下拉）与风扇/液冷/充电/温控/采样率/性能/亮度/电池渲染。所有状态都等快照回来再画，不做乐观更新。 |
| `js/touch.js` | 触控页：15 项表单（下拉/数字/四元组）、预设（电竞/日常）、600ms 防抖自动保存、脏标记、置灰与回滚提示。 |
| `js/status.js` | 状态页与日志页：模块健康、各功能开关灯、电池健康、读取日志、运行自检。 |
| `js/main.js` | 入口：导航、语言切换、轮询节奏（可见 1s / 隐藏停）、版本号读取、离开页面发 `release`。 |

## tools/（开发工具，不进入安装包）

| 文件 | 作用 |
|---|---|
| `check.ps1` | 静态检查：JS 语法、CRLF、契约（函数唯一、日志只有一份、采样率必须写驱动、`run/` 目录约束、版本一致、安装不得删 `run/`），有设备时再对全部 `.sh` 跑 `sh -n`。 |
| `build.ps1` | 打包：先跑 `check.ps1`，再按 `module.prop` 生成 `update.json`，最后把运行时文件压成 `dist/REDMAGIC-<version>.zip`（自写 ZIP，确保 `/` 分隔符）。 |
| `device_test.sh` | 设备侧触控/节点功能测试脚本。 |
| `device_charge_test.sh` | 设备侧充电相关测试脚本。 |

## run/（运行期，安装后才有，卸载整目录删除）

| 路径 | 作用 |
|---|---|
| `state.txt` | 用户记忆（唯一真相）：开关值与所有数值。 |
| `auto_*` | 开关标记（存在=开）：风扇 / 液冷 / 充电分离 / 温控 / 触控 / 加速 / 亮度 / 采样率 / 熄屏提速 / 子选项。 |
| `webui_cmd` | 前端命令队列，`loop.sh` 消费。 |
| `webui_status` | 状态快照，前端每 500ms 读。 |
| `.webui_hb` / `.hb_seen` | 前端心跳与「本进程确实产出过快照」门控。 |
| `.snap_fan` / `.snap_pump` / `.snap_boost` / `.snap_heat` / `.snap_cfreq` | 接管快照（原值+原权限），还原时按它写回。 |
| `.snap_fan_keep` / `.snap_pump_keep` | 「息屏保持」接管 enable 时的原值原权限。 |
| `.snap_cpu` / `.snap_gpu` | CPU 各簇硬件上下限、GPU 接管前的 max/min pwrlevel 基线。 |
| `.rate_orig` / `.rate_applied` / `.rate_state` | 采样率原档位（含 settings 显示值）、驱动确认过的已生效档位、状态变化标记。 |
| `.fast_state` / `.touch_state` / `.cpu_state` / `.gpu_state` | 各功能状态变化标记（只在切换时记日志，避免刷屏）。 |
| `touch_snapshot.txt` / `touch_na.txt` / `touch_rollback.txt` / `touch_defer.txt` | 触控原始值、不可用项、上次回滚明细、暂缓项。 |
| `sep_limit` / `boost_limit` | 充电分离阈值、加速温度上限（数值文件）。 |
| `.sep_state` / `.rate_cur` | 运行期缓存（避免每轮 fork settings）。 |
| `REDMAGIC.log` | 唯一日志：开机重写，超 256KB 从尾部截断，所有失败以 `[FAIL]` 落这里。 |
| `.svc_pid` / `.svc_lock` | 单实例锁与服务 PID。 |
| `.migrated` | 旧布局迁移完成标记。 |
