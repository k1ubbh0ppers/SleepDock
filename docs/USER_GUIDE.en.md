# SleepDock 1.1.1 user guide

[English homepage](../README.en.md) · [Agent integration](AGENTS.md)

SleepDock controls temporary sleep protection, timers, and supported lid behavior from a frosted desktop widget. The current user interface is in Simplified Chinese. This guide provides English explanations of its controls.

## Install and open

Download the matching asset from [Releases](https://github.com/k1ubbh0ppers/SleepDock/releases/tag/v1.1.1).

| Platform | Package and launch |
| --- | --- |
| macOS 14+ / Apple Silicon | Extract `SleepDock-macOS-arm64.zip`, move the app to Applications if desired, and open `SleepDock.app` |
| Windows x64 | Extract the **complete** `SleepDock-Windows-x64.zip` folder, then open `SleepDock.exe` |
| Linux glibc x64 graphical desktop | Extract `SleepDock-Linux-x64.tar.gz`, then run `./启动SleepDock.sh` |

Windows/Linux packages include the runtime. Do not move only the executable out of its directory. Linux needs the usual graphical desktop libraries used by Electron; target-distribution compatibility is not yet hardware-validated. The app retains Chromium's sandbox and does not automatically disable security settings.

Packages have no commercial release signing. macOS is ad-hoc signed, not Developer ID notarized. Building from source is available when a system blocks an unsigned package; system security need not be disabled.

On first launch, the master switch and automatic sleep after agent completion are off. Review the detected tools and power conditions before enabling them.

## Window controls

- `−` hides the widget to the menu bar or system tray. Protection continues while it is hidden.
- `×` quits the app and releases ordinary protection. Enabled temporary lid rules are restored/released through the platform cleanup mechanism.
- Use the menu-bar or tray item to show the window again. On Linux desktops without a working tray, launching the same program again restores its window.
- Drag the header to move the widget. The width stays at 390 logical units.
- Drag the bottom handle to adjust height; content scrolls as needed. Compact and expanded modes remember separate heights.
- The cross-platform bottom handle also accepts Up/Down keys in 20-unit steps when focused.
- Always-on-top, compact mode, and frosted depth are independent display preferences.

Version 1.1.1 removes the outer white stroke and native shadow. Pixels outside the rounded corners are transparent, while the interior keeps its translucent layer. Native Windows/Linux rendering still needs target-system verification. Windows 11 acrylic depends on system support; Linux blur and tray availability depend on the desktop environment.

## Sleep modes

| Chinese label | Behavior |
| --- | --- |
| 跟随系统 | Follow system sleep policy, with temporary protection only for enabled agent/display rules |
| 空闲后休眠 | Request sleep after uninterrupted keyboard/mouse inactivity reaches the selected duration; selected agent work delays it |
| 倒计时休眠 | Start a fixed timer from the Start button; ordinary input does not reset this timer; selected agent work delays sleep |
| 永不休眠 | Prevent ordinary system idle sleep while the app and relevant protection remain enabled |

Durations range from 1 to 1440 minutes. Ordinary never-sleep protection does not override hardware lid sleep, low battery, forced sleep, or the user manually requesting sleep.

Countdown expiration provides a 60-second cancellation window. A manual sleep request provides 15 seconds. Cross-platform idle sleep uses a 15-second cancellation window. Cancel a request from the widget if you want to continue working.

Display-off, lock, and system-sleep actions are separate. Turning off a display does not by itself sleep the computer. Missing system capabilities disable the relevant action or produce an explicit error. Wayland has no single universal display-off interface, so that action may be unavailable.

### Battery and AC conditions

Low-battery protection releases keep-awake protection at the configured cutoff; the default is 20%. AC-only mode releases protection when external power is absent or cannot be confirmed. Keep-display-awake is a separate switch, subject to the master switch and eligible power conditions.

## Select agents

DeepSeek Harness, Codex, WorkBuddy, Muse, Claude Code, and Cindy are selected by default. Deselect tools you do not need, or add another installed program. Selections persist across launches. A selected but uninstalled default remains selected for future installation.

Detection precision differs:

- **Codex:** compatible local task lifecycle events can prove successful completion.
- **Cindy on macOS:** running-task metadata can protect work, but cannot reliably distinguish successful completion from interruption.
- **Other defaults / custom apps:** conservative app/process-running protection. An open app keeps protection active. App exit is not a successful task event.
- **Generic wrapper:** heartbeat and command exit state can prove a successful command completion.

Read [Agent integration](AGENTS.md) before using automatic sleep after completion. A selected GUI app or CLI can also create a process-protection task with no success event. To monitor only an explicitly wrapped command, deselect that app before starting work and omit the wrapper's `--agent` argument. Otherwise its source is filtered by the same app checkbox. Untagged generic tasks remain subject to the master and agent-protection switches.

### Sleep after agents complete

The feature is off by default. Enable it with agent protection and the master switch. SleepDock must observe the running batch and confirm every task's normal completion. It then starts a 60-second countdown while the computer remains unused. Input, new tasks, interrupted or unknown state, and cancellation stop or defer this request. SleepDock rechecks tasks and power conditions immediately before asking the OS to sleep.

Old completion records, application exit, archived sessions, timeouts, and disappeared tasks are not evidence of success. Tools without a reliable normal terminal state cannot trigger this feature; use an explicit timer or suitable wrapped CLI instead.

## Lid behavior

Keep-running mode needs AC power and ventilation. Do not place a running, closed laptop in a bag. Ordinary agent protection cannot guarantee overriding the hardware's existing lid policy.

### macOS

- **系统默认 / System default:** preserve normal system behavior, including supported external-display clamshell mode.
- **合盖休眠 / Sleep on lid close:** while enabled, poll lid state and request sleep when appropriate. The OS may already have slept first. Selected agent work takes priority in the app's own decision, but cannot override hardware sleep by itself.
- **保持运行 / Keep running:** each activation requires a separate click, administrator authorization, and external power. It uses the private `disablesleep` setting and temporarily disables **system-wide sleep**, not merely the lid action.

The privileged watchdog saves the previous `SleepDisabled` value and restores only that setting. Disabling the feature, quitting, unplugging, losing the parent process, or a heartbeat timeout triggers recovery, normally within roughly 2–15 seconds. Regular keep-awake assertions have renewable 30-second leases so they expire if the app stops responding.

If an administrator force-kills the watchdog itself, it cannot clean up immediately. A recovery record is kept under `/Library/Application Support/com.phecda.SleepDock/LidGuard/state`. The next authorized activation first restores the old value. Manual recovery should inspect the saved `original` value and restore that value only; do not reset all power settings.

### Windows

Nondefault lid modes require the master switch and an in-app confirmation. Keep running also requires AC power. The helper temporarily changes the **current power plan's AC/DC lid actions** to “do nothing” or “sleep.” A separate watchdog saves and reads back original values, then restores them on disable, quit, parent exit, heartbeat failure, or unplugging in keep-running mode.

The app reports permission failures and does not elevate automatically. If the watchdog is force-killed, the next launch attempts recovery using the saved record. Failed recovery displays the record location and error. Hardware lid sleep may occur before agent detection; select keep-running mode when intentionally working with the lid closed. Nondefault lid modes do not silently reactivate across an app restart.

### Linux

Keep running uses a temporary logind lid inhibitor and does not write a persistent system configuration. The inhibitor is released on exit. Desktop managers may own lid policy and override this behavior.

Sleep on lid close needs an ACPI/UPower lid sensor. The app detects closure and, when not agent-protected, requests sleep with a cancellation window. The desktop's existing policy may act first. Systems without a usable logind session disable unsupported controls. Nondefault lid modes require confirmation each activation and do not automatically reactivate after restarting the app.

## Login startup

The native macOS app can register as a system login item. Moving it to Applications before enabling this is recommended. If macOS asks for approval, use System Settings → Login Items. Windows/Linux currently have no built-in launch-at-login switch.

## Local data

SleepDock does not require an account or configure a remote task service. Local settings remember the window and selections. Agent detection reads installed-app/process information and necessary lifecycle metadata. Codex session files may contain conversation bodies; the current parser extracts lifecycle fields and does not display or separately save the conversation text.

The generic wrapper writes task ID/name, PID, agent ID, timestamps, and state. It does not save the wrapped command text or output. Native macOS leases live in `~/Library/Application Support/SleepDock/tasks`; Windows/Linux leases live in `~/.sleepdock/tasks`. Avoid sensitive content in custom task names and remove private paths or credentials before reporting issues.

## Diagnostics and verification boundaries

Native macOS supports a read-only `--diagnostics` mode. `--assertion-probe` temporarily creates and releases system/display keep-awake assertions; it does not request sleep.

```sh
'/Applications/SleepDock.app/Contents/MacOS/SleepDock' --diagnostics
```

Development verified the native macOS build, signature, UI, saved selections/height, transparent pixels, and creation/release of actual keep-awake assertions. It also ran 85 native checks and 8 isolated watchdog simulations.

The cross-platform implementation passed 82 Node checks, wrapper success/interruption checks, and an Electron UI smoke test on macOS. Windows/Linux packages were inspected for PE/ELF entry points, resources, and archive consistency. They have **not** been run on physical Windows/Linux systems.

Actual lid close, requested sleep, lock, administrator authorization, and login-startup behavior were not triggered during development. Functional checks and isolated simulations do not replace hardware acceptance. The baseline records are dated 2026-10-22.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Master switch is off | This is the first-launch default; select rules before enabling |
| Protection remains after a task | Check for a selected app still using process-based protection |
| Automatic sleep never starts | Verify every observed task has a reliable success event; check unknown/interrupted states and AC/battery conditions |
| Agent is not detected | Check installation/process naming, tool version, and supported log path; add the app manually if needed |
| Linux window has no blur or tray | Check compositor/tray support; relaunch to show a hidden window |
| Lid mode fails | Inspect the displayed capability/permission error; do not assume ordinary idle protection overrides hardware lid sleep |
| Display-off unavailable | The desktop may not offer a supported interface, especially under Wayland |
| Package will not run | Keep the full extracted directory and inspect OS/architecture/library compatibility; no ARM Windows/Linux or Intel Mac package is currently supplied |

Issue reports should include OS and app versions, the selected sleep/lid mode, the displayed detection method, and reproducible steps. Label whether the observation came from a simulation or a real machine.
