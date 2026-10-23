import AppKit
import SwiftUI

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

final class VerticalResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.32).setFill()
        NSBezierPath(roundedRect: NSRect(x: (bounds.width - 42) / 2, y: (bounds.height - 3) / 2,
                                       width: 42, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let initialHeight = window.frame.height
        let initialMouseY = window.convertPoint(toScreen: event.locationInWindow).y
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let mouseY = window.convertPoint(toScreen: next.locationInWindow).y
            onDrag?(initialHeight + initialMouseY - mouseY)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: SleepModel!
    private var panel: WidgetPanel!
    private var statusItem: NSStatusItem!
    private var enableItem: NSMenuItem!
    private var applyingLayout = false
    private var heightKey: String { model.settings.compact ? "SleepDockHeightCompact" : "SleepDockHeightExpanded" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "dev.phecda.SleepDock").filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).count > 0 {
            NSRunningApplication.runningApplications(withBundleIdentifier: "dev.phecda.SleepDock").first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?.activate()
            NSApp.terminate(nil); return
        }
        model = SleepModel()
        panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 728), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.title = "SleepDock"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.minSize = NSSize(width: WidgetWindowSizing.width, height: WidgetWindowSizing.minimumHeight)
        panel.maxSize = NSSize(width: WidgetWindowSizing.width, height: 1200)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.wantsLayer = true
        blur.layer?.backgroundColor = NSColor.clear.cgColor
        blur.layer?.isOpaque = false
        blur.layer?.cornerRadius = 25
        blur.layer?.masksToBounds = true
        let host = TransparentHostingView(rootView: WidgetView(model: model))
        host.wantsLayer = true
        host.layer?.isOpaque = false
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.cornerRadius = 25
        host.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor), host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor), host.bottomAnchor.constraint(equalTo: blur.bottomAnchor)
        ])
        let resizeHandle = VerticalResizeHandle()
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.toolTip = "拖动调整高度 · 宽度固定"
        resizeHandle.setAccessibilityElement(true)
        resizeHandle.setAccessibilityLabel("拖动底边调整插件高度")
        resizeHandle.onDrag = { [weak self] height in self?.resizeManually(to: height) }
        blur.addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            resizeHandle.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 16),
            resizeHandle.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -16),
            resizeHandle.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -2),
            resizeHandle.heightAnchor.constraint(equalToConstant: 14)
        ])
        panel.contentView = blur
        if let frameView = blur.superview {
            frameView.wantsLayer = true
            frameView.layer?.backgroundColor = NSColor.clear.cgColor
            frameView.layer?.isOpaque = false
            frameView.layer?.cornerRadius = 25
            frameView.layer?.masksToBounds = true
        }
        panel.setFrameAutosaveName("SleepDockWidget")
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if !panel.setFrameUsingName("SleepDockWidget") {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 414, y: max(screen.minY + 20, screen.maxY - 748)))
        }
        model.onLayoutChange = { [weak self] in self?.updateLayout() }
        model.onStatusChange = { [weak self] in
            self?.updateStatus()
        }
        model.onHide = { [weak self] in self?.panel.orderOut(nil) }
        model.onQuit = { NSApp.terminate(nil) }
        makeMenu()
        updateLayout()
        showWidget()
        if let i = CommandLine.arguments.firstIndex(of: "--window-check-out"), CommandLine.arguments.count > i + 1 {
            let destination = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.checkWindow(destination: destination) }
        }
    }

    private func checkWindow(destination: String) {
        guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let points = [(0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)]
        let alpha = points.map { bitmap.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? -1 }
        let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        var outsidePixels = 0
        var nontransparentOutsidePixels = 0
        for y in 0..<Int(ceil(25 * scaleY)) {
            for x in 0..<Int(ceil(25 * scaleX)) {
                // Leave one physical pixel for the curved edge's antialiasing.
                let dx = 25 - (CGFloat(x) + 0.5) / scaleX
                let dy = 25 - (CGFloat(y) + 0.5) / scaleY
                guard hypot(dx, dy) > 25 + 1 / min(scaleX, scaleY) else { continue }
                for (px, py) in [(x, y), (bitmap.pixelsWide - x - 1, y),
                                 (x, bitmap.pixelsHigh - y - 1), (bitmap.pixelsWide - x - 1, bitmap.pixelsHigh - y - 1)] {
                    outsidePixels += 1
                    if (bitmap.colorAt(x: px, y: py)?.alphaComponent ?? 1) > 0 { nontransparentOutsidePixels += 1 }
                }
            }
        }
        let record: [String: Any] = ["width": panel.frame.width, "height": panel.frame.height, "opaque": panel.isOpaque,
                                   "backgroundAlpha": panel.backgroundColor?.alphaComponent ?? -1, "cornerAlpha": alpha,
                                   "hasShadow": panel.hasShadow, "outsidePixels": outsidePixels,
                                   "nontransparentOutsidePixels": nontransparentOutsidePixels]
        let directory = URL(fileURLWithPath: destination, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: directory.appendingPathComponent("mac-window-alpha.png")) }
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("mac-window-alpha.json")); print(String(decoding: data, as: UTF8.self))
        }
        NSApp.terminate(nil)
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "显示桌面插件", action: #selector(showWidget), keyEquivalent: "w").target = self
        enableItem = menu.addItem(withTitle: "启用插件", action: #selector(toggleMaster), keyEquivalent: "")
        enableItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "使用说明", action: #selector(help), keyEquivalent: "").target = self
        menu.addItem(withTitle: "退出并释放保护", action: #selector(quitApp), keyEquivalent: "q").target = self
        statusItem.menu = menu
        updateStatus()
    }
    private func updateLayout() {
        guard panel != nil else { return }
        panel.level = model.settings.floatOnTop ? .floating : .normal
        let storedHeight = UserDefaults.standard.double(forKey: heightKey)
        let desiredHeight: CGFloat = storedHeight > 0 ? storedHeight : (model.settings.compact ? 240 : 728)
        applyHeight(desiredHeight)
        updateStatus()
    }
    private func applyHeight(_ height: CGFloat) {
        applyingLayout = true
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.minSize = NSSize(width: WidgetWindowSizing.width, height: min(WidgetWindowSizing.minimumHeight, WidgetWindowSizing.maximumHeight(visibleHeight: visible.height)))
        panel.maxSize = NSSize(width: WidgetWindowSizing.width, height: WidgetWindowSizing.maximumHeight(visibleHeight: visible.height))
        let frame = WidgetWindowSizing.frame(height: height, top: panel.frame.maxY, x: panel.frame.minX, visible: visible)
        panel.setFrame(frame, display: true)
        applyingLayout = false
    }
    private func resizeManually(to height: CGFloat) {
        applyHeight(height)
        UserDefaults.standard.set(panel.frame.height, forKey: heightKey)
        panel.saveFrame(usingName: "SleepDockWidget")
    }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let visibleHeight = sender.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 900
        return NSSize(width: WidgetWindowSizing.width, height: WidgetWindowSizing.height(frameSize.height, visibleHeight: visibleHeight))
    }
    func windowDidResize(_ notification: Notification) {
        guard !applyingLayout, panel != nil, model != nil else { return }
        UserDefaults.standard.set(panel.frame.height, forKey: heightKey)
    }
    func windowDidChangeScreen(_ notification: Notification) {
        guard panel != nil, model != nil else { return }
        updateLayout()
    }
    private func updateStatus() {
        guard statusItem != nil else { return }
        statusItem.button?.image = NSImage(systemSymbolName: model.protected ? "sun.max.fill" : "moon.zzz", accessibilityDescription: "SleepDock")
        statusItem.button?.toolTip = "SleepDock · \(model.statusTitle)"
        enableItem?.state = model.settings.masterEnabled ? .on : .off
    }
    @objc func showWidget() { panel?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func toggleMaster() { model.settings.masterEnabled.toggle() }
    @objc private func help() { model.openHelp() }
    @objc private func quitApp() { model.quit() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWidget(); return true }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

@main struct SleepDockMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--diagnostics") {
            let power = PowerControl.powerStatus()
            let monitor = AgentMonitor()
            var snapshot = monitor.poll()
            for _ in 0..<15 where snapshot.uncertain { snapshot = monitor.poll() }
            let native = NativeAgentMonitor().poll()
            let savedSettings = UserDefaults.standard.data(forKey: "settings")
                .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
            let result: [String: Any] = ["battery": power.battery, "pluggedIn": power.pluggedIn,
                "idleSeconds": PowerControl.idleSeconds(), "lidClosed": PowerControl.lidClosed(),
                "sleepDisabled": PowerControl.sleepDisabled(), "taskCount": snapshot.tasks.count,
                "uncertainAgents": snapshot.uncertain || native.uncertain,
                "nativeTaskCount": native.tasks.count,
                "defaultSelectedAgents": Settings().selectedAgents, "selectedAgents": savedSettings.selectedAgents,
                "masterEnabled": savedSettings.masterEnabled,
                "installedAgents": AppDiscovery().scan().map { ["id": $0.id, "installed": $0.installed, "running": $0.running] as [String: Any] }]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
            return
        }
        if args.contains("--assertion-probe") {
            let controller = PowerControl()
            if let error = controller.apply(keepAwake: true, keepDisplayAwake: true) { fputs(error + "\n", stderr); exit(1) }
            guard controller.systemAssertion != nil, controller.displayAssertion != nil else { exit(1) }
            print("ASSERTIONS_CREATED system=\(controller.systemAssertion!) display=\(controller.displayAssertion!)")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 4)
            controller.releaseAll()
            print("ASSERTIONS_RELEASED")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
