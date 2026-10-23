import AppKit

final class AppDiscovery {
    struct Candidate {
        var id: String
        var name: String
        var bundles: [String]
        var paths: [String]
    }
    private var custom: [Candidate] = []
    private let defaults = UserDefaults.standard
    private let known: [Candidate] = [
        Candidate(id: "deepseek", name: "DeepSeek Harness", bundles: ["com.deepseek.dsh"], paths: ["/Applications/DeepSeek Harness.app"]),
        Candidate(id: "codex", name: "Codex", bundles: ["com.openai.codex", "com.openai.chat"], paths: ["/Applications/Codex.app", "/Applications/ChatGPT.app"]),
        Candidate(id: "workbuddy", name: "WorkBuddy", bundles: ["com.tencent.workbuddy.mac", "com.workbuddy.workbuddy"], paths: ["/Applications/WorkBuddy.app"]),
        Candidate(id: "muse", name: "Muse", bundles: ["com.meta.endo"], paths: ["/Applications/Muse.app"]),
        Candidate(id: "claude", name: "Claude Code", bundles: ["com.anthropic.claudefordesktop"], paths: ["/Applications/Claude.app"]),
        Candidate(id: "cindy", name: "Cindy", bundles: ["com.xd.cindycn"], paths: ["/Applications/Cindy.app"])
    ]
    init() {
        let paths = defaults.stringArray(forKey: "customAgentApps") ?? []
        for path in paths { if let value = candidate(URL(fileURLWithPath: path)) { custom.append(value) } }
    }
    func scan() -> [InstalledAgent] {
        let running = NSWorkspace.shared.runningApplications
        return (known + custom).map { app in
            var installed = app.paths.contains { FileManager.default.fileExists(atPath: $0) }
            installed = installed || app.bundles.contains { identifier in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            }
            var active = running.contains { process in
                app.bundles.contains(process.bundleIdentifier ?? "") || app.paths.contains(process.bundleURL?.path ?? "")
            }
            if app.id == "claude" {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let locations = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
                installed = installed || locations.contains { FileManager.default.isExecutableFile(atPath: $0) }
                active = active || Self.claudeCLIIsRunning()
            }
            return InstalledAgent(id: app.id, name: app.name, installed: installed, running: active,
                                  detection: app.id == "codex" ? "任务事件 · 自动检测" : "运行状态保护 · 通用命令可接入任务")
        }
    }
    func add(_ url: URL) -> String? {
        guard let app = candidate(url) else { return nil }
        if let existing = (known + custom).first(where: { !$0.bundles.filter(app.bundles.contains).isEmpty }) { return existing.id }
        custom.append(app)
        defaults.set(custom.flatMap(\.paths), forKey: "customAgentApps")
        return app.id
    }
    private func candidate(_ url: URL) -> Candidate? {
        guard url.pathExtension == "app", let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
        return Candidate(id: identifier, name: name, bundles: [identifier], paths: [url.path])
    }
    private static func claudeCLIIsRunning() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "comm="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n").contains { URL(fileURLWithPath: String($0)).lastPathComponent == "claude" }
    }
}
