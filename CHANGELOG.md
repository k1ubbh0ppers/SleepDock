# Changelog / 更新记录

All entries describe implemented behavior. Validation limits remain explicit; a packaged platform is not automatically a hardware-validated platform.

## 1.1.1

### 中文

- 移除 macOS 与 Electron 窗口的外圈白色描边和原生窗口阴影。
- Windows 窗口关闭原生 thick frame，保留固定宽度与自定义调高方式。
- 保留内部磨砂，圆角外为透明背景；同时检查角外区域与边缘亮度，避免只检查四个角点。
- 保留 390 固定宽、紧凑/展开分别记忆高度、六款 Agent 默认全选和退出释放保护。
- 整理完整双语项目主页、Agent 接入说明与英文使用指南。

原生 macOS 缓存检查的 1,872 个圆角外像素、macOS 上 Electron 页面检查的 368 个圆角外像素均为 alpha=0。Windows/Linux 本机显示效果仍待目标系统验收。

### English

- Remove the outer white stroke and native window shadow from the macOS and Electron implementations.
- Disable Windows' native thick frame while retaining fixed width and custom height resizing.
- Keep the frosted interior with transparent rounded-corner exterior; inspect both the exterior area and edge brightness.
- Preserve the fixed 390 width, separate compact/expanded heights, six selected default agents, and quit cleanup.
- Add a complete bilingual project homepage, agent integration documentation, and English user guide.

All 1,872 inspected native macOS corner-exterior pixels and 368 inspected Electron corner-exterior pixels on macOS had alpha=0. Rendering on actual Windows/Linux desktops remains unverified.

## 1.1

### 中文

- 新增 Windows x64 与 Linux x64 Electron 运行包。
- 三平台统一固定宽 390，支持底部拖柄手动调高并保存。
- 紧凑与展开模式分别保存高度。
- 圆角外背景透明，六款 Agent 默认选中，支持保存选择与添加其他程序。
- 平台电源 helper 包含临时合盖规则和退出/失联恢复机制。

验证基准：85 项原生检查、8 项隔离守护模拟、82 项跨平台 Node 检查；macOS 真实界面与保活断言检查通过。Windows/Linux 完成交叉打包、归档与资源核对，尚未真机验收。

### English

- Add Windows x64 and Linux x64 Electron packages.
- Use a fixed width of 390 across implementations, with a bottom handle for saved height adjustment.
- Store separate compact and expanded heights.
- Keep the rounded-corner exterior transparent, select six agents by default, and support saved selection and custom apps.
- Include platform power helpers with temporary lid rules and cleanup on exit or lost heartbeat.

Validation baseline: 85 native checks, 8 isolated watchdog simulations, and 82 cross-platform Node checks; actual macOS UI and keep-awake assertion checks passed. Windows/Linux were cross-built and archive/resource-checked, without target-hardware acceptance.

## Initial implementation / 初始实现

- 原生 macOS 磨砂桌面插件；跟随系统、空闲后、倒计时、永不休眠四种模式。
- Agent 运行保护、明确正常完成后的无人操作倒计时与通用命令包装器。
- 平台能力约束下的合盖模式、低电量与仅接电保护、独立屏幕控制。
- Native macOS frosted widget with system, idle, countdown, and never-sleep modes.
- Agent protection, idle countdown after explicit successful completion, and a generic command wrapper.
- Capability-dependent lid behavior, low-battery / AC-only protection, and independent display controls.

真实合盖、主动休眠、锁屏、管理员授权及登录启动未在开发中触发；这些行为仍需用户主动验收。

Actual lid close, requested sleep, lock, administrator authorization, and login startup were not triggered during development and still require deliberate acceptance testing.
