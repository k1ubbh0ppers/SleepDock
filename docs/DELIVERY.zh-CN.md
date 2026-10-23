# SleepDock 1.1.1 三平台交付

| 系统 | 文件 | 打开方式 |
| --- | --- | --- |
| macOS · Apple Silicon | SleepDock-macOS-arm64.zip | 解压后打开 SleepDock.app |
| Windows · x64 | SleepDock-Windows-x64.zip | 完整解压，打开 SleepDock.exe |
| Linux · x64 | SleepDock-Linux-x64.tar.gz | 解压后运行 启动SleepDock.sh |

三版宽度固定 390，拖动底部横条调整高度，紧凑／展开分别保存。1.1.1 删除外轮廓白色描边和窗口阴影；四个圆角外完全透明（alpha=0），内部保留磨砂。保留六款 Agent 默认全选，可取消、保存与添加其他程序。

首次启动总开关关闭；按需启用。插件内 `×` 完全退出并释放保护，`−` 隐藏到菜单栏／托盘。Windows/Linux 包内已包含运行时，保留完整目录，不要只复制主程序。

Windows 使用系统电源接口，合盖规则需应用内单独确认；权限不足报错，不自动提权。Linux 依赖桌面合成器与 logind，缺失接口时禁用对应按钮。Windows/Linux 其他五款 Agent 目前按进程运行保护，Codex 与通用命令可识别正常完成；Cindy 在 macOS 使用运行元数据，跨平台版暂用进程方式。

macOS 已实测拖动调高、重开保存和透明像素；Windows/Linux 已完成交叉打包、包结构和平台模拟检查，尚未真机验收。真实合盖、主动休眠、锁屏均未在开发中触发。不能把模拟检查视为硬件验证。

详细说明位于源码的 `macos/使用说明.md` 与 `cross-platform/使用说明.md`。源码包含构建脚本与检查；运行包均未做商业发布签名／公证。
