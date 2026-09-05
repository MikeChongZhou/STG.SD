import AppKit
import AuthenticationServices
import Combine
import ServiceManagement
import STGCore

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: STGSettings
    @Published var localMinutes = 0
    @Published var allMinutes = 0
    @Published var dayBitmaps: [DeviceDayBitmap] = []
    @Published var syncStatus = "Sync off — choose a provider in Settings"
    @Published var isScreenAvailable = true
    @Published var lastReminder: ReminderDecision?
    @Published var oneDriveAccountLabel = UserDefaults.standard.string(forKey: "oneDriveAccountLabel") ?? "Not signed in"
    @Published var oneDriveUserCode: String?
    @Published var googleDriveAccountLabel = UserDefaults.standard.string(forKey: "googleDriveAccountLabel") ?? "Not signed in"
    @Published var iCloudAccountLabel = FileManager.default.ubiquityIdentityToken == nil ? "Not signed in" : "System Apple Account"
    @Published var launchAtLoginStatus = "Checking login-item status…"

    let repository: BitmapRepository?
    let diagnosticLog: DiagnosticLog
    private let oneDriveCredentialService = "com.timbertrail.stg.macos.onedrive"
    private let googleDriveCredentialService = "com.timbertrail.stg.macos.googledrive"
    private let iCloudContainer = "iCloud.com.timbertrail.screentimeguardian"
    private let webAuthentication = MacWebAuthenticationPresenter()
    private var syncInProgress = false
    private let settingsStore: SettingsStore
    private var reminderState = ReminderState()
    private let reminderEngine = ReminderEngine()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let sessionID: String
    private var terminationRecorded = false
    var currentReportTimeZone: String { TimeZone.current.identifier }

    private static let sessionIDKey = "runtime_session_id"
    private static let sessionStartedAtKey = "runtime_session_started_at"
    private static let sessionHeartbeatAtKey = "runtime_session_heartbeat_at"
    private static let sessionCleanShutdownKey = "runtime_session_clean_shutdown"
    private static let sessionTerminationReasonKey = "runtime_session_termination_reason"

    init() {
        sessionID = UUID().uuidString.lowercased()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScreenTimeGuardian", isDirectory: true)
        settingsStore = SettingsStore(applicationSupport: support)
        var loadedSettings = settingsStore.load()
        loadedSettings.reportTimeZone = TimeZone.current.identifier
        settings = loadedSettings
        diagnosticLog = DiagnosticLog(directory: support.appendingPathComponent("Diagnostics", isDirectory: true))
        repository = try? BitmapRepository(url: support.appendingPathComponent("stg.sqlite"))
        if let repository, let storedState = try? repository.reminderState(deviceID: settings.deviceID) {
            reminderState = storedState
            diagnosticLog.record("reminder state restored; device=\(settings.deviceID.prefix(8)); last=\(storedState.lastReminder?.rawValue ?? "none"); last_eye=\(storedState.lastEyeAt.ISO8601Format()); last_posture=\(storedState.lastPostureAt.ISO8601Format())", category: "reminder")
        }
        let provider = settings.syncProvider ?? .none
        if provider != .none { syncStatus = isConnected(provider) ? "\(provider.displayName) connected" : "\(provider.displayName) account sign-in required" }
        let runtimeDefaults = UserDefaults.standard
        let previousSessionID = runtimeDefaults.string(forKey: Self.sessionIDKey)
        let previousStartedAt = runtimeDefaults.object(forKey: Self.sessionStartedAtKey) as? Date
        let previousHeartbeatAt = runtimeDefaults.object(forKey: Self.sessionHeartbeatAtKey) as? Date
        let previousCleanShutdown = runtimeDefaults.object(forKey: Self.sessionCleanShutdownKey) as? Bool
        let previousTerminationReason = runtimeDefaults.string(forKey: Self.sessionTerminationReasonKey)
        if let previousSessionID, previousCleanShutdown == false {
            diagnosticLog.record(
                "previous session ended without clean shutdown; previous_session=\(previousSessionID); previous_started_at=\(previousStartedAt?.ISO8601Format() ?? "unknown"); previous_heartbeat_at=\(previousHeartbeatAt?.ISO8601Format() ?? "unknown"); previous_termination_reason=\(previousTerminationReason ?? "none"); previous_session_unclean=true",
                category: "lifecycle"
            )
        }
        let launchedAt = Date()
        runtimeDefaults.set(sessionID, forKey: Self.sessionIDKey)
        runtimeDefaults.set(launchedAt, forKey: Self.sessionStartedAtKey)
        runtimeDefaults.set(launchedAt, forKey: Self.sessionHeartbeatAtKey)
        runtimeDefaults.set(false, forKey: Self.sessionCleanShutdownKey)
        runtimeDefaults.removeObject(forKey: Self.sessionTerminationReasonKey)
        runtimeDefaults.synchronize()
        diagnosticLog.record("launch; session=\(sessionID); repository=\(repository == nil ? "unavailable" : "ready"); provider=\(provider.rawValue); device=\(settings.deviceID.prefix(8))", category: "lifecycle")
        if repository == nil { syncStatus = "Database unavailable; export the test log" }
        configureWorkspaceObservers()
        Task {
            await refresh()
            if (settings.syncProvider ?? .none) != .none {
                diagnosticLog.record("incremental sync requested; trigger=launch", category: "sync")
                await synchronize()
            }
        }
    }

    func start() {
        diagnosticLog.record("minute recorder started; session=\(sessionID); screen_available=\(isScreenAvailable)", category: "lifecycle")
        installMinuteTimer()
        Task { await tick() }
    }

    func stop(reason: String) {
        guard !terminationRecorded else { return }
        terminationRecorded = true
        timer?.invalidate(); timer = nil
        let stoppedAt = Date()
        diagnosticLog.record("minute recorder stopped; session=\(sessionID); reason=\(reason); clean_shutdown=true", category: "lifecycle")
        let runtimeDefaults = UserDefaults.standard
        runtimeDefaults.set(stoppedAt, forKey: Self.sessionHeartbeatAtKey)
        runtimeDefaults.set(true, forKey: Self.sessionCleanShutdownKey)
        runtimeDefaults.set(reason, forKey: Self.sessionTerminationReasonKey)
        runtimeDefaults.synchronize()
    }

    func reconcileLaunchAtLogin(trigger: String) {
        let service = SMAppService.mainApp
        do {
            if settings.launchAtLogin {
                if service.status == .notRegistered || service.status == .notFound { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            launchAtLoginStatus = Self.loginItemDescription(service.status, requested: settings.launchAtLogin)
            diagnosticLog.record("login item reconciled; trigger=\(trigger); requested=\(settings.launchAtLogin); status=\(service.status.rawValue)", category: "lifecycle")
        } catch {
            launchAtLoginStatus = "Login-item update failed: \(error.localizedDescription)"
            diagnosticLog.record("login item reconciliation failed; trigger=\(trigger); requested=\(settings.launchAtLogin); status=\(service.status.rawValue); error_type=\(String(reflecting: type(of: error))); error=\(error.localizedDescription)", category: "lifecycle")
        }
    }

    func saveSettings() {
        settings.reportTimeZone = currentReportTimeZone
        settings.updatedAt = .now
        do {
            try settingsStore.save(settings)
            try repository?.upsertDevice(DeviceRecord(deviceID: settings.deviceID, name: settings.deviceName, kind: settings.deviceKind, updatedAt: settings.updatedAt))
            diagnosticLog.record("settings saved; plan=\(settings.dailyPlanMinutes)m; timezone=\(settings.reportTimeZone); provider=\((settings.syncProvider ?? .none).rawValue); meeting=\(settings.meetingMode)")
            reconcileLaunchAtLogin(trigger: "settings_save")
        }
        catch { syncStatus = "Settings save failed: \(error.localizedDescription)"; diagnosticLog.record(syncStatus, category: "error") }
    }

    func synchronize() async {
        guard let repository else { syncStatus = "Database unavailable"; return }
        guard !syncInProgress else { diagnosticLog.record("sync request coalesced; another sync is running", category: "sync"); return }
        syncInProgress = true
        defer { syncInProgress = false }
        let provider = settings.syncProvider ?? .none
        guard provider != .none else { syncStatus = "Sync off — choose a provider in Settings"; diagnosticLog.record("sync skipped; provider=none", category: "sync"); return }
        if provider == .oneDrive {
            guard let clientID = oneDriveClientID else { syncStatus = "OneDrive developer Client ID is not configured"; diagnosticLog.record("sync blocked; provider=oneDrive; missing_client_id", category: "sync"); return }
            guard OneDriveCredentialStore.load(service: oneDriveCredentialService) != nil else { syncStatus = "OneDrive account sign-in required"; diagnosticLog.record("sync blocked; provider=oneDrive; account_not_signed_in", category: "sync"); return }
            syncStatus = "Syncing OneDrive…"; diagnosticLog.record("sync begin; provider=oneDrive; local_device=\(settings.deviceID.prefix(8))", category: "sync")
            do {
                let result = try await OneDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, credentialService: oneDriveCredentialService).synchronize(settings: settings)
                syncStatus = "Uploaded \(result.uploaded), downloaded \(result.downloaded)"
                diagnosticLog.record("OneDrive sync complete; uploaded=\(result.uploaded); downloaded=\(result.downloaded); upload_cursor=\(result.uploadCursor ?? "none"); discovered=[\(result.discoveredDeviceIDs.map { String($0.prefix(8)) }.sorted().joined(separator: ","))]; download_cursors=[\(result.downloadCursors.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))=\($0.value)" }.joined(separator: ","))]", category: "sync")
                await runWeeklyActionIfDue()
                await refresh()
            } catch { syncStatus = "OneDrive sync failed: \(error.localizedDescription)"; diagnosticLog.record(syncStatus, category: "sync") }
            return
        }
        if provider == .googleDrive {
            guard let clientID = googleDriveClientID else { syncStatus = "Google Drive developer OAuth Client ID is not configured"; diagnosticLog.record("sync blocked; provider=googleDrive; missing_client_id", category: "sync"); return }
            guard GoogleDriveCredentialStore.load(service: googleDriveCredentialService) != nil else { syncStatus = "Google Drive account sign-in required"; return }
            syncStatus = "Syncing Google Drive…"; diagnosticLog.record("sync begin; provider=googleDrive; local_device=\(settings.deviceID.prefix(8))", category: "sync")
            do {
                let result = try await GoogleDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, clientSecret: googleDriveClientSecret ?? "", credentialService: googleDriveCredentialService).synchronize(settings: settings)
                syncStatus = "Uploaded \(result.uploaded), downloaded \(result.downloaded)"
                diagnosticLog.record("Google Drive sync complete; uploaded=\(result.uploaded); downloaded=\(result.downloaded); upload_cursor=\(result.uploadCursor ?? "none"); discovered=[\(result.discoveredDeviceIDs.map { String($0.prefix(8)) }.sorted().joined(separator: ","))]; download_cursors=[\(result.downloadCursors.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))=\($0.value)" }.joined(separator: ","))]", category: "sync")
                await runWeeklyActionIfDue()
                await refresh()
            } catch { syncStatus = "Google Drive sync failed: \(error.localizedDescription)"; diagnosticLog.record(syncStatus, category: "sync") }
            return
        }
        guard provider == .iCloudDrive else { return }
        syncStatus = "Syncing iCloud Drive…"; diagnosticLog.record("sync begin; provider=iCloudDrive; local_device=\(settings.deviceID.prefix(8))", category: "sync")
        do {
            guard let folder = await Task.detached(priority: .utility, operation: { Self.iCloudFolder(containerID: self.iCloudContainer) }).value else {
                iCloudAccountLabel = "Not signed in"; syncStatus = "iCloud Drive unavailable — sign in to Apple Account in System Settings"; return
            }
            iCloudAccountLabel = "System Apple Account"
            let sync = CloudFolderSync(repository: repository, deviceID: settings.deviceID)
            try await sync.uploadSettings(folder: folder, settings: settings)
            let result = try await sync.incrementalSync(folder: folder, uploadCursorTarget: "iCloudDrive")
            syncStatus = "Uploaded \(result.uploaded), downloaded \(result.downloaded)"
            diagnosticLog.record("iCloud Drive sync complete; uploaded=\(result.uploaded); downloaded=\(result.downloaded); upload_cursor=\(result.uploadCursor ?? "none"); discovered=[\(result.discoveredDeviceIDs.map { String($0.prefix(8)) }.sorted().joined(separator: ","))]; download_cursors=[\(result.downloadCursors.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))=\($0.value)" }.joined(separator: ","))]", category: "sync")
            await runWeeklyActionIfDue()
            await refresh()
        } catch { syncStatus = "iCloud Drive sync failed: \(error.localizedDescription)"; diagnosticLog.record(syncStatus, category: "sync") }
    }

    func refresh() async {
        guard let repository else { return }
        let deviceID = settings.deviceID
        let deviceName = settings.deviceName
        let deviceUpdatedAt = settings.updatedAt
        let timeZoneID = currentReportTimeZone
        let provider = settings.syncProvider ?? .none
        let syncEnabled = isConnected(provider)
        diagnosticLog.record("refresh begin; timezone=\(timeZoneID); sync_enabled=\(syncEnabled)", category: "report")
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                let now = Date()
                try repository.upsertDevice(DeviceRecord(deviceID: deviceID, name: deviceName, kind: .macos, updatedAt: deviceUpdatedAt))
                let deviceNames = Dictionary(uniqueKeysWithValues: try repository.deviceRecords().map { ($0.deviceID, $0.name) })
                let local = try repository.localClockDayBitmap(deviceID: deviceID, instant: now, timeZoneID: timeZoneID)
                let localCount = try repository.localDayMinutes(deviceID: deviceID, instant: now, timeZoneID: timeZoneID)
                let aggregate: [Bool]
                let aggregateCount: Int
                var ids: [String]
                if syncEnabled {
                    for key in STGTime.utcDateKeys(overlapping: STGTime.localDayInterval(containing: now, timeZoneID: timeZoneID)) { _ = try repository.rebuildAllDevices(utcDate: key) }
                    aggregate = try repository.localClockDayBitmap(deviceID: "alldevices", instant: now, timeZoneID: timeZoneID)
                    aggregateCount = try repository.localDayMinutes(deviceID: "alldevices", instant: now, timeZoneID: timeZoneID)
                    ids = try repository.deviceIDs()
                } else { aggregate = local; aggregateCount = localCount; ids = [deviceID] }
                if !ids.contains(deviceID) { ids.insert(deviceID, at: 0) }
                var values = [DeviceDayBitmap(deviceID: "alldevices", displayName: "All devices", minutes: aggregate, isAggregate: true, usedMinutes: aggregateCount)]
                for id in ids {
                    let name = id == deviceID ? deviceName : (deviceNames[id] ?? "Other device")
                    let clock = id == deviceID ? local : try repository.localClockDayBitmap(deviceID: id, instant: now, timeZoneID: timeZoneID)
                    let count = id == deviceID ? localCount : try repository.localDayMinutes(deviceID: id, instant: now, timeZoneID: timeZoneID)
                    values.append(DeviceDayBitmap(deviceID: id, displayName: name, minutes: clock, usedMinutes: count))
                }
                return values
            }.value
            dayBitmaps = snapshot
            allMinutes = snapshot.first?.usedMinutes ?? 0
            localMinutes = snapshot.first(where: { $0.deviceID == deviceID })?.usedMinutes ?? 0
            diagnosticLog.record("refresh complete; \(snapshot.map { "\($0.deviceID.prefix(8))=\($0.usedMinutes)m" }.joined(separator: ","))", category: "report")
        } catch { syncStatus = "Database error: \(error.localizedDescription)"; diagnosticLog.record(syncStatus, category: "database") }
    }

    func reportDay(at instant: Date) async -> [DeviceDayBitmap] {
        guard let repository else { return [] }
        let deviceID = settings.deviceID, deviceName = settings.deviceName, kind = settings.deviceKind, zone = currentReportTimeZone
        let includeSynced = isConnected(settings.syncProvider ?? .none)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try repository.dayReport(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: kind, instant: instant, timeZoneID: zone, includeSyncedDevices: includeSynced)
            }.value
            diagnosticLog.record("selected day report complete; date=\(Self.dateLabel(instant, zone: zone)); devices=\(result.count); totals=[\(result.map { "\($0.deviceID.prefix(8))=\($0.usedMinutes)m" }.joined(separator: ","))]", category: "report")
            return result
        } catch { syncStatus = "Report failed: \(error.localizedDescription)"; diagnosticLog.record(syncStatus, category: "report"); return [] }
    }

    func multiDayReport(from start: Date, through end: Date) async -> [DailyUsagePoint] {
        guard let repository else { return [] }
        let deviceID = settings.deviceID, deviceName = settings.deviceName, kind = settings.deviceKind, zone = currentReportTimeZone
        let includeSynced = isConnected(settings.syncProvider ?? .none)
        do {
            let points = try await Task.detached(priority: .userInitiated) {
                try repository.multiDayReport(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: kind, start: start, end: end, timeZoneID: zone, includeSyncedDevices: includeSynced)
            }.value
            diagnosticLog.record("multi-day report complete; start=\(Self.dateLabel(start, zone: zone)); end=\(Self.dateLabel(end, zone: zone)); points=\(points.count); series=\(Set(points.map(\.deviceID)).count)", category: "report")
            return points
        } catch { syncStatus = "Multi-day report failed: \(error.localizedDescription)"; diagnosticLog.record(syncStatus, category: "report"); return [] }
    }

    private func runWeeklyActionIfDue() async {
        guard let repository else { return }
        do { guard try repository.weeklyActionDue() else { return } }
        catch { diagnosticLog.record("weekly action due check failed: \(error.localizedDescription)", category: "sync"); return }
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = STGTime.utc
        let today = calendar.startOfDay(for: .now)
        guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: today),
              let lastSunday = calendar.date(byAdding: .day, value: -1, to: currentWeek.start) else { return }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = STGTime.utc; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let first = formatter.date(from: "2025-01-01")!
        let totalCursorText = try? repository.latestOpenRouterWeekEnd()
        let totalStart = totalCursorText.flatMap(formatter.date(from:)).flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? first
        let start = totalStart
        diagnosticLog.record("weekly action begin; openrouter_start=\(formatter.string(from: start)); openrouter_end=\(formatter.string(from: lastSunday)); latest_week_cursor=\(totalCursorText ?? "none")", category: "sync")
        do {
            let rows = start <= lastSunday ? try await OpenRouterTrackingService.shared.weeklyHistory(startDate: formatter.string(from: start), endDate: formatter.string(from: lastSunday)) : []
            if start <= lastSunday && rows.isEmpty { throw STGError.invalidDocument("OpenRouter returned no weekly model-activity rows; detail cursor was not advanced") }
            try repository.upsertOpenRouterWeeks(rows)
            try repository.completeOpenRouterDetailWeek(through: formatter.string(from: lastSunday))
            try repository.completeWeeklyAction()
            diagnosticLog.record("weekly action complete; openrouter_rows=\(rows.count); weeks=\(Set(rows.map(\.weekStart)).count); completion_recorded=true", category: "sync")
        } catch {
            diagnosticLog.record("weekly action failed; completion_not_recorded=true; error=\(error.localizedDescription)", category: "sync")
        }
    }

    func openRouterWeeks(models: [String]) -> [OpenRouterWeeklyRankingRow] {
        (try? repository?.openRouterWeeks(models: models)) ?? []
    }

    func latestOpenRouterTopModels(metric: OpenRouterWeeklyMetric) -> [String] {
        (try? repository?.latestOpenRouterTopModels(metric: metric, limit: 10)) ?? []
    }

    private static func dateLabel(_ date: Date, zone: String) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: zone) ?? .current; formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date) }

    private func tick() async {
        guard let repository else { return }
        let now = Date()
        markSessionHeartbeat(at: now)
        let previousWasUsed: Bool
        do {
            let previous = now.addingTimeInterval(-60)
            previousWasUsed = try repository.bitmap(deviceID: settings.deviceID, utcDate: STGTime.utcDateKey(for: previous))[STGTime.utcMinute(for: previous)]
            if isScreenAvailable {
                let changed = try repository.mark(deviceID: settings.deviceID, instant: now)
                diagnosticLog.record("active minute sample; utc_date=\(STGTime.utcDateKey(for: now)); utc_minute=\(STGTime.utcMinute(for: now)); newly_marked=\(changed)", category: "record")
            }
            await refresh()
            let priorLastEye = reminderState.lastEyeAt
            let priorLastPosture = reminderState.lastPostureAt
            let priorLastReminder = reminderState.lastReminder
            if let decision = reminderEngine.evaluate(active: isScreenAvailable, now: now, localMinuteIsSet: previousWasUsed, allDeviceDailyMinutes: allMinutes, settings: settings, state: &reminderState) {
                if reminderState.lastEyeAt != priorLastEye || reminderState.lastPostureAt != priorLastPosture || reminderState.lastReminder != priorLastReminder {
                    try repository.saveReminderState(deviceID: settings.deviceID, state: reminderState, updatedAt: now)
                }
                diagnosticLog.record("reminder; kind=\(decision.kind.rawValue); previous_slot=\(priorLastReminder?.rawValue ?? "none"); next_slot=\(reminderState.lastReminder?.rawValue ?? "none"); all_used=\(decision.usedMinutes)m; local_used=\(localMinutes)m; countdown=\(decision.closeCountdownMinutes)m; silent=\(decision.silent)", category: "reminder")
                lastReminder = decision
                NotificationCenter.default.post(name: .stgReminder, object: decision)
                diagnosticLog.record("incremental sync requested; trigger=reminder; kind=\(decision.kind.rawValue)", category: "sync")
                await synchronize()
            }
        } catch { syncStatus = "Record failed: \(error.localizedDescription)"; diagnosticLog.record(syncStatus, category: "record") }
    }

    private func configureWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let unavailable: [NSNotification.Name] = [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification]
        let available: [NSNotification.Name] = [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification]
        for name in unavailable { observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in Task { @MainActor in self?.handleScreenUnavailable(note.name.rawValue) } }) }
        for name in available { observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in Task { @MainActor in self?.handleScreenAvailable(note.name.rawValue) } }) }
    }

    private func installMinuteTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in await self?.tick() } }
    }

    private func handleScreenUnavailable(_ notificationName: String) {
        let wasRunning = timer != nil
        isScreenAvailable = false
        timer?.invalidate(); timer = nil
        markSessionHeartbeat(at: Date(), flush: true)
        diagnosticLog.record("screen unavailable; notification=\(notificationName); minute_timer_paused=\(wasRunning)", category: "lifecycle")
    }

    private func handleScreenAvailable(_ notificationName: String) {
        let requiresResume = !isScreenAvailable || timer == nil
        isScreenAvailable = true
        guard requiresResume else {
            diagnosticLog.record("screen available callback coalesced; notification=\(notificationName); minute_timer_running=true", category: "lifecycle")
            return
        }
        installMinuteTimer()
        diagnosticLog.record("screen available; notification=\(notificationName); minute_timer_resumed=true; immediate_tick=true; immediate_sync=true", category: "lifecycle")
        Task {
            await tick()
            await synchronize()
        }
    }

    private func markSessionHeartbeat(at date: Date, flush: Bool = false) {
        let runtimeDefaults = UserDefaults.standard
        runtimeDefaults.set(date, forKey: Self.sessionHeartbeatAtKey)
        if flush { runtimeDefaults.synchronize() }
    }

    private static func loginItemDescription(_ status: SMAppService.Status, requested: Bool) -> String {
        switch status {
        case .enabled: return "Starts automatically at login"
        case .requiresApproval: return "Allow Screen Time Guardian in System Settings › General › Login Items"
        case .notRegistered: return requested ? "Login item is not registered" : "Does not start automatically"
        case .notFound: return "Install Screen Time Guardian in Applications before enabling login startup"
        @unknown default: return "Login-item status is unavailable"
        }
    }

    func exportTestLog() {
        diagnosticLog.record("test log export requested", category: "diagnostics")
        let panel = NSSavePanel(); panel.nameFieldStringValue = "stg-test.log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try diagnosticLog.data().write(to: url, options: .atomic); diagnosticLog.clear() }
        catch { syncStatus = "Log export failed: \(error.localizedDescription)" }
    }

    func requestOneDriveSignIn() {
        guard let clientID = oneDriveClientID else {
            syncStatus = "OneDrive sign-in unavailable: Microsoft Entra Client ID is missing"
            diagnosticLog.record("OneDrive sign-in blocked; missing_client_id", category: "sync")
            return
        }
        syncStatus = "Requesting Microsoft sign-in code…"
        diagnosticLog.record("OneDrive sign-in begin", category: "sync")
        Task {
            do {
                let client = OneDriveClient(clientID: clientID)
                let code = try await client.requestDeviceCode(); oneDriveUserCode = code.userCode
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code.userCode, forType: .string)
                webAuthentication.present(url: code.verificationURL)
                syncStatus = "Waiting for Microsoft authorization: \(code.userCode)"
                let credential = try await client.waitForAuthorization(code)
                webAuthentication.cancel(); oneDriveUserCode = nil
                try OneDriveCredentialStore.save(credential, service: oneDriveCredentialService)
                let account = try await client.account(using: credential)
                oneDriveAccountLabel = "\(account.displayName) (\(account.email))"
                UserDefaults.standard.set(oneDriveAccountLabel, forKey: "oneDriveAccountLabel")
                syncStatus = "OneDrive signed in as \(oneDriveAccountLabel)"
                diagnosticLog.record("OneDrive sign-in complete; account=authorized", category: "sync")
            } catch { webAuthentication.cancel(); oneDriveUserCode = nil; syncStatus = error.localizedDescription; diagnosticLog.record("OneDrive sign-in failed: \(error.localizedDescription)", category: "sync") }
        }
    }

    func signOutOneDrive() {
        OneDriveCredentialStore.remove(service: oneDriveCredentialService)
        oneDriveAccountLabel = "Not signed in"; UserDefaults.standard.removeObject(forKey: "oneDriveAccountLabel")
        syncStatus = "OneDrive signed out"; diagnosticLog.record("OneDrive signed out", category: "sync")
    }

    private var oneDriveClientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "STGOneDriveClientID") as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    func requestGoogleDriveSignIn() {
        guard let clientID = googleDriveClientID else {
            syncStatus = "Google Drive sign-in unavailable: OAuth Client ID is missing"; diagnosticLog.record("Google Drive sign-in blocked; missing_client_id", category: "sync"); return
        }
        syncStatus = "Opening Google account sign-in…"; diagnosticLog.record("Google Drive sign-in begin", category: "sync")
        Task {
            do {
                let client = GoogleDriveClient(clientID: clientID, clientSecret: googleDriveClientSecret ?? "")
                let request = try await client.authorizationRequest(callbackScheme: googleCallbackScheme)
                let callback = try await webAuthentication.authenticate(url: request.authorizationURL, callbackScheme: request.callbackScheme)
                let credential = try await client.credential(callbackURL: callback, request: request)
                try GoogleDriveCredentialStore.save(credential, service: googleDriveCredentialService)
                let account = try await client.account(using: credential)
                googleDriveAccountLabel = "\(account.displayName) (\(account.email))"; UserDefaults.standard.set(googleDriveAccountLabel, forKey: "googleDriveAccountLabel")
                syncStatus = "Google Drive signed in as \(googleDriveAccountLabel)"; diagnosticLog.record("Google Drive sign-in complete; account=authorized", category: "sync")
            } catch { syncStatus = error.localizedDescription; diagnosticLog.record("Google Drive sign-in failed: \(error.localizedDescription)", category: "sync") }
        }
    }

    func signOutGoogleDrive() {
        let credential = GoogleDriveCredentialStore.load(service: googleDriveCredentialService)
        GoogleDriveCredentialStore.remove(service: googleDriveCredentialService)
        googleDriveAccountLabel = "Not signed in"; UserDefaults.standard.removeObject(forKey: "googleDriveAccountLabel")
        syncStatus = "Google Drive signed out"; diagnosticLog.record("Google Drive signed out", category: "sync")
        if let credential, let clientID = googleDriveClientID { Task { await GoogleDriveClient(clientID: clientID).revoke(credential) } }
    }

    func connect(to provider: SyncProvider) {
        switch provider {
        case .none: syncStatus = "Sync off"
        case .iCloudDrive:
            if FileManager.default.ubiquityIdentityToken != nil {
                iCloudAccountLabel = "System Apple Account"; syncStatus = "iCloud Drive connected"
            } else {
                iCloudAccountLabel = "Not signed in"; syncStatus = "Sign in to Apple Account in System Settings"
                openAppleAccountSettings()
            }
        case .oneDrive: if OneDriveCredentialStore.load(service: oneDriveCredentialService) == nil { requestOneDriveSignIn() }
        case .googleDrive: if GoogleDriveCredentialStore.load(service: googleDriveCredentialService) == nil { requestGoogleDriveSignIn() }
        }
    }

    func openAppleAccountSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") { NSWorkspace.shared.open(url) }
    }

    private func isConnected(_ provider: SyncProvider) -> Bool {
        switch provider {
        case .none: false
        case .iCloudDrive: FileManager.default.ubiquityIdentityToken != nil
        case .oneDrive: OneDriveCredentialStore.load(service: oneDriveCredentialService) != nil
        case .googleDrive: GoogleDriveCredentialStore.load(service: googleDriveCredentialService) != nil
        }
    }

    private var googleDriveClientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "STGGoogleClientID") as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private var googleCallbackScheme: String {
        guard let clientID = googleDriveClientID else { return "com.timbertrail.screentimeguardian.oauth" }
        let suffix = ".apps.googleusercontent.com"
        let identifier = clientID.hasSuffix(suffix) ? String(clientID.dropLast(suffix.count)) : clientID
        return "com.googleusercontent.apps.\(identifier)"
    }

    private var googleDriveClientSecret: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "STGGoogleClientSecret") as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    nonisolated private static func iCloudFolder(containerID: String) -> URL? {
        guard let root = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else { return nil }
        let folder = root.appendingPathComponent("Documents/ScreenTimeGuardian", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

}

@MainActor
private final class MacWebAuthenticationPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func present(url: URL) {
        cancel()
        let value = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in }
        value.presentationContextProvider = self; value.prefersEphemeralWebBrowserSession = false
        session = value; _ = value.start()
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        cancel()
        return try await withCheckedThrowingContinuation { continuation in
            let value = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
                self?.session = nil
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? STGError.invalidDocument("Account sign-in was cancelled")) }
            }
            value.presentationContextProvider = self; value.prefersEphemeralWebBrowserSession = false
            session = value
            if !value.start() { session = nil; continuation.resume(throwing: STGError.invalidDocument("Unable to open account sign-in window")) }
        }
    }

    func cancel() { session?.cancel(); session = nil }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
}

extension SyncProvider {
    var displayName: String {
        switch self { case .none: "Off"; case .iCloudDrive: "iCloud Drive"; case .oneDrive: "OneDrive"; case .googleDrive: "Google Drive" }
    }
}

extension Notification.Name { static let stgReminder = Notification.Name("STGReminder") }
