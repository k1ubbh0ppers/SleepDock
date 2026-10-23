import SwiftUI

struct WidgetView: View {
    @ObservedObject var model: SleepModel
    @State private var showUtilities = false
    @State private var showEvents = false
    @State private var showAgentApps = false

    private let accent = Color(red: 0.41, green: 0.92, blue: 0.79)
    private let muted = Color.white.opacity(0.54)
    private let secondary = Color.white.opacity(0.73)

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(spacing: 12) {
                    statusCard
                    if model.countdownSeconds != nil { countdownCard }
                    if !model.settings.compact {
                        if let message = model.lastError { errorCard(message) }
                        sleepSection
                        lidSection
                        agentSection
                        utilitiesSection
                        actionsSection
                        eventSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)
            .scrollIndicators(.hidden)
            footer
        }
        .frame(width: 390)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 25, style: .circular)
                .fill(Color(red: 0.055, green: 0.085, blue: 0.10).opacity(model.settings.opacity * 0.8))
                .overlay(alignment: .topLeading) {
                    Circle().fill(accent.opacity(0.075)).frame(width: 240, height: 240)
                        .blur(radius: 45).offset(x: -120, y: -130)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 25, style: .circular))
        .preferredColorScheme(.dark)
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(accent.opacity(0.13))
                Image(systemName: "moon.zzz.fill").font(.system(size: 20, weight: .medium)).foregroundStyle(accent)
            }
            .frame(width: 39, height: 39)
            VStack(alignment: .leading, spacing: 2) {
                Text("SleepDock").font(.system(size: 16, weight: .semibold, design: .rounded)).tracking(0.2)
                Text("让休眠，听你的").font(.system(size: 10)).foregroundStyle(muted)
            }
            Spacer(minLength: 6)
            Toggle("启用插件", isOn: $model.settings.masterEnabled)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help("总开关：停用后释放插件的休眠控制")
                .accessibilityLabel("启用插件")
            iconButton("minus", help: "隐藏到菜单栏", action: model.hideWidget)
            iconButton("xmark", help: "关闭插件并恢复休眠", action: model.quit)
        }
        .padding(.horizontal, 17).padding(.top, 17).padding(.bottom, 15)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(model.protected ? accent : muted).frame(width: 5, height: 5)
                    Text(model.settings.masterEnabled ? (model.protected ? "保护中" : "已启用") : "已停用")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(model.protected ? accent : secondary)
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: model.pluggedIn ? "bolt.batteryblock.fill" : batteryIcon)
                    Text(model.battery >= 0 ? "\(model.battery)%" : "电量未知")
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(secondary)
            }
            HStack(alignment: .center, spacing: 13) {
                ZStack {
                    Circle().fill(accent.opacity(0.09)).frame(width: 44, height: 44)
                    Image(systemName: model.protected ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 22, weight: .light)).foregroundStyle(model.protected ? accent : .white.opacity(0.70))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.statusTitle).font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text(model.statusDetail).font(.system(size: 11)).foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            if !model.settings.compact {
                HStack(spacing: 0) {
                    miniMetric("键鼠空闲", value: idleDescription, icon: "cursorarrow")
                    Spacer()
                    miniMetric("Agent 任务", value: "\(model.activeAgents.count) 个", icon: "sparkles")
                    Spacer()
                    miniMetric("供电", value: model.pluggedIn ? "已接电" : "电池", icon: model.pluggedIn ? "powerplug" : "battery.75percent")
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(cardBackground(highlighted: true))
    }

    private var countdownCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "hourglass").font(.system(size: 20)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.countdownSeconds ?? 0) 秒后休眠").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                Text(model.countdownReason).font(.system(size: 10)).foregroundStyle(secondary)
            }
            Spacer()
            Button("取消", action: model.cancelCountdown)
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 16).fill(.orange.opacity(0.11)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.orange.opacity(0.22), lineWidth: 0.7))
    }

    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("休眠节奏", eyebrow: "SLEEP", icon: "moon")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                ForEach(SleepMode.allCases) { mode in
                    modeButton(mode)
                }
            }
            if model.settings.mode == .idle || model.settings.mode == .timer {
                HStack {
                    Text("时长").font(.system(size: 11)).foregroundStyle(secondary)
                    Picker("常用时长", selection: $model.settings.minutes) {
                        ForEach([5, 10, 15, 30, 60, 120], id: \.self) { value in
                            Text("\(value) 分钟").tag(value)
                        }
                        if ![5, 10, 15, 30, 60, 120].contains(model.settings.minutes) {
                            Text("\(model.settings.minutes) 分钟").tag(model.settings.minutes)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 111)
                    Spacer(minLength: 0)
                    Stepper(value: $model.settings.minutes, in: 1...1440) {
                        Text("\(model.settings.minutes)").font(.system(size: 11)).monospacedDigit()
                    }
                    .frame(width: 99).controlSize(.small)
                }
            }
            if model.settings.mode == .timer {
                HStack(spacing: 9) {
                    Button(action: model.startTimer) {
                        Label("开始倒计时", systemImage: "timer")
                            .font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!model.settings.masterEnabled)
                    Text(model.timerRemaining).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(accent)
                    Button(action: model.cancelCountdown) {
                        Image(systemName: "stop.circle").font(.system(size: 14)).foregroundStyle(secondary)
                    }.buttonStyle(.plain).help("取消定时休眠")
                }
            }
            Text(sleepExplanation).font(.system(size: 10)).foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).background(cardBackground())
    }

    private var lidSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                sectionHeading("合上屏幕", eyebrow: "LID", icon: "laptopcomputer")
                Spacer()
                if model.lidBusy { ProgressView().controlSize(.mini) }
                else {
                    Text(model.lidClosed ? "已合盖" : "已开盖")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
            }
            HStack(spacing: 7) {
                lidOption("系统默认", subtitle: "保留原行为", icon: "gearshape", selected: model.settings.lidMode == .system) {
                    model.settings.lidMode = .system
                }
                lidOption("合盖休眠", subtitle: "合上即休眠", icon: "moon.zzz", selected: model.settings.lidMode == .sleep) {
                    model.chooseLid(keepAwake: false)
                }
                lidOption("保持运行", subtitle: "合盖继续工作", icon: "laptopcomputer.and.arrow.down", selected: model.lidOverrideActive) {
                    model.chooseLid(keepAwake: true)
                }
                .disabled(!model.settings.masterEnabled || !model.pluggedIn)
            }
            .disabled(model.lidBusy)
            Text("保持运行需启用总开关、接通电源并单独授权。退出插件后恢复原设置；选系统默认时遵循外接显示器等系统规则。")
                .font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).background(cardBackground())
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                sectionHeading("Agent 守护", eyebrow: "AGENT", icon: "sparkles")
                Spacer()
                if !model.activeAgents.isEmpty {
                    Text("\(model.activeAgents.count) 项运行中").font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
                }
            }
            settingToggle("任务运行时不休眠", detail: "已选工具按任务事件或运行状态保护", binding: $model.settings.agentProtection)
            Divider().overlay(.white.opacity(0.04))
            settingToggle("任务完成后自动休眠", detail: "全部正常完成后倒计时 60 秒，操作电脑可取消", binding: $model.settings.sleepAfterAgents)
            DisclosureGroup(isExpanded: $showAgentApps) {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(model.installedAgents) { app in
                        agentAppRow(app)
                    }
                    HStack {
                        Button(action: model.addAgentApp) {
                            Label("添加其他 App", systemImage: "plus")
                        }
                        Spacer()
                        Button(action: model.refreshAgentApps) {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.mini).font(.system(size: 10))
                    Text("无法读取任务事件的 App，运行期间持续保护；自动休眠只依据可靠的任务结束事件。")
                        .font(.system(size: 9)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 9)
            } label: {
                HStack(spacing: 5) {
                    Text("监控的 Agent App").font(.system(size: 11, weight: .medium))
                    Text("\(model.settings.selectedAgents.count) 个已选")
                        .font(.system(size: 9)).foregroundStyle(muted)
                }
            }
            .font(.system(size: 11)).foregroundStyle(secondary)
            if !model.activeAgents.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(model.activeAgents.prefix(3))) { task in
                        HStack(spacing: 7) {
                            Circle().fill(accent).frame(width: 4, height: 4)
                            Text(task.name).lineLimit(1)
                            Spacer()
                            Text(task.source).foregroundStyle(muted)
                        }
                        .font(.system(size: 10))
                    }
                    if model.activeAgents.count > 3 {
                        Text("另有 \(model.activeAgents.count - 3) 项任务").font(.system(size: 10)).foregroundStyle(muted)
                    }
                }
                .padding(9).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "waveform.path").font(.system(size: 10)).foregroundStyle(accent.opacity(0.7))
                Text(model.agentSourceStatus).font(.system(size: 10)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).background(cardBackground())
    }

    private var utilitiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showUtilities.toggle() }
            } label: {
                HStack {
                    sectionHeading("实用设置", eyebrow: "MORE", icon: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: showUtilities ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showUtilities {
                settingToggle("屏幕保持常亮", detail: "与系统防休眠分开控制", binding: $model.settings.keepDisplayAwake)
                settingToggle("仅接电时保护", detail: "拔掉电源，允许系统正常休眠", binding: $model.settings.acOnly)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("低电量保护").font(.system(size: 12, weight: .medium))
                        Text("电池低于阈值时释放防休眠").font(.system(size: 10)).foregroundStyle(muted)
                    }
                    Spacer()
                    Picker("低电量阈值", selection: $model.settings.lowBatteryCutoff) {
                        Text("关闭").tag(0)
                        ForEach([10, 15, 20, 25, 30], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 75)
                }
                Divider().overlay(.white.opacity(0.04))
                settingToggle("悬浮置顶", detail: "切换窗口时仍可看到插件", binding: $model.settings.floatOnTop)
                settingToggle("开机启动", detail: model.loginStatus, binding: $model.settings.launchAtLogin)
                settingToggle("紧凑模式", detail: "收起控制面板，只显示当前状态", binding: $model.settings.compact)
                HStack {
                    Text("透明度").font(.system(size: 11)).foregroundStyle(secondary)
                    Slider(value: $model.settings.opacity, in: 0.45...1.0).controlSize(.mini)
                    Text("\(Int(model.settings.opacity * 100))%")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).frame(width: 30)
                }
            }
        }
        .padding(14).background(cardBackground())
    }

    private var actionsSection: some View {
        HStack(spacing: 8) {
            actionButton("立即休眠", icon: "moon.zzz", action: model.sleepNow)
            actionButton("关闭屏幕", icon: "display", action: model.screenOff)
            actionButton("锁定屏幕", icon: "lock", action: model.lockScreen)
        }
    }

    private var eventSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showEvents.toggle() }
            } label: {
                HStack {
                    Label("最近记录", systemImage: "clock.arrow.circlepath").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("\(model.recentEvents.count)").font(.system(size: 10, design: .monospaced))
                    Image(systemName: showEvents ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(secondary).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showEvents {
                if model.recentEvents.isEmpty {
                    Text("启用或切换功能后，记录会显示在这里。").font(.system(size: 10)).foregroundStyle(muted)
                }
                ForEach(Array(model.recentEvents.prefix(8))) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Text(event.date, style: .time).font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).frame(width: 58, alignment: .leading)
                        Text(event.title).font(.system(size: 10)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12).background(cardBackground())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.settings.compact {
                Button { model.settings.compact = false } label: {
                    Label("展开控制", systemImage: "arrow.up.left.and.arrow.down.right")
                }.buttonStyle(.plain)
            } else {
                Image(systemName: "checkmark.shield").foregroundStyle(accent.opacity(0.65))
                Text("本机运行 · 退出即释放控制").foregroundStyle(muted)
            }
            Spacer(minLength: 0)
            Button(action: model.copyHookCommand) {
                Image(systemName: "terminal").font(.system(size: 11))
            }.buttonStyle(.plain).help("复制通用 Agent 接入命令")
            Button(action: model.openHelp) {
                Image(systemName: "questionmark.circle").font(.system(size: 12))
            }.buttonStyle(.plain).help("使用说明与能力边界")
        }
        .font(.system(size: 9)).foregroundStyle(secondary)
        .padding(.horizontal, 18).padding(.bottom, 21).padding(.top, 7)
    }

    private func modeButton(_ mode: SleepMode) -> some View {
        let selected = model.settings.mode == mode
        return Button { model.settings.mode = mode } label: {
            HStack(spacing: 7) {
                Image(systemName: modeIcon(mode)).font(.system(size: 12))
                Text(mode.title).font(.system(size: 11, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            }
            .foregroundStyle(selected ? accent : secondary)
            .padding(.horizontal, 10).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? accent.opacity(0.12) : .white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? accent.opacity(0.30) : .white.opacity(0.055), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func lidOption(_ title: String, subtitle: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: icon).font(.system(size: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 11, weight: .medium))
                    Text(subtitle).font(.system(size: 9)).foregroundStyle(selected ? accent.opacity(0.65) : muted)
                }
            }
            .foregroundStyle(selected ? accent : secondary)
            .padding(10).frame(maxWidth: .infinity, minHeight: 67, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? accent.opacity(0.10) : .white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? accent.opacity(0.25) : .white.opacity(0.05), lineWidth: 0.7))
        }.buttonStyle(.plain)
    }

    private func settingToggle(_ title: String, detail: String, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.91))
                Text(detail).font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch).controlSize(.small)
        .accessibilityLabel(title)
    }

    private func agentAppRow(_ app: InstalledAgent) -> some View {
        Toggle(isOn: Binding(
            get: { model.settings.selectedAgents.contains(app.id) },
            set: { selected in
                if selected {
                    if !model.settings.selectedAgents.contains(app.id) { model.settings.selectedAgents.append(app.id) }
                } else {
                    model.settings.selectedAgents.removeAll { $0 == app.id }
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.91))
                    Spacer(minLength: 0)
                    Text(app.running ? "运行中" : (app.installed ? "已安装" : "未检测到"))
                        .font(.system(size: 9)).foregroundStyle(app.running ? accent : muted)
                }
                Text(app.detection).font(.system(size: 9)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox).controlSize(.small)
        .accessibilityLabel("监控 \(app.name)")
    }

    private func sectionHeading(_ title: String, eyebrow: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(accent.opacity(0.80))
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
            Text(eyebrow).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.3).foregroundStyle(muted.opacity(0.65))
        }
    }

    private func miniMetric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9)).foregroundStyle(muted)
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(value).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
            }.foregroundStyle(secondary)
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 15, weight: .regular)).foregroundStyle(accent.opacity(0.85))
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 63)
            .background(cardBackground())
        }.buttonStyle(.plain)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(secondary).frame(width: 23, height: 27).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.system(size: 10)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: model.clearError) { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain)
        }
        .padding(11).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func cardBackground(highlighted: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(highlighted ? accent.opacity(0.035) : .white.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(highlighted ? 0.115 : 0.075), lineWidth: 0.7))
    }

    private var idleDescription: String {
        if model.idleSeconds < 60 { return "\(max(0, Int(model.idleSeconds))) 秒" }
        return "\(Int(model.idleSeconds / 60)) 分钟"
    }

    private var batteryIcon: String {
        switch model.battery {
        case 0..<15: return "battery.0percent"
        case 15..<40: return "battery.25percent"
        case 40..<65: return "battery.50percent"
        case 65..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var sleepExplanation: String {
        switch model.settings.mode {
        case .system: return "沿用 macOS 原有休眠设置；Agent 守护仍可单独生效。"
        case .idle: return "连续无键鼠操作达设定时长后休眠，任务运行时延后。"
        case .timer: return "开始后按时休眠；Agent 运行时暂缓，休眠前可取消。"
        case .never: return "保持系统运行，屏幕可单独休眠；低电量保护仍生效。"
        }
    }

    private func modeIcon(_ mode: SleepMode) -> String {
        switch mode {
        case .system: return "gearshape"
        case .idle: return "cursorarrow.motionlines"
        case .timer: return "timer"
        case .never: return "infinity"
        }
    }
}
