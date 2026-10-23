import Foundation

enum SleepMode: String, Codable, CaseIterable, Identifiable {
    case system, idle, timer, never
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "跟随系统"; case .idle: return "空闲后休眠"; case .timer: return "倒计时休眠"; case .never: return "永不休眠" }
    }
}

enum LidMode: String, Codable, CaseIterable, Identifiable {
    case system, sleep, awake
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "系统默认"; case .sleep: return "合盖休眠"; case .awake: return "保持运行" }
    }
}

struct Settings: Codable, Equatable {
    var masterEnabled = false
    var mode: SleepMode = .system
    var minutes = 30
    var agentProtection = true
    var sleepAfterAgents = false
    var keepDisplayAwake = false
    var acOnly = false
    var lowBatteryCutoff = 20
    var floatOnTop = true
    var launchAtLogin = false
    var compact = false
    var opacity = 0.82
    var lidMode: LidMode = .system
    var selectedAgents: [String] = ["deepseek", "codex", "workbuddy", "muse", "claude", "cindy"]
}

struct AgentTask: Identifiable, Equatable {
    var id: String
    var name: String
    var startedAt: Date
    var source: String
    var agentID: String? = nil
}

struct InstalledAgent: Identifiable {
    var id: String
    var name: String
    var installed: Bool
    var running: Bool
    var detection: String
}

struct EventEntry: Identifiable {
    let id = UUID()
    let date: Date
    let title: String
}

struct AgentSnapshot {
    var tasks: [AgentTask] = []
    var completedNormally = false
    var uncertain = false
    var status = "正在连接本机 Codex"
    var uncertainSources: Set<String> = []
    var completedTaskIDs: Set<String> = []
    var interruptedSources: Set<String> = []
}

enum CountdownReason: String { case timer = "定时休眠", agents = "任务完成", manual = "立即休眠" }

struct PolicyInput {
    var settings: Settings
    var battery: Int
    var pluggedIn: Bool
    var idleSeconds: Double
    var taskCount: Int
    var uncertainAgents = false
}

struct PolicyDecision: Equatable {
    var keepAwake: Bool
    var keepDisplayAwake: Bool
    var sleepForIdle: Bool
    var reason: String
}
