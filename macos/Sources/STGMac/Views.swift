import SwiftUI
import Charts
import STGCore
import UniformTypeIdentifiers

enum MacDestination { case report, tracking, settings, about }

struct DashboardView: View {
    @ObservedObject var model: AppModel
    let open: (MacDestination) -> Void
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Screen Time Guardian").font(.largeTitle.bold())
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 14) {
                    card("Report", "All Devices: \(duration(model.allMinutes))\nThis Mac: \(duration(model.localMinutes))", "chart.bar.fill") { open(.report) }
                    card("Tracking", "Latest week · Top models\n\(model.latestTrackingTopTwo)", "waveform.path.ecg") { open(.tracking) }
                    card("Settings", "Daily Limit: \(duration(model.settings.dailyPlanMinutes))\n\(meetingStatus)", "gearshape.fill") { open(.settings) }
                    card("About", "Version 1.1.9\nLocal + private cloud", "info.circle.fill") { open(.about) }
                }
                HStack {
                    Circle().fill(model.isScreenAvailable ? .green : .gray).frame(width: 8)
                    Text(model.syncStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync Now") { Task { await model.synchronize() } }.buttonStyle(.borderedProminent)
                }
            }.padding(24)
        }.frame(minWidth: 680, minHeight: 460)
    }

    private var meetingStatus: String {
        NSLocalizedString(model.settings.meetingMode ? "Meeting Mode: On" : "Meeting auto-detect: On", comment: "Dashboard meeting detection state")
    }

    private func card(_ title: String, _ body: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) { Label(title, systemImage: icon).font(.title2.bold()); Text(body).monospacedDigit(); Spacer() }
                .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading).padding(18).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).contentShape(Rectangle())
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft: STGSettings
    @State private var showCloudSetup = false
    @State private var confirmClose = false
    let close: () -> Void
    init(model: AppModel, close: @escaping () -> Void) { self.model = model; self.close = close; _draft = State(initialValue: model.settings) }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Settings").font(.largeTitle.bold())
                    GroupBox("Daily Limit") {
                        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
                            GridRow { Text("Daily Limit").foregroundStyle(.secondary); HStack { Stepper("Hours: \(draft.dailyPlanMinutes / 60)", value: planHours, in: 0...24); Stepper("Minutes: \(draft.dailyPlanMinutes % 60)", value: planMinutes, in: 0...45, step: 15) }.fixedSize() }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox("Reminder close countdowns") {
                        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
                            GridRow { Text("Eye break").foregroundStyle(.secondary); Stepper("\(draft.eyeCloseCountdownMinutes) minutes", value: $draft.eyeCloseCountdownMinutes, in: 0...10).fixedSize() }
                            GridRow { Text("Posture").foregroundStyle(.secondary); Stepper("\(draft.postureCloseCountdownMinutes) minutes", value: $draft.postureCloseCountdownMinutes, in: 0...10).fixedSize() }
                            GridRow { Text("Daily Limit").foregroundStyle(.secondary); Stepper("\(draft.dailyCloseCountdownMinutes) minutes", value: $draft.dailyCloseCountdownMinutes, in: 0...10).fixedSize() }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox("Notification Options") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Eye Break Notifications", isOn: $draft.eyeNotificationsEnabled)
                            Toggle("Posture Notifications", isOn: $draft.postureNotificationsEnabled)
                            Toggle("Daily Usage Notifications", isOn: $draft.dailyNotificationsEnabled)
                            Text("Usage is still recorded when all options are off.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox("General") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Manual meeting-mode override", isOn: $draft.meetingMode)
                            Toggle("Launch automatically at login", isOn: $draft.launchAtLogin)
                            Text(model.launchAtLoginStatus).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox("Private cloud") {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text((draft.syncProvider ?? .none).displayName).font(.headline)
                                Text(macCloudAccount(provider: draft.syncProvider ?? .none, model: model)).foregroundStyle(.secondary)
                                Text(model.syncStatus).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Button("Configure…") { showCloudSetup = true }
                        }.padding(8)
                    }
                    GroupBox("Diagnostics") {
                        HStack {
                            Text("Export lifecycle, screen-use, reminder, database, and synchronization events without cloud credentials.").foregroundStyle(.secondary)
                            Spacer(); Button("Export App Data…") { model.exportAppData() }; Button("Export Test Log…") { model.exportTestLog() }
                        }.padding(8)
                    }
                }.padding(28)
            }
            Divider()
            HStack(spacing: 12) {
                Spacer()
                Button("Save") { model.settings = draft; model.saveSettings(); draft = model.settings; Task { await model.synchronize() } }.disabled(!hasChanges)
                Button("Close") { if hasChanges { confirmClose = true } else { close() } }.keyboardShortcut(.cancelAction)
            }.padding(18)
        }.frame(minWidth: 780, minHeight: 650)
            .sheet(isPresented: $showCloudSetup) { MacCloudSetupView(model: model, draft: $draft) }
            .alert("Save changes before closing?", isPresented: $confirmClose) {
                Button("Save") { model.settings = draft; model.saveSettings(); close() }
                Button("Discard Changes", role: .destructive) { draft = model.settings; close() }
                Button("Keep Editing", role: .cancel) { }
            }
    }
    private var planHours: Binding<Int> { Binding(get: { draft.dailyPlanMinutes / 60 }, set: { draft.dailyPlanMinutes = min(1_440, max(20, $0 * 60 + draft.dailyPlanMinutes % 60)) }) }
    private var planMinutes: Binding<Int> { Binding(get: { draft.dailyPlanMinutes % 60 }, set: { draft.dailyPlanMinutes = min(1_440, max(20, (draft.dailyPlanMinutes / 60) * 60 + $0)) }) }
    private var hasChanges: Bool { draft != model.settings }
}

@MainActor private func macCloudAccount(provider: SyncProvider, model: AppModel) -> String {
    switch provider { case .none: "Single-device mode"; case .iCloudDrive: model.iCloudAccountLabel; case .oneDrive: model.oneDriveAccountLabel; case .googleDrive: model.googleDriveAccountLabel }
}

struct MacCloudSetupView: View {
    @ObservedObject var model: AppModel
    @Binding var draft: STGSettings
    @Environment(\.dismiss) private var dismiss
    @State private var ios = false
    @State private var android = false
    @State private var windows = false
    @State private var china = false
    private var recommendation: SyncProvider { (android || windows) ? (china ? .oneDrive : .googleDrive) : .iCloudDrive }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure Private Cloud").font(.title.bold())
            Text("Which devices will share this data?").font(.headline)
            Toggle("This Mac", isOn: .constant(true)).disabled(true)
            Toggle("iPhone / iPad", isOn: $ios); Toggle("Android", isOn: $android); Toggle("Windows", isOn: $windows)
            if android || windows { Toggle("I need this to work while travelling in mainland China", isOn: $china) }
            GroupBox("Recommendation") { Text(recommendation.displayName).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
            Picker("Provider", selection: Binding(get: { draft.syncProvider ?? recommendation }, set: { draft.syncProvider = $0; draft.cloudFolderPath = nil })) {
                Text("Off — single device").tag(SyncProvider.none); Text("iCloud Drive").tag(SyncProvider.iCloudDrive); Text("OneDrive").tag(SyncProvider.oneDrive); Text("Google Drive").tag(SyncProvider.googleDrive)
            }
            cloudConnection
            Text(model.syncStatus).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { model.settings = draft; model.saveSettings(); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 580, height: 580)
            .onAppear { if (draft.syncProvider ?? SyncProvider.none) == SyncProvider.none { draft.syncProvider = recommendation } }
            .onChange(of: android) { _, _ in draft.syncProvider = recommendation }
            .onChange(of: windows) { _, _ in draft.syncProvider = recommendation }
            .onChange(of: china) { _, _ in draft.syncProvider = recommendation }
    }
    @ViewBuilder private var cloudConnection: some View {
        switch draft.syncProvider ?? .none {
        case .none: Text("No cloud account will be used.").foregroundStyle(.secondary)
        case .iCloudDrive: LabeledContent("Apple Account", value: model.iCloudAccountLabel); HStack { Button("Connect iCloud Drive") { model.connect(to: .iCloudDrive) }; Button("Apple Account Settings") { model.openAppleAccountSettings() } }
        case .oneDrive: LabeledContent("Microsoft account", value: model.oneDriveAccountLabel); HStack { Button("Sign in") { model.requestOneDriveSignIn() }; if model.oneDriveAccountLabel != "Not signed in" { Button("Sign out") { model.signOutOneDrive() } } }
        case .googleDrive: LabeledContent("Google account", value: model.googleDriveAccountLabel); HStack { Button("Sign in") { model.requestGoogleDriveSignIn() }; if model.googleDriveAccountLabel != "Not signed in" { Button("Sign out") { model.signOutGoogleDrive() } } }
        }
    }
}

struct MacOnboardingView: View {
    @ObservedObject var model: AppModel
    let complete: () -> Void
    @State private var step = 0
    @State private var showCloudSetup = false
    @State private var draft: STGSettings

    init(model: AppModel, complete: @escaping () -> Void) {
        self.model = model; self.complete = complete; _draft = State(initialValue: model.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set Up Screen Time Guardian").font(.largeTitle.bold())
            Text("Step \(step + 1) of 2").foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    if step == 0 {
                        Text("Connect your private cloud?").font(.title2.bold())
                        Text("Private-cloud sync combines screen-use records from your own devices. You can skip this and configure it later.").foregroundStyle(.secondary)
                    } else {
                        Text("Start automatically when you sign in?").font(.title2.bold())
                        Text("Automatic startup keeps minute recording and reminders available after you sign in.").foregroundStyle(.secondary)
                    }
                    if step == 0 {
                        HStack { Button("Set Up Private Cloud") { showCloudSetup = true }; Button("Not Now") { step = 1 } }
                    } else {
                        Toggle("Launch Screen Time Guardian when I sign in", isOn: $draft.launchAtLogin)
                    }
                }.frame(maxWidth: .infinity, minHeight: 180, alignment: .leading).padding(12)
            }
            HStack {
                if step == 1 { Button("Back") { step = 0 } }
                Spacer()
                if step == 1 { Button("Finish") { model.settings = draft; model.saveSettings(); UserDefaults.standard.set(true, forKey: "desktopOnboardingV1Complete"); complete() }.keyboardShortcut(.defaultAction) }
            }
        }.padding(30).frame(width: 620, height: 390)
            .sheet(isPresented: $showCloudSetup, onDismiss: { draft = model.settings; step = 1 }) { MacCloudSetupView(model: model, draft: $draft) }
    }
}

struct ReportView: View {
    @ObservedObject var model: AppModel
    let preferredContentHeightChanged: (CGFloat) -> Void
    @State private var mode = 0
    @State private var selectedDate = Date()
    @State private var rangeStart = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var rangeEnd = Date()
    @State private var dailyBitmaps: [DeviceDayBitmap] = []
    @State private var multiDayPoints: [DailyUsagePoint] = []
    @State private var periodPoints: [DailyUsagePoint] = []
    @State private var unavailablePeriods: [PeriodUsagePoint] = []
    @State private var loading = false
    @State private var showDailyCalendar = false
    init(model: AppModel, preferredContentHeightChanged: @escaping (CGFloat) -> Void = { _ in }) {
        self.model = model
        self.preferredContentHeightChanged = preferredContentHeightChanged
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text("Screen Time Report").font(.title.bold())
                if mode == 0 {
                    summaryMetric("All Devices", dailyBitmaps.first(where: { $0.isAggregate })?.usedMinutes ?? 0)
                    summaryMetric("This Mac", dailyBitmaps.first(where: { $0.deviceID == model.settings.deviceID })?.usedMinutes ?? 0)
                    summaryMetric("Daily Limit", model.settings.dailyPlanMinutes)
                }
                Spacer()
                Button("Sync Now") { Task { await model.synchronize(); await reload() } }
                Button("Export CSV…") { exportReportCSV(text: reportCSV) }
            }
            HStack(spacing: 12) {
                reportModeButton("Daily", index: 0)
                if mode == 0 {
                    Button { showDailyCalendar.toggle() } label: {
                        HStack(spacing: 7) { Image(systemName: "calendar"); Text(selectedDate.formatted(date: .numeric, time: .omitted)).monospacedDigit() }
                    }.popover(isPresented: $showDailyCalendar, arrowEdge: .bottom) {
                        DatePicker("Report date", selection: $selectedDate, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden().padding(14)
                            .onChange(of: selectedDate) { _, _ in showDailyCalendar = false }
                    }
                }
                reportModeButton("Multiple Days", index: 1)
                reportModeButton("Year by Week", index: 2)
                reportModeButton("Years by Month", index: 3)
                if mode == 1 {
                    DatePicker("Start", selection: $rangeStart, displayedComponents: .date)
                    DatePicker("End", selection: $rangeEnd, displayedComponents: .date)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            if mode == 0 {
                HStack(spacing: 12) {
                    averageMetric("This Week", model.statisticsSummary.thisWeekAverageMinutes)
                    averageMetric("Last Week", model.statisticsSummary.lastWeekAverageMinutes)
                    averageMetric("This Month", model.statisticsSummary.thisMonthAverageMinutes)
                    averageMetric("Last Month", model.statisticsSummary.lastMonthAverageMinutes)
                    averageMetric("This Year", model.statisticsSummary.thisYearAverageMinutes)
                    Spacer()
                    if model.statisticsSummary.containsEstimatedIOSData {
                        Label("Estimated: includes iPhone/iPad data", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            GeometryReader { viewport in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if mode == 0 {
                            ForEach(dailyBitmaps) { bitmap in
                                VStack(alignment: .leading, spacing: 4) {
                                    (Text("\(bitmap.displayName), \(duration(bitmap.usedMinutes)).  ").fontWeight(.semibold) + Text("Active intervals: \(usageIntervals(bitmap.minutes, timeZoneID: model.currentReportTimeZone))"))
                                        .font(.callout).textSelection(.enabled)
                                    if bitmap.usedMinutes > 0 {
                                        let bitmapView = MinuteBitmapView(minutes: bitmap.minutes, rowHeight: 24, alignmentMinutes: dailyAlignmentMinutes)
                                        bitmapView.frame(height: bitmapView.preferredHeight, alignment: .topLeading)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))
                            }
                        } else if mode == 1 {
                            Chart(multiDayPoints) { point in
                                LineMark(x: .value("Date", point.date), y: .value("Minutes", point.minutes)).foregroundStyle(by: .value("Device", point.displayName)).symbol(by: .value("Device", point.displayName))
                                PointMark(x: .value("Date", point.date), y: .value("Minutes", point.minutes)).foregroundStyle(by: .value("Device", point.displayName)).annotation(position: .top) { if point.isAggregate { Text(usagePointLabel(point.minutes)).font(.caption2).foregroundStyle(.secondary) } }
                            }.chartYScale(domain: 0...usageAxisMaximum(multiDayPoints)).chartYAxis { usageAxisMarks }.chartLegend(position: .bottom, alignment: .leading)
                                .frame(height: max(360, viewport.size.height - 30)).padding().background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                            if let average = macIntervalAverage(multiDayPoints) { Text("Interval average: \(duration(average)) per day").font(.caption).foregroundStyle(.secondary) }
                        } else {
                            if !unavailablePeriods.isEmpty {
                                DisclosureGroup("— · No eligible completed days") {
                                    ForEach(unavailablePeriods) { value in
                                        Text("\(value.periodLabel) · \(value.displayName): —").font(.caption)
                                    }
                                }
                            }
                            Chart(periodPoints) { point in
                                LineMark(x: .value("Period", point.date), y: .value("Minutes", point.minutes)).foregroundStyle(by: .value("Device", point.displayName)).symbol(by: .value("Device", point.displayName))
                                PointMark(x: .value("Period", point.date), y: .value("Minutes", point.minutes)).foregroundStyle(by: .value("Device", point.displayName)).annotation(position: .top) { if point.isAggregate { Text(usagePointLabel(point.minutes)).font(.caption2).foregroundStyle(.secondary) } }
                            }.chartYScale(domain: 0...usageAxisMaximum(periodPoints)).chartYAxis { usageAxisMarks }.chartLegend(position: .bottom, alignment: .leading)
                                .frame(height: max(360, viewport.size.height - 30)).padding().background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .frame(width: max(940, viewport.size.width - 1), alignment: .topLeading)
                    .frame(minHeight: viewport.size.height, alignment: .topLeading)
                }
            }
            HStack {
                Text(model.syncStatus).font(.caption).foregroundStyle(.secondary)
                Spacer(); if loading { ProgressView().controlSize(.small) }
            }
        }.padding(18).frame(minWidth: 980, minHeight: 500).task { await reload() }
            .onChange(of: mode) { _, _ in Task { await reload() } }
            .onChange(of: selectedDate) { _, _ in if mode == 0 { Task { await reloadDaily() } } }
            .onChange(of: rangeStart) { _, _ in if mode == 1 { Task { await reloadMultiple() } } }
            .onChange(of: rangeEnd) { _, _ in if mode == 1 { Task { await reloadMultiple() } } }
            .onChange(of: preferredContentHeight, initial: true) { _, height in preferredContentHeightChanged(height) }
    }

    private func summaryMetric(_ title: String, _ minutes: Int) -> some View {
        HStack(spacing: 5) { Text(title.uppercased()).font(.caption2).foregroundStyle(.secondary); Text(duration(minutes)).font(.headline).monospacedDigit() }
            .padding(.horizontal, 9).padding(.vertical, 6).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }
    private func usageAxisMaximum(_ points: [DailyUsagePoint]) -> Int { max(60, (((points.map(\.minutes).max() ?? 0) + 59) / 60) * 60) }
    private var usageAxisTicks: [Int] { Array(stride(from: 0, through: max(60, ((((mode == 1 ? multiDayPoints : periodPoints).map(\.minutes).max() ?? 0) + 59) / 60) * 60), by: 60)) }
    @AxisContentBuilder private var usageAxisMarks: some AxisContent {
        AxisMarks(position: .leading, values: usageAxisTicks) { value in AxisGridLine(); AxisTick(); AxisValueLabel { if let minutes = value.as(Int.self) { Text("\(minutes / 60)h") } } }
        AxisMarks(position: .trailing, values: usageAxisTicks) { value in AxisTick(); AxisValueLabel { if let minutes = value.as(Int.self) { Text("\(minutes / 60)h") } } }
    }
    private func usagePointLabel(_ minutes: Int) -> String { String(format: "%.1fh", Double(minutes) / 60) }
    private func averageMetric(_ title: String, _ minutes: Double?) -> some View {
        HStack(spacing: 4) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(minutes.map { duration(Int($0.rounded())) } ?? "—").font(.caption.bold()).monospacedDigit() }
    }
    @ViewBuilder private func reportModeButton(_ title: String, index: Int) -> some View {
        if mode == index {
            Button(title) { mode = index }.buttonStyle(.borderedProminent)
        } else {
            Button(title) { mode = index }.buttonStyle(.bordered)
        }
    }
    private func reload() async { if mode == 0 { await reloadDaily() } else if mode == 1 { await reloadMultiple() } else { await reloadPeriod() } }
    private func reloadDaily() async { loading = true; dailyBitmaps = await model.reportDay(at: macReportInstant(selectedDate, zone: model.currentReportTimeZone)); loading = false }
    private func reloadMultiple() async { loading = true; multiDayPoints = await model.multiDayReport(from: macReportInstant(rangeStart, zone: model.currentReportTimeZone), through: macReportInstant(rangeEnd, zone: model.currentReportTimeZone)); loading = false }
    private func reloadPeriod() async {
        loading = true
        let calendar = Calendar.current, now = Date()
        let start = mode == 2 ? (calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: 1, day: 1)) ?? now) : (calendar.date(byAdding: .year, value: -2, to: now) ?? now)
        let values = await model.periodReport(kind: mode == 2 ? "week" : "month", from: start, through: now)
        unavailablePeriods = values.filter { $0.includedDays == 0 }
        periodPoints = values.compactMap(macPeriodChartPoint)
        loading = false
    }
    private var preferredContentHeight: CGFloat {
        guard mode == 0 else { return 720 }
        let cardsHeight = dailyBitmaps.reduce(CGFloat.zero) { total, bitmap in
            let bitmapHeight = bitmap.usedMinutes > 0 ? MinuteBitmapView(minutes: bitmap.minutes, rowHeight: 24, alignmentMinutes: dailyAlignmentMinutes).preferredHeight : 0
            return total + bitmapHeight + 35
        }
        let gaps = CGFloat(max(0, dailyBitmaps.count - 1)) * 12
        return min(760, max(500, 162 + cardsHeight + gaps))
    }
    private var dailyAlignmentMinutes: [Bool] {
        if let aggregate = dailyBitmaps.first(where: \.isAggregate) { return aggregate.minutes }
        let count = dailyBitmaps.map(\.minutes.count).max() ?? 0
        guard count > 0 else { return [] }
        var combined = [Bool](repeating: false, count: count)
        for bitmap in dailyBitmaps {
            for index in 0..<min(count, bitmap.minutes.count) where bitmap.minutes[index] { combined[index] = true }
        }
        return combined
    }
    private var reportCSV: String {
        if mode == 1 { return (["date,device_id,device_name,minutes,report_timezone,estimated"] + multiDayPoints.map { "\($0.dateLabel),\($0.deviceID),\($0.displayName.replacingOccurrences(of: ",", with: " ")),\($0.minutes),\(model.currentReportTimeZone),\($0.estimated)" }).joined(separator: "\n") + "\n" }
        if mode > 1 { return (["period,device_id,device_name,average_daily_minutes,estimated"] + periodPoints.map { "\($0.dateLabel),\($0.deviceID),\($0.displayName.replacingOccurrences(of: ",", with: " ")),\($0.minutes),\($0.estimated)" }).joined(separator: "\n") + "\n" }
        let date = macReportDateString(selectedDate, zone: model.currentReportTimeZone)
        return (["date,device_id,device_name,minutes,report_timezone,estimated,bitmap"] + dailyBitmaps.map { bitmap in "\(date),\(bitmap.deviceID),\(bitmap.displayName.replacingOccurrences(of: ",", with: " ")),\(bitmap.usedMinutes),\(model.currentReportTimeZone),true,\(bitmap.minutes.map { $0 ? "1" : "0" }.joined())" }).joined(separator: "\n") + "\n"
    }

}

private func macPeriodChartPoint(_ value: PeriodUsagePoint) -> DailyUsagePoint? {
    guard value.includedDays > 0 else { return nil }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: value.periodStart) else { return nil }
    return DailyUsagePoint(date: date, dateLabel: value.periodLabel, deviceID: value.deviceID, displayName: value.displayName, minutes: Int(value.averageDailyMinutes.rounded()), isAggregate: value.deviceID == "alldevices", estimated: value.estimated)
}

private func macIntervalAverage(_ points: [DailyUsagePoint]) -> Int? {
    let values = points.filter(\.isAggregate).map(\.minutes)
    return values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
}

struct MinuteBitmapView: View {
    let minutes: [Bool]
    var rowHeight: CGFloat = 22
    var alignmentMinutes: [Bool]? = nil

    var preferredHeight: CGFloat {
        let count = visibleSegments.count
        return count == 0 ? 17 : CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * 3
    }

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
                Text("No Activity").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(segments) { segment in
                        GeometryReader { proxy in
                            ZStack(alignment: .topLeading) {
                                ForEach(segment.hourBoundaries, id: \.self) { boundary in
                                    let progress = CGFloat(boundary - segment.startMinute) / CGFloat(segment.minuteCount)
                                    Text(String(format: "%02d", boundary / 60))
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .position(x: min(proxy.size.width - 9, max(9, progress * proxy.size.width)), y: 6)
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
                                        context.stroke(tick, with: .color(.secondary.opacity(isHour ? 0.42 : (isHalfHour ? 0.28 : 0.17))), lineWidth: isHour ? 0.8 : 0.5)
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
                                                context.stroke(run, with: .color(.accentColor.opacity(0.82)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                                            }
                                            runStart = nil
                                        }
                                    }

                                    for offset in 0..<segment.minuteCount {
                                        let index = segment.startMinute + offset
                                        let active = index < minutes.count && minutes[index]
                                        let radius: CGFloat = active ? 1.25 : 0.62
                                        let center = CGPoint(x: (CGFloat(offset) + 0.5) * minuteWidth, y: baselineY)
                                        let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                                        context.fill(dot, with: .color(active ? .accentColor : .secondary.opacity(0.22)))
                                    }
                                }
                                .frame(height: max(14, rowHeight - 9))
                                .offset(y: 11)
                            }
                        }
                        .frame(height: rowHeight)
                        .accessibilityLabel(segmentAccessibilityLabel(segment))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var visibleSegments: [Segment] {
        let source = alignmentMinutes ?? minutes
        let count = min(source.count, 1_440)
        var result: [Segment] = []
        var cursor = 0
        while cursor < count {
            guard let firstActive = (cursor..<count).first(where: { source[$0] }) else { break }
            let start = (firstActive / 60) * 60
            let end = min(start + 360, 1_440)
            result.append(Segment(startMinute: start, endMinute: end))
            cursor = end
        }
        return result
    }

    private func segmentAccessibilityLabel(_ segment: Segment) -> String {
        let used = (segment.startMinute..<min(segment.endMinute, minutes.count)).reduce(into: 0) { if minutes[$1] { $0 += 1 } }
        return "\(STGTime.localClockLabel(minute: segment.startMinute))–\(STGTime.localClockLabel(minute: segment.endMinute)), \(used) active minutes"
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Spacer(); Image(systemName: "shield.lefthalf.filled").font(.system(size: 56)).foregroundStyle(.blue); Spacer() }
                Text("Screen Time Guardian").font(.title.bold()).frame(maxWidth: .infinity)
                Text("Version 1.1.9\nCopyright © 2026 Fairy Phoenix Foundation.")
                Text("This app records minute-level estimates of screen use, either on this Mac alone or across your devices, and reminds you to take breaks.")
                Text("Privacy: Your screen-use data remains on this Mac and, if enabled, in your chosen private-cloud account. STG does not send it to the developer or anyone else.")
                Text("Accuracy: STG estimates screen use from macOS activity signals, so its totals may differ from other system usage statistics.")
                Text("Third-Party Software Acknowledgments").bold()
                Text("This app includes SQLite and open-source components from Apple’s Swift project. Their original copyright notices and license terms are preserved. All rights remain with their respective owners. STG claims no ownership of these components.")
                Link("Open-source licenses", destination: URL(string: "https://www.swift.org/LICENSE.txt")!)
            }.padding(30)
        }.frame(width: 580, height: 500)
    }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OpenRouter Tracking").font(.largeTitle.bold())
            Picker("View", selection: $viewIndex) { Text("Top 20 Since Date").tag(0); Text("Weekly Trends").tag(1) }.pickerStyle(.segmented)
            if viewIndex == 0 {
                HStack {
                    DatePicker("Start", selection: $customStart, displayedComponents: .date)
                    Text("through the latest completed UTC day").foregroundStyle(.secondary)
                    Spacer(); Button("Export CSV…") { exportTrackingCSV(rows: sortedRows, period: "date_to_latest", startDate: startDate, endDate: endDate) }.disabled(rows.isEmpty)
                    Button("Refresh") { Task { await refresh() } }
                }
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0) { trackingHeader; Divider(); ForEach(sortedRows) { row in trackingRow(row); Divider() } }.frame(width: 1_068)
                }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                Text("Prices are OpenRouter's observed effective weighted prices (including cache and provider discounts). Revenue is an estimate, not OpenRouter financial reporting.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("Value", selection: $metric) { ForEach(OpenRouterWeeklyMetric.allCases) { Text($0.label).tag($0) } }.frame(width: 260)
                    Spacer(); Button("Export CSV…") { exportWeeklyTrackingCSV(rows: weeklyRows) }.disabled(weeklyRows.isEmpty)
                    Text("Updated by the weekly action in incremental sync").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView([.horizontal, .vertical]) {
                    Chart(weeklyRows) { row in
                        if let value = metric.value(row) {
                            LineMark(x: .value("Week", trackingISOWeekLabel(row.weekStart)), y: .value(metric.label, value))
                                .foregroundStyle(by: .value("Model", row.modelPermaslug))
                            PointMark(x: .value("Week", trackingISOWeekLabel(row.weekStart)), y: .value(metric.label, value))
                                .foregroundStyle(by: .value("Model", row.modelPermaslug))
                        }
                    }
                    .chartLegend(position: .trailing, alignment: .top)
                    .chartXAxis {
                        AxisMarks(values: weeklyAxisWeeks) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let week = value.as(String.self) { Text(weeklyAxisLabel(week)) }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine(); AxisTick()
                            AxisValueLabel { if let number = value.as(Double.self) { Text(trackingAxisLabel(number)) } }
                        }
                    }
                    .frame(width: weeklyChartWidth, height: 460).padding()
                }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 1_100, minHeight: 600)
            .task { loadWeeks() }
            .onChange(of: viewIndex) { _, value in
                if value == 0 && rows.isEmpty { Task { await refresh() } }
                else if value == 1 { loadWeeks() }
            }
            .onChange(of: metric) { _, _ in if viewIndex == 1 { loadWeeks() } }
    }
    private var sortedRows: [OpenRouterRankingRow] { sortedOpenRouterRows(rows, by: sortField, direction: sortDirection) }
    private var weeklyChartWidth: CGFloat {
        max(980, CGFloat(Set(weeklyRows.map(\.weekStart)).count) * 72 + 300)
    }
    private var weeklyAxisWeeks: [String] {
        Array(Set(weeklyRows.map { trackingISOWeekLabel($0.weekStart) })).sorted()
    }
    private func weeklyAxisLabel(_ week: String) -> String {
        guard let index = weeklyAxisWeeks.firstIndex(of: week) else { return week }
        let previousYear = index > 0 ? String(weeklyAxisWeeks[index - 1].prefix(4)) : nil
        let includeYear = index == 0 || index == weeklyAxisWeeks.count - 1 || String(week.prefix(4)) != previousYear
        return includeYear ? week : String(week.dropFirst(5))
    }
    private func trackingAxisLabel(_ value: Double) -> String {
        if metric == .promptPrice || metric == .completionPrice { return String(format: "$%.2f", value) }
        if metric == .revenue { return String(format: "$%.0f", value) }
        if value >= 1_000_000_000_000 { return String(format: "%.1f Trillion", value / 1_000_000_000_000) }
        if value >= 1_000_000_000 { return String(format: "%.1f Billion", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f Million", value / 1_000_000) }
        return String(format: "%.0f", value)
    }
    private var trackingHeader: some View {
        HStack(spacing: 0) {
            trackingHeaderButton("Rank", .rank, 58); trackingHeaderButton("Model", .model, 250)
            trackingHeaderButton("Input tokens", .promptTokens, 130); trackingHeaderButton("Output tokens", .completionTokens, 130); trackingHeaderButton("Total tokens", .totalTokens, 130)
            trackingHeaderButton("Input price", .promptPrice, 125); trackingHeaderButton("Output price", .completionPrice, 125); trackingHeaderButton("Estimated Revenue", .revenue, 150)
        }.font(.caption.bold()).padding(.vertical, 8)
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
        }.font(.caption.monospacedDigit()).padding(.vertical, 6)
    }
    private func trackingCell(_ text: String, _ width: CGFloat, leading: Bool = false) -> some View { Text(text).lineLimit(1).padding(.horizontal, 5).frame(width: width, alignment: leading ? .leading : .trailing) }
    private func refresh() async {
        status = "Loading public ranking data…"; model.diagnosticLog.record("OpenRouter refresh begin; period=date_to_latest", category: "tracking")
        do {
            let end = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
            let snapshot = try await OpenRouterTrackingService.shared.top20(startDate: trackingDateString(customStart), endDate: trackingDateString(end))
            rows = snapshot.rows; startDate = snapshot.startDate; endDate = snapshot.endDate; status = "\(snapshot.startDate) – \(snapshot.endDate) UTC · \(snapshot.citation)"; model.diagnosticLog.record("OpenRouter refresh complete; window=\(snapshot.startDate)...\(snapshot.endDate); rows=\(snapshot.rows.count)", category: "tracking")
        }
        catch { status = error.localizedDescription; model.diagnosticLog.record("OpenRouter refresh failed: \(error.localizedDescription)", category: "tracking") }
    }
    private func loadWeeks() {
        let models = model.latestOpenRouterTopModels(metric: metric)
        weeklyRows = model.openRouterWeeks(models: models)
        status = weeklyRows.isEmpty ? "No saved weekly data contains \(metric.label). The weekly action will add it when OpenRouter publishes that field." : "Showing all saved weeks for the latest completed week's \(metric.label) Top \(models.count)."
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

struct ReminderView: View {
    let decision: ReminderDecision
    @State private var remaining: Int
    let close: () -> Void
    init(decision: ReminderDecision, close: @escaping () -> Void) { self.decision = decision; self.close = close; _remaining = State(initialValue: decision.silent ? 0 : decision.closeCountdownMinutes * 60) }
    var body: some View {
        VStack(spacing: 18) { Image(systemName: icon).font(.system(size: 50)).foregroundStyle(.blue); Text(title).font(.largeTitle.bold()); Text(message).font(.title3).multilineTextAlignment(.center); if decision.silent { Text("Meeting mode: can close immediately") } else if remaining > 0 { Text("Close available in \(remaining)s").monospacedDigit() }; Button("Close", action: close).disabled(remaining > 0) }
            .padding(32).frame(width: 520, height: 360).task { while remaining > 0 { try? await Task.sleep(for: .seconds(1)); remaining -= 1 } }
    }
    private var title: String { decision.kind == .eye ? "Eye Break" : decision.kind == .posture ? "Posture Break" : "Daily Limit Reached" }
    private var message: String { decision.kind == .eye ? "Look 20 feet away for 20 seconds." : decision.kind == .posture ? "Stand or walk for 4 minutes and rest your eyes." : "You've used your screen for \(duration(decision.usedMinutes)). Take a 5-minute walk." }
    private var icon: String { decision.kind == .eye ? "eye" : decision.kind == .posture ? "figure.walk" : "clock.badge.exclamationmark" }
}

func duration(_ minutes: Int) -> String { "\(minutes / 60)h \(minutes % 60)m" }

private func trackingPeriodName(_ index: Int) -> String { index == 0 ? "previous_week" : index == 1 ? "previous_month" : "custom_range" }
private func trackingDateString(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

func tokenCount(_ value: Int64) -> String { value.formatted(.number.notation(.compactName)) }
func pricePerMillion(_ value: Double?) -> String { value.map { String(format: "$%.4f/M", $0 * 1_000_000) } ?? "N/A" }
func usd(_ value: Double?) -> String { formattedWholeDollarUSD(value) }

func usageIntervals(_ minutes: [Bool], timeZoneID: String) -> String {
    guard minutes.contains(true) else { return "None" }
    var ranges: [String] = []; var index = 0
    while index < minutes.count {
        guard minutes[index] else { index += 1; continue }
        let start = index; while index < minutes.count && minutes[index] { index += 1 }
        ranges.append("\(STGTime.localClockLabel(minute: start))–\(STGTime.localClockLabel(minute: index))")
    }
    return ranges.joined(separator: ", ")
}

@MainActor private func exportTrackingCSV(rows: [OpenRouterRankingRow], period: String, startDate: String, endDate: String) {
    let panel = NSSavePanel(); panel.nameFieldStringValue = "stg-openrouter-\(period).csv"; panel.allowedContentTypes = [.commaSeparatedText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? openRouterTrackingCSV(rows: rows, period: period, startDate: startDate, endDate: endDate).write(to: url, atomically: true, encoding: .utf8)
}

@MainActor private func exportWeeklyTrackingCSV(rows: [OpenRouterWeeklyRankingRow]) {
    let panel = NSSavePanel(); panel.nameFieldStringValue = "stg-openrouter-weekly-trends.csv"; panel.allowedContentTypes = [.commaSeparatedText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    var lines = ["week_start_utc,week_end_utc,rank,model,input_tokens,output_tokens,total_tokens,input_price_usd_per_token,output_price_usd_per_token,estimated_revenue_usd"]
    lines += rows.sorted { $0.weekStart == $1.weekStart ? $0.rank < $1.rank : $0.weekStart < $1.weekStart }.map { row in
        let model = "\"\(row.modelPermaslug.replacingOccurrences(of: "\"", with: "\"\""))\""
        let promptPrice = row.promptPricePerToken.map { String($0) } ?? ""
        let completionPrice = row.completionPricePerToken.map { String($0) } ?? ""
        let revenue = row.revenueUSD.map { String($0) } ?? ""
        let fields = [row.weekStart, row.weekEnd, String(row.rank), model, String(row.promptTokens), String(row.completionTokens), String(row.totalTokens), promptPrice, completionPrice, revenue]
        return fields.joined(separator: ",")
    }
    try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

@MainActor private func exportCSV(model: AppModel) {
    let panel = NSSavePanel(); panel.nameFieldStringValue = "stg-report.csv"; panel.allowedContentTypes = [.commaSeparatedText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    var lines = ["device_id,device_name,minutes,report_timezone,estimated,bitmap"]
    lines += model.dayBitmaps.map { bitmap in
        let bits = bitmap.minutes.map { $0 ? "1" : "0" }.joined()
        return "\(bitmap.deviceID),\(bitmap.displayName.replacingOccurrences(of: ",", with: " ")),\(bitmap.usedMinutes),\(model.currentReportTimeZone),\(bitmap.isAggregate),\(bits)"
    }
    let text = lines.joined(separator: "\n") + "\n"
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

private func macReportInstant(_ pickedDate: Date, zone: String) -> Date {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: pickedDate)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone) ?? .current
    return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)) ?? pickedDate
}

private func macReportDateString(_ date: Date, zone: String) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: zone) ?? .current; formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: macReportInstant(date, zone: zone))
}

@MainActor private func exportReportCSV(text: String) {
    let panel = NSSavePanel(); panel.nameFieldStringValue = "stg-report.csv"; panel.allowedContentTypes = [.commaSeparatedText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? text.write(to: url, atomically: true, encoding: .utf8)
}
