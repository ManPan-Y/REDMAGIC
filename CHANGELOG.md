# 更新日志

本项目遵循 `主.次.修订` 版本号，`versionCode` 为纯整数且单调递增（`350` 对应 `v3.5.0`）。
每条记录对应一个 GitHub Release；Manager 内的更新提示读取 `update.json`。

## v3.5.0 — WebUI 全面重设计（versionCode 350）

### 界面
- 全新扁平视觉系统：顶栏品牌块、三格实时概览（电池 / 温度 / 功率）、吸顶胶囊标签栏
- 九个面板统一卡片结构：风扇、液冷、充电、温控屏蔽、触控、采样率、性能、亮度、状态
- 重新绘制的开关、滑杆、分段选择、状态格、代码日志区；全部颜色与间距收敛为 `:root` 变量
- 依旧保持无渐变、无阴影、无过渡、无动效（`tools/check.ps1` 有专门校验）

### 清理（无行为变更）
- 前端：移除 `core.js` 中从未被调用的 `start` / `transport` / `raw` / `lastOk` / `err` / `base` 导出与 `onLogs` / `__logs` 日志回调链；移除 `cards.js` 的 `busy()`；移除两条从未命中的 CSS 规则
- 后端：移除状态快照中 6 个无人读取的字段（`ac`、`usb`、`health`、`touch_preset`、`fast_sio`、`gpu_cur`）及对应采集语句；移除已无发送方的 `touch_preset` 命令分支；移除 `battery_health_state()` 与 `BAT_HEALTH` 常量
- 删除运行期从不读取的 `conf/thermal-engine.conf`，温控空配置目录改为运行时 `mkdir -p` 创建
- 打包排除 `conf/`、`.screenshots/`、`.trae-html-share-packages/`

### 兼容性
- 命令协议、状态快照（除上述无用字段）、全部 Shell 判定逻辑与 v3.4.0 一致
- 覆盖安装无需额外重启项，`run/state.txt`、开关标记、接管快照完整保留

### 校验
- `tools/check.ps1` 26 项全过；`validate_module.py` 0 错误

## v3.4.0 及更早

早期版本未逐条归档。功能演进主线：风扇/液冷接管 → 充电分离与加速 → 温控屏蔽 → 触控 15 项与采样率 → CPU/GPU 频率固定 → 亮度解锁与电池健康读数。
