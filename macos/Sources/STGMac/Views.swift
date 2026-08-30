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
                    card("Report", "All devices today: \(duration(model.allMinutes))\nThis Mac: \(duration(model.localMinutes))\nPlan: \(duration(model.settings.dailyPlanMinutes))", "chart.bar.fill") { open(.report) }
                    card("Tracking", "OpenRouter public model rankings\nNo API key needed", "waveform.path.ecg") { open(.tracking) }
                    card("Settings", "Report timezone: \(model.settings.reportTimeZone)\nMeeting mode: \(model.settings.meetingMode ? "On" : "Off")", "gearshape.fill") { open(.settings) }
                    card("About", "Version 1.1.6\nLocal + private cloud", "info.circle.fill") { open(.about) }
                }
                HStack {
                    Circle().fill(model.isScreenAvailable ? .green : .gray).frame(width: 8)
                    Text(model.syncStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync now") { Task { await model.synchronize() } }.buttonStyle(.borderedProminent)
                }
            }.padding(24)
        }.frame(minWidth: 680, minHeight: 460)
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
    let close: () -> Void
    init(model: AppModel, close: @escaping () -> Void) { self.model = model; self.close = close; _draft = State(initialValue: model.settings) }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Settings").font(.largeTitle.bold())
                    GroupBox("Plan and report") {
                        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
                            GridRow { Text("Daily plan").foregroundStyle(.secondary); HStack { Stepper("Hours: \(draft.dailyPlanMinutes / 60)", value: planHours, in: 0...24); Stepper("Minutes: \(draft.dailyPlanMinutes % 60)", value: planMinutes, in: 0...59, step: 5) }.fixedSize() }
                            GridRow { Text("Report timezone").foregroundStyle(.secondary); TextField("IANA timezone", text: $draft.reportTimeZone).frame(minWidth: 360) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox("Reminder close countdowns") {
                        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
                            GridRow { Text("Eye break").foregroundStyle(.secondary); Stepper("\(draft.eyeCloseCountdownMinutes) minutes", value: $draft.eyeCloseCountdownMinutes, in: 0...10).fixedSize() }
                            GridRow { Text("Posture").foregroundStyle(.secondary); Stepper("\(draft.postureCloseCountdownMinutes) minutes", value: $draft.postureCloseCountdownMinutes, in: 0...10).fixedSize() }
                            GridRow { Text("Daily limit").foregroundStyle(.secondary); Stepper("\(draft.dailyCloseCountdownMinutes) minutes", value: $draft.dailyCloseCountdownMinutes, in: 0...10).fixedSize() }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox("General") { VStack(alignment: .leading, spacing: 12) { Toggle("Manual meeting-mode override", isOn: $draft.meetingMode); Toggle("Launch automatically at login", isOn: $draft.launchAtLogin) }.frame(maxWidth: .infinity, alignment: .leading).padding(8) }
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
                }.padding(28)
            }
            Divider()
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { draft = model.settings; close() }.keyboardShortcut(.cancelAction)
                Button("Save") { model.settings = draft; model.saveSettings(); Task { await model.synchronize() }; close() }.keyboardShortcut(.defaultAction)
            }.padding(18)
        }.frame(minWidth: 780, minHeight: 650)
            .sheet(isPresented: $showCloudSetup) { MacCloudSetupView(model: model, draft: $draft) }
    }
    private var planHours: Binding<Int> { Binding(get: { draft.dailyPlanMinutes / 60 }, set: { draft.dailyPlanMinutes = min(1_440, max(20, $0 * 60 + draft.dailyPlanMinutes % 60)) }) }
    private var planMinutes: Binding<Int> { Binding(get: { draft.dailyPlanMinutes % 60 }, set: { draft.dailyPlanMinutes = min(1_440, max(20, (draft.dailyPlanMinutes / 60) * 60 + $0)) }) }
}

@MainActor private func macCloudAccount(provider: SyncProvider, model: AppModel) -> String {
    switch provider { case .none: "Single-device mode"; case .iCloudDrive: model.iCloudAccountLabel; case .oneDrive: model.oneDriveAccountLabel; case .googleDrive: model.googleDriveAccountLabel }
}

private struct MacCloudSetupView: View {
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
            Text("Configure private cloud").font(.title.bold())
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
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Screen Time Report").font(.largeTitle.bold()); Spacer(); Picker("Report type", selection: $mode) { Text("Daily").tag(0); Text("Multiple days").tag(1) }.pickerStyle(.segmented).frame(width: 300) }
            Text("Report timezone: \(model.settings.reportTimeZone)").foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if mode == 0 {
                        DatePicker("Report date", selection: $selectedDate, displayedComponents: .date).frame(maxWidth: 260)
                        HStack(spacing: 12) {
                            summaryMetric("All devices", dailyBitmaps.first(where: { $0.isAggregate })?.usedMinutes ?? 0)
                            summaryMetric("This Mac", dailyBitmaps.first(where: { $0.deviceID == model.settings.deviceID })?.usedMinutes ?? 0)
                            summaryMetric("Daily plan", model.settings.dailyPlanMinutes)
                        }
                        ForEach(dailyBitmaps) { bitmap in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(bitmap.displayName).font(.headline); Spacer(); Text(duration(bitmap.usedMinutes)).monospacedDigit() }
                                MinuteBitmapView(minutes: bitmap.minutes)
                                Text("Active intervals: \(usageIntervals(bitmap.minutes, timeZoneID: model.settings.reportTimeZone))").font(.caption).textSelection(.enabled)
                            }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        }
                    } else {
                        HStack { DatePicker("Start", selection: $rangeStart, displayedComponents: .date); DatePicker("End", selection: $rangeEnd, displayedComponents: .date); Spacer() }
                        Text("One line per device; All devices is the deduplicated device-set line.").font(.caption).foregroundStyle(.secondary)
                        Chart(multiDayPoints) { point in
                            LineMark(x: .value("Date", point.date), y: .value("Minutes", point.minutes)).foregroundStyle(by: .value("Device", point.displayName)).symbol(by: .value("Device", point.displayName))
                            PointMark(x: .value("Date", point.date), y: .value("Minutes", point.minutes)).foregroundStyle(by: .value("Device", point.displayName))
                        }.chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine(); AxisTick(); AxisValueLabel { if let minutes = value.as(Int.self) { Text(duration(minutes)) } } } }.chartLegend(position: .bottom, alignment: .leading).frame(height: 360).padding().background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            HStack {
                Text(model.syncStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Sync now") { Task { await model.synchronize() } }
                Button("Refresh") { Task { await reload() } }
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(reportCSV, forType: .string) }
                Button("Export CSV") { exportReportCSV(text: reportCSV) }
            }
        }.padding(28).frame(minWidth: 900, minHeight: 650).task { await reload() }
            .onChange(of: mode) { _, _ in Task { await reload() } }
            .onChange(of: selectedDate) { _, _ in if mode == 0 { Task { await reloadDaily() } } }
            .onChange(of: rangeStart) { _, _ in if mode == 1 { Task { await reloadMultiple() } } }
            .onChange(of: rangeEnd) { _, _ in if mode == 1 { Task { await reloadMultiple() } } }
    }

    private func summaryMetric(_ title: String, _ minutes: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(duration(minutes)).font(.title2.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
    private func reload() async { if mode == 0 { await reloadDaily() } else { await reloadMultiple() } }
    private func reloadDaily() async { loading = true; dailyBitmaps = await model.reportDay(at: macReportInstant(selectedDate, zone: model.settings.reportTimeZone)); loading = false }
    private func reloadMultiple() async { loading = true; multiDayPoints = await model.multiDayReport(from: macReportInstant(rangeStart, zone: model.settings.reportTimeZone), through: macReportInstant(rangeEnd, zone: model.settings.reportTimeZone)); loading = false }
    private var reportCSV: String {
        if mode == 1 { return (["date,device_id,device_name,minutes,report_timezone,estimated"] + multiDayPoints.map { "\($0.dateLabel),\($0.deviceID),\($0.displayName.replacingOccurrences(of: ",", with: " ")),\($0.minutes),\(model.settings.reportTimeZone),true" }).joined(separator: "\n") + "\n" }
        let date = macReportDateString(selectedDate, zone: model.settings.reportTimeZone)
        return (["date,device_id,device_name,minutes,report_timezone,estimated,bitmap"] + dailyBitmaps.map { bitmap in "\(date),\(bitmap.deviceID),\(bitmap.displayName.replacingOccurrences(of: ",", with: " ")),\(bitmap.usedMinutes),\(model.settings.reportTimeZone),true,\(bitmap.minutes.map { $0 ? "1" : "0" }.joined())" }).joined(separator: "\n") + "\n"
    }
}

struct MinuteBitmapView: View {
    let minutes: [Bool]
    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 7) {
                        Text(String(format: "%02d–%02d", row * 6, (row + 1) * 6)).font(.caption2).frame(width: 42, alignment: .leading)
                        VStack(spacing: 1) {
                            HStack(spacing: 0) { ForEach(0..<6, id: \.self) { hour in Text(String(format: "%02d:00", row * 6 + hour)).font(.system(size: 8)).frame(width: 150, alignment: .leading) } }
                            Canvas { context, size in
                                let cellWidth = size.width / 360
                                for offset in 0..<360 {
                                    let index = row * 360 + offset
                                    let rect = CGRect(x: CGFloat(offset) * cellWidth, y: 0, width: max(1, cellWidth - 0.35), height: size.height)
                                    context.fill(Path(rect), with: .color(index < minutes.count && minutes[index] ? .accentColor : Color.secondary.opacity(0.14)))
                                }
                                for hour in 0...6 { let x = CGFloat(hour) * size.width / 6; var path = Path(); path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: size.height)); context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 0.5) }
                            }.frame(width: 900, height: 12)
                        }
                    }
                }
            }
        }.accessibilityLabel("\(minutes.filter { $0 }.count) used minutes out of \(minutes.count)")
    }
}

struct AboutView: View {
    let exportLog: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Spacer(); Image(systemName: "shield.lefthalf.filled").font(.system(size: 56)).foregroundStyle(.blue); Spacer() }
                Text("Screen Time Guardian").font(.title.bold()).frame(maxWidth: .infinity)
                Text("Version 1.1.6 · Developer: TimberTrail\nCopyright © 2026 TimberTrail.")
                Text("Screen Time Guardian records minute-level screen-use estimates, reminds you to rest, and can combine data from your own devices.")
                Text("Privacy: screen-use data remains on this device and in the private-cloud account you explicitly authorize. It is not uploaded to the app developer.")
                Text("Accuracy: iOS minute maps and cross-device deduplication are estimates. Daily reminder calculations reset at local midnight.")
                Text("Open-source claim: this application includes SQLite (public domain) and Apple Swift open-source runtime components. Their copyright notices and license terms are preserved in THIRD_PARTY_NOTICES.md. STG does not claim ownership of those components.")
                HStack { Button("Export Test Log…", action: exportLog); Link("Open-source licenses", destination: URL(string: "https://www.swift.org/LICENSE.txt")!) }
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
    @State private var metric: WeeklyTrackingMetric = .totalTokens
    @State private var sortField: TrackingSortField = .rank
    @State private var sortDirection: TrackingSortDirection = .ascending
    @State private var startDate = ""
    @State private var endDate = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OpenRouter Tracking").font(.largeTitle.bold())
            Picker("View", selection: $viewIndex) { Text("Top 20 from date").tag(0); Text("Weekly trends").tag(1) }.pickerStyle(.segmented)
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
                    Picker("Value", selection: $metric) { ForEach(WeeklyTrackingMetric.allCases) { Text($0.label).tag($0) } }.frame(width: 260)
                    Spacer(); Button("Export CSV…") { exportWeeklyTrackingCSV(rows: weeklyRows) }.disabled(weeklyRows.isEmpty)
                    Text("Updated by the weekly action in incremental sync").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView([.horizontal, .vertical]) {
                    Chart(weeklyRows) { row in
                        if let value = metric.value(row) {
                            LineMark(x: .value("Week", row.weekStart), y: .value(metric.label, value))
                                .foregroundStyle(by: .value("Model", row.modelPermaslug))
                            PointMark(x: .value("Week", row.weekStart), y: .value(metric.label, value))
                                .foregroundStyle(by: .value("Model", row.modelPermaslug))
                        }
                    }.chartLegend(position: .trailing, alignment: .top).frame(minWidth: 980, minHeight: 460).padding()
                }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 1_100, minHeight: 600)
            .task { loadWeeks() }
            .onChange(of: viewIndex) { _, value in
                if value == 0 && rows.isEmpty { Task { await refresh() } }
                else if value == 1 { loadWeeks() }
            }
    }
    private var sortedRows: [OpenRouterRankingRow] { sortedOpenRouterRows(rows, by: sortField, direction: sortDirection) }
    private var trackingHeader: some View {
        HStack(spacing: 0) {
            trackingHeaderButton("Rank", .rank, 58); trackingHeaderButton("Model", .model, 250)
            trackingHeaderButton("Input tokens", .promptTokens, 130); trackingHeaderButton("Output tokens", .completionTokens, 130); trackingHeaderButton("Total tokens", .totalTokens, 130)
            trackingHeaderButton("Input price", .promptPrice, 125); trackingHeaderButton("Output price", .completionPrice, 125); trackingHeaderButton("Revenue", .revenue, 120)
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
            loadWeeks()
        }
        catch { status = error.localizedDescription; model.diagnosticLog.record("OpenRouter refresh failed: \(error.localizedDescription)", category: "tracking") }
    }
    private func loadWeeks() {
        let models = rows.isEmpty ? model.latestOpenRouterTopModels() : Array(rows.sorted { $0.rank < $1.rank }.prefix(10).map(\.modelPermaslug))
        weeklyRows = model.openRouterWeeks(models: models)
        status = weeklyRows.isEmpty ? "Weekly data will be collected by the weekly action during incremental sync." : "Showing saved weekly data for the latest Top 10 models. Historical seed data contains Rank and Total tokens; OpenRouter does not publish its historical input/output split and returned no rows for 2025-06-15 or 2025-07-15."
    }
}

private enum WeeklyTrackingMetric: String, CaseIterable, Identifiable {
    case rank, promptTokens, completionTokens, totalTokens, promptPrice, completionPrice, revenue
    var id: String { rawValue }
    var label: String { switch self { case .rank: "Rank"; case .promptTokens: "Input tokens"; case .completionTokens: "Output tokens"; case .totalTokens: "Total tokens"; case .promptPrice: "Input price / M"; case .completionPrice: "Output price / M"; case .revenue: "Revenue" } }
    func value(_ row: OpenRouterWeeklyRankingRow) -> Double? { switch self { case .rank: Double(row.rank); case .promptTokens: row.hasTokenBreakdown ? Double(row.promptTokens) : nil; case .completionTokens: row.hasTokenBreakdown ? Double(row.completionTokens) : nil; case .totalTokens: Double(row.totalTokens); case .promptPrice: row.promptPricePerToken.map { $0 * 1_000_000 }; case .completionPrice: row.completionPricePerToken.map { $0 * 1_000_000 }; case .revenue: row.revenueUSD } }
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
    private var title: String { decision.kind == .eye ? "Time for an Eye Break" : decision.kind == .posture ? "Stand Up & Stretch" : "Daily Limit Reached" }
    private var message: String { decision.kind == .eye ? "Look at something 20 feet away for 20 seconds." : decision.kind == .posture ? "Stand or walk around for 4 minutes and rest your eyes." : "You've used your screen for \(duration(decision.usedMinutes)). Time to walk around for 5 minutes." }
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
        return "\(bitmap.deviceID),\(bitmap.displayName.replacingOccurrences(of: ",", with: " ")),\(bitmap.usedMinutes),\(model.settings.reportTimeZone),\(bitmap.isAggregate),\(bits)"
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
