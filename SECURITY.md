# Security / 安全反馈

SleepDock 管理本机防休眠与部分系统电源设置。权限、命令执行、IPC、状态文件、合盖恢复或任务完成判断出现问题，都可能影响电脑的可用性。

SleepDock controls local sleep assertions and selected power settings. Problems involving permissions, command execution, IPC, state files, lid-policy restoration, or completion detection can affect the availability of the machine.

## 报告方式 / Reporting

请优先使用本仓库 GitHub Security 页中的 **Report a vulnerability**（若维护者已启用）。若该入口不可用，请提交不含复现细节、凭据和个人数据的 issue，请求私下联系维护者；不要公开可利用步骤或完整 Agent 日志。

Prefer **Report a vulnerability** on the repository's GitHub Security tab when available. If private reporting is unavailable, open a minimal issue requesting a private contact channel. Do not publish exploit details, credentials, private paths, task contents, or full agent logs.

## 版本与发布状态 / Release status

当前维护版本为 1.1.x，安全修复优先进入最新版本。项目尚无商业签名发布流程或响应时间承诺。macOS 下载包为临时签名，未公证；Windows / Linux 包未作商业签名。请核对 Releases 附带的 SHA256，或从源码构建。

The maintained line is 1.1.x; fixes target the latest release. There is no commercial signing pipeline or guaranteed response time. The macOS artifact is ad-hoc signed and not notarized; Windows and Linux packages do not have commercial signatures. Verify release SHA256 values or build from source.

## 本地数据 / Local data

任务检测在本机完成。报告问题时只提供必要、脱敏的片段。请勿把真实任务记录、配置目录或系统授权记录提交到代码仓库。

Task detection runs locally. Share only the minimum redacted information needed to reproduce a problem. Keep real task records, settings folders, and system authorization records out of the repository.
