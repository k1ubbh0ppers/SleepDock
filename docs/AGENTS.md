# Agent 接入 / Agent integration

[中文主页](../README.md) · [English homepage](../README.en.md)

## 中文

### 默认勾选与检测精度

DeepSeek Harness、Codex、WorkBuddy、Muse、Claude Code、Cindy 六款默认全部勾选。取消、添加其他本机程序及选中状态会保存。未发现安装的默认工具仍保留勾选，便于后续安装。安装路径、进程名和任务格式会随工具版本变化；界面中应以当前检测方式为准。

| 工具 | macOS 检测 | Windows/Linux 检测 | 正常完成事件 |
| --- | --- | --- | --- |
| Codex | 任务生命周期日志 | 任务生命周期日志 | 支持 |
| DeepSeek Harness | App 运行状态 | 进程运行状态 | 无默认可靠接入 |
| WorkBuddy | App 运行状态 | 进程运行状态 | 无默认可靠接入 |
| Muse | App 运行状态 | 进程运行状态 | 无默认可靠接入 |
| Claude Code | App / CLI 运行状态 | 进程运行状态 | 使用通用包装器可接入 |
| Cindy | 只读任务库运行元数据；不可读时保守保护 | 进程运行状态 | 无可靠成功/中断区分 |
| 其他自选程序 | App 运行状态 | 进程运行状态 | 无默认可靠接入 |

App/进程运行状态保护不等同于任务级检测。程序运行即保持保护，程序退出不标记任务成功。选中的 GUI App 或 CLI 可同时被识别为运行状态保护任务；该保护任务没有正常完成事件，可能阻止整批自动休眠。给包装器传入 `--agent claude` 等来源时，该来源也受勾选过滤；取消同一来源会同时排除其包装任务。若只想监控明确包装的 CLI，可在任务开始前取消对应 App 的勾选并**省略 `--agent`**，使用不按 App 来源过滤的通用任务。不要在一个任务运行中途切换监控范围来尝试触发完成后休眠。

### Codex

- 原生 macOS 当前读取 `~/.codex/sessions`。
- Windows/Linux 实现读取 `$CODEX_HOME/sessions`；未设置 `CODEX_HOME` 时使用 `~/.codex/sessions`。
- 仅处理 `event_msg` 中的 `task_started`、`task_complete`、`turn_aborted` 生命周期事件，并处理并发任务与子任务继承历史。
- 初次读取已有日志建立基线，历史完成记录不触发自动休眠。
- 日志格式不兼容、不可读或状态不明确时暂缓自动休眠，不把超时或记录消失作为成功。

它依赖工具实际写出的生命周期格式，不保证所有 Codex 版本、所有第三方兼容客户端或自定义日志目录自动可用。

### Cindy

macOS 适配器以只读方式查询 `~/Library/Application Support/Cindy/cindy-*.db` 的运行元数据，包括活动轮次时间和进程状态。会话 `active` 仅表示未归档，不直接表示正在运行。`last_turn_ended_at` 不能可靠证明正常完成，因此适配器不产生正常完成事件。Windows/Linux 当前不读取该任务库。

### 通用命令包装器

包装器需要 Python 3，不自动修改 Agent 配置。在插件中复制“通用命令接入”示例后，把 `--` 后面的命令换为实际要运行的命令。它适用于真实命令生命周期可代表任务生命周期的 CLI；若命令只启动一个后台 GUI 后立即返回，退出码不代表 GUI 内的任务结束，不适合这样包装。

macOS 已安装 App 示例：

```sh
'/Applications/SleepDock.app/Contents/Resources/sleepdock-run' \
  --agent claude --name 'Claude Code' -- claude -p '你的任务'
```

Windows 已解压包，在包目录中使用 PowerShell：

```powershell
py -3 '.\resources\app\resources\sleepdock-run.py' --agent claude --name 'Claude Code' -- claude -p '你的任务'
```

Linux 已解压包，在包目录中运行：

```sh
python3 './resources/app/resources/sleepdock-run.py' \
  --agent claude --name 'Claude Code' -- claude -p '你的任务'
```

支持的默认 `--agent` 标识为 `deepseek`、`codex`、`workbuddy`、`muse`、`claude`、`cindy`。只有实际安装、可从终端启动的工具命令才可使用；示例不承诺这些工具都提供同样的 CLI。自选 App 可使用对应的自定义标识。任务名称只是显示标签，不应放敏感内容。

只监控明确包装的任务、避免同一 App 运行状态阻挡时，先按需要取消该 App 的勾选，再省略来源参数，例如：

```sh
'/Applications/SleepDock.app/Contents/Resources/sleepdock-run' \
  --name 'Claude Code CLI' -- claude -p '你的任务'
```

此通用任务独立于六款 App 勾选，仍受总开关与 Agent 保护开关控制。

包装器每 3 秒续写心跳，记录自身 PID、任务 ID、来源、时间和状态。退出码 0 且没有中断才写为 `complete`；非零退出、信号中断或无法启动写为 `aborted`。心跳失联、记录损坏或消失不代表成功。

记录位置：

| 实现 | 目录 |
| --- | --- |
| macOS 原生包装器 | `~/Library/Application Support/SleepDock/tasks` |
| Windows/Linux 包装器 | `~/.sleepdock/tasks` |

包装器不保存命令文本或命令输出；输出仍由被包装程序写入原终端。任务名称、PID 和时间等元数据会保存在本机文件中。

### 完成后自动休眠的条件

1. 开启总开关、Agent 任务保护与完成后自动休眠。
2. 插件实际观察到本批任务运行。
3. 本批每个被观察任务都收到明确正常完成事件，没有中断、失联或未知来源。
4. 当前电源条件允许保护/休眠，并且没有其他被选中 App 的运行状态保护。
5. 开始 60 秒倒计时；键鼠操作、新任务和取消操作会阻止该次自动休眠。
6. 请求休眠前再次读取任务、电源与活动状态，复核通过才交给系统执行。

只有运行状态、没有可靠正常终态的工具不会触发自动休眠。可选择普通倒计时，或使用合适的 CLI 包装器。设置变更、唤醒等操作会重置相关跟踪状态，避免用旧任务完成驱动新休眠。

## English

### Selection and precision

The six default tools are selected on first launch. Selections and custom apps are saved; defaults remain selected even when not installed. Installation paths, process names, and task formats can change between tool versions.

Codex uses local lifecycle events on all supported implementations. Cindy uses read-only running-task metadata on macOS and process protection on Windows/Linux. DeepSeek Harness, WorkBuddy, Muse, Claude Code, and custom apps primarily use app/process-running protection. Running-process protection is not task-level completion detection: an open app keeps protection active, and closing it does not mean success.

Native macOS currently reads Codex logs from `~/.codex/sessions`. The cross-platform implementation supports `$CODEX_HOME/sessions`, falling back to `~/.codex/sessions`. Only compatible `task_started`, `task_complete`, and `turn_aborted` lifecycle events are used. Historical completions establish a baseline rather than initiating sleep. Incompatible, unreadable, or uncertain state delays automatic sleep.

The macOS Cindy adapter reads running metadata from `~/Library/Application Support/Cindy/cindy-*.db`. An active/unarchived session is not necessarily running. Existing end metadata does not reliably distinguish success from interruption, so this adapter never manufactures a success event.

### Generic command integration

Use the widget's copy-integration action to obtain a path appropriate to the installed package. Python 3 is required. Replace the command after `--` with an actual runnable CLI task. The macOS, PowerShell, and Linux examples above show packaged paths; substitute your task for the final quoted argument.

Default agent IDs are `deepseek`, `codex`, `workbuddy`, `muse`, `claude`, and `cindy`. The examples do not imply every named product offers a CLI. A launcher that exits immediately after opening a GUI is unsuitable: the launcher's exit is not completion of work inside that GUI.

The wrapper writes a heartbeat every three seconds. It records task ID/name, PID, agent ID, timestamps, and state. Exit code 0 without interruption produces `complete`; nonzero exit, interruption, or launch failure produces `aborted`. Lost heartbeats and missing or damaged records do not mean success. Command text and output are not saved by the wrapper. Avoid sensitive information in task names.

Native macOS leases live in `~/Library/Application Support/SleepDock/tasks`; Windows/Linux leases live in `~/.sleepdock/tasks`.

A selected GUI app or CLI may also be detected as a process-protection task. That fallback task has no successful completion event and can block the batch's automatic sleep. A wrapper task with `--agent claude` is filtered by that agent's checkbox too; deselecting the same source also excludes its wrapped tasks. To monitor only an explicitly wrapped CLI, deselect that app before starting the task and omit `--agent`. Untagged generic tasks are not filtered by the six app selections, but still require the master and agent-protection switches. Do not change monitored sources midway through a task to try to induce automatic sleep.

### Automatic sleep after completion

Enable the master switch, agent protection, and sleep-after-completion. SleepDock must have observed the running batch and received explicit successful completion for every observed task. Interruption, uncertainty, missing state, ineligible power conditions, or another selected running app prevents the completion countdown. A 60-second countdown follows; user activity or new work cancels it. Task and power state are checked again immediately before requesting sleep.

Adapters without reliable success events cannot initiate this feature. Use an explicit timer or a suitable wrapped CLI instead. SleepDock does not control or guarantee the quality of an agent's result; process exit and lifecycle events only describe execution state.
