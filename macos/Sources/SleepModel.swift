import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers

final class SleepModel: ObservableObject {
    @Published var settings: Settings { didSet { settingsChanged(from: oldValue) } }
    @Published var battery = -1
    @Published var pluggedIn = true
    @Published var idleSeconds: Double = 0
    @Published var lidClosed = false
    @Published var activeAgents: [AgentTask] = []
    @Published var agentSourceStatus = "正在连接本机 Codex"
    @Published var countdownSeconds: Int?
    @Published var countdownReason = ""
    @Published var statusTitle = "交还系统管理"
    @Published var statusDetail = "打开总开关，启用你的休眠规则"
    @Published var protected = false
    @Published var displayProtected = false
    @Published var lidOverrideActive = false
    @Published var lidBusy = false
    @Published var lastError: String?
    @Published var recentEvents: [EventEntry] = []
    @Published var timerRemaining = "尚未开始"
    @Published var loginStatus = ""
    @Published var installedAgents: [InstalledAgent] = []

    let power = PowerControl()
    let lid = LidController()
    private let monitor = AgentMonitor()
    private let nativeMonitor = NativeAgentMonitor()
    private var nativeSupported = Set<String>()
    private let monitorQueue = DispatchQueue(label: "dev.phecda.sleepdock.monitor", qos: .utility)
    private let gate = AutoSleepGate()
    private let completionTracker = AgentCompletionTracker()
    private let appDiscovery = AppDiscovery()
    private var lastSnapshot = AgentSnapshot()
    private var timer: Timer?
    private var timerDeadline: Date?
    private var timerDeferred = false
    private var uncertainAgents = false
    private var polling = false
    private var ticks = 0
    private var preparingSleep = false
    private var previousIdleSleep = false
    private var stopped = false
    private var sleepRequestToken: UUID?
    private var syncingLoginItem = false
    private let defaults: UserDefaults
    private let testing: Bool
    var onLayoutChange: (() -> Void)?
    var onStatusChange: (() -> Void)?
    var onHide: (() -> Void)?
    var onQuit: (() -> Void)?

    init(testing: Bool = false) {
        self.testing = testing
        defaults = testing ? UserDefaults(suiteName: "dev.phecda.sleepdock.test.\(UUID().uuidString)")! : .standard
        if let data = defaults.data(forKey: "settings"), let value = try? JSONDecoder().decode(Settings.self, from: data) {
            var value = value
            value.lidMode = value.lidMode == .awake ? .system : value.lidMode
            settings = value
        } else { settings = Settings() }
        updateLoginStatus()
        refreshAgentApps()
        log("插件已打开 · 合盖保持运行需每次单独授权")
        if !testing {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!, forMode: .common)
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.gate.cancel()
                self?.completionTracker.reset()
                self?.sleepRequestToken = nil
                self?.preparingSleep = false
                self?.timerDeadline = nil
                self?.timerDeferred = false
                self?.log("电脑已唤醒 · 已清除旧倒计时")
            }
            tick()
        }
    }

    private func settingsChanged(from old: Settings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "settings") }
        if old.mode != settings.mode {
            sleepRequestToken = nil; preparingSleep = false
            timerDeadline = nil; timerDeferred = false; gate.cancel(); previousIdleSleep = false
            log("休眠规则：\(settings.mode.title)")
        }
        if old.masterEnabled != settings.masterEnabled {
            sleepRequestToken = nil; preparingSleep = false
            log(settings.masterEnabled ? "总开关已开启" : "总开关已关闭 · 释放所有保护")
            gate.cancel(); timerDeadline = nil; timerDeferred = false
            completionTracker.reset()
        }
        if !settings.masterEnabled || settings.lidMode != .awake { lid.disable() }
        if !settings.masterEnabled || !settings.sleepAfterAgents || !settings.agentProtection {
            if gate.reason == .agents { gate.cancel() }
        }
        if old.agentProtection != settings.agentProtection || old.sleepAfterAgents != settings.sleepAfterAgents {
            completionTracker.reset()
            sleepRequestToken = nil; preparingSleep = false
        }
        if old.launchAtLogin != settings.launchAtLogin && !testing && !syncingLoginItem { changeLoginItem() }
        if old.selectedAgents != settings.selectedAgents {
            gate.cancel(); sleepRequestToken = nil; preparingSleep = false
            completionTracker.reset()
            mergeAgentSources()
        }
        onLayoutChange?()
        if !testing { evaluate(now: Date()) }
    }

    private func tick() {
        guard !stopped else { return }
        ticks += 1
        idleSeconds = PowerControl.idleSeconds()
        if ticks == 1 || ticks % 5 == 0 {
            let p = PowerControl.powerStatus()
            battery = p.battery; pluggedIn = p.pluggedIn
            let wasClosed = lidClosed
            lidClosed = PowerControl.lidClosed()
            if !wasClosed && lidClosed && settings.masterEnabled && settings.lidMode == .sleep {
                if settings.agentProtection && (!activeAgents.isEmpty || uncertainAgents) {
                    log("合盖 · Agent 任务保护优先；系统仍可能按硬件策略休眠")
                } else { requestSleep(reason: "合盖休眠") }
            }
            pollAgents()
            refreshAgentApps()
        }
        let batteryProtected = !pluggedIn && battery >= 0 && battery <= settings.lowBatteryCutoff
        if lid.active && (!settings.masterEnabled || !pluggedIn || batteryProtected) {
            lid.disable(); settings.lidMode = .system
            log("供电条件变化 · 正在恢复合盖系统行为")
        }
        lid.heartbeat()
        lidOverrideActive = lid.active
        lidBusy = lid.busy
        if preparingSleep {
            if let error = power.apply(keepAwake: true, keepDisplayAwake: settings.keepDisplayAwake) {
                lastError = error
                sleepRequestToken = nil; preparingSleep = false
            }
            protected = power.systemAssertion != nil
            displayProtected = power.displayAssertion != nil
        }
        evaluate(now: Date())
    }

    private func pollAgents() {
        guard !polling else { return }
        polling = true
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.scanAgents()
            let supported = self.nativeMonitor.supportedIDs
            DispatchQueue.main.async {
                self.polling = false
                let oldCount = self.activeAgents.count
                self.nativeSupported = supported
                self.lastSnapshot = snapshot
                self.mergeAgentSources()
                let interrupted = snapshot.hasInterruption(selectedAgentIDs: Set(self.settings.selectedAgents))
                if interrupted && self.gate.reason == .agents { self.gate.cancel() }
                if self.preparingSleep && self.settings.agentProtection && (!self.activeAgents.isEmpty || self.uncertainAgents || interrupted) {
                    self.sleepRequestToken = nil; self.preparingSleep = false
                    self.log("任务状态已变化 · 已取消正在准备的休眠")
                }
                if oldCount != self.activeAgents.count { self.log("Agent 运行中：\(self.activeAgents.count) 个") }
                let allCompleted = self.completionTracker.consume(tasks: self.activeAgents,
                    completedTaskIDs: snapshot.completedTaskIDs, uncertain: self.uncertainAgents, interrupted: interrupted)
                if allCompleted && self.settings.masterEnabled && self.settings.agentProtection && self.settings.sleepAfterAgents {
                    self.gate.arm(.agents, now: Date())
                    self.log("全部任务正常完成 · 60 秒后休眠，操作键鼠可取消")
                }
                self.evaluate(now: Date())
            }
        }
    }

    private func evaluate(now: Date) {
        guard !stopped, !preparingSleep else { return }
        let policy = SleepPolicy.evaluate(PolicyInput(settings: settings, battery: battery, pluggedIn: pluggedIn, idleSeconds: idleSeconds, taskCount: activeAgents.count, uncertainAgents: uncertainAgents))
        let taskBlocksSleep = settings.agentProtection && (!activeAgents.isEmpty || uncertainAgents)
        if settings.masterEnabled && settings.mode == .timer, let deadline = timerDeadline {
            let remaining = max(0, Int(ceil(deadline.timeIntervalSince(now))))
            timerRemaining = String(format: "%02d:%02d", remaining / 60, remaining % 60)
            if remaining == 0 {
                timerDeadline = nil
                if taskBlocksSleep { timerDeferred = true; log("定时已到 · 等待 Agent 任务完成") }
                else { gate.arm(.timer, now: now); log("定时已到 · 60 秒后休眠") }
            }
        } else if timerDeferred { timerRemaining = "等待任务结束" }
        else if settings.mode != .timer || gate.reason != .timer { timerRemaining = "尚未开始" }
        if timerDeferred && !taskBlocksSleep && settings.masterEnabled {
            timerDeferred = false
            gate.arm(.timer, now: now)
        }
        if gate.reason == .agents && (!settings.sleepAfterAgents || !settings.agentProtection) { gate.cancel() }
        let mayRunGate = settings.masterEnabled || gate.reason == .manual
        let hadGate = gate.deadline != nil
        if gate.tick(now: now, enabled: mayRunGate, taskCount: taskBlocksSleep ? activeAgents.count : 0, uncertain: taskBlocksSleep && uncertainAgents, idleSeconds: idleSeconds) {
            let reason = gate.reason?.rawValue ?? "休眠"
            gate.cancel(); requestSleep(reason: reason); return
        }
        if hadGate && gate.deadline == nil { log("自动休眠已取消 · 有操作、新任务或保护状态变化") }
        countdownSeconds = gate.remaining(now: now)
        countdownReason = gate.reason?.rawValue ?? ""
        var awake = policy.keepAwake
        if settings.mode == .timer && timerDeadline == nil && !timerDeferred && gate.deadline == nil {
            awake = settings.masterEnabled && (taskBlocksSleep || settings.keepDisplayAwake)
        }
        if countdownSeconds != nil { awake = true }
        let supplyAllowsProtection = (!settings.acOnly || pluggedIn) && (pluggedIn || battery < 0 || battery > settings.lowBatteryCutoff)
        awake = awake && supplyAllowsProtection
        if let error = power.apply(keepAwake: awake, keepDisplayAwake: awake && settings.keepDisplayAwake) { lastError = error }
        protected = power.systemAssertion != nil
        displayProtected = power.displayAssertion != nil
        statusTitle = !settings.masterEnabled ? "交还系统管理" : protected ? "保持清醒" : "允许休眠"
        if countdownSeconds != nil { statusTitle = "准备休眠" }
        statusDetail = !settings.masterEnabled ? "所有自动规则已暂停" : policy.reason
        if settings.mode == .timer && timerDeadline == nil && !timerDeferred && gate.deadline == nil && !taskBlocksSleep {
            statusDetail = "选择时长，然后开始倒计时"
        }
        if lidOverrideActive { statusDetail = "合盖保持运行 · 仅在接电时生效" }
        if policy.sleepForIdle && !previousIdleSleep && gate.deadline == nil { requestSleep(reason: "空闲 \(settings.minutes) 分钟") }
        previousIdleSleep = policy.sleepForIdle
        onStatusChange?()
    }

    func startTimer() {
        guard settings.masterEnabled else { lastError = "请先打开总开关"; return }
        settings.mode = .timer
        gate.cancel(); timerDeferred = false
        timerDeadline = Date().addingTimeInterval(Double(max(1, settings.minutes)) * 60)
        log("已开始 \(settings.minutes) 分钟倒计时")
        evaluate(now: Date())
    }

    func cancelCountdown() {
        sleepRequestToken = nil; preparingSleep = false
        gate.cancel(); timerDeadline = nil; timerDeferred = false
        countdownSeconds = nil; countdownReason = ""; timerRemaining = "已取消"
        log("已取消本次休眠")
        evaluate(now: Date())
    }

    func chooseLid(keepAwake: Bool) {
        if !keepAwake { lid.disable(); settings.lidMode = .sleep; log("合盖后请求休眠"); return }
        guard settings.masterEnabled else { lastError = "请先打开总开关，再启用合盖保持运行"; return }
        guard pluggedIn else { lastError = "合盖保持运行只在接通电源时启用"; return }
        guard !lid.busy else { return }
        lidBusy = true
        lid.enable { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lidBusy = false
                if let error { self.lastError = error; return }
                guard self.settings.masterEnabled, self.pluggedIn else { self.lid.disable(); return }
                self.settings.lidMode = .awake
                self.lidOverrideActive = self.lid.active
                self.log("合盖保持运行已启用 · 退出或失联后自动恢复")
            }
        }
    }

    func sleepNow() {
        if settings.agentProtection && (!activeAgents.isEmpty || uncertainAgents) {
            lastError = "Agent 仍在运行或状态未确认。关闭任务保护后，可主动休眠。"; return
        }
        gate.arm(.manual, now: Date(), delay: 15)
        log("主动休眠 · 15 秒取消窗口")
        evaluate(now: Date())
    }

    private func requestSleep(reason: String) {
        guard !preparingSleep else { return }
        preparingSleep = true
        let token = UUID()
        sleepRequestToken = token
        let requestedAt = Date()
        // Hold the lease through the final scan and privileged-setting restoration.
        // Releasing early could let macOS idle-sleep before new tasks are rechecked.
        if let error = power.apply(keepAwake: true, keepDisplayAwake: settings.keepDisplayAwake) {
            lastError = error; preparingSleep = false; sleepRequestToken = nil
            return
        }
        protected = power.systemAssertion != nil
        displayProtected = power.displayAssertion != nil
        let hadLidOverride = lid.active
        lid.disable(); lidOverrideActive = false
        if settings.lidMode == .awake { settings.lidMode = .system }
        log("请求休眠：\(reason)")
        monitorQueue.async { [weak self] in
            guard let self else { return }
            var restored = !hadLidOverride
            if hadLidOverride {
                for _ in 0..<15 {
                    if !PowerControl.sleepDisabled() { restored = true; break }
                    Thread.sleep(forTimeInterval: 1)
                }
            }
            // Refresh lifecycle state immediately before the side effect, not only on the 5-second poll.
            let snapshot = self.scanAgents()
            let supported = self.nativeMonitor.supportedIDs
            DispatchQueue.main.async {
                guard !self.stopped, self.sleepRequestToken == token else { return }
                self.preparingSleep = false
                self.nativeSupported = supported
                self.lastSnapshot = snapshot
                self.refreshAgentApps()
                let interrupted = snapshot.hasInterruption(selectedAgentIDs: Set(self.settings.selectedAgents))
                _ = self.completionTracker.consume(tasks: self.activeAgents,
                    completedTaskIDs: snapshot.completedTaskIDs, uncertain: self.uncertainAgents, interrupted: interrupted)
                let isManual = reason == CountdownReason.manual.rawValue
                let activityCancelled = reason == CountdownReason.agents.rawValue && PowerControl.idleSeconds() < Date().timeIntervalSince(requestedAt) - 1
                let idleCancelled = reason.hasPrefix("空闲 ") && (self.settings.mode != .idle || PowerControl.idleSeconds() < Double(max(1, self.settings.minutes) * 60))
                let taskCancelled = self.settings.agentProtection && (!self.activeAgents.isEmpty || self.uncertainAgents)
                let agentsCancelled = reason == CountdownReason.agents.rawValue && (!self.settings.agentProtection || !self.settings.sleepAfterAgents || interrupted)
                guard restored, (self.settings.masterEnabled || isManual), !activityCancelled, !idleCancelled, !taskCancelled, !agentsCancelled else {
                    self.sleepRequestToken = nil
                    self.lastError = !restored ? "合盖保护尚未恢复，已取消休眠" : "状态已变化，本次休眠已取消"
                    self.evaluate(now: Date()); return
                }
                self.sleepRequestToken = nil
                self.power.releaseAll(); self.protected = false; self.displayProtected = false
                if self.testing { self.log("测试模式 · 未实际休眠"); return }
                if let error = PowerControl.sleepSystem() { self.lastError = error; self.log("休眠请求失败") }
            }
        }
    }

    func screenOff() {
        settings.keepDisplayAwake = false
        if !testing, let error = PowerControl.turnOffDisplay() { lastError = error }
    }
    func lockScreen() { if !testing, let error = PowerControl.lockScreen() { lastError = error } }
    func clearError() { lastError = nil }
    func refreshAgentApps() {
        installedAgents = appDiscovery.scan()
        for i in installedAgents.indices where nativeSupported.contains(installedAgents[i].id) {
            installedAgents[i].detection = "任务元数据 · 不推断正常完成"
        }
        mergeAgentSources()
    }
    private func mergeAgentSources() {
        let selected = Set(settings.selectedAgents)
        var tasks = lastSnapshot.tasks.filter { task in
            let id = task.agentID ?? (task.source == "Codex" ? "codex" : nil)
            return id.map { selected.contains($0) } ?? true
        }
        let appFallbacks = installedAgents.filter { $0.id != "codex" && !nativeSupported.contains($0.id) && selected.contains($0.id) && $0.running }
        for app in appFallbacks {
            tasks.append(AgentTask(id: "app:" + app.id, name: app.name + " 已打开", startedAt: Date(), source: "运行状态", agentID: app.id))
        }
        activeAgents = tasks
        uncertainAgents = lastSnapshot.hasUncertainty(selectedAgentIDs: selected) || !appFallbacks.isEmpty
        agentSourceStatus = appFallbacks.isEmpty ? lastSnapshot.status : "\(appFallbacks.count) 个 App 按运行状态保护；无任务结束事件时暂缓自动休眠"
    }
    func addAgentApp() {
        let panel = NSOpenPanel()
        panel.title = "选择需要监控的 Agent App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let id = appDiscovery.add(url), !settings.selectedAgents.contains(id) { settings.selectedAgents.append(id) }
            }
            refreshAgentApps()
        }
    }
    func hideWidget() { onHide?() }
    func quit() { shutdown(); onQuit?() }
    func shutdown() {
        guard !stopped else { return }
        stopped = true; sleepRequestToken = nil; timer?.invalidate(); gate.cancel(); power.releaseAll(); lid.disable()
    }
    func openHelp() {
        let url = Bundle.main.resourceURL?.appendingPathComponent("使用说明.md")
        if let url { NSWorkspace.shared.open(url) }
    }
    func copyHookCommand() {
        let path = Bundle.main.resourceURL?.appendingPathComponent("sleepdock-run").path ?? "sleepdock-run"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(shellQuote(path)) --name '我的 Agent' -- 你的命令", forType: .string)
        log("已复制通用命令格式 · 替换末尾命令即可")
    }
    private func updateLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = "已开启"
        case .requiresApproval: loginStatus = "请在系统登录项中允许"
        case .notFound: loginStatus = "安装到“应用程序”后可开启"
        default: loginStatus = "未开启"
        }
        let status = SMAppService.mainApp.status
        let enabled = status == .enabled || status == .requiresApproval
        if settings.launchAtLogin != enabled {
            syncingLoginItem = true
            settings.launchAtLogin = enabled
            syncingLoginItem = false
        }
    }
    private func changeLoginItem() {
        do {
            if settings.launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            updateLoginStatus()
        } catch { lastError = "开机启动设置失败：\(error.localizedDescription)"; updateLoginStatus() }
    }
    private func log(_ message: String) {
        recentEvents.insert(EventEntry(date: Date(), title: message), at: 0)
        if recentEvents.count > 30 { recentEvents.removeLast(recentEvents.count - 30) }
    }
    private func scanAgents() -> AgentSnapshot {
        let codex = monitor.poll()
        let native = nativeMonitor.poll()
        let uncertainSources = codex.uncertainSources.union(native.uncertainSources)
        return AgentSnapshot(tasks: codex.tasks + native.tasks, completedNormally: codex.completedNormally || native.completedNormally,
                             uncertain: codex.uncertain || native.uncertain,
                             status: codex.uncertain || native.uncertain ? "部分任务状态未知，自动休眠已暂缓" : "任务事件已连接",
                             uncertainSources: uncertainSources, completedTaskIDs: codex.completedTaskIDs.union(native.completedTaskIDs),
                             interruptedSources: codex.interruptedSources.union(native.interruptedSources))
    }
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
