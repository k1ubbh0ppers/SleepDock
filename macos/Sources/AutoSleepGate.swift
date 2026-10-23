import Foundation

/// Only a confirmed completion may arm this gate. Missing logs never imply completion.
final class AutoSleepGate {
    private(set) var deadline: Date?
    private(set) var reason: CountdownReason?
    private var armedAt: Date?

    func arm(_ reason: CountdownReason, now: Date, delay: TimeInterval = 60) {
        self.reason = reason
        armedAt = now
        deadline = now.addingTimeInterval(delay)
    }

    func cancel() { deadline = nil; reason = nil; armedAt = nil }

    func tick(now: Date, enabled: Bool, taskCount: Int, uncertain: Bool, idleSeconds: Double) -> Bool {
        guard let deadline, let armedAt, let reason else { return false }
        guard enabled, taskCount == 0, !uncertain else { cancel(); return false }
        // A new keyboard/mouse event cancels task-completion sleep. An explicit timer remains explicit.
        if reason == .agents && idleSeconds < now.timeIntervalSince(armedAt) - 1 {
            cancel(); return false
        }
        return now >= deadline
    }

    func remaining(now: Date) -> Int? {
        deadline.map { max(0, Int(ceil($0.timeIntervalSince(now)))) }
    }
}
