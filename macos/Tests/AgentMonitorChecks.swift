import Foundation

@main
struct AgentMonitorChecks {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func append(_ url: URL, _ object: [String: Any], newline: Bool = true) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if newline { data.append(10) }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
    }
    static func meta(_ url: URL, at date: Date, id: String = UUID().uuidString) throws {
        try append(url, ["type": "session_meta", "payload": ["id": id, "timestamp": ISO8601DateFormatter().string(from: date)]])
    }
    static func event(_ url: URL, _ type: String, _ id: String, started: Date, at date: Date, newline: Bool = true) throws {
        try append(url, ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: date), "payload": ["type": type, "turn_id": id, "started_at": started.timeIntervalSince1970]], newline: newline)
    }
    static func main() throws {
        if ProcessInfo.processInfo.arguments.contains("--live") {
            let snapshot = AgentMonitor().poll()
            print("LIVE: tasks=\(snapshot.tasks.count) uncertain=\(snapshot.uncertain) completedNormally=\(snapshot.completedNormally) status=\(snapshot.status)")
            return
        }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("SleepDock-AgentChecks-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let now = Date()
        func folders(_ name: String) throws -> (URL, URL) {
            let root = temp.appendingPathComponent(name); let leases = root.appendingPathComponent("leases")
            try fm.createDirectory(at: leases, withIntermediateDirectories: true); return (root, leases)
        }
        do {
            let (root, leases) = try folders("concurrent")
            let a = root.appendingPathComponent("a.jsonl"), b = root.appendingPathComponent("b.jsonl")
            try meta(a, at: now.addingTimeInterval(-10)); try meta(b, at: now.addingTimeInterval(-10))
            try event(a, "task_started", "a", started: now, at: now); try event(b, "task_started", "b", started: now, at: now)
            let monitor = AgentMonitor(root: root, leaseDirectory: leases)
            let initial = monitor.poll(now: now)
            expect(initial.tasks.count == 2, "detect two concurrent tasks")
            expect(initial.tasks.allSatisfy { $0.agentID == "codex" }, "Codex task carries stable agent selection id")
            expect(!initial.completedNormally, "startup never triggers sleep")
            try event(a, "task_complete", "a", started: now, at: now.addingTimeInterval(1))
            let one = monitor.poll(now: now.addingTimeInterval(1))
            expect(one.tasks.count == 1 && !one.completedNormally, "one completed task cannot finish concurrent batch")
            expect(one.completedTaskIDs == ["a"], "normal terminal provenance emitted before other tasks finish")
            try event(b, "task_complete", "b", started: now, at: now.addingTimeInterval(2))
            let finished = monitor.poll(now: now.addingTimeInterval(2))
            expect(finished.tasks.isEmpty && finished.completedNormally, "last successful completion triggers once")
            expect(finished.completedTaskIDs == ["b"], "completion IDs describe only current poll terminals")
            expect(!monitor.poll(now: now.addingTimeInterval(3)).completedNormally, "no repeated completion")
        }
        do {
            let (root, leases) = try folders("baseline")
            let file = root.appendingPathComponent("history.jsonl")
            try meta(file, at: now.addingTimeInterval(-100))
            try event(file, "task_started", "old", started: now.addingTimeInterval(-50), at: now.addingTimeInterval(-50))
            try event(file, "task_complete", "old", started: now.addingTimeInterval(-50), at: now.addingTimeInterval(-20))
            let snapshot = AgentMonitor(root: root, leaseDirectory: leases).poll(now: now)
            expect(snapshot.tasks.isEmpty && !snapshot.completedNormally, "completed startup history cannot trigger sleep")
            expect(snapshot.completedTaskIDs.isEmpty, "startup history cannot emit terminal provenance")
            expect(snapshot.interruptedSources.isEmpty, "startup cannot emit interrupted history")
        }
        do {
            let (root, leases) = try folders("aborted")
            let file = root.appendingPathComponent("a.jsonl")
            try meta(file, at: now.addingTimeInterval(-10)); try event(file, "task_started", "a", started: now, at: now)
            let monitor = AgentMonitor(root: root, leaseDirectory: leases); _ = monitor.poll(now: now)
            try event(file, "turn_aborted", "a", started: now, at: now.addingTimeInterval(1))
            let snap = monitor.poll(now: now.addingTimeInterval(1))
            expect(snap.tasks.isEmpty && !snap.completedNormally, "aborted task releases protection without normal completion")
            expect(snap.interruptedSources == ["codex"], "aborted task emits source for completion tracker and countdown cancellation")
        }
        do {
            let (root, leases) = try folders("short-abort-between-polls")
            let file = root.appendingPathComponent("a.jsonl")
            try meta(file, at: now.addingTimeInterval(-10))
            try event(file, "task_started", "a", started: now, at: now)
            let monitor = AgentMonitor(root: root, leaseDirectory: leases)
            _ = monitor.poll(now: now)
            try event(file, "task_started", "b", started: now.addingTimeInterval(1), at: now.addingTimeInterval(1))
            try event(file, "turn_aborted", "b", started: now.addingTimeInterval(1), at: now.addingTimeInterval(2))
            try event(file, "task_complete", "a", started: now, at: now.addingTimeInterval(3))
            let snap = monitor.poll(now: now.addingTimeInterval(4))
            expect(snap.tasks.isEmpty && snap.completedTaskIDs == ["a"] && snap.interruptedSources == ["codex"], "short aborted task survives an otherwise successful empty snapshot")
            expect(monitor.poll(now: now.addingTimeInterval(5)).interruptedSources.isEmpty, "interruption is delivered once instead of poisoning future batches")
        }
        do {
            let (root, leases) = try folders("inheritance")
            let parent = root.appendingPathComponent("parent.jsonl"), child = root.appendingPathComponent("child.jsonl")
            let parentStart = now.addingTimeInterval(-100)
            try meta(parent, at: now.addingTimeInterval(-200)); try event(parent, "task_started", "parent-turn", started: parentStart, at: parentStart)
            try meta(child, at: now, id: "child-session"); try meta(child, at: now.addingTimeInterval(-200), id: "parent-session")
            try event(child, "task_started", "parent-turn", started: parentStart, at: now)
            try event(child, "turn_aborted", "parent-turn", started: parentStart, at: now)
            try event(child, "task_started", "child-turn", started: now, at: now)
            let snap = AgentMonitor(root: root, leaseDirectory: leases).poll(now: now)
            expect(snap.tasks.count == 2, "inherited parent abort cannot clear live parent task")
            expect(Set(snap.tasks.map(\.id)).count == 2, "turn identifiers deduplicate")
        }
        do {
            let (root, leases) = try folders("same-second-inheritance")
            let parent = root.appendingPathComponent("parent.jsonl"), child = root.appendingPathComponent("child.jsonl")
            try meta(parent, at: now.addingTimeInterval(-10))
            try event(parent, "task_started", "parent", started: now, at: now)
            let monitor = AgentMonitor(root: root, leaseDirectory: leases)
            _ = monitor.poll(now: now)
            try append(child, ["type":"session_meta", "payload":["id":"child", "timestamp":ISO8601DateFormatter().string(from: now), "subagent_history_start_ordinal":4]])
            try meta(child, at: now.addingTimeInterval(-10), id:"parent")
            try event(child, "task_started", "parent", started: now, at: now)
            try event(child, "turn_aborted", "parent", started: now, at: now)
            try event(child, "task_started", "child", started: now, at: now)
            expect(monitor.poll(now: now.addingTimeInterval(1)).tasks.count == 2, "same-second inherited parent history is skipped by ordinal")
            try event(child, "task_complete", "child", started: now, at: now.addingTimeInterval(2))
            try event(parent, "task_complete", "parent", started: now, at: now.addingTimeInterval(2))
            expect(monitor.poll(now: now.addingTimeInterval(2)).completedNormally, "inherited synthetic abort cannot poison normal batch completion")
        }
        do {
            let (root, leases) = try folders("partial")
            let file = root.appendingPathComponent("a.jsonl")
            try meta(file, at: now.addingTimeInterval(-10)); try event(file, "task_started", "a", started: now, at: now)
            let monitor = AgentMonitor(root: root, leaseDirectory: leases); _ = monitor.poll(now: now)
            try event(file, "task_complete", "a", started: now, at: now.addingTimeInterval(1), newline: false)
            expect(monitor.poll(now: now.addingTimeInterval(1)).tasks.count == 1, "incomplete JSONL waits for newline")
            let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data([10])); try handle.close()
            expect(monitor.poll(now: now.addingTimeInterval(2)).completedNormally, "buffered complete event processed after newline")
        }
        do {
            let (root, leases) = try folders("leases")
            let file = leases.appendingPathComponent("job.json")
            let lease: [String: Any] = ["id":"job", "name":"Test Agent", "agentID":"claude", "pid":ProcessInfo.processInfo.processIdentifier, "createdAt":now.timeIntervalSince1970, "heartbeatAt":now.timeIntervalSince1970]
            try JSONSerialization.data(withJSONObject: lease).write(to: file)
            let monitor = AgentMonitor(root: root, leaseDirectory: leases)
            let leased = monitor.poll(now: now)
            expect(leased.tasks.count == 1, "fresh live lease protects task")
            expect(leased.tasks.first?.agentID == "claude", "lease agent id survives for user selection filtering")
            let expired = monitor.poll(now: now.addingTimeInterval(21))
            expect(expired.tasks.isEmpty && !expired.completedNormally && expired.uncertain, "expired lease releases without pretending success")
            expect(expired.uncertainSources == ["claude"], "lease uncertainty carries actual source instead of Codex")
            let stillExpired = monitor.poll(now: now.addingTimeInterval(21.5))
            expect(!stillExpired.uncertain && !stillExpired.completedNormally, "known expired lease cannot block protection forever")
            var complete = lease; complete["state"] = "complete"; complete["heartbeatAt"] = now.addingTimeInterval(22).timeIntervalSince1970
            try JSONSerialization.data(withJSONObject: complete).write(to: file)
            expect(!monitor.poll(now: now.addingTimeInterval(22)).completedNormally, "late terminal lease after expiration cannot trigger sleep")
            let file2 = leases.appendingPathComponent("job2.json"); var second = lease; second["id"] = "job2"; second["heartbeatAt"] = now.addingTimeInterval(23).timeIntervalSince1970
            try JSONSerialization.data(withJSONObject: second).write(to: file2)
            _ = monitor.poll(now: now.addingTimeInterval(23))
            second["state"] = "complete"; second["heartbeatAt"] = now.addingTimeInterval(24).timeIntervalSince1970
            try JSONSerialization.data(withJSONObject: second).write(to: file2)
            let normalLease = monitor.poll(now: now.addingTimeInterval(24))
            expect(normalLease.completedNormally, "live lease terminal success triggers normal completion")
            expect(normalLease.completedTaskIDs == ["lease:job2"], "lease normal terminal uses exactly the task identifier")
            let short = leases.appendingPathComponent("short-abort.json")
            let shortLease: [String: Any] = ["id":"short-abort", "state":"aborted", "agentID":"claude", "createdAt":now.addingTimeInterval(25).timeIntervalSince1970, "heartbeatAt":now.addingTimeInterval(26).timeIntervalSince1970]
            try JSONSerialization.data(withJSONObject: shortLease).write(to: short)
            expect(monitor.poll(now: now.addingTimeInterval(27)).interruptedSources == ["claude"], "a whole short failed generic command between polls still emits its selected source")
            expect(monitor.poll(now: now.addingTimeInterval(28)).interruptedSources.isEmpty, "terminal generic interruption is not replayed every poll")
        }
        do {
            let (root, leases) = try folders("old-path-current-task")
            let oldDirectory = root.appendingPathComponent("2025/01/01")
            try fm.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
            let file = oldDirectory.appendingPathComponent("resumed.jsonl")
            try meta(file, at: now.addingTimeInterval(-86_400 * 100))
            try event(file, "task_started", "resumed", started: now, at: now)
            let snapshot = AgentMonitor(root: root, leaseDirectory: leases).poll(now: now)
            expect(snapshot.tasks.count == 1, "resumed old-directory conversation discovered by modification date")
        }
        do {
            let (root, leases) = try folders("stale-unfinished")
            let file = root.appendingPathComponent("stale.jsonl")
            try meta(file, at: now.addingTimeInterval(-7_000))
            try event(file, "task_started", "stale", started: now.addingTimeInterval(-6_000), at: now.addingTimeInterval(-6_000))
            try fm.setAttributes([.modificationDate:now.addingTimeInterval(-2_000)], ofItemAtPath: file.path)
            let snapshot = AgentMonitor(root: root, leaseDirectory: leases).poll(now: now)
            expect(snapshot.tasks.count == 1 && snapshot.uncertain && !snapshot.completedNormally, "stale unfinished task remains unknown instead of becoming successful")
        }
        print("PASS: \(checks) AgentMonitor checks")
    }
}
