import FamilyControls
import Charts
import STGCore
import SwiftUI
import UserNotifications

struct RootView: View {
    @StateObject var model: AppModel
    @StateObject private var activity = DeviceActivityController()
    @State private var showOnboarding = !SharedEnvironment.defaults.bool(forKey: "permission_onboarding_v1_complete")
    var body: some View {
        TabView {
            NavigationStack { TodayView(model: model) }.tabItem { Label("Today", systemImage: "shield.fill") }
            NavigationStack { ReportView(model: model) }.tabItem { Label("Report", systemImage: "chart.bar") }
            NavigationStack { TrackingView(model: model) }.tabItem { Label("Tracking", systemImage: "waveform.path.ecg") }
            NavigationStack { SettingsView(model: model, activity: activity) }.tabItem { Label("Settings", systemImage: "gear") }
            NavigationStack { AboutView() }.tabItem { Label("About", systemImage: "info.circle") }
        }.task { await model.refresh(); await model.sync() }
            .fullScreenCover(isPresented: $showOnboarding) {
                PermissionOnboardingView(model: model, activity: activity) {
                    SharedEnvironment.defaults.set(true, forKey: "permission_onboarding_v1_complete")
                    SharedEnvironment.defaults.synchronize()
                    SharedEnvironment.diagnosticLog.record("permission onboarding completed", category: "permissions")
                    showOnboarding = false
                }
            }
    }
}

private struct PermissionOnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var activity: DeviceActivityController
    @Environment(\.scenePhase) private var scenePhase
    let finish: () -> Void
    @State private var step = 0
    @State private var notificationStatus = "Checking…"
    @State private var persistentStatus = "Checking…"
    @State private var soundStatus = "Checking…"
    @State private var notificationAuthorized = false
    @State private var notificationReady = false
    @State private var showActivityPicker = false
    @State private var showCloudSetup = false
    @State private var cloudSetupVisited = false
    @State private var showNotificationWarning = false
    @State private var notificationWarning = ""
    @State private var showCategoryWarning = false
    @State private var showSelectionWarning = false
    @State private var selectionWarning = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ProgressView(value: Double(step + 1), total: 5)
                    if step == 0 {
                        Label("Allow notifications", systemImage: "bell.badge.fill").font(.largeTitle.bold())
                        Text("Screen Time Guardian uses notifications for eye, posture, and daily-plan reminders.").font(.title3).foregroundStyle(.secondary)
                        permissionRow("Notifications", notificationStatus)
                        permissionRow("Sounds", soundStatus)
                        Button("Allow notifications") { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]); await refreshNotificationStatus() } }.buttonStyle(.borderedProminent)
                    } else if step == 1 {
                        Label("Keep reminders visible", systemImage: "rectangle.stack.badge.person.crop.fill").font(.largeTitle.bold())
                        permissionRow("Persistent presentation", persistentStatus)
                        Text("Open Notification Settings and set Screen Time Guardian’s Banner Style to Persistent. Return here when finished; this page refreshes automatically.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Open Notification Settings") { openNotificationSettings() }.buttonStyle(.borderedProminent)
                    } else if step == 2 {
                        Label("Authorize Screen Time", systemImage: "hourglass.badge.plus").font(.largeTitle.bold())
                        permissionRow("Family Controls", String(describing: activity.authorization))
                        Text("This permission lets the system measure the apps and websites you choose without revealing their identities to Screen Time Guardian.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Authorize Screen Time") { Task { await activity.requestAuthorization() } }.buttonStyle(.borderedProminent)
                        Text(activity.status).foregroundStyle(.secondary)
                    } else if step == 3 {
                        Label("Choose apps to record", systemImage: "apps.iphone").font(.largeTitle.bold())
                        Button("Choose apps and websites") { showActivityPicker = true }
                        Text("Selected: \(activity.selection.applicationTokens.count) apps, \(activity.selection.categoryTokens.count) categories, \(activity.selection.webDomainTokens.count) websites").foregroundStyle(.secondary)
                        Text("Expand categories or use search to choose individual apps. Do not select an entire category; category monitoring can make the time estimate inaccurate. Websites may also be selected.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("Private cloud", systemImage: "icloud.and.arrow.up.fill").font(.largeTitle.bold())
                        Text("Would you like to configure your private cloud now? It lets Screen Time Guardian combine screen-use records from all your devices. Your data stays in the cloud account you authorize.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        LabeledContent("Current provider", value: syncProviderName(model.settings.syncProvider ?? .none))
                        Button("Set up private cloud now") { cloudSetupVisited = true; showCloudSetup = true }.buttonStyle(.borderedProminent)
                        Button("Not now — use this device only") {
                            model.selectSyncProvider(.none)
                            finish()
                        }
                        if model.privateCloudSetupComplete {
                            Label("Account connected and initial sync completed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            Button("Finish setup") { model.save(); finish() }.buttonStyle(.borderedProminent)
                        } else if cloudSetupVisited || (model.settings.syncProvider ?? .none) != .none {
                            Text("Finish becomes available after account connection and one successful incremental sync.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 24)
                    HStack {
                        if step > 0 { Button("Back") { step -= 1 } }
                        Spacer()
                        if step < 4 { Button("Continue", action: continueFromCurrentStep).buttonStyle(.borderedProminent) }
                    }
                }.padding(28)
            }.navigationTitle("Setup · Step \(step + 1) of 5")
        }
        .interactiveDismissDisabled()
        .task { await refreshNotificationStatus() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refreshNotificationStatus() } } }
        .onChange(of: showActivityPicker) { _, presented in
            if !presented && !activity.selection.categoryTokens.isEmpty { showCategoryWarning = true }
        }
        .familyActivityPicker(headerText: "Expand a category or use search, then select individual apps", footerText: "Do not select an entire category. Individual apps and websites are allowed.", isPresented: $showActivityPicker, selection: $activity.selection)
        .sheet(isPresented: $showCloudSetup) { IOSCloudSetupView(model: model, requiresVerifiedConnection: true) }
        .alert("Notification setup required", isPresented: $showNotificationWarning) {
            Button("Open Notification Settings") { openNotificationSettings() }
            Button("Cancel", role: .cancel) { }
        } message: { Text(notificationWarning) }
        .alert("Categories are not supported", isPresented: $showCategoryWarning) {
            Button("Return to selection") { DispatchQueue.main.async { showActivityPicker = true } }
        } message: { Text("Remove every selected category. Select individual apps instead; websites may remain selected.") }
        .alert("Screen Time setup required", isPresented: $showSelectionWarning) {
            Button("OK", role: .cancel) { }
        } message: { Text(selectionWarning) }
    }

    private func permissionRow(_ title: String, _ value: String) -> some View { HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }.padding().background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)) }
    private func continueFromCurrentStep() {
        switch step {
        case 0:
            Task {
                await refreshNotificationStatus()
                if notificationAuthorized { step = 1 }
                else {
                    notificationWarning = "Allow Screen Time Guardian notifications before continuing."
                    showNotificationWarning = true
                }
            }
        case 1:
            Task {
                await refreshNotificationStatus()
                if notificationReady { step = 2 }
                else {
                    notificationWarning = "Set Screen Time Guardian’s notification presentation or Banner Style to Persistent, then return to the app."
                    showNotificationWarning = true
                }
            }
        case 2:
            guard activity.authorization == .approved else {
                selectionWarning = "Authorize Family Controls before continuing."
                showSelectionWarning = true
                return
            }
            step = 3
        case 3:
            guard activity.selection.categoryTokens.isEmpty else {
                showCategoryWarning = true
                return
            }
            guard !activity.selection.applicationTokens.isEmpty || !activity.selection.webDomainTokens.isEmpty else {
                selectionWarning = "Select at least one individual app or website before continuing."
                showSelectionWarning = true
                return
            }
            guard activity.startMonitoring() else {
                selectionWarning = activity.status
                showSelectionWarning = true
                return
            }
            step = 4
        default:
            break
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authorized = switch settings.authorizationStatus { case .authorized, .provisional, .ephemeral: true; case .denied, .notDetermined: false; @unknown default: false }
        notificationAuthorized = authorized && settings.alertSetting == .enabled
        notificationStatus = switch settings.authorizationStatus { case .authorized, .provisional, .ephemeral: "Enabled"; case .denied: "Denied"; case .notDetermined: "Not requested"; @unknown default: "Unknown" }
        soundStatus = settings.soundSetting == .enabled ? "Enabled" : "Not enabled"
        persistentStatus = settings.alertStyle == .alert ? "Alert/Persistent enabled" : settings.alertStyle == .banner ? "Banner/Temporary — review Settings" : "No alert presentation"
        notificationReady = authorized && settings.alertSetting == .enabled && settings.alertStyle == .alert
        SharedEnvironment.diagnosticLog.record("notification permission status; authorization=\(settings.authorizationStatus.rawValue); sound=\(settings.soundSetting.rawValue); alert=\(settings.alertSetting.rawValue); alert_style=\(settings.alertStyle.rawValue); persistent_style=\(settings.alertStyle == .alert)", category: "permissions")
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

struct TodayView: View {
    @ObservedObject var model: AppModel
    var body: some View { ScrollView { VStack(spacing: 16) { Image(systemName: "shield.lefthalf.filled").font(.system(size: 58)).foregroundStyle(.blue); Text("Screen Time Guardian").font(.largeTitle.bold()); metric("All devices", model.allMinutes); metric("This iPhone/iPad", model.localMinutes); metric("Daily plan", model.settings.dailyPlanMinutes); Text("The iOS value is reconstructed from DeviceActivity 20-minute threshold events stored in STG's bitmap; Apple does not expose the Screen Time total directly to this app, so it can differ from Settings → Screen Time.").font(.footnote).foregroundStyle(.secondary); Button("Sync now") { Task { await model.sync() } }.buttonStyle(.borderedProminent); Text(model.syncStatus).font(.caption) }.padding() }.navigationTitle("Today") }
    private func metric(_ name: String, _ minutes: Int) -> some View { HStack { Text(name); Spacer(); Text(duration(minutes)).bold().monospacedDigit() }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14)) }
}

struct ReportView: View {
    @ObservedObject var model: AppModel
    @State private var mode = 0
    @State private var selectedDate = Date()
    @State private var rangeStart = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var rangeEnd = Date()
    @State private var dailyBitmaps: [DeviceDayBitmap] = []
    @State private var multiDayPoints: [DailyUsagePoint] = []
    @State private var loading = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Report type", selection: $mode) { Text("Daily").tag(0); Text("Multiple days").tag(1) }.pickerStyle(.segmented)
                if mode == 0 {
                    DatePicker("Report date", selection: $selectedDate, displayedComponents: .date)
                    HStack(spacing: 10) {
                        reportMetric("All devices", dailyBitmaps.first(where: { $0.isAggregate })?.usedMinutes ?? 0)
                        reportMetric("This device", dailyBitmaps.first(where: { $0.deviceID == model.settings.deviceID })?.usedMinutes ?? 0)
                        reportMetric("Daily plan", model.settings.dailyPlanMinutes)
                    }
                    Text("Complete minute bitmaps").font(.headline)
                    ForEach(dailyBitmaps) { bitmap in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(bitmap.displayName).bold(); Spacer(); Text(duration(bitmap.usedMinutes)).monospacedDigit() }
                            MinuteBitmapView(minutes: bitmap.minutes)
                            Text("Active intervals: \(usageIntervals(bitmap.minutes, timeZoneID: model.currentReportTimeZone))").font(.caption).textSelection(.enabled)
                        }.padding().background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    DatePicker("Start date", selection: $rangeStart, displayedComponents: .date)
                    DatePicker("End date", selection: $rangeEnd, displayedComponents: .date)
                    Text("Each device has one line; All devices is the deduplicated device-set line.").font(.caption).foregroundStyle(.secondary)
                    Chart(multiDayPoints) { point in
                        LineMark(x: .value("Date", point.date), y: .value("Minutes", point.minutes))
                            .foregroundStyle(by: .value("Device", point.displayName))
                            .symbol(by: .value("Device", point.displayName))
                        PointMark(x: .value("Date", point.date), y: .value("Minutes", point.minutes))
                            .foregroundStyle(by: .value("Device", point.displayName))
                    }
                    .chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine(); AxisTick(); AxisValueLabel { if let minutes = value.as(Int.self) { Text(duration(minutes)) } } } }
                    .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
                    .frame(minHeight: 320)
                    if multiDayPoints.isEmpty && !loading { ContentUnavailableView("No report data", systemImage: "chart.xyaxis.line") }
                }
                Text("iOS observations and cross-device deduplication are estimates.").font(.caption).foregroundStyle(.secondary)
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }.padding()
        }
        .navigationTitle("Report")
        .toolbar {
            Button("Refresh") { Task { await reload() } }
            ShareLink(item: csv, preview: SharePreview("STG report.csv")) { Image(systemName: "square.and.arrow.up") }
        }
        .task { await reload() }
        .onChange(of: mode) { _, _ in Task { await reload() } }
        .onChange(of: selectedDate) { _, _ in if mode == 0 { Task { await reloadDaily() } } }
        .onChange(of: rangeStart) { _, _ in if mode == 1 { Task { await reloadMultiple() } } }
        .onChange(of: rangeEnd) { _, _ in if mode == 1 { Task { await reloadMultiple() } } }
    }
    private func reportMetric(_ title: String, _ minutes: Int) -> some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(duration(minutes)).font(.headline).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)) }
    private func reload() async { if mode == 0 { await reloadDaily() } else { await reloadMultiple() } }
    private func reloadDaily() async { loading = true; dailyBitmaps = await model.reportDay(at: reportInstant(selectedDate, timeZoneID: model.currentReportTimeZone)); loading = false }
    private func reloadMultiple() async { loading = true; multiDayPoints = await model.multiDayReport(from: reportInstant(rangeStart, timeZoneID: model.currentReportTimeZone), through: reportInstant(rangeEnd, timeZoneID: model.currentReportTimeZone)); loading = false }
    private var csv: String {
        if mode == 1 {
            var lines = ["date,device_id,device_name,minutes,report_timezone,estimated"]
            lines += multiDayPoints.map { "\($0.dateLabel),\($0.deviceID),\($0.displayName.replacingOccurrences(of: ",", with: " ")),\($0.minutes),\(model.currentReportTimeZone),true" }
            return lines.joined(separator: "\n") + "\n"
        }
        var lines = ["date,device_id,device_name,minutes,report_timezone,estimated,bitmap"]
        let date = reportDateString(selectedDate, timeZoneID: model.currentReportTimeZone)
        lines += dailyBitmaps.map { bitmap in let bits = bitmap.minutes.map { $0 ? "1" : "0" }.joined(); return "\(date),\(bitmap.deviceID),\(bitmap.displayName.replacingOccurrences(of: ",", with: " ")),\(bitmap.usedMinutes),\(model.currentReportTimeZone),true,\(bits)" }
        return lines.joined(separator: "\n") + "\n"
    }
}

private func reportInstant(_ pickedDate: Date, timeZoneID: String) -> Date {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: pickedDate)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
    return calendar.date(from: DateComponents(year: components.year, month: components.month, day: components.day, hour: 12)) ?? pickedDate
}

private func reportDateString(_ date: Date, timeZoneID: String) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current; formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: reportInstant(date, timeZoneID: timeZoneID)) }

struct MinuteBitmapView: View {
    let minutes: [Bool]
    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 7) {
                        Text(String(format: "%02d–%02d", row * 6, (row + 1) * 6)).font(.caption2).frame(width: 42, alignment: .leading)
                        VStack(spacing: 1) {
                            HStack(spacing: 0) { ForEach(0..<6, id: \.self) { hour in Text(String(format: "%02d:00", row * 6 + hour)).font(.system(size: 8)).frame(width: 120, alignment: .leading) } }
                            Canvas { context, size in
                                let cellWidth = size.width / 360
                                for offset in 0..<360 {
                                    let index = row * 360 + offset
                                    let rect = CGRect(x: CGFloat(offset) * cellWidth, y: 0, width: max(1, cellWidth - 0.3), height: size.height)
                                    context.fill(Path(rect), with: .color(index < minutes.count && minutes[index] ? .accentColor : Color.secondary.opacity(0.13)))
                                }
                                for hour in 0...6 { let x = CGFloat(hour) * size.width / 6; var path = Path(); path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: size.height)); context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 0.5) }
                            }.frame(width: 720, height: 12)
                        }
                    }
                }
            }
        }.accessibilityLabel("\(minutes.filter { $0 }.count) used minutes out of \(minutes.count)")
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var activity: DeviceActivityController
    @State private var logShare: LogShareItem?
    @State private var showActivityPicker = false
    @State private var showCloudSetup = false
    @State private var showCategoryWarning = false
    var body: some View {
        Form {
            Section("Plan") { Stepper("Daily plan: \(duration(model.settings.dailyPlanMinutes))", value: $model.settings.dailyPlanMinutes, in: 20...1440, step: 10); Toggle("Meeting mode", isOn: $model.settings.meetingMode) }
            Section("Private cloud sync") {
                LabeledContent("Provider", value: syncProviderName(model.settings.syncProvider ?? .none))
                LabeledContent("Account", value: iosCloudAccount(provider: model.settings.syncProvider ?? .none, model: model))
                Text(model.syncStatus).font(.caption).foregroundStyle(.secondary)
                Button("Configure private cloud") { showCloudSetup = true }
            }
            Section("Screen Time") {
                Text(activity.status)
                Text("Selected: \(activity.selection.applicationTokens.count) apps, \(activity.selection.categoryTokens.count) categories, \(activity.selection.webDomainTokens.count) websites").font(.footnote).foregroundStyle(.secondary)
                Button("Authorize Screen Time") { Task { await activity.requestAuthorization() } }
                Button("Choose apps and websites") { showActivityPicker = true }
                Text("Select individual apps or websites. Entire categories are rejected because category selection can make the time estimate inaccurate.").font(.footnote).foregroundStyle(.secondary)
                Button("Start 20-minute monitoring") {
                    if !activity.startMonitoring(), !activity.selection.categoryTokens.isEmpty { showCategoryWarning = true }
                }
            }
            Section("Notifications") { Button("Open notification settings") { UIApplication.shared.open(URL(string: UIApplication.openNotificationSettingsURLString)!) } }
            Section("Diagnostics") {
                Button { if let url = model.prepareTestLogExport() { logShare = LogShareItem(url: url) } } label: { Label("Export test log", systemImage: "square.and.arrow.up") }
                Text("Exports lifecycle, Screen Time, database, and sync diagnostics. It does not include private-cloud contents or credentials.").font(.footnote).foregroundStyle(.secondary)
            }
            Section { Button("Save") { model.save() }.frame(maxWidth: .infinity) }
        }.navigationTitle("Settings")
            .onChange(of: showActivityPicker) { _, presented in
                if !presented && !activity.selection.categoryTokens.isEmpty { showCategoryWarning = true }
            }
            .familyActivityPicker(headerText: "Select apps to record screen use", footerText: "Do not select an entire category. Category selections can make the time estimate inaccurate. Individual apps and websites are allowed.", isPresented: $showActivityPicker, selection: $activity.selection)
            .sheet(item: $logShare) { item in
                ActivityShareView(url: item.url) { completed in
                    model.finishTestLogExport(completed: completed)
                    logShare = nil
                }
            }
            .sheet(isPresented: $showCloudSetup) { IOSCloudSetupView(model: model) }
            .alert("Categories are not supported", isPresented: $showCategoryWarning) {
                Button("Return to selection") { DispatchQueue.main.async { showActivityPicker = true } }
            } message: { Text("Remove every selected category. Select individual apps instead; websites may remain selected.") }
    }
}

@MainActor private func iosCloudAccount(provider: SyncProvider, model: AppModel) -> String {
    switch provider { case .none: "Single-device mode"; case .iCloudDrive: model.iCloudAccountLabel; case .oneDrive: model.oneDriveAccountLabel; case .googleDrive: model.googleDriveAccountLabel }
}

private struct IOSCloudSetupView: View {
    @ObservedObject var model: AppModel
    var requiresVerifiedConnection = false
    @Environment(\.dismiss) private var dismiss
    @State private var mac = false
    @State private var android = false
    @State private var windows = false
    @State private var china = false
    private var recommendation: SyncProvider { (android || windows) ? (china ? .oneDrive : .googleDrive) : .iCloudDrive }
    var body: some View {
        NavigationStack {
            Form {
                Section("Devices") {
                    Toggle("This iPhone / iPad", isOn: .constant(true)).disabled(true)
                    Toggle("Mac", isOn: $mac); Toggle("Android", isOn: $android); Toggle("Windows", isOn: $windows)
                    if android || windows { Toggle("Use while travelling in mainland China", isOn: $china) }
                }
                Section("Recommendation") {
                    LabeledContent("Recommended provider", value: syncProviderName(recommendation))
                    Picker("Provider", selection: Binding(get: { model.settings.syncProvider ?? recommendation }, set: { model.selectSyncProvider($0) })) {
                        Text("Off — single device").tag(SyncProvider.none); Text("iCloud Drive").tag(SyncProvider.iCloudDrive); Text("OneDrive").tag(SyncProvider.oneDrive); Text("Google Drive").tag(SyncProvider.googleDrive)
                    }
                }
                Section("Account") { connection }
                Section {
                    Text(model.syncStatus).font(.caption).foregroundStyle(.secondary)
                    if model.privateCloudSetupComplete {
                        Label("Private cloud verified", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else if (model.settings.syncProvider ?? .none) != .none {
                        Text("Connect the account and complete one successful incremental sync before finishing setup.").font(.caption).foregroundStyle(.secondary)
                        Button("Verify and sync now") { Task { await model.sync() } }
                    }
                }
            }.navigationTitle("Private Cloud").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.save(); dismiss() }
                        .disabled(requiresVerifiedConnection && !model.privateCloudSetupComplete)
                }
            }
        }.onAppear { if (model.settings.syncProvider ?? SyncProvider.none) == SyncProvider.none { model.selectSyncProvider(recommendation) } }
            .onChange(of: android) { _, _ in model.selectSyncProvider(recommendation) }
            .onChange(of: windows) { _, _ in model.selectSyncProvider(recommendation) }
            .onChange(of: china) { _, _ in model.selectSyncProvider(recommendation) }
    }
    @ViewBuilder private var connection: some View {
        switch model.settings.syncProvider ?? .none {
        case .none: Text("No cloud account is used.")
        case .iCloudDrive: LabeledContent("Apple Account", value: model.iCloudAccountLabel); Button("Connect iCloud Drive") { model.connect(to: .iCloudDrive) }; Button("Apple Account Settings") { model.openAppleAccountSettings() }
        case .oneDrive: LabeledContent("Microsoft account", value: model.oneDriveAccountLabel); if let code = model.oneDriveUserCode { Text("Code: \(code)").textSelection(.enabled) }; Button("Sign in") { model.requestOneDriveSignIn() }; if model.oneDriveAccountLabel != "Not signed in" { Button("Sign out", role: .destructive) { model.signOutOneDrive() } }
        case .googleDrive: LabeledContent("Google account", value: model.googleDriveAccountLabel); Button("Sign in") { model.requestGoogleDriveSignIn() }; if model.googleDriveAccountLabel != "Not signed in" { Button("Sign out", role: .destructive) { model.signOutGoogleDrive() } }
        }
    }
}

private struct LogShareItem: Identifiable { let id = UUID(); let url: URL }

private struct ActivityShareView: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in completion(completed) }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

struct TrackingView: View {
    @ObservedObject var model: AppModel
    @State private var rows: [OpenRouterRankingRow] = []
    @State private var weeklyRows: [OpenRouterWeeklyRankingRow] = []
    @State private var status = "Public data; no OpenRouter account or API key is needed."
    @State private var viewIndex = 1
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var metric: OpenRouterWeeklyMetric = .totalTokens
    @State private var sortField: TrackingSortField = .rank
    @State private var sortDirection: TrackingSortDirection = .ascending
    @State private var startDate = ""
    @State private var endDate = ""
    @State private var trackingShare: LogShareItem?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("OpenRouter public rankings").font(.headline)
                Picker("View", selection: $viewIndex) { Text("Top 20 from date").tag(0); Text("Weekly trends").tag(1) }.pickerStyle(.segmented)
                if viewIndex == 0 {
                    DatePicker("Start date", selection: $customStart, in: ...Calendar.current.date(byAdding: .day, value: -1, to: .now)!, displayedComponents: .date)
                    Text("Top 20 is fetched only when this view is opened or Refresh is tapped.").font(.caption).foregroundStyle(.secondary)
                    HStack { Button("Refresh report") { Task { await refresh() } }; Spacer(); Button { prepareTrackingExport() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }.disabled(rows.isEmpty) }
                    ScrollView(.horizontal) {
                        LazyVStack(spacing: 0) { trackingHeader; Divider(); ForEach(sortedRows) { row in trackingRow(row); Divider() } }.frame(width: 1_068)
                    }
                    Text("Prices are OpenRouter's observed effective weighted prices per 1M tokens (including cache and provider discounts). Revenue is an estimate, not OpenRouter financial reporting.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Value", selection: $metric) { ForEach(OpenRouterWeeklyMetric.allCases) { Text($0.label).tag($0) } }
                    Chart(weeklyRows) { row in
                        if let value = metric.value(row) {
                            LineMark(x: .value("Week", row.weekStart), y: .value(metric.label, value)).foregroundStyle(by: .value("Model", row.modelPermaslug))
                            PointMark(x: .value("Week", row.weekStart), y: .value(metric.label, value)).foregroundStyle(by: .value("Model", row.modelPermaslug))
                        }
                    }.chartLegend(position: .bottom, alignment: .leading).frame(minHeight: 360)
                    Text("Weekly data is updated by the weekly action during incremental sync.").font(.caption).foregroundStyle(.secondary)
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
                Text("Source: OpenRouter public rankings").font(.caption)
            }.padding()
        }.navigationTitle("Tracking").task { loadWeeks() }
            .onChange(of: viewIndex) { _, value in if value == 0 && rows.isEmpty { Task { await refresh() } } else if value == 1 { loadWeeks() } }
            .onChange(of: metric) { _, _ in if viewIndex == 1 { loadWeeks() } }
            .sheet(item: $trackingShare) { item in ActivityShareView(url: item.url) { _ in trackingShare = nil } }
    }
    private var sortedRows: [OpenRouterRankingRow] { sortedOpenRouterRows(rows, by: sortField, direction: sortDirection) }
    private var trackingHeader: some View {
        HStack(spacing: 0) {
            trackingHeaderButton("Rank", .rank, 58); trackingHeaderButton("Model", .model, 250)
            trackingHeaderButton("Input tokens", .promptTokens, 130); trackingHeaderButton("Output tokens", .completionTokens, 130); trackingHeaderButton("Total tokens", .totalTokens, 130)
            trackingHeaderButton("Input price", .promptPrice, 125); trackingHeaderButton("Output price", .completionPrice, 125); trackingHeaderButton("Revenue", .revenue, 120)
        }.font(.caption.bold()).padding(.vertical, 8).background(Color.secondary.opacity(0.08))
    }
    private func trackingHeaderButton(_ title: String, _ field: TrackingSortField, _ width: CGFloat) -> some View {
        Button { if sortField == field { sortDirection = sortDirection == .descending ? .ascending : .descending } else { sortField = field; sortDirection = .descending } } label: {
            HStack(spacing: 3) { Text(title); if sortField == field { Image(systemName: sortDirection == .descending ? "chevron.down" : "chevron.up") } }.padding(.horizontal, 5).frame(width: width, alignment: field == .model ? .leading : .trailing).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func trackingRow(_ row: OpenRouterRankingRow) -> some View {
        HStack(spacing: 0) {
            trackingCell("\(row.rank)", 58); trackingCell(row.modelPermaslug, 250, leading: true)
            trackingCell(row.promptTokens.formatted(), 130); trackingCell(row.completionTokens.formatted(), 130); trackingCell(row.totalTokens.formatted(), 130)
            trackingCell(pricePerMillion(row.promptPricePerToken), 125); trackingCell(pricePerMillion(row.completionPricePerToken), 125); trackingCell(usd(row.revenueUSD), 120)
        }.font(.caption.monospacedDigit()).padding(.vertical, 7)
    }
    private func trackingCell(_ text: String, _ width: CGFloat, leading: Bool = false) -> some View { Text(text).lineLimit(1).padding(.horizontal, 5).frame(width: width, alignment: leading ? .leading : .trailing) }
    private func refresh() async {
        status = "Loading public ranking data…"
        SharedEnvironment.diagnosticLog.record("OpenRouter refresh begin; period=date_to_latest", category: "tracking")
        do {
            let latest = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
            let snapshot = try await OpenRouterTrackingService.shared.top20(startDate: trackingDateString(customStart), endDate: trackingDateString(latest))
            rows = snapshot.rows; startDate = snapshot.startDate; endDate = snapshot.endDate
            status = "\(snapshot.startDate) – \(snapshot.endDate) UTC · \(snapshot.citation)"
            SharedEnvironment.diagnosticLog.record("OpenRouter refresh complete; window=\(snapshot.startDate)...\(snapshot.endDate); rows=\(snapshot.rows.count)", category: "tracking")
        } catch { status = error.localizedDescription; SharedEnvironment.diagnosticLog.record("OpenRouter: \(status)", category: "tracking") }
    }
    private func loadWeeks() {
        let models = model.latestOpenRouterTopModels(metric: metric)
        weeklyRows = model.openRouterWeeks(models: models)
        status = weeklyRows.isEmpty ? "No saved weekly data contains \(metric.label). The weekly action will add it when OpenRouter publishes that field." : "Showing all saved weeks for the latest completed week's \(metric.label) Top \(models.count)."
    }
    private func prepareTrackingExport() {
        let periodName = "date_to_latest"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stg-openrouter-\(periodName).csv")
        do {
            try openRouterTrackingCSV(rows: sortedRows, period: periodName, startDate: startDate, endDate: endDate).write(to: url, atomically: true, encoding: .utf8)
            trackingShare = LogShareItem(url: url)
        } catch { status = "Export failed: \(error.localizedDescription)" }
    }
}

struct AboutView: View {
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 16) { HStack { Spacer(); Image(systemName: "shield.lefthalf.filled").font(.system(size: 64)).foregroundStyle(.blue); Spacer() }; Text("Screen Time Guardian").font(.title.bold()).frame(maxWidth: .infinity); Group { Text("Version 1.1.7 · Developer: TimberTrail\nCopyright © 2026 TimberTrail."); Text("Screen Time Guardian reconstructs a minute-level screen-use estimate, reminds you to rest, and can combine data from your own devices."); Text("Privacy: screen-use data remains on this device and in the private-cloud account you explicitly authorize. It is not uploaded to the app developer."); Text("Accuracy: Apple does not expose its Screen Time total directly to this app. STG estimates minutes from DeviceActivity threshold callbacks, so its value can differ from iOS Settings → Screen Time."); Text("Open-source claim: this application includes SQLite (public domain) and Apple Swift open-source runtime components. Their copyright notices and license terms are preserved in THIRD_PARTY_NOTICES.md. STG does not claim ownership of those components.") } }.padding() } .navigationTitle("About") }
}

func duration(_ minutes: Int) -> String { "\(minutes / 60)h \(minutes % 60)m" }
private func trackingPeriodName(_ index: Int) -> String { index == 0 ? "previous_week" : index == 1 ? "previous_month" : "custom_range" }
private func trackingDateString(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}
func syncProviderName(_ provider: SyncProvider) -> String { switch provider { case .none: "Off"; case .iCloudDrive: "iCloud Drive"; case .oneDrive: "OneDrive"; case .googleDrive: "Google Drive" } }
func pricePerMillion(_ value: Double?) -> String { value.map { String(format: "$%.4f/M", $0 * 1_000_000) } ?? "N/A" }
func usd(_ value: Double?) -> String { formattedWholeDollarUSD(value) }
func usageIntervals(_ minutes: [Bool], timeZoneID: String) -> String {
    guard minutes.contains(true) else { return "None" }
    var ranges: [String] = []; var index = 0
    while index < minutes.count { guard minutes[index] else { index += 1; continue }; let start = index; while index < minutes.count && minutes[index] { index += 1 }; ranges.append("\(STGTime.localClockLabel(minute: start))–\(STGTime.localClockLabel(minute: index))") }
    return ranges.joined(separator: ", ")
}
