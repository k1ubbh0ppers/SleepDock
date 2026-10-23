import AppKit
import Foundation
import SQLite3
import Darwin

/// Reads runtime metadata only. Cindy's session `status=active` means unarchived,
/// not that a turn is running, and `last_turn_ended_at` does not distinguish aborts.
/// Therefore this adapter never manufactures a normal-completion event.
final class NativeAgentMonitor {
    private let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cindy", isDirectory: true)
    var supportedIDs: Set<String> { FileManager.default.fileExists(atPath: directory.path) ? ["cindy"] : [] }

    func poll(now: Date = Date()) -> AgentSnapshot {
        guard supportedIDs.contains("cindy") else {
            return AgentSnapshot(status: "其他 Agent 使用运行状态保护")
        }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.xd.cindycn")
        guard !applications.isEmpty else {
            // Application exit is not evidence of successful task completion.
            return AgentSnapshot(status: "Cindy 未运行")
        }
        let appLaunch = applications.compactMap(\.launchDate).min()
        var tasks: [AgentTask] = []
        var uncertain = false
        let databases: [URL]
        do {
            databases = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("cindy-") && $0.pathExtension == "db" }
        } catch {
            return unknown("Cindy 任务库无法读取，保留休眠保护")
        }
        guard !databases.isEmpty else { return unknown("Cindy 任务库尚未找到，保留休眠保护") }

        for url in databases {
            var connection: OpaquePointer?
            let opened = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
            guard opened == SQLITE_OK, let database = connection else {
                if let connection { sqlite3_close(connection) }
                uncertain = true
                continue
            }
            sqlite3_busy_timeout(database, 150)
            let query = """
                SELECT id, status, active_turn_started_at, active_turn_pid, last_turn_ended_at
                FROM sessions
                WHERE status NOT IN ('archived', 'deleted')
                  AND (active_turn_started_at IS NOT NULL OR active_turn_pid IS NOT NULL)
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
                sqlite3_close(database)
                uncertain = true
                continue
            }
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                let id = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "unknown"
                let startMS = sqlite3_column_int64(statement, 2)
                let pid = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Int32(exactly: sqlite3_column_int64(statement, 3))
                let endMS = sqlite3_column_int64(statement, 4)
                if startMS > 0 && endMS < startMS {
                    let startedAt = Date(timeIntervalSince1970: Double(startMS) / 1000)
                    let pidAlive = pid.map { $0 > 1 && (kill($0, 0) == 0 || errno == EPERM) } ?? false
                    // A previous process may leave a turn marker behind. Without a live PID,
                    // never interpret a marker older than the current application as a task.
                    let belongsToCurrentLaunch = appLaunch.map { startedAt >= $0.addingTimeInterval(-2) } ?? false
                    if pidAlive || belongsToCurrentLaunch {
                        tasks.append(AgentTask(id: "cindy:\(url.lastPathComponent):\(id)",
                            name: "Cindy · 任务执行中", startedAt: min(startedAt, now),
                            source: "本机任务元数据", agentID: "cindy"))
                    } else if appLaunch == nil {
                        uncertain = true
                    }
                }
                step = sqlite3_step(statement)
            }
            if step != SQLITE_DONE { uncertain = true }
            sqlite3_finalize(statement)
            sqlite3_close(database)
        }
        return AgentSnapshot(tasks: tasks, completedNormally: false, uncertain: uncertain,
            status: uncertain ? "Cindy 部分任务元数据不可读，自动休眠暂缓" : "Cindy 任务元数据已连接（不推断正常完成）",
            uncertainSources: uncertain ? ["cindy"] : [])
    }

    private func unknown(_ status: String) -> AgentSnapshot {
        AgentSnapshot(tasks: [], completedNormally: false, uncertain: true, status: status, uncertainSources: ["cindy"])
    }
}
