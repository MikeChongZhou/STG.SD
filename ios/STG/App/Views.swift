import FamilyControls
import Charts
import STGCore
import SwiftUI
import UserNotifications

struct RootView: View {
    @StateObject var model: AppModel
    @StateObject private var activity = DeviceActivityController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOnboarding = !SharedEnvironment.defaults.bool(forKey: "permission_onboarding_v1_complete")
    @State private var initialLoadComplete = false
    @State private var selectedTab = 0
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { TodayView(model: model) }.tabItem { Label("Today", systemImage: "shield.fill") }.tag(0)
            NavigationStack { ReportView(model: model) }.tabItem { Label("Report", systemImage: "chart.bar") }.tag(1)
            NavigationStack { TrackingView(model: model) }.tabItem { Label("Tracking", systemImage: "waveform.path.ecg") }.tag(2)
            NavigationStack { SettingsView(model: model, activity: activity) { selectedTab = 0 } }.tabItem { Label("Settings", systemImage: "gear") }.tag(3)
            NavigationStack { AboutView() }.tabItem { Label("About", systemImage: "info.circle") }.tag(4)
        }.task {
            model.beginDeferredStartup()
            await model.refresh()
            initialLoadComplete = true
            if !showOnboarding { await model.sync() }
        }
            .onAppear { model.recordFirstFrame() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, initialLoadComplete else { return }
                Task {
                    await model.refresh()
                    if SharedEnvironment.defaults.bool(forKey: "permission_onboarding_v1_complete") { await model.sync() }
                }
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                PermissionOnboardingView(
                    model: model,
                    activity: activity,
                    finish: {
                        SharedEnvironment.defaults.set(true, forKey: "permission_onboarding_v1_complete")
                        SharedEnvironment.defaults.synchronize()
                        SharedEnvironment.diagnosticLog.record("permission onboarding completed", category: "permissions")
                        showOnboarding = false
                    }
                )
            }
    }
}

private struct PermissionOnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var activity: DeviceActivityController
    @Environment(\.scenePhase) private var scenePhase
    let finish: () -> Void
    @State private var step = 0
    @State private var notificationStatus = String(localized: "Checking…")
    @State private var persistentStatus = String(localized: "Checking…")
    @State private var soundStatus = String(localized: "Checking…")
    @State private var notificationAuthorized = false
    @State private var notificationReady = false
    @State private var authorizingScreenTime = false
    @State private var showActivityPicker = false
    @State private var showCloudSetup = false
    @State private var showCategoryWarning = false
    @State private var showSelectionWarning = false
    @State private var selectionWarningTitle = String(localized: "Selection Required")
    @State private var selectionWarning = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ProgressView(value: Double(step + 1), total: 5)
                    if step == 0 {
                        Label("Turn On Notifications", systemImage: "bell.badge.fill").font(.largeTitle.bold())
                        Text("Get eye-break, posture, and daily-limit reminders.").font(.title3).foregroundStyle(.secondary)
                        permissionRow("Notifications", notificationStatus)
                        permissionRow("Sounds", soundStatus)
                        Button("Allow Notifications", action: allowNotifications).buttonStyle(.borderedProminent)
                    } else if step == 1 {
                        Label("Keep Reminders Visible", systemImage: "rectangle.stack.badge.person.crop.fill").font(.largeTitle.bold())
                        permissionRow("Banner Style", persistentStatus)
                        Text("In Settings, set Banner Style to Persistent. Return to STG when you’re done.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Temporary → Persistent", action: configurePersistentNotifications).buttonStyle(.borderedProminent)
                    } else if step == 2 {
                        Label("Allow Screen Time Access", systemImage: "hourglass.badge.plus").font(.largeTitle.bold())
                        permissionRow("Screen Time Access", screenTimeAuthorizationStatus)
                        Text("Allow STG to measure screen use for the apps and websites you choose. Their identities remain private.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(action: authorizeScreenTime) {
                            HStack {
                                if authorizingScreenTime { ProgressView().controlSize(.small) }
                                Text(authorizingScreenTime ? "Authorizing…" : "Authorize Screen Time")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(authorizingScreenTime)
                        if activity.status.hasPrefix("Couldn’t") { Text(activity.status).foregroundStyle(.secondary) }
                    } else if step == 3 {
                        Label("Choose Apps and Websites", systemImage: "apps.iphone").font(.largeTitle.bold())
                        Button("Choose Apps and Websites") { showActivityPicker = true }.buttonStyle(.borderedProminent)
                        Text(selectionSummary).foregroundStyle(.secondary)
                        Text("Select at least one app or website. Do not select categories; category totals can make the estimate inaccurate.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("Set Up Private Cloud?", systemImage: "icloud.and.arrow.up.fill").font(.largeTitle.bold())
                        Text("Sync and combine screen-use data across your devices. Your data stays in the cloud account you choose.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        LabeledContent("Provider", value: syncProviderName(model.settings.syncProvider ?? .none))
                        Button(model.privateCloudSetupComplete ? "Manage Private Cloud" : "Set Up Private Cloud") { showCloudSetup = true }.buttonStyle(.borderedProminent)
                        Button("Use This Device Only") {
                            model.selectSyncProvider(.none)
                            finish()
                        }
                        if model.privateCloudSetupComplete {
                            Label("Private cloud is connected and synced.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                    }
                    Spacer(minLength: 24)
                    HStack {
                        if step > 0 {
                            Button("Back") { step -= 1 }
                        }
                        Spacer()
                    }
                }.padding(28)
            }.navigationTitle("Set Up STG · Step \(step + 1) of 5")
        }
        .interactiveDismissDisabled()
        .task {
            activity.refreshAuthorizationStatus()
            await refreshNotificationStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshNotificationStatus(advanceAfterReturn: true) } }
        }
        .onChange(of: showActivityPicker) { _, presented in
            if !presented { validateSelectionAndAdvance() }
        }
        .familyActivityPicker(headerText: "Select Apps and Websites", footerText: "Select individual apps or websites only. Do not select categories.", isPresented: $showActivityPicker, selection: $activity.selection)
        .sheet(isPresented: $showCloudSetup) {
            IOSCloudSetupView(model: model, requiresVerifiedConnection: true) { finish() }
        }
        .alert("Categories Aren’t Supported", isPresented: $showCategoryWarning) {
            Button("Edit Selection") { DispatchQueue.main.async { showActivityPicker = true } }
        } message: { Text("Deselect all categories. Individual apps and websites may remain selected.") }
        .alert(selectionWarningTitle, isPresented: $showSelectionWarning) {
            Button("OK", role: .cancel) { }
        } message: { Text(selectionWarning) }
    }

    private func permissionRow(_ title: LocalizedStringKey, _ value: String) -> some View { HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }.padding().background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)) }
    private var screenTimeAuthorizationStatus: String {
        if activity.authorization == .approved { return String(localized: "Authorized") }
        if activity.authorization == .denied { return String(localized: "Not Authorized") }
        return String(localized: "Not Requested")
    }
    private var selectionSummary: String {
        let apps = activity.selection.applicationTokens.count
        let categories = activity.selection.categoryTokens.count
        let websites = activity.selection.webDomainTokens.count
        if categories > 0 {
            return String.localizedStringWithFormat(NSLocalizedString("Selected: %d apps · %d websites · %d categories", comment: "Activity picker selection summary"), apps, websites, categories)
        }
        return String.localizedStringWithFormat(NSLocalizedString("Selected: %d apps · %d websites", comment: "Activity picker selection summary"), apps, websites)
    }
    private func allowNotifications() {
        Task {
            let current = await UNUserNotificationCenter.current().notificationSettings()
            if current.authorizationStatus == .denied {
                openNotificationSettings()
                return
            }
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                SharedEnvironment.diagnosticLog.record("notification authorization request completed; granted=\(granted)", category: "permissions")
            } catch {
                SharedEnvironment.diagnosticLog.record("notification authorization request failed; error=\(error.localizedDescription)", category: "permissions")
            }
            await refreshNotificationStatus()
            if notificationAuthorized { step = 1 }
        }
    }
    private func configurePersistentNotifications() {
        Task {
            await refreshNotificationStatus()
            if notificationReady { step = 2 }
            else { openNotificationSettings() }
        }
    }
    private func authorizeScreenTime() {
        authorizingScreenTime = true
        Task {
            await activity.requestAuthorization()
            authorizingScreenTime = false
            if activity.authorization == .approved { step = 3 }
        }
    }
    private func validateSelectionAndAdvance() {
        guard step == 3 else { return }
        guard activity.selection.categoryTokens.isEmpty else {
            showCategoryWarning = true
            return
        }
        guard !activity.selection.applicationTokens.isEmpty || !activity.selection.webDomainTokens.isEmpty else {
            selectionWarningTitle = String(localized: "Selection Required")
            selectionWarning = String(localized: "Select at least one app or website.")
            showSelectionWarning = true
            return
        }
        guard activity.startMonitoring() else {
            selectionWarningTitle = String(localized: "Monitoring Couldn’t Start")
            selectionWarning = String(localized: "Try again. Details are available in the test log.")
            showSelectionWarning = true
            return
        }
        step = 4
    }

    private func refreshNotificationStatus(advanceAfterReturn: Bool = false) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authorized = switch settings.authorizationStatus { case .authorized, .provisional, .ephemeral: true; case .denied, .notDetermined: false; @unknown default: false }
        notificationAuthorized = authorized && settings.alertSetting == .enabled
        notificationStatus = switch settings.authorizationStatus { case .authorized, .provisional, .ephemeral: String(localized: "On"); case .denied: String(localized: "Not Allowed"); case .notDetermined: String(localized: "Not Requested"); @unknown default: String(localized: "Unknown") }
        soundStatus = settings.soundSetting == .enabled ? String(localized: "On") : String(localized: "Off")
        persistentStatus = settings.alertStyle == .alert ? String(localized: "Persistent") : settings.alertStyle == .banner ? String(localized: "Temporary") : String(localized: "Off")
        notificationReady = authorized && settings.alertSetting == .enabled && settings.alertStyle == .alert
        SharedEnvironment.diagnosticLog.record("notification permission status; authorization=\(settings.authorizationStatus.rawValue); sound=\(settings.soundSetting.rawValue); alert=\(settings.alertSetting.rawValue); alert_style=\(settings.alertStyle.rawValue); persistent_style=\(settings.alertStyle == .alert)", category: "permissions")
        guard advanceAfterReturn else { return }
        if step == 0, notificationAuthorized { step = 1 }
        else if step == 1, notificationReady { step = 2 }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

struct TodayView: View {
    @ObservedObject var model: AppModel
    var body: some View { ScrollView { VStack(spacing: 16) { Image(systemName: "shield.lefthalf.filled").font(.system(size: 58)).foregroundStyle(.blue); Text("Screen Time Guardian").font(.largeTitle.bold()); metric("All Devices", model.allMinutes); metric("This Device", model.localMinutes); metric("Daily Limit", model.settings.dailyPlanMinutes); GroupBox("Latest Week · Top Models") { Text(model.latestTrackingTopTwo).frame(maxWidth: .infinity, alignment: .leading) }; Text("Screen use is estimated from DeviceActivity and may differ from Settings → Screen Time.").font(.footnote).foregroundStyle(.secondary); Button("Sync Now") { Task { await model.sync() } }.buttonStyle(.borderedProminent); Text(model.syncStatus).font(.caption) }.padding() }.navigationTitle("Today") }
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
    @State private var periodPoints: [DailyUsagePoint] = []
    @State private var unavailablePeriods: [PeriodUsagePoint] = []
    @State private var loading = false
    @State private var expandedIntervalIDs: Set<String> = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Report Type", selection: $mode) {
                    Text("Daily").tag(0); Text("Multiple Days").tag(1); Text("This Year by Week").tag(2); Text("Years by Month").tag(3)
                }.pickerStyle(.menu)
                if mode == 0 {
                    DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                    HStack(spacing: 10) {
                        reportMetric("All Devices", dailyBitmaps.first(where: { $0.isAggregate })?.usedMinutes ?? 0)
                        reportMetric("This Device", dailyBitmaps.first(where: { $0.deviceID == model.settings.deviceID })?.usedMinutes ?? 0)
                        reportMetric("Daily Limit", model.settings.dailyPlanMinutes)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
                        averageMetric("This Week Avg.", model.statisticsSummary.thisWeekAverageMinutes)
                        averageMetric("Last Week Avg.", model.statisticsSummary.lastWeekAverageMinutes)
                        averageMetric("This Month Avg.", model.statisticsSummary.thisMonthAverageMinutes)
                        averageMetric("Last Month Avg.", model.statisticsSummary.lastMonthAverageMinutes)
                        averageMetric("This Year Avg.", model.statisticsSummary.thisYearAverageMinutes)
                    }
                    Text("Minute-by-Minute Activity").font(.headline)
                    ForEach(dailyBitmaps) { bitmap in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(bitmap.displayName).bold(); Spacer(); Text(duration(bitmap.usedMinutes)).monospacedDigit() }
                            MinuteBitmapView(minutes: bitmap.minutes)
                            let intervalID = "\(bitmap.deviceID)-\(selectedDate.timeIntervalSince1970)"
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("Active intervals: \(usageIntervals(bitmap.minutes, timeZoneID: model.currentReportTimeZone))")
                                    .font(.caption).textSelection(.enabled).lineLimit(expandedIntervalIDs.contains(intervalID) ? nil : 1)
                                Spacer(minLength: 0)
                                Button { if expandedIntervalIDs.contains(intervalID) { expandedIntervalIDs.remove(intervalID) } else { expandedIntervalIDs.insert(intervalID) } } label: { Image(systemName: expandedIntervalIDs.contains(intervalID) ? "chevron.up" : "chevron.down") }
                                    .buttonStyle(.plain).accessibilityLabel(expandedIntervalIDs.contains(intervalID) ? "Collapse active intervals" : "Show all active intervals")
                            }
                        }.padding().background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                } else if mode == 1 {
                    DatePicker("From", selection: $rangeStart, displayedComponents: .date)
                    DatePicker("To", selection: $rangeEnd, displayedComponents: .date)
                    Text("One line per device. All Devices combines overlapping use.").font(.caption).foregroundStyle(.secondary)
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
                    if let average = intervalAverage(multiDayPoints) { Text("Interval average: \(duration(average)) per day").font(.caption).foregroundStyle(.secondary) }
                    if multiDayPoints.isEmpty && !loading { ContentUnavailableView("No Data for This Period", systemImage: "chart.xyaxis.line") }
                } else {
                    Text(mode == 2 ? "Average daily use by week in the current year" : "Average daily use by month across recent years").font(.caption).foregroundStyle(.secondary)
                    Chart(periodPoints) { point in
                        LineMark(x: .value("Period", point.date), y: .value("Minutes", point.minutes)).foregroundStyle(by: .value("Device", point.displayName)).symbol(by: .value("Device", point.displayName))
                        PointMark(x: .value("Period", point.date), y: .value("Minutes", point.minutes)).foregroundStyle(by: .value("Device", point.displayName))
                    }.chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine(); AxisTick(); AxisValueLabel { if let minutes = value.as(Int.self) { Text(duration(minutes)) } } } }
                        .chartLegend(position: .bottom, alignment: .leading, spacing: 8).frame(minHeight: 320)
                    if !unavailablePeriods.isEmpty {
                        DisclosureGroup("— · No eligible completed days") {
                            ForEach(unavailablePeriods) { value in
                                Text("\(value.periodLabel) · \(value.displayName): —").font(.caption)
                            }
                        }
                    }
                    if periodPoints.isEmpty && !loading { ContentUnavailableView("No Statistics for This Period", systemImage: "chart.xyaxis.line") }
                }
                if model.statisticsSummary.containsEstimatedIOSData {
                    Label("Estimated: this report includes iPhone or iPad DeviceActivity data.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
    private func averageMetric(_ title: String, _ minutes: Double?) -> some View {
        HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer(); Text(minutes.map { duration(Int($0.rounded())) } ?? "—").font(.caption.bold()).monospacedDigit() }
            .padding(8).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
    private func reload() async { if mode == 0 { await reloadDaily() } else if mode == 1 { await reloadMultiple() } else { await reloadPeriod() } }
    private func reloadDaily() async { loading = true; dailyBitmaps = await model.reportDay(at: reportInstant(selectedDate, timeZoneID: model.currentReportTimeZone)); loading = false }
    private func reloadMultiple() async { loading = true; multiDayPoints = await model.multiDayReport(from: reportInstant(rangeStart, timeZoneID: model.currentReportTimeZone), through: reportInstant(rangeEnd, timeZoneID: model.currentReportTimeZone)); loading = false }
    private func reloadPeriod() async {
        loading = true
        let calendar = Calendar.current, now = Date()
        let start = mode == 2 ? (calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: 1, day: 1)) ?? now) : (calendar.date(byAdding: .year, value: -2, to: now) ?? now)
        let values = await model.periodReport(kind: mode == 2 ? "week" : "month", from: start, through: now)
        unavailablePeriods = values.filter { $0.includedDays == 0 }
        periodPoints = values.compactMap(periodChartPoint)
        loading = false
    }
    private var csv: String {
        if mode == 1 {
            var lines = ["date,device_id,device_name,minutes,report_timezone,estimated"]
            lines += multiDayPoints.map { "\($0.dateLabel),\($0.deviceID),\($0.displayName.replacingOccurrences(of: ",", with: " ")),\($0.minutes),\(model.currentReportTimeZone),true" }
            return lines.joined(separator: "\n") + "\n"
        }
        if mode > 1 {
            return (["period,device_id,device_name,average_daily_minutes,estimated"] + periodPoints.map { "\($0.dateLabel),\($0.deviceID),\($0.displayName.replacingOccurrences(of: ",", with: " ")),\($0.minutes),\($0.estimated)" }).joined(separator: "\n") + "\n"
        }
        var lines = ["date,device_id,device_name,minutes,report_timezone,estimated,bitmap"]
        let date = reportDateString(selectedDate, timeZoneID: model.currentReportTimeZone)
        lines += dailyBitmaps.map { bitmap in let bits = bitmap.minutes.map { $0 ? "1" : "0" }.joined(); return "\(date),\(bitmap.deviceID),\(bitmap.displayName.replacingOccurrences(of: ",", with: " ")),\(bitmap.usedMinutes),\(model.currentReportTimeZone),true,\(bits)" }
        return lines.joined(separator: "\n") + "\n"
    }
}

private func periodChartPoint(_ value: PeriodUsagePoint) -> DailyUsagePoint? {
    guard value.includedDays > 0 else { return nil }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: value.periodStart) else { return nil }
    return DailyUsagePoint(date: date, dateLabel: value.periodLabel, deviceID: value.deviceID, displayName: value.displayName, minutes: Int(value.averageDailyMinutes.rounded()), isAggregate: value.deviceID == "alldevices", estimated: value.estimated)
}

private func intervalAverage(_ points: [DailyUsagePoint]) -> Int? {
    let values = points.filter(\.isAggregate).map(\.minutes)
    return values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
}

private func reportInstant(_ pickedDate: Date, timeZoneID: String) -> Date {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: pickedDate)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
    return calendar.date(from: DateComponents(year: components.year, month: components.month, day: components.day, hour: 12)) ?? pickedDate
}

private func reportDateString(_ date: Date, timeZoneID: String) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current; formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: reportInstant(date, timeZoneID: timeZoneID)) }

struct MinuteBitmapView: View {
    let minutes: [Bool]

    private struct Segment: Identifiable {
        let startMinute: Int
        let endMinute: Int
        var id: Int { startMinute }
        var minuteCount: Int { endMinute - startMinute }
        var hourBoundaries: [Int] { Array(stride(from: startMinute, through: endMinute, by: 60)) }
    }

    var body: some View {
        let segments = visibleSegments
        Group {
            if segments.isEmpty {
                Text("No activity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(segments) { segment in
                        GeometryReader { proxy in
                            ZStack(alignment: .topLeading) {
                                ForEach(segment.hourBoundaries, id: \.self) { boundary in
                                    let progress = CGFloat(boundary - segment.startMinute) / CGFloat(segment.minuteCount)
                                    Text(String(format: "%02d", boundary / 60))
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .position(x: min(proxy.size.width - 10, max(10, progress * proxy.size.width)), y: 8)
                                }
                                Canvas { context, size in
                                    let minuteWidth = size.width / CGFloat(segment.minuteCount)
                                    let baselineY = size.height * 0.58

                                    var baseline = Path()
                                    baseline.move(to: CGPoint(x: 0, y: baselineY))
                                    baseline.addLine(to: CGPoint(x: size.width, y: baselineY))
                                    context.stroke(baseline, with: .color(.secondary.opacity(0.13)), lineWidth: 0.5)

                                    for offset in stride(from: 0, through: segment.minuteCount, by: 5) {
                                        let absoluteMinute = segment.startMinute + offset
                                        let x = CGFloat(offset) * minuteWidth
                                        let isHour = absoluteMinute.isMultiple(of: 60)
                                        let isHalfHour = absoluteMinute.isMultiple(of: 30)
                                        let length: CGFloat = isHour ? size.height : (isHalfHour ? size.height * 0.58 : size.height * 0.32)
                                        var tick = Path()
                                        tick.move(to: CGPoint(x: x, y: baselineY - length / 2))
                                        tick.addLine(to: CGPoint(x: x, y: baselineY + length / 2))
                                        context.stroke(
                                            tick,
                                            with: .color(.secondary.opacity(isHour ? 0.42 : (isHalfHour ? 0.28 : 0.17))),
                                            lineWidth: isHour ? 0.8 : 0.5
                                        )
                                    }

                                    var runStart: Int?
                                    for offset in 0...segment.minuteCount {
                                        let index = segment.startMinute + offset
                                        let active = offset < segment.minuteCount && index < minutes.count && minutes[index]
                                        if active, runStart == nil { runStart = offset }
                                        if !active, let start = runStart {
                                            let end = offset - 1
                                            if end > start {
                                                var run = Path()
                                                run.move(to: CGPoint(x: (CGFloat(start) + 0.5) * minuteWidth, y: baselineY))
                                                run.addLine(to: CGPoint(x: (CGFloat(end) + 0.5) * minuteWidth, y: baselineY))
                                                context.stroke(run, with: .color(.accentColor.opacity(0.82)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                                            }
                                            runStart = nil
                                        }
                                    }

                                    for offset in 0..<segment.minuteCount {
                                        let index = segment.startMinute + offset
                                        let active = index < minutes.count && minutes[index]
                                        let radius: CGFloat = active ? 0.72 : 0.42
                                        let center = CGPoint(x: (CGFloat(offset) + 0.5) * minuteWidth, y: baselineY)
                                        let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                                        context.fill(dot, with: .color(active ? .accentColor : .secondary.opacity(0.22)))
                                    }
                                }
                                .frame(height: 18)
                                .offset(y: 14)
                            }
                        }
                        .frame(height: 34)
                        .accessibilityLabel(segmentAccessibilityLabel(segment))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var visibleSegments: [Segment] {
        let dayMinuteCount = min(minutes.count, 1_440)
        var segments: [Segment] = []
        var cursor = 0
        while cursor < dayMinuteCount {
            guard let firstActive = (cursor..<dayMinuteCount).first(where: { minutes[$0] }) else { break }
            let start = (firstActive / 60) * 60
            let end = min(start + 180, 1_440)
            segments.append(Segment(startMinute: start, endMinute: end))
            cursor = end
        }
        return segments
    }

    private func segmentAccessibilityLabel(_ segment: Segment) -> String {
        let used = (segment.startMinute..<min(segment.endMinute, minutes.count)).reduce(into: 0) { count, index in
            if minutes[index] { count += 1 }
        }
        return "\(STGTime.localClockLabel(minute: segment.startMinute))–\(STGTime.localClockLabel(minute: segment.endMinute)), \(used) active minutes"
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var activity: DeviceActivityController
    let close: () -> Void
    @State private var draft: STGSettings
    @State private var logShare: LogShareItem?
    @State private var dataShare: LogShareItem?
    @State private var showActivityPicker = false
    @State private var showCloudSetup = false
    @State private var showCategoryWarning = false
    @State private var showSelectionWarning = false
    @State private var selectionWarningTitle = String(localized: "Selection Required")
    @State private var selectionWarning = ""
    @State private var confirmClose = false
    init(model: AppModel, activity: DeviceActivityController, close: @escaping () -> Void) {
        self.model = model; self.activity = activity; self.close = close
        _draft = State(initialValue: model.settings)
    }
    var body: some View {
        Form {
            Section("Daily Limit") {
                HStack {
                    Picker("Hours", selection: planHours) { ForEach(0...24, id: \.self) { Text("\($0) h").tag($0) } }
                    Picker("Minutes", selection: planMinutes) { ForEach([0, 15, 30, 45], id: \.self) { Text("\($0) m").tag($0) } }.disabled(draft.dailyPlanMinutes / 60 >= 24)
                }
                Toggle("Meeting Mode", isOn: $draft.meetingMode)
            }
            Section("Private Cloud") {
                LabeledContent("Provider", value: syncProviderName(draft.syncProvider ?? .none))
                LabeledContent("Account", value: iosCloudAccount(provider: draft.syncProvider ?? .none, model: model))
                Text(model.syncStatus).font(.caption).foregroundStyle(.secondary)
                Button((draft.syncProvider ?? SyncProvider.none) == SyncProvider.none ? "Set Up Private Cloud" : "Manage Private Cloud") { model.settings = draft; showCloudSetup = true }
            }
            Section("Screen Time") {
                Text(settingsSelectionSummary).font(.footnote).foregroundStyle(.secondary)
                Button("Change Apps and Websites") { showActivityPicker = true }
                Text("Select individual apps or websites. Categories aren’t supported because they may reduce accuracy.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Notification Options") {
                Toggle("Eye Break Notifications", isOn: $draft.eyeNotificationsEnabled)
                Toggle("Posture Notifications", isOn: $draft.postureNotificationsEnabled)
                Toggle("Daily Usage Notifications", isOn: $draft.dailyNotificationsEnabled)
                Text("Usage is still recorded when all options are off.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Notifications") { Button("Notification Settings") { UIApplication.shared.open(URL(string: UIApplication.openNotificationSettingsURLString)!) } }
            Section("Diagnostics") {
                Button { Task { if let urls = await model.prepareDataExport() { dataShare = LogShareItem(urls: urls) } } } label: { Label("Export App Data", systemImage: "externaldrive.badge.timemachine") }
                Button { if let url = model.prepareTestLogExport() { logShare = LogShareItem(url: url) } } label: { Label("Export Test Log", systemImage: "square.and.arrow.up") }
                Text("Includes app activity, Screen Time, database, and sync events. Cloud files and credentials are never included.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Save") { model.settings = draft; model.save(); draft = model.settings }.disabled(!hasChanges)
                    Spacer()
                    Button("Close") { if hasChanges { confirmClose = true } else { close() } }
                }
            }
        }.navigationTitle("Settings")
            .onChange(of: showActivityPicker) { _, presented in
                if !presented { validateSettingsSelection() }
            }
            .familyActivityPicker(headerText: "Select Apps and Websites", footerText: "Select individual apps or websites only. Do not select categories.", isPresented: $showActivityPicker, selection: $activity.selection)
            .sheet(item: $logShare) { item in
                ActivityShareView(urls: item.urls) { completed in
                    model.finishTestLogExport(completed: completed)
                    logShare = nil
                }
            }
            .sheet(item: $dataShare) { item in ActivityShareView(urls: item.urls) { _ in dataShare = nil } }
            .sheet(isPresented: $showCloudSetup, onDismiss: { draft = model.settings }) { IOSCloudSetupView(model: model) }
            .alert("Categories Aren’t Supported", isPresented: $showCategoryWarning) {
                Button("Edit Selection") { DispatchQueue.main.async { showActivityPicker = true } }
            } message: { Text("Deselect all categories. Individual apps and websites may remain selected.") }
            .alert(selectionWarningTitle, isPresented: $showSelectionWarning) {
                Button("OK", role: .cancel) { }
            } message: { Text(selectionWarning) }
            .alert("Save changes before closing?", isPresented: $confirmClose) {
                Button("Save") { model.settings = draft; model.save(); close() }
                Button("Discard Changes", role: .destructive) { draft = model.settings; close() }
                Button("Keep Editing", role: .cancel) { }
            }
    }

    private var hasChanges: Bool { draft != model.settings }
    private var planHours: Binding<Int> { Binding(get: { draft.dailyPlanMinutes / 60 }, set: { draft.dailyPlanMinutes = min(1_440, max(20, $0 * 60 + ($0 == 24 ? 0 : draft.dailyPlanMinutes % 60))) }) }
    private var planMinutes: Binding<Int> { Binding(get: { min(45, (draft.dailyPlanMinutes % 60) / 15 * 15) }, set: { draft.dailyPlanMinutes = min(1_440, max(20, draft.dailyPlanMinutes / 60 * 60 + $0)) }) }

    private var settingsSelectionSummary: String {
        let apps = activity.selection.applicationTokens.count
        let categories = activity.selection.categoryTokens.count
        let websites = activity.selection.webDomainTokens.count
        if categories > 0 {
            return String.localizedStringWithFormat(NSLocalizedString("Selected: %d apps · %d websites · %d categories", comment: "Activity picker selection summary"), apps, websites, categories)
        }
        return String.localizedStringWithFormat(NSLocalizedString("Selected: %d apps · %d websites", comment: "Activity picker selection summary"), apps, websites)
    }

    private func validateSettingsSelection() {
        guard activity.selection.categoryTokens.isEmpty else {
            showCategoryWarning = true
            return
        }
        guard !activity.selection.applicationTokens.isEmpty || !activity.selection.webDomainTokens.isEmpty else {
            selectionWarningTitle = String(localized: "Selection Required")
            selectionWarning = String(localized: "Select at least one app or website.")
            showSelectionWarning = true
            return
        }
        guard activity.startMonitoring() else {
            selectionWarningTitle = String(localized: "Monitoring Couldn’t Start")
            selectionWarning = String(localized: "Try again. Details are available in the test log.")
            showSelectionWarning = true
            return
        }
    }
}

@MainActor private func iosCloudAccount(provider: SyncProvider, model: AppModel) -> String {
    switch provider { case .none: "This Device Only"; case .iCloudDrive: model.iCloudAccountLabel; case .oneDrive: model.oneDriveAccountLabel; case .googleDrive: model.googleDriveAccountLabel }
}

private struct IOSCloudSetupView: View {
    @ObservedObject var model: AppModel
    var requiresVerifiedConnection = false
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var mac = false
    @State private var android = false
    @State private var windows = false
    @State private var china = false
    @State private var attemptedConnection = false
    @State private var completingVerifiedSetup = false
    private var recommendation: SyncProvider { (android || windows) ? (china ? .oneDrive : .googleDrive) : .iCloudDrive }
    var body: some View {
        NavigationStack {
            Form {
                Section("Devices") {
                    Toggle("This Device", isOn: .constant(true)).disabled(true)
                    Toggle("Mac", isOn: $mac); Toggle("Android", isOn: $android); Toggle("Windows", isOn: $windows)
                    if android || windows { Toggle("Use in mainland China", isOn: $china) }
                }
                Section("Recommendation") {
                    LabeledContent("Recommended", value: syncProviderName(recommendation))
                    Picker("Provider", selection: Binding(get: { model.settings.syncProvider ?? recommendation }, set: { model.selectSyncProvider($0) })) {
                        Text("Off (This Device Only)").tag(SyncProvider.none); Text("iCloud Drive").tag(SyncProvider.iCloudDrive); Text("OneDrive").tag(SyncProvider.oneDrive); Text("Google Drive").tag(SyncProvider.googleDrive)
                    }
                }
                Section("Account") { connection }
                Section {
                    Text(model.syncStatus).font(.caption).foregroundStyle(.secondary)
                    if model.privateCloudSetupComplete {
                        Label("Private Cloud Ready", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else if model.privateCloudConnectionInProgress {
                        Button("Connecting and Syncing…") { }
                            .disabled(true)
                    } else if (model.settings.syncProvider ?? .none) != .none {
                        Text("Connect your account, then complete one sync.").font(.caption).foregroundStyle(.secondary)
                        if !requiresVerifiedConnection || attemptedConnection {
                            Button("Verify and Sync") { retryConnection() }
                        }
                    }
                }
            }.navigationTitle("Private Cloud").toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.privateCloudConnectionInProgress)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { model.save(); dismiss(); onDone?() } label: {
                        HStack(spacing: 6) {
                            if model.privateCloudConnectionInProgress { ProgressView().controlSize(.small) }
                            Text("Done")
                        }
                    }
                    .disabled(model.privateCloudConnectionInProgress || (requiresVerifiedConnection && !model.privateCloudSetupComplete))
                }
            }
        }.onAppear { if (model.settings.syncProvider ?? SyncProvider.none) == SyncProvider.none { model.selectSyncProvider(recommendation) } }
            .onChange(of: android) { _, _ in model.selectSyncProvider(recommendation) }
            .onChange(of: windows) { _, _ in model.selectSyncProvider(recommendation) }
            .onChange(of: china) { _, _ in model.selectSyncProvider(recommendation) }
            .onChange(of: model.privateCloudSetupComplete) { _, _ in finishVerifiedSetupIfReady() }
            .onChange(of: model.privateCloudConnectionInProgress) { _, _ in finishVerifiedSetupIfReady() }
    }
    @ViewBuilder private var connection: some View {
        switch model.settings.syncProvider ?? .none {
        case .none: Text("No cloud account is connected.")
        case .iCloudDrive:
            LabeledContent("Apple Account", value: model.iCloudAccountLabel)
            Button("Use iCloud Drive") { beginSignIn(to: .iCloudDrive) }.disabled(model.privateCloudConnectionInProgress)
            Button("Apple Account Settings") { model.openAppleAccountSettings() }.disabled(model.privateCloudConnectionInProgress)
        case .oneDrive:
            LabeledContent("Microsoft Account", value: model.oneDriveAccountLabel)
            Button("Sign In") { beginSignIn(to: .oneDrive) }.disabled(model.privateCloudConnectionInProgress)
            if model.oneDriveAccountLabel != "Not signed in" { Button("Sign Out", role: .destructive) { model.signOutOneDrive() }.disabled(model.privateCloudConnectionInProgress) }
        case .googleDrive:
            LabeledContent("Google Account", value: model.googleDriveAccountLabel)
            Button("Sign In") { beginSignIn(to: .googleDrive) }.disabled(model.privateCloudConnectionInProgress)
            if model.googleDriveAccountLabel != "Not signed in" { Button("Sign Out", role: .destructive) { model.signOutGoogleDrive() }.disabled(model.privateCloudConnectionInProgress) }
        }
    }
    private func beginSignIn(to provider: SyncProvider) {
        guard provider != .none else { return }
        attemptedConnection = true
        switch provider {
        case .oneDrive: model.requestOneDriveSignIn()
        case .googleDrive: model.requestGoogleDriveSignIn()
        case .iCloudDrive: model.connect(to: provider)
        case .none: break
        }
    }
    private func retryConnection() {
        let provider = model.settings.syncProvider ?? .none
        guard provider != .none else { return }
        attemptedConnection = true
        model.connect(to: provider)
    }
    private func finishVerifiedSetupIfReady() {
        guard requiresVerifiedConnection, attemptedConnection, model.privateCloudSetupComplete,
              !model.privateCloudConnectionInProgress, !completingVerifiedSetup else { return }
        completingVerifiedSetup = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard model.privateCloudSetupComplete else { completingVerifiedSetup = false; return }
            model.save()
            dismiss()
            onDone?()
        }
    }
}

private struct LogShareItem: Identifiable { let id = UUID(); let urls: [URL]; init(url: URL) { urls = [url] }; init(urls: [URL]) { self.urls = urls } }

private struct ActivityShareView: UIViewControllerRepresentable {
    let urls: [URL]
    let completion: (Bool) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in completion(completed) }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

struct TrackingView: View {
    @ObservedObject var model: AppModel
    @State private var rows: [OpenRouterRankingRow] = []
    @State private var weeklyRows: [OpenRouterWeeklyRankingRow] = []
    @State private var weeklyModels: [String] = []
    @State private var status = "Public data. No OpenRouter account or API key is required."
    @State private var viewIndex = 0
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
                Text("OpenRouter Rankings").font(.headline)
                Picker("View", selection: $viewIndex) { Text("Top 20 Since Date").tag(0); Text("Weekly Trends").tag(1) }.pickerStyle(.segmented)
                if viewIndex == 0 {
                    DatePicker("From", selection: $customStart, in: ...Calendar.current.date(byAdding: .day, value: -1, to: .now)!, displayedComponents: .date)
                    Text("Data loads when you open this view or tap Refresh.").font(.caption).foregroundStyle(.secondary)
                    HStack { Button("Refresh") { Task { await refresh() } }; Spacer(); Button { prepareTrackingExport() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }.disabled(rows.isEmpty) }
                    ScrollView(.horizontal) {
                        trackingTable.frame(width: 1_068)
                    }
                    Text("Prices are effective weighted averages per 1M tokens, including cache and provider discounts. Revenue is estimated and is not official OpenRouter financial data.").font(.caption).foregroundStyle(.secondary)
                } else {
                    if model.trackingHistoryPreparing {
                        HStack(spacing: 8) { ProgressView(); Text("Preparing tracking history…") }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Metric", selection: $metric) { ForEach(OpenRouterWeeklyMetric.allCases) { Text($0.label).tag($0) } }
                    ScrollView(.horizontal) {
                        Chart {
                            ForEach(weeklyAxisWeeks, id: \.self) { week in
                                RuleMark(x: .value("Week", week)).opacity(0)
                            }
                            ForEach(weeklyRows) { row in
                                weeklyMarks(row)
                            }
                        }
                        .chartForegroundStyleScale(domain: weeklyModels, range: weeklyModelColors)
                        .chartLegend(.hidden)
                        .chartXAxis {
                            AxisMarks(values: weeklyAxisWeeks) { value in
                                AxisGridLine()
                                AxisTick()
                                AxisValueLabel {
                                    if let week = value.as(String.self) { Text(weeklyAxisLabel(week)) }
                                }
                            }
                        }
                        .frame(minWidth: weeklyChartWidth, minHeight: 360)
                    }
                    weeklyModelLegend
                    Text("Weekly data updates during the weekly sync.").font(.caption).foregroundStyle(.secondary)
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
                Text("Source: OpenRouter public rankings").font(.caption)
            }.padding()
        }.navigationTitle("Tracking").task { if viewIndex == 0 && rows.isEmpty { await refresh() } else { await loadWeeks() } }
            .onChange(of: viewIndex) { value in if value == 0 && rows.isEmpty { Task { await refresh() } } else if value == 1 { Task { await loadWeeks() } } }
            .onChange(of: metric) { _ in if viewIndex == 1 { Task { await loadWeeks() } } }
            .onChange(of: model.trackingHistoryPreparing) { preparing in if !preparing && viewIndex == 1 { Task { await loadWeeks() } } }
            .sheet(item: $trackingShare) { item in ActivityShareView(urls: item.urls) { _ in trackingShare = nil } }
    }
    private let weeklyModelColors: [Color] = [
        .blue, .orange, .green, .red, .purple,
        .pink, .teal, .indigo, .mint, .brown
    ]
    private var weeklyChartWidth: CGFloat {
        max(320, CGFloat(Set(weeklyRows.map(\.weekStart)).count) * 32)
    }
    private var weeklyAxisWeeks: [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = STGTime.utc
        formatter.dateFormat = "yyyy-MM-dd"
        guard let latest = weeklyRows.map(\.weekStart).sorted().last.flatMap(formatter.date(from:)) else { return [] }
        return (-12...0).compactMap { offset in
            formatter.calendar.date(byAdding: .weekOfYear, value: offset, to: latest).map { trackingISOWeekLabel(formatter.string(from: $0)) }
        }
    }
    private func weeklyAxisLabel(_ week: String) -> String {
        guard let index = weeklyAxisWeeks.firstIndex(of: week) else { return week }
        let previousYear = index > 0 ? String(weeklyAxisWeeks[index - 1].prefix(4)) : nil
        let includeYear = index == 0 || index == weeklyAxisWeeks.count - 1 || String(week.prefix(4)) != previousYear
        return includeYear ? week : String(week.dropFirst(5))
    }
    private var weeklyModelLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(weeklyModels.enumerated()), id: \.element) { index, name in
                HStack(spacing: 6) {
                    Circle()
                        .fill(weeklyModelColors[index % weeklyModelColors.count])
                        .frame(width: 8, height: 8)
                    Text(name).lineLimit(1)
                }
                .font(.caption2)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityLabel("Models shown in weekly trends")
    }
    private var sortedRows: [OpenRouterRankingRow] { sortedOpenRouterRows(rows, by: sortField, direction: sortDirection) }
    @ChartContentBuilder private func weeklyMarks(_ row: OpenRouterWeeklyRankingRow) -> some ChartContent {
        if let value = metric.value(row) {
            LineMark(x: .value("Week", trackingISOWeekLabel(row.weekStart)), y: .value(metric.label, value))
                .foregroundStyle(by: .value("Model", row.modelPermaslug))
            PointMark(x: .value("Week", trackingISOWeekLabel(row.weekStart)), y: .value(metric.label, value))
                .foregroundStyle(by: .value("Model", row.modelPermaslug))
        }
    }
    private var trackingTable: some View {
        LazyVStack(spacing: 0) {
            trackingHeader
            Divider()
            ForEach(sortedRows) { row in
                trackingRow(row)
                Divider()
            }
        }
    }
    private var trackingHeader: some View {
        HStack(spacing: 0) {
            trackingHeaderButton("Rank", .rank, 58); trackingHeaderButton("Model", .model, 250)
            trackingHeaderButton("Input tokens", .promptTokens, 130); trackingHeaderButton("Output tokens", .completionTokens, 130); trackingHeaderButton("Total tokens", .totalTokens, 130)
            trackingHeaderButton("Input price", .promptPrice, 125); trackingHeaderButton("Output price", .completionPrice, 125); trackingHeaderButton("Estimated Revenue", .revenue, 150)
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
        status = "Loading rankings…"
        SharedEnvironment.diagnosticLog.record("OpenRouter refresh begin; period=date_to_latest", category: "tracking")
        do {
            let latest = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
            let snapshot = try await OpenRouterTrackingService.shared.top20(startDate: trackingDateString(customStart), endDate: trackingDateString(latest))
            rows = snapshot.rows; startDate = snapshot.startDate; endDate = snapshot.endDate
            status = "\(snapshot.startDate) – \(snapshot.endDate) UTC · \(snapshot.citation)"
            SharedEnvironment.diagnosticLog.record("OpenRouter refresh complete; window=\(snapshot.startDate)...\(snapshot.endDate); rows=\(snapshot.rows.count)", category: "tracking")
        } catch { status = error.localizedDescription; SharedEnvironment.diagnosticLog.record("OpenRouter: \(status)", category: "tracking") }
    }
    private func loadWeeks() async {
        guard !model.trackingHistoryPreparing else {
            weeklyRows = []
            weeklyModels = []
            status = "Preparing tracking history…"
            return
        }
        let requestedMetric = metric
        status = "Loading weekly trends…"
        // A yield keeps the tab transition responsive before the chart data is prepared.
        await Task.yield()
        let result = await model.trackingWeeks(metric: requestedMetric)
        guard requestedMetric == metric, viewIndex == 1 else { return }
        let recentWeeks = Set(result.rows.map(\.weekStart).sorted().suffix(13))
        weeklyModels = result.models
        weeklyRows = result.rows.filter { recentWeeks.contains($0.weekStart) }
        status = weeklyRows.isEmpty ? "No weekly data is available for \(requestedMetric.label) yet." : "Showing the latest \(recentWeeks.count) weeks of \(requestedMetric.label) for the top \(result.models.count) models."
    }
    private func prepareTrackingExport() {
        let periodName = "date_to_latest"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stg-openrouter-\(periodName).csv")
        do {
            try openRouterTrackingCSV(rows: sortedRows, period: periodName, startDate: startDate, endDate: endDate).write(to: url, atomically: true, encoding: .utf8)
            trackingShare = LogShareItem(url: url)
        } catch { status = "Export failed. Try again."; SharedEnvironment.diagnosticLog.record("OpenRouter export failed; error=\(error.localizedDescription)", category: "tracking") }
    }
}

private func trackingISOWeekLabel(_ dateText: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: dateText) else { return dateText }
    let components = formatter.calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
    return String(format: "%04d-W%02d", components.yearForWeekOfYear ?? 0, components.weekOfYear ?? 0)
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Spacer(); Image(systemName: "shield.lefthalf.filled").font(.system(size: 64)).foregroundStyle(.blue); Spacer() }
                Text("Screen Time Guardian").font(.title.bold()).frame(maxWidth: .infinity)
                Text("Version 1.1.9\nCopyright © 2026 Fairy Phoenix Foundation.")
                Text("This app records minute-level estimates of screen use on this device or across all your devices, and reminds you to take breaks.")
                Text("Privacy: Your screen-use data stays on this device and, if enabled, in the private cloud you choose. It is never sent to the app developer or any other service.")
                Text("Accuracy: Apple does not make Screen Time data available to third-party apps. STG estimates usage from DeviceActivity data, so its totals may differ from those shown in Settings → Screen Time.")
                Text("Third-Party Software Acknowledgments").bold()
                Text("This app includes SQLite and open-source components from Apple’s Swift project. Their original copyright notices and license terms are preserved. All rights remain with their respective owners. STG claims no ownership of these components.")
                Link("Apple Swift License", destination: URL(string: "https://www.swift.org/LICENSE.txt")!)
                Link("SQLite Copyright and Public-Domain Notice", destination: URL(string: "https://www.sqlite.org/copyright.html")!)
            }.padding()
        }.navigationTitle("About")
    }
}

func duration(_ minutes: Int) -> String { "\(minutes / 60)h \(minutes % 60)m" }
private func countLabel(_ count: Int, singular: String, plural: String? = nil) -> String { "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))" }
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
