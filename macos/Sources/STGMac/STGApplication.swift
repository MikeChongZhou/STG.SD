import AppKit
import SwiftUI
import STGCore

@main
@MainActor
final class STGApplication: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var windows: [String: NSWindow] = [:]
    private var reminderWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = STGApplication(); app.delegate = delegate
        app.setActivationPolicy(.accessory); app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🛡 STG"
        let menu = NSMenu()
        add("Main", #selector(showMain), to: menu)
        add("Report", #selector(showReport), to: menu)
        add("Settings", #selector(showSettings), to: menu)
        add("Tracking", #selector(showTracking), to: menu)
        add("About", #selector(showAbout), to: menu)
        add("Export Test Log…", #selector(exportTestLog), to: menu)
        menu.addItem(.separator()); add("Quit", #selector(quit), to: menu)
        statusItem.menu = menu
        NotificationCenter.default.addObserver(forName: .stgReminder, object: nil, queue: .main) { [weak self] note in
            if let decision = note.object as? ReminderDecision { Task { @MainActor in self?.showReminder(decision) } }
        }
        model.start(); showMain()
    }

    private func add(_ title: String, _ action: Selector, to menu: NSMenu) { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }

    @objc private func showMain() {
        show("main", title: "Screen Time Guardian", root: DashboardView(model: model) { [weak self] destination in
            switch destination {
            case .report: self?.showReport()
            case .tracking: self?.showTracking()
            case .settings: self?.showSettings()
            case .about: self?.showAbout()
            }
        })
    }
    @objc private func showReport() { show("report", title: "STG Report", root: ReportView(model: model)) }
    @objc private func showSettings() { show("settings", title: "STG Settings", root: SettingsView(model: model) { [weak self] in self?.windows["settings"]?.close() }) }
    @objc private func showAbout() { show("about", title: "About STG", root: AboutView { [weak self] in self?.model.exportTestLog() }) }
    @objc private func showTracking() { show("tracking", title: "STG Tracking", root: TrackingView(model: model)) }
    @objc private func exportTestLog() { model.exportTestLog() }
    @objc private func quit() { model.stop(); NSApp.terminate(nil) }

    private func show<V: View>(_ key: String, title: String, root: V) {
        let window = windows[key] ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.contentView = NSHostingView(rootView: root); window.center(); window.isReleasedWhenClosed = false
        windows[key] = window; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
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
