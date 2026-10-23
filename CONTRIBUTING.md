# Contributing / 参与贡献

欢迎提交缺陷报告、文档改进和平台兼容性修复。先阅读 [构建说明](docs/BUILD.md)、[Agent 检测边界](docs/AGENTS.md) 和两套实现中的验证记录。

Welcome bug reports, documentation improvements, and platform compatibility fixes. Start with the [build guide](docs/BUILD.md), [agent detection notes](docs/AGENTS.md), and each implementation's validation record.

## 报告问题 / Report an issue

- 说明 SleepDock 版本、系统版本、CPU 架构和桌面环境；Linux 请补充 X11 / Wayland。
- 写清操作步骤、预期行为、实际结果，以及是否接电、是否启用总开关和相关规则。
- 附必要的脱敏截图或最小日志片段。请勿上传 Agent 对话、个人路径、访问令牌或完整任务数据库。
- 区分界面问题、任务状态问题与真实电源行为；模拟检查结果不能代替真机验收。

Include the app version, OS, CPU architecture, desktop environment, reproduction steps, expected result, actual result, and relevant switches. Redact private paths, task content, and credentials. Separate UI, task detection, and hardware power behavior.

## 提交修改 / Propose changes

1. 从最新 `main` 创建分支，尽量保持修改范围集中。
2. 功能变化同步更新中英文说明和检测能力表；不要把 App 退出或日志超时当作任务成功。
3. 运行与修改相关的检查。修改电源逻辑时，先使用隔离测试，不要在不知情的机器上触发休眠、锁屏、合盖策略或提权。
4. 在 PR 中说明修改目的、验证方法、实际验证的平台以及未验证的行为。

Create a focused branch from `main`; update both language guides when behavior changes. Use isolated tests for power logic. State which platforms were actually tested and which behaviors remain unverified. Never equate a process exit or missing log with successful task completion.

## 风格与边界 / Scope and style

macOS 使用原生 Swift / AppKit / SwiftUI；Windows 和 Linux 使用 Electron。优先复用现有策略层与测试夹具。保持渲染层与电源操作隔离；新增平台能力必须提供失败反馈、退出清理和可恢复路径。

The macOS implementation uses Swift, AppKit and SwiftUI; Windows and Linux use Electron. Reuse the existing policy layer and fixtures. Keep rendering separate from power operations. New platform capabilities need clear failure reporting, cleanup on exit, and recovery behavior.
