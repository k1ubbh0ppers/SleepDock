# Third-party notices / 第三方版权说明

SleepDock source code is distributed under the MIT license in [`LICENSE`](LICENSE).

## Windows and Linux application packages

The runtime packages include Electron and its Chromium, Node.js, and other bundled components. Their upstream licenses and copyright notices are distributed with the runtime:

- `LICENSE`: Electron's upstream license. This file is preserved unchanged.
- `LICENSES.chromium.html`: notices for Chromium and other components bundled by Electron. This file is preserved unchanged.
- `LICENSE-SleepDock.txt`: SleepDock's MIT license.
- `resources/app/LICENSE`: another copy of SleepDock's MIT license next to its application source.

Please preserve these notices when redistributing the application. See [Electron](https://github.com/electron/electron) for the upstream project and additional component information.

Windows/Linux 运行包包含 Electron 及其 Chromium、Node.js 等组件。根目录 `LICENSE` 属于 Electron；`LICENSES.chromium.html` 为 Electron 提供的组件版权文件，两者均原样保留。SleepDock 自身许可证另放在 `LICENSE-SleepDock.txt` 和 `resources/app/LICENSE`，避免覆盖运行时版权。再次分发时请一并保留。

## macOS native application

The macOS native app uses Apple frameworks supplied by the operating system; it does not bundle Electron. Its `Contents/Resources/LICENSE` contains SleepDock's MIT license. Apple system components remain subject to Apple's terms.

macOS 原生应用使用操作系统提供的 Apple 框架，不包含 Electron。SleepDock 许可证位于应用的 `Contents/Resources/LICENSE`。系统组件遵循其原有条款。

## Build tools and optional command integration

Development dependency versions and integrity values are recorded in `cross-platform/package-lock.json`. These dependencies retain their respective upstream licenses. The packaged application excludes development `node_modules`.

Python 3, required only for generic command integration, is supplied separately by the user and is not bundled by SleepDock.

开发依赖版本与完整性校验值见 `cross-platform/package-lock.json`，各依赖保留其上游许可证。运行包不包含开发用 `node_modules`。通用命令接入所需 Python 3 由用户另行安装，SleepDock 不捆绑分发。
