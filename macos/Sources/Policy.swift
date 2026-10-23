import Foundation

enum SleepPolicy {
    static func evaluate(_ input: PolicyInput) -> PolicyDecision {
        let s = input.settings
        func decision(_ awake: Bool, _ reason: String, idle: Bool = false) -> PolicyDecision {
            PolicyDecision(keepAwake: awake, keepDisplayAwake: awake && s.keepDisplayAwake, sleepForIdle: idle, reason: reason)
        }
        guard s.masterEnabled else { return decision(false, "插件已暂停") }
        guard !s.acOnly || input.pluggedIn else { return decision(false, "仅接电保护 · 当前使用电池") }
        guard input.pluggedIn || input.battery < 0 || input.battery > s.lowBatteryCutoff else {
            return decision(false, "低电量 · 已释放休眠保护")
        }
        if s.agentProtection && input.taskCount > 0 { return decision(true, "Agent 正在工作") }
        if s.agentProtection && input.uncertainAgents { return decision(true, "任务状态待确认 · 保留保护") }
        switch s.mode {
        case .system: return decision(s.keepDisplayAwake, "跟随系统休眠设置")
        case .never: return decision(true, "保持清醒 · 允许屏幕熄灭")
        case .timer: return decision(true, "定时模式")
        case .idle:
            let reached = input.idleSeconds >= Double(max(1, s.minutes) * 60)
            return decision(!reached, reached ? "空闲时间已到" : "等待空闲 \(s.minutes) 分钟", idle: reached)
        }
    }
}
