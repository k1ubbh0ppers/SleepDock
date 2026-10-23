# SleepDock 1.1 跨平台实现

本次目标：Windows x64、Linux x64 可解压运行包；macOS 继续使用原生版本。三版宽度固定 390，高度拖动调整，紧凑／展开各自记忆。窗口四角外透明，内部保留磨砂层。

Windows／Linux 使用 Electron 45 的隔离页面、托盘与临时电源断言；renderer 不持有 Node 权限，所有动作通过有限 IPC 白名单。policy 负责电量、空闲、任务优先级；controller 负责整批正常完成、60 秒取消窗口与休眠前复核。最终复核与合盖恢复期间保留断言。设置变更、退出、新任务、中断、未知状态使旧请求失效。

Agent 模块仅提取生命周期字段，六款工具默认全选，自选程序单独保存。Codex 读取 CODEX_HOME 或 ~/.codex/sessions；通用命令在 ~/.sleepdock/tasks 写心跳与终态；其他工具未验证任务接口时采用进程运行保护，关闭 App 不等于任务正常完成。

Windows 使用系统 PowerShell 调用原生接口。合盖动作先独立确认，守护快照保存当前方案原 AC/DC 值，读回确认；停用、退出、拔电、失联恢复。Linux 使用 logind 临时合盖抑制器，不写系统配置。Wayland 无统一熄屏接口、无 logind／合盖传感器时禁用对应动作。

验证顺序：策略与生命周期检查 → 电源接口模拟与并发检查 → 跨平台页面实际启动与透明／尺寸检查 → Windows PE、Linux ELF 包结构与解压校验。当前主机为 macOS；Windows/Linux硬件行为不以模拟替代验收。源码包排除依赖、构建缓存及用户数据。
