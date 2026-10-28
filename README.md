# REDMAGIC 内核模块

**红魔 Pro+ 系列（NX809J）的 KernelSU / ReSukiSU 性能与散热控制模块**

一个用 Shell 守护进程接管硬件节点的模块：风扇、液冷泵、充电（含亮屏「熄屏提速」）、温控屏蔽、触控 15 项、触控采样率、CPU / GPU 频率、亮度解锁，外加内核级电池健康读数。所有功能默认关闭，改动全部可还原。

> ⚠️ **仅适用于红魔 Pro+ 系列，目前只在 NX809J（红魔 11 Pro+ / Android 16）实机验证。**
> 其它机型的温控、充电、触控节点并不通用，刷入可能功能失效甚至无法正常开机。
> 安装器会用 `nodes.req` 逐项校验节点，任一不存在即中止安装——这是最后一道防线，不要绕过它。

---

## 功能

| 模块 | 说明 | 是否可还原 |
|---|---|---|
| 风扇 | 1–5 档接管；息屏保持；电池/皮肤温度联动自动调档 | 是 |
| 液冷 | 内循环泵 1–4 档；息屏保持；温度联动 | 是 |
| 充电分离 | 按阈值分离开关，走系统电源路径 | 是 |
| 充电加速 | 温控屏屏蔽 + 解除热降流，温度上限可设 | 是 |
| 熄屏提速 | 亮屏充电时只把「熄屏」告诉充电模组，屏幕与亮度不变 | 是 |
| 温控屏蔽 | 空文件顶替 `thermal-engine.conf`，策略全部失效 | 是 |
| 触控 | 15 项参数：12 项档位 + 握持防误触 / 手掌抑制 / 手写笔模式 | 是（首次接管写快照） |
| 采样率 | 120 / 180 / 300 / 360 / 720Hz 驱动档位 | 是 |
| 性能 | CPU 频率表直读；GPU `pwrlevel` 直读；可锁定 min=max | 是 |
| 亮度解锁 | 系统顶格后继续写面板物理上限 | 是 |
| 电池健康 | soh / 循环次数 / 满充与设计容量 / 内阻 / 皮肤温度（只读） | — |

### 设计原则

- **不写裸数值**：CPU/GPU 频率只从驱动自己的 `scaling_available_frequencies`、`gpu_available_frequencies` 里取，界面上出现的每一档都是驱动确实支持的。
- **不显示假状态**：驱动写不进去的项（`glove_mode` 等）根本不做成开关；「已生效」以驱动回读 + 落盘记录为准，不靠一次 write 就宣布成功。
- **该让行就让行**：息屏挂起、游戏空间接管（`play_game=1`）期间，触控/采样率/GPU 一律停写，亮屏或退出游戏后由对账补写，避免和系统互相覆盖。
- **能改也能还**：关闭功能、停服、卸载三个入口都会还原原始节点值；触控/采样率的接管前原值有快照文件。

---

## 安装

1. 下载 Release 里的 `REDMAGIC-vX.Y.Z.zip`（不要解压，不要重新打包）。
2. KernelSU / ReSukiSU Manager → 模块 → 从本地安装。
3. 安装器执行 `customize.sh`：先校验机型节点，再剔除开发文件，失败会 `abort` 并回滚安装。
4. 重启，打开模块 WebUI。

升级覆盖安装不需要额外重启项，用户记忆（`state.txt`、开关标记、数值、接管快照）完整保留。

### 从旧版升级

≤ v3.0.8 散落在模块根目录的运行期文件，会在首次启动时由 `paths.sh` 一次性搬进 `run/`，瞬态文件直接删除。

---

## 仓库结构

```
├── module.prop          # 模块元数据（id / version / versionCode / updateJson）
├── customize.sh         # 安装期：节点校验、剔除开发文件
├── post-fs-data.sh      # 开机早期：温控屏蔽 bind
├── service.sh           # 常驻服务：命令分发、状态对账、看门狗
├── paths.sh             # 全部路径常量唯一来源（含旧布局迁移）
├── uninstall.sh         # 卸载：还原所有改过的节点
├── common.sh            # 日志、读取、写值等公共函数
├── lib/                 # 功能实现
│   ├── fanpump.sh  charge.sh  thermal.sh  bright.sh
│   ├── touch.sh    touch_table.txt         # 触控 15 项定义
│   ├── cpufreq.sh  gpufreq.sh  loop.sh
│   ├── status.sh   commands.sh  state.sh
│   └── system.sh   diag.sh  teardown.sh
├── webroot/             # WebUI（纯静态，无构建步骤）
│   ├── index.html  css/style.css  version.txt
│   └── js/ core.js cards.js touch.js status.js i18n.js main.js
├── nodes.req            # 机型节点清单（安装器校验用）
├── update.json          # Manager 更新源（jsDelivr 指向本仓库 main）
├── CHANGELOG.md
└── tools/               # 开发工具，不随 ZIP 分发
    ├── build.ps1        # 校验 + 可复现打包到 dist/
    ├── check.ps1        # 语法 / LF / 重复函数 / 目录整洁
    └── device_test.sh   # 真机只读探测
```

运行期文件全部集中在 `run/`（`state.txt`、开关标记、命令队列、接管快照、日志、PID），卸载时整目录删除。

---

## WebUI

- 通过 `window.ksu.exec` 读写模块目录内的命令队列与状态快照；`kernelsu` 不可用时回退 HTTP。
- 1 秒轮询，快照超过 6 秒未刷新即清空显示，不展示过期数值。
- 扁平样式，无渐变 / 阴影 / 过渡 / 动效（`tools/check.ps1` 会校验）。
- 中文 / English 双语，跟随界面切换。

---

## 开发

需要 Windows + PowerShell 7+ 与 Python 3：

```powershell
# 自检（语法、LF、重复定义、目录整洁、版本一致性）
powershell -File tools/check.ps1

# 打包（先自检，再按固定时间戳与权限打包，产物 dist/REDMAGIC-vX.Y.Z.zip）
powershell -File tools/build.ps1
```

发布流程：

1. 同步修改三处版本号：`module.prop`（`version` + `versionCode`）、`webroot/version.txt`、`update.json`；
2. 在 `CHANGELOG.md` 追加条目；
3. `tools/build.ps1` 出包；
4. 建 Release，上传 `dist/` 里的 ZIP，标签与 `update.json` 中的 `zipUrl` 必须完全对应。

ZIP 必须是 `module.prop` 位于**根层**的结构，且所有文本文件为 LF、无 BOM——用图形化工具「压缩文件夹」极易多套一层目录，请始终用 `build.ps1`。

---

## 常见问题

**装完没反应？** 看 `run/REDMAGIC.log`（每次开机清空重写，超过 256KB 从尾部截断，所有运行期问题都以 `[FAIL]` 行落在这里），再配合 WebUI 状态页的「运行自检」。

**开关显示已开但没效果？** 本模块对「已生效」判定是驱动回读 + 落盘记录，若显示已生效却无体感，先用 `tools/device_test.sh` 确认节点可写。

**Manager 不提示更新？** `update.json` 走 jsDelivr 缓存，Release 建好后有延迟；确认 Release 标签与 `zipUrl` 一致即可。

---

## 许可

[PolyForm Noncommercial License 1.0.0](LICENSE)：源码公开，可自由用于个人学习、研究、修改与分享，**禁止任何商业用途**。分发请保留署名与本许可证。

欢迎 Issue / PR 交流；本项目及其修改版不得用于售卖、付费服务或其他商业行为。
