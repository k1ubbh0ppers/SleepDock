import Foundation

/// Serial-use, read-only monitor. Only lifecycle metadata is retained; messages are discarded.
final class AgentMonitor {
    private final class Cursor {
        let url: URL
        var offset: UInt64 = 0
        var remainder = Data()
        var identity: String?
        var createdAt: Date?
        var active: [String: AgentTask] = [:]
        var modifiedAt = Date.distantPast
        var unknownLifecycle = false
        var recordOrdinal = 0
        var historyBoundary: Int?
        init(_ url: URL) { self.url = url }
    }
    private struct Changes {
        var normal = false
        var interruptedSources = Set<String>()
        var uncertainSources = Set<String>()
        var completedTaskIDs = Set<String>()
        var uncertain: Bool { !uncertainSources.isEmpty }
        var interrupted: Bool { !interruptedSources.isEmpty }
        mutating func interrupt(_ source: String = "codex") { interruptedSources.insert(source) }
        mutating func markUncertain(_ source: String = "codex") { uncertainSources.insert(source) }
        mutating func complete(_ id: String) { normal = true; completedTaskIDs.insert(id) }
    }
    private let root: URL
    private let leaseDirectory: URL
    private let calendarLayout: Bool
    private var cursors: [URL: Cursor] = [:]
    private var leases: [String: AgentTask] = [:]
    private var expiredLeaseIDs = Set<String>()
    private var seenTerminalLeaseIDs = Set<String>()
    private var monitoredSince: Date?
    private var lastMetadataScan: Date?
    private var batchInterrupted = false
    private let fm = FileManager.default
    private let timestampFormatter = ISO8601DateFormatter()
    private let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(root: URL? = nil, leaseDirectory: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        self.leaseDirectory = leaseDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SleepDock/tasks")
        self.calendarLayout = root == nil
    }

    func poll(now: Date = Date()) -> AgentSnapshot {
        let baseline = monitoredSince == nil
        if baseline { monitoredSince = now }
        var changes = Changes()
        let discovered = discover(now: now, changes: &changes)
        for url in discovered where cursors[url] == nil { cursors[url] = Cursor(url) }
        for cursor in Array(cursors.values) {
            read(cursor, now: now, changes: &changes)
            if cursor.active.isEmpty && now.timeIntervalSince(cursor.modifiedAt) > 86_400 {
                cursors.removeValue(forKey: cursor.url)
            }
        }
        readLeases(now: now, changes: &changes)
        var active: [String: AgentTask] = [:]
        for cursor in cursors.values {
            for (id, task) in cursor.active {
                if let old = active[id], old.startedAt > task.startedAt { continue }
                active[id] = task
            }
            if !cursor.active.isEmpty && now.timeIntervalSince(cursor.modifiedAt) > 1_800 {
                changes.markUncertain()
            }
            if cursor.unknownLifecycle { changes.markUncertain() }
        }
        for (id, task) in leases { active["lease:" + id] = task }
        let tasks = active.values.sorted {
            $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt
        }
        // Historical interruptions do not taint a running batch discovered at startup.
        if baseline { batchInterrupted = changes.uncertain }
        else if changes.interrupted || changes.uncertain { batchInterrupted = true }
        let completed = !baseline && changes.normal && tasks.isEmpty && !changes.uncertain && !batchInterrupted
        if tasks.isEmpty { batchInterrupted = false }
        let status: String
        if changes.uncertain { status = "部分任务状态未知，自动休眠已暂缓" }
        else if !tasks.isEmpty { status = "\(tasks.count) 个 Agent 任务运行中" }
        else if fm.fileExists(atPath: root.path) { status = "未检测到运行中的 Agent 任务" }
        else { status = "未找到 Codex 日志，可使用通用任务接入" }
        return AgentSnapshot(tasks: tasks, completedNormally: completed, uncertain: changes.uncertain, status: status,
                             uncertainSources: changes.uncertainSources, completedTaskIDs: baseline ? [] : changes.completedTaskIDs,
                             interruptedSources: baseline ? [] : changes.interruptedSources)
    }

    private func discover(now: Date, changes: inout Changes) -> Set<URL> {
        var result = Set<URL>()
        var directories = [root]
        let fullScan = lastMetadataScan.map { now.timeIntervalSince($0) >= 30 } ?? true
        if fullScan { lastMetadataScan = now }
        if calendarLayout && !fullScan {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/MM/dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            directories = (-1...0).map { root.appendingPathComponent(formatter.string(from: now.addingTimeInterval(Double($0) * 86_400))) }
        }
        for directory in directories {
            guard fm.fileExists(atPath: directory.path) else { continue }
            var enumerationFailed = false
            guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in
                enumerationFailed = true
                return true
            }) else { changes.markUncertain(); continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
                if let modified = values.contentModificationDate, now.timeIntervalSince(modified) <= 86_400 { result.insert(url) }
            }
            if enumerationFailed { changes.markUncertain() }
        }
        return result
    }

    private func read(_ cursor: Cursor, now: Date, changes: inout Changes) {
        do {
            let attributes = try fm.attributesOfItem(atPath: cursor.url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            cursor.modifiedAt = attributes[.modificationDate] as? Date ?? now
            if size < cursor.offset {
                if !cursor.active.isEmpty { changes.interrupt(); changes.markUncertain() }
                cursor.offset = 0; cursor.remainder.removeAll(); cursor.active.removeAll()
                cursor.identity = nil; cursor.createdAt = nil; cursor.unknownLifecycle = false
                cursor.recordOrdinal = 0; cursor.historyBoundary = nil
            }
            guard size > cursor.offset else { return }
            let handle = try FileHandle(forReadingFrom: cursor.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: cursor.offset)
            let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            cursor.offset += UInt64(chunk.count)
            cursor.remainder.append(chunk)
            var start = cursor.remainder.startIndex
            while let newline = cursor.remainder[start...].firstIndex(of: 10) {
                let line = cursor.remainder[start..<newline]
                parse(Data(line), cursor: cursor, now: now, changes: &changes)
                start = cursor.remainder.index(after: newline)
            }
            cursor.remainder = Data(cursor.remainder[start...])
            if cursor.offset < size { changes.markUncertain() }
            // A giant unfinished record is not interpreted as a finished task.
            if cursor.remainder.count > 8 * 1_024 * 1_024 { changes.markUncertain() }
        } catch {
            // Losing access is not evidence of successful completion.
            changes.markUncertain()
        }
    }

    private func parse(_ line: Data, cursor: Cursor, now: Date, changes: inout Changes) {
        defer { cursor.recordOrdinal += 1 }
        guard !line.isEmpty else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return }
        if type == "session_meta" {
            // Forked logs replay their parent's session_meta; only the first belongs to this file.
            if cursor.identity == nil {
                cursor.identity = payload["id"] as? String ?? cursor.url.lastPathComponent
                cursor.createdAt = date(payload["timestamp"])
                cursor.historyBoundary = (payload["subagent_history_start_ordinal"] as? NSNumber)?.intValue
            }
            return
        }
        if let boundary = cursor.historyBoundary, cursor.recordOrdinal < boundary { return }
        guard type == "event_msg", let event = payload["type"] as? String,
              ["task_started", "task_complete", "turn_aborted"].contains(event) else { return }
        guard let id = payload["turn_id"] as? String, !id.isEmpty else {
            cursor.unknownLifecycle = true; return
        }
        let began = date(payload["started_at"])
        // Replayed starts and synthetic aborts refer to a task that predates this file's identity.
        if let created = cursor.createdAt, let began, began.timeIntervalSince(created) < -1 { return }
        let eventDate = date(object["timestamp"]) ?? now
        switch event {
        case "task_started":
            let started = began ?? eventDate
            cursor.active[id] = AgentTask(id: id, name: "Codex 任务", startedAt: started, source: "Codex", agentID: "codex")
        case "task_complete", "turn_aborted":
            guard cursor.active.removeValue(forKey: id) != nil else { return }
            if event == "turn_aborted" {
                if eventDate >= (monitoredSince ?? now) { changes.interrupt() }
            }
            else if eventDate >= (monitoredSince ?? now) { changes.complete(id) }
        default: break
        }
    }

    private func readLeases(now: Date, changes: inout Changes) {
        guard fm.fileExists(atPath: leaseDirectory.path) else {
            if !leases.isEmpty {
                for task in leases.values {
                    changes.interrupt(task.agentID ?? "*")
                    changes.markUncertain(task.agentID ?? "*")
                }
                leases.removeAll()
            }
            return
        }
        guard let files = try? fm.contentsOfDirectory(at: leaseDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            changes.markUncertain("*"); return
        }
        var seen = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = object["id"] as? String, !id.isEmpty else {
                changes.markUncertain("*"); continue
            }
            seen.insert(id)
            let sourceID = object["agentID"] as? String ?? leases[id]?.agentID ?? "*"
            let state = object["state"] as? String ?? "running"
            let heartbeat = date(object["heartbeatAt"])
            let fresh = heartbeat.map { now.timeIntervalSince($0) >= -5 && now.timeIntervalSince($0) <= 20 } ?? false
            if state == "complete" || state == "aborted" {
                let firstTerminal = seenTerminalLeaseIDs.insert(id).inserted
                if leases.removeValue(forKey: id) != nil {
                    if state == "complete" && fresh && !expiredLeaseIDs.contains(id) { changes.complete("lease:" + id) }
                    else { changes.interrupt(sourceID) }
                } else if state == "aborted", firstTerminal, fresh,
                          let created = date(object["createdAt"]), created >= (monitoredSince ?? now) {
                    // A whole failed short command may fit between two polls.
                    changes.interrupt(sourceID)
                }
                continue
            }
            let pid = (object["pid"] as? NSNumber)?.int32Value ?? 0
            guard fresh && pid > 0 && processIsAlive(pid) else {
                let wasRunning = leases.removeValue(forKey: id) != nil
                if wasRunning { changes.interrupt(sourceID) }
                if wasRunning || !expiredLeaseIDs.contains(id) { changes.markUncertain(sourceID) }
                expiredLeaseIDs.insert(id)
                continue
            }
            expiredLeaseIDs.remove(id)
            seenTerminalLeaseIDs.remove(id)
            let name = object["name"] as? String ?? "通用 Agent 任务"
            leases[id] = AgentTask(id: "lease:" + id, name: String(name.prefix(100)), startedAt: date(object["createdAt"]) ?? now, source: "通用接入", agentID: object["agentID"] as? String)
        }
        for id in Array(leases.keys) where !seen.contains(id) {
            let task = leases.removeValue(forKey: id)
            expiredLeaseIDs.insert(id)
            changes.interrupt(task?.agentID ?? "*"); changes.markUncertain(task?.agentID ?? "*")
        }
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        let result = kill(pid, 0)
        return result == 0 || errno == EPERM
    }

    private func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let string = value as? String else { return nil }
        return fractionalFormatter.date(from: string) ?? timestampFormatter.date(from: string)
    }
}
