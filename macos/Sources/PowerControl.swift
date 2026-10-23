import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Darwin

final class PowerControl {
    var systemAssertion: UInt32?
    var displayAssertion: UInt32?

    deinit { releaseAll() }

    /// Power assertions are renewable leases. If the app stops ticking, macOS expires them.
    func apply(keepAwake: Bool, keepDisplayAwake: Bool) -> String? {
        let systemError = updateAssertion(&systemAssertion, wanted: keepAwake,
            type: kIOPMAssertPreventUserIdleSystemSleep as CFString, name: "SleepDock · 任务和休眠保护")
        let displayError = updateAssertion(&displayAssertion, wanted: keepDisplayAwake,
            type: kIOPMAssertPreventUserIdleDisplaySleep as CFString, name: "SleepDock · 保持屏幕常亮")
        return systemError ?? displayError
    }

    private func updateAssertion(_ assertion: inout UInt32?, wanted: Bool, type: CFString, name: String) -> String? {
        guard wanted else {
            if let existing = assertion { IOPMAssertionRelease(existing); assertion = nil }
            return nil
        }
        if let existing = assertion {
            // A timed-out lease retains its ID at level zero; re-arm both its timeout and level.
            let timeoutResult = IOPMAssertionSetProperty(existing, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: 30))
            let levelResult = IOPMAssertionSetProperty(existing, kIOPMAssertionLevelKey as CFString, NSNumber(value: kIOPMAssertionLevelOn))
            if timeoutResult == kIOReturnSuccess && levelResult == kIOReturnSuccess { return nil }
            IOPMAssertionRelease(existing)
            assertion = nil
        }
        var created: IOPMAssertionID = 0
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: type,
            kIOPMAssertionNameKey: name,
            kIOPMAssertionLevelKey: NSNumber(value: kIOPMAssertionLevelOn),
            kIOPMAssertionTimeoutKey: NSNumber(value: 30),
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionTurnOff
        ]
        let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &created)
        guard result == kIOReturnSuccess else { return "休眠保护申请失败（\(result)）" }
        assertion = created
        return nil
    }

    func releaseAll() {
        if let id = systemAssertion { IOPMAssertionRelease(id); systemAssertion = nil }
        if let id = displayAssertion { IOPMAssertionRelease(id); displayAssertion = nil }
    }

    static func powerStatus() -> (battery: Int, pluggedIn: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (-1, true)
        }
        var capacity = -1
        var pluggedIn = true
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                capacity = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
            }
            pluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            break
        }
        return (capacity, pluggedIn)
    }

    static func lidClosed() -> Bool {
        rootDomainBool("AppleClamshellState") ?? false
    }

    private static func rootDomainBool(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    }

    static func sleepDisabled() -> Bool {
        // Unknown is conservative: callers must not mistake a failed read for
        // restoration and immediately request automatic sleep.
        sleepDisabledState() ?? true
    }

    static func sleepDisabledState() -> Bool? {
        let result = command("/usr/bin/pmset", ["-g"])
        if result.status == 0 {
            for line in result.output.split(separator: "\n") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                guard parts.count >= 2, parts[0] == "SleepDisabled" else { continue }
                if parts[1] == "1" { return true }
                if parts[1] == "0" { return false }
            }
        }
        return rootDomainBool("SleepDisabled")
    }

    /// Public IOKit API permits the console user to request system sleep.
    static func sleepSystem() -> String? {
        let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard connection != 0 else { return "无法连接系统电源管理服务" }
        defer { IOServiceClose(connection) }
        let result = IOPMSleepSystem(connection)
        return result == kIOReturnSuccess ? nil : "系统未接受休眠请求（\(result)）"
    }

    static func turnOffDisplay() -> String? {
        let result = command("/usr/bin/pmset", ["displaysleepnow"])
        return result.status == 0 ? nil : "熄屏失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// This private symbol is resolved at runtime; absence is an explicit error, never silent success.
    static func lockScreen() -> String? {
        guard let library = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY) else {
            return "当前系统没有可用的锁屏接口；请按 Control–Command–Q"
        }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "SACLockScreenImmediate") else {
            return "当前系统不支持此锁屏接口；请按 Control–Command–Q"
        }
        typealias LockFunction = @convention(c) () -> Void
        unsafeBitCast(symbol, to: LockFunction.self)()
        return nil
    }

    fileprivate static func command(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch { return (-1, error.localizedDescription) }
    }
}

final class LidController {
    private static let stateFile = "/Library/Application Support/com.phecda.SleepDock/LidGuard/state"
    // Keep this digest synchronized with the reviewed bundled script. Snapshot
    // its verified bytes before authorization, so no mutable path runs as root.
    private static let watchdogSHA256 = "faa76f848c3efd2569eb6547e17fd3898e9246898c5476ff5de49ee7c766da53"
    private var token = UUID().uuidString
    private var requested = false
    private(set) var busy = false
    private var lastDetail = "合盖行为跟随系统；外接显示器时系统可能保持运行"
    private var leaseURL: URL {
        URL(fileURLWithPath: "/tmp/com.phecda.SleepDock-lid-\(getuid())-\(token).lease")
    }

    init() {}
    deinit { disable() }

    var active: Bool {
        guard requested, !busy, leaseFresh else { return false }
        let state = readState()
        return state["token"] == token && state["status"] == "active" && guardAlive(state)
            && PowerControl.sleepDisabledState() == true
    }

    var detail: String {
        if busy { return "等待管理员授权与系统确认" }
        let state = readState()
        if requested && state["token"] == token && state["status"] == "active" {
            guard guardAlive(state) else { return "合盖守护已退出；请重新启用，以恢复遗留的系统设置" }
            guard leaseFresh else { return "合盖心跳已过期，等待守护恢复原系统策略" }
            guard PowerControl.sleepDisabledState() == true else { return "未确认系统合盖设置，请重新启用" }
            return "合盖保持运行 · 屏幕可熄灭；关闭后约 2–15 秒恢复"
        }
        if !requested && state["token"] == token && state["status"] == "active" {
            guard guardAlive(state) else { return "合盖守护已退出；请重新启用，以恢复遗留的系统设置" }
            return "已停止合盖保护，正在恢复原系统策略（约 2–15 秒）"
        }
        if requested && state["token"] == token && state["status"] == "restored" {
            return "合盖保护已因心跳失联自动恢复；需要重新启用"
        }
        if state["token"] == token && state["status"] == "error" {
            return "系统恢复失败；恢复记录保存在 /Library/Application Support/com.phecda.SleepDock/LidGuard"
        }
        return lastDetail
    }

    func enable(completion: @escaping (String?) -> Void) {
        guard !busy else { completion("合盖设置正在处理中"); return }
        if active { completion(nil); return }
        guard let script = Bundle.main.url(forResource: "lid-watchdog", withExtension: "sh"),
              let scriptData = try? Data(contentsOf: script), scriptData.count <= 65_536,
              SHA256.hash(data: scriptData).map({ String(format: "%02x", $0) }).joined() == Self.watchdogSHA256,
              let scriptSource = String(data: scriptData, encoding: .utf8) else {
            completion("合盖守护资源缺失或校验失败，未更改系统设置"); return
        }
        let alert = NSAlert()
        alert.messageText = "启用合盖保持运行？"
        alert.informativeText = "此功能需要管理员授权，会临时关闭系统整体休眠限制，不只影响合盖。建议接通电源、保持散热，不要放入包中。\n\n关闭功能、退出插件或失去心跳后，守护程序会在约 2–15 秒内恢复原值。若管理员守护被强制终止，恢复记录仍保留，下次启用时先恢复；本插件不会更改其他电源设置。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "授权启用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { completion("已取消启用合盖保持运行"); return }
        // A fresh lease separates this attempt from a still-exiting old guard.
        removeLease()
        token = UUID().uuidString
        let requestToken = token
        requested = true
        busy = true
        heartbeat()
        guard requested else {
            busy = false
            completion("合盖心跳写入失败，未更改系统设置"); return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let uid = getuid()
        let command = "/bin/bash -c \(shellQuote(scriptSource)) sleepdock \(pid) \(uid) \(shellQuote(requestToken)) >/dev/null 2>&1 &"
        let appleScript = "do shell script \(appleScriptQuote(command)) with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PowerControl.command("/usr/bin/osascript", ["-e", appleScript])
            guard let self else { return }
            if result.status != 0 {
                DispatchQueue.main.async {
                    guard self.token == requestToken else { return }
                    self.busy = false; self.requested = false; self.removeLease()
                    self.lastDetail = "合盖保持运行未启用"
                    let cancelled = result.output.contains("-128")
                    completion(cancelled ? "管理员授权已取消，未启用合盖保持运行" : "管理员授权失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                return
            }
            // The privileged process returns asynchronously. Do not report success before read-back.
            var confirmed = false
            for _ in 0..<80 {
                let state = self.readState()
                if state["token"] == requestToken && state["status"] == "active" && self.guardAlive(state)
                    && PowerControl.sleepDisabledState() == true {
                    confirmed = true; break
                }
                if state["token"] == requestToken && ["restored", "error"].contains(state["status"] ?? "") { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            let didConfirm = confirmed
            DispatchQueue.main.async {
                guard self.token == requestToken else { return }
                self.busy = false
                if didConfirm && self.requested {
                    self.lastDetail = "合盖保持运行已启用"
                    completion(nil)
                } else {
                    self.requested = false; self.removeLease()
                    self.lastDetail = "未确认合盖保护生效；已停止续租"
                    completion("未确认合盖保护生效，已停止续租；守护程序将恢复原系统设置")
                }
            }
        }
    }

    func disable() {
        requested = false
        removeLease()
        lastDetail = "合盖保护已关闭；合盖行为跟随系统"
    }

    func heartbeat() {
        guard requested else { return }
        // Existing user-owned lease only: privileged helper never executes or sources its content.
        do {
            let data = Data(token.utf8)
            try data.write(to: leaseURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: leaseURL.path)
        } catch {
            requested = false
            lastDetail = "合盖心跳写入失败，已停止保护"
        }
    }

    private var leaseFresh: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: leaseURL.path),
              let modified = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) <= 12
    }

    private func removeLease() { try? FileManager.default.removeItem(at: leaseURL) }

    private func readState() -> [String: String] {
        guard let contents = try? String(contentsOfFile: Self.stateFile, encoding: .utf8) else { return [:] }
        return contents.split(separator: "\n").reduce(into: [:]) { result, line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
    }

    private func guardAlive(_ state: [String: String]) -> Bool {
        guard let rawPID = state["guard_pid"], let pid = Int32(rawPID), pid > 1,
              let expectedStart = state["guard_start"], !expectedStart.isEmpty else { return false }
        let result = PowerControl.command("/bin/ps", ["-p", String(pid), "-o", "lstart="])
        return result.status == 0 && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == expectedStart
    }

    private func shellQuote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func appleScriptQuote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
