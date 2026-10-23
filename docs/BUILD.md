# 从源码构建 / Build from source

## macOS 原生版

要求 macOS 14 或更新版本、Xcode 或 Xcode Command Line Tools。运行 `xcode-select --install` 安装 Apple 官方命令行工具。

```sh
bash macos/scripts/check.sh
bash macos/scripts/build-app.sh
open macos/build/SleepDock.app
```

构建脚本优先通过 `xcrun` 选取当前 macOS SDK，并先用最小 SwiftUI 程序验证工具链兼容性。若默认 SDK 缺少配套插件，会依次检查同目录已安装 SDK；也可通过 `SLEEPDOCK_MACOS_SDK` 明确指定。没有兼容 SDK 时停止构建并报告诊断，不会下载或修改系统工具链。产物固定为 Apple Silicon arm64，最低系统版本为 macOS 14。`macos/.build/` 只放缓存与测试产物，`macos/build/` 放应用。脚本使用临时签名；不包含 Developer ID、公证或分发证书。测试会将电源命令替换为隔离模拟，构建不会启动应用。

Requirements: macOS 14+, Xcode or Xcode Command Line Tools. Run the commands above from the repository root. The script starts with the active SDK from `xcrun` and probes a minimal SwiftUI view. If that SDK lacks required toolchain plugins, it checks other installed SDKs in the same directory. Set `SLEEPDOCK_MACOS_SDK` to choose one explicitly. If none works, the build stops with diagnostics without modifying or downloading a toolchain. It builds an arm64 app targeting macOS 14 and applies an ad-hoc signature. Build output is `macos/build/SleepDock.app`; caches and checks stay under `macos/.build/`. Building does not launch the application. Checks replace power commands with isolated mocks.

## Windows / Linux Electron 版

开发环境使用 Node.js 24；工具依赖最低要求 Node.js 22.12.0。锁定 Electron 45.0.0 和 Electron Packager 20.3.0。先完整克隆本仓库，再执行：

```sh
cd cross-platform
npm ci
npm test
npm start
```

`npm start` 会通过 Electron 官方安装器下载当前平台的运行时并启动开发界面。运行包包含 Electron，使用者无需另装 Node.js。通用命令包装器另外需要 Python 3。

For development, use Node.js 24 (minimum supported by the toolchain: 22.12.0). `npm ci` uses the committed lockfile. `npm start` downloads the matching official Electron runtime when needed and launches the app. Downloaded application packages already contain Electron; end users do not need Node.js. The generic command wrapper requires Python 3 separately.

### 打包 / Packaging

```sh
# Both Windows x64 and Linux x64
npm run package
# One target only
npm run package:win
npm run package:linux
```

产物位于 `cross-platform/dist/`。可用环境变量 `SLEEPDOCK_PACKAGE_OUT` 更改输出目录。Windows/Linux 均为 x64；脚本不生成安装程序，不进行商业签名。Linux 包自带 `启动SleepDock.sh`。跨平台打包仍受 Electron 工具链及宿主系统限制；推荐在对应平台上构建。Windows 修改可执行文件资源时，在 macOS/Linux 上可能需要额外工具。

Output is under `cross-platform/dist/`; optionally set `SLEEPDOCK_PACKAGE_OUT`. Both targets are x64 directory packages, without installers or commercial signatures. Linux includes a launcher script. Cross-building depends on the Electron toolchain and host capabilities; native runners are recommended. Editing Windows executable resources from macOS/Linux can require additional tools.

离线构建可设置 `SLEEPDOCK_ELECTRON_ZIP_DIR`，指向已下载的官方 Electron ZIP 所在目录。文件名必须为 `electron-v45.0.0-win32-x64.zip` 或 `electron-v45.0.0-linux-x64.zip`；脚本会逐个与 npm Electron 包内的 SHA256 对照，校验失败即停止。默认仍从官方源下载并校验。

For an offline build, set `SLEEPDOCK_ELECTRON_ZIP_DIR` to a directory containing the official runtime ZIPs with the filenames above. Every supplied archive is verified against the SHA256 values in the npm Electron package before packaging. A mismatch stops the build. The default path downloads and verifies official runtime archives.

## 自动检查和手动构建 / CI and manual builds

- `Source checks` runs source hygiene checks, Node tests on Ubuntu, and native checks/build on macOS after pushes or pull requests.
- `Build downloadable packages` is started manually in GitHub Actions. It produces macOS arm64, Windows x64, and Linux x64 archive artifacts. It does not publish or overwrite GitHub Releases and requires no signing secrets.
- `python3 scripts/check-source.py` catches known credential formats, personal absolute paths, and files over 10 MiB. This targeted check supplements human review; it cannot prove that every possible secret format is absent.

CI 构建或测试通过不等于真实设备上的休眠、合盖、锁屏、权限和散热验收。当前验证范围见 [中文主页](../README.md) 和平台目录中的 `验证记录.md`。GitHub 工作流文件随源码提供；只有实际运行成功的远端结果才算 CI 通过。

CI success does not verify hardware sleep, lid behavior, locking, permissions, or thermal conditions. See the [English overview](../README.en.md) and the per-platform validation records. Workflow definitions are included, but remote CI must actually run successfully before its status can be claimed.
