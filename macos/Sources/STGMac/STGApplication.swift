import AppKit
import Darwin
import SwiftUI
import STGCore

@main
@MainActor
final class STGApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var pendingStatusClick: DispatchWorkItem?
    private var windows: [String: NSWindow] = [:]
    private var reminderWindow: NSWindow?
    private var userRequestedQuit = false
    private var terminationPreparationInProgress = false
    private var terminationPrepared = false

    static func main() {
        let app = NSApplication.shared
        let delegate = STGApplication(); app.delegate = delegate
        app.setActivationPolicy(.accessory); app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Screen Time Guardian is recording screen availability")
        ProcessInfo.processInfo.disableSuddenTermination()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let appIcon = NSApp.applicationIconImage?.copy() as? NSImage {
            appIcon.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = appIcon
            statusItem.button?.imageScaling = .scaleProportionallyDown
            statusItem.button?.imagePosition = .imageLeading
        }
        statusItem.button?.title = "STG"
        let menu = NSMenu()
        add(NSLocalizedString("Main", comment: ""), #selector(showMain), to: menu)
        add(NSLocalizedString("Report", comment: ""), #selector(showReport), to: menu)
        add(NSLocalizedString("Settings", comment: ""), #selector(showSettings), to: menu)
        add(NSLocalizedString("Tracking", comment: ""), #selector(showTracking), to: menu)
        add(NSLocalizedString("About", comment: ""), #selector(showAbout), to: menu)
        menu.addItem(.separator()); add(NSLocalizedString("Quit", comment: ""), #selector(quit), to: menu)
        statusMenu = menu
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        NotificationCenter.default.addObserver(forName: .stgReminder, object: nil, queue: .main) { [weak self] note in
            if let decision = note.object as? ReminderDecision { Task { @MainActor in self?.showReminder(decision) } }
        }
        model.reconcileLaunchAtLogin(trigger: "application_launch")
        model.start()
        if !UserDefaults.standard.bool(forKey: "desktopOnboardingV1Complete") {
            show("onboarding", title: "Set Up Screen Time Guardian", root: MacOnboardingView(model: model) { [weak self] in self?.windows["onboarding"]?.close() })
        }
    }

    private func add(_ title: String, _ action: Selector, to menu: NSMenu) { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }

    @objc private func showMain() {
        guard !terminationPreparationInProgress else { return }
        show("main", title: "Screen Time Guardian", root: DashboardView(model: model) { [weak self] destination in
            switch destination {
            case .report: self?.showReport()
            case .tracking: self?.showTracking()
            case .settings: self?.showSettings()
            case .about: self?.showAbout()
            }
        })
    }
    @objc private func showReport() {
        guard !terminationPreparationInProgress else { return }
        show("report", title: "STG Report", root: ReportView(model: model) { [weak self] height in
            self?.resizeReportWindow(toContentHeight: height)
        })
    }
    @objc private func showSettings() { guard !terminationPreparationInProgress else { return }; show("settings", title: "STG Settings", root: SettingsView(model: model) { [weak self] in self?.windows["settings"]?.close() }) }
    @objc private func showAbout() { guard !terminationPreparationInProgress else { return }; show("about", title: "About STG", root: AboutView()) }
    @objc private func showTracking() { guard !terminationPreparationInProgress else { return }; show("tracking", title: "STG Tracking", root: TrackingView(model: model)) }
    @objc private func quit() {
        guard !terminationPreparationInProgress else { return }
        userRequestedQuit = true
        beginTerminationPreparation(reason: "menu_quit") {
            NSApp.terminate(nil)
        }
    }

    @objc private func statusItemClicked() {
        guard !terminationPreparationInProgress else { return }
        guard let event = NSApp.currentEvent else { return }
        if event.type == .leftMouseUp && event.clickCount >= 2 {
            pendingStatusClick?.cancel(); pendingStatusClick = nil; showMain(); return
        }
        if event.type == .rightMouseUp { showStatusMenu(); return }
        pendingStatusClick?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showStatusMenu() }
        pendingStatusClick = work; DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    private func showStatusMenu() {
        pendingStatusClick = nil
        guard !terminationPreparationInProgress else { return }
        guard let button = statusItem.button, let window = button.window else { return }
        let buttonFrameOnScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        let menuAnchor = NSPoint(x: buttonFrameOnScreen.minX, y: buttonFrameOnScreen.minY - 1)
        statusMenu.popUp(positioning: statusMenu.items.first, at: menuAnchor, in: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { showMain() }; return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPrepared { return .terminateNow }
        guard !terminationPreparationInProgress else { return .terminateLater }
        beginTerminationPreparation(reason: userRequestedQuit ? "menu_quit" : "application_termination") {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func beginTerminationPreparation(reason: String, completion: @escaping @MainActor () -> Void) {
        guard !terminationPreparationInProgress else { return }
        terminationPreparationInProgress = true
        pendingStatusClick?.cancel(); pendingStatusClick = nil
        model.diagnosticLog.record("quit action accepted; reason=\(reason); preparing_before_appkit_termination=true; process_fallback=5s", category: "lifecycle")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { Darwin._exit(EXIT_SUCCESS) }
        Task { @MainActor in
            await model.prepareForTermination(reason: reason)
            terminationPrepared = true
            ProcessInfo.processInfo.enableAutomaticTermination("Screen Time Guardian quit preparation completed")
            ProcessInfo.processInfo.enableSuddenTermination()
            model.diagnosticLog.record("quit preparation finished; requesting terminateNow=true", category: "lifecycle")
            completion()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop(reason: userRequestedQuit ? "menu_quit" : "application_will_terminate")
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.returnToMenuBarIfNoVisibleWindows() }
    }

    private func show<V: View>(_ key: String, title: String, root: V) {
        guard !terminationPreparationInProgress else { return }
        let requestedSize: NSSize = key == "report" ? .init(width: 1_180, height: 580) : key == "tracking" ? .init(width: 1_120, height: 720) : key == "settings" ? .init(width: 860, height: 700) : .init(width: 720, height: 500)
        let isNewWindow = windows[key] == nil
        let window = windows[key] ?? NSWindow(contentRect: NSRect(origin: .zero, size: requestedSize), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.contentView = NSHostingView(rootView: root); window.isReleasedWhenClosed = false; window.delegate = self
        if isNewWindow {
            if let visible = NSScreen.main?.visibleFrame {
                window.setContentSize(.init(width: min(requestedSize.width, visible.width - 32), height: min(requestedSize.height, visible.height - 32)))
            }
            window.center()
        }
        windows[key] = window
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }

    private func resizeReportWindow(toContentHeight requestedHeight: CGFloat) {
        guard let window = windows["report"], !window.styleMask.contains(.fullScreen), !window.isZoomed else { return }
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maximumContentHeight = max(500, (visibleFrame?.height ?? 760) - 32 - (window.frame.height - (window.contentView?.bounds.height ?? 0)))
        let contentHeight = min(maximumContentHeight, max(500, requestedHeight))
        guard let contentView = window.contentView, abs(contentView.bounds.height - contentHeight) > 8 else { return }

        let contentRect = NSRect(x: 0, y: 0, width: contentView.bounds.width, height: contentHeight)
        let newFrameSize = window.frameRect(forContentRect: contentRect).size
        var newFrame = window.frame
        let currentTop = newFrame.maxY
        newFrame.size.height = newFrameSize.height
        newFrame.origin.y = currentTop - newFrameSize.height
        if let visibleFrame, newFrame.minY < visibleFrame.minY + 16 {
            newFrame.origin.y = visibleFrame.minY + 16
        }
        window.setFrame(newFrame, display: true, animate: true)
    }

    private func returnToMenuBarIfNoVisibleWindows() {
        let hasVisibleWindow = windows.values.contains { $0.isVisible || $0.isMiniaturized }
        guard !hasVisibleWindow, NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func showReminder(_ originalDecision: ReminderDecision) {
        var decision = originalDecision
        let detection = MeetingDetector.detect()
        if model.settings.meetingMode || detection.isInMeeting { decision.silent = true }
        model.diagnosticLog.record("meeting check; manual=\(model.settings.meetingMode); detected=\(detection.isInMeeting); reason=\(detection.reason); reminder_close=\(decision.silent ? "immediate" : "countdown")", category: "meeting")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.level = .floating; window.center(); window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReminderView(decision: decision) { [weak window] in window?.close() })
        reminderWindow?.close(); reminderWindow = window; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
}
