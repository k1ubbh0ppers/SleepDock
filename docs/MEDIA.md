# Media / 介绍图片

## `assets/hero.png`

SleepDock 原创品牌主视觉，使用内置 ImageGen 生成。它表达后台任务与休眠管理的使用场景，不是产品截图或检测能力证明。未使用参考项目 Ponytail 的图片、标识或文案。

Original SleepDock brand illustration generated with the built-in ImageGen tool. It communicates the product's use case; it is not an app screenshot, a hardware test, or evidence of agent detection accuracy. No Ponytail image, logo, or copy was reused.

最终提示词 / Final prompt:

```text
Use case: ads-marketing
Asset type: GitHub README hero banner for SleepDock desktop sleep controller, wide landscape 16:9.
Primary request: Create a polished original product illustration for SleepDock. A calm night desk with a thin silver laptop, its screen a soft abstract dark teal glow, and an elegant translucent frosted glass crescent moon dock floating nearby. Six tiny soft light points orbit it, symbolizing background agent tasks. Visual story: work stays awake while tasks run, and rests when work is done.
Style/medium: premium editorial 3D still life with glass, brushed aluminum, carefully controlled reflections; contemporary desktop utility brand. Refined and minimal, no cartoon mascot.
Composition: clean generous negative space on the left for the product wordmark, laptop and glass moon on right, deep charcoal to blue-grey gradient background, muted icy cyan accents, subtle tactile grain. All elements comfortably within safe margins. Balanced wide banner, crisp at GitHub README size.
Text (verbatim): "SleepDock" and beneath it "Keep tasks awake. Let your laptop rest."
Constraints: Do not draw or invent an app interface, task statistics, partner logos, performance claims, badges, or OS logos. Only this exact title and tagline. This is a brand illustration, not a screenshot. No bright white border, no watermark.
```

## `assets/widget-macos.png`

真实 macOS 1.1.1 窗口的 RGBA 缓存截图。保持圆角外 alpha=0。总开关处于关闭状态；可见运行状态仅为截图时状态，不代表持续实时监控，也不代表其他平台界面已经过真机验收。截图未包含任务正文、用户名或个人文件路径。

Actual RGBA capture of the macOS 1.1.1 window, with fully transparent pixels outside the rounded corners. The master switch is off. Visible status reflects the moment of capture, not live monitoring or validation of another platform. The image contains no task content, username, or private file path.

## 更新原则 / Updating images

功能截图必须来自对应版本的真实界面；示意图必须标注。不要把模拟电量、任务计数、进程状态或生成界面描述为真机验证。保留主视觉提示词，避免未来介绍偏离实际能力。

Capture functional screenshots from the actual release and label illustrations. Never present simulated battery values, task counts, process state, or generated UI as hardware validation. Keep the hero prompt with the repository for reproducible editorial intent.
