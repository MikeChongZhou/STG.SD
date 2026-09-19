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
    @Published var statisticsSummary = UsageStatisticsSummary()
    @Published var syncStatus = "Sync off — choose a provider in Settings"
    @Published var isScreenAvailable = true
    @Published var lastReminder: ReminderDecision?
    @Published var oneDriveAccountLabel = UserDefaults.standard.string(forKey: "oneDriveAccountLabel") ?? "Not signed in"
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
    private var syncWarnings: [String] = []
    private var quickUploadInProgress = false
    private let settingsStore: SettingsStore
    private var reminderState = ReminderState()
    private var reminderStateLocalDate = ""
    private let reminderEngine = ReminderEngine()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let sessionID: String
    private var terminationRecorded = false
    private var terminationPreparationStarted = false
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
        let today = Self.dateLabel(.now, zone: TimeZone.current.identifier)
        reminderStateLocalDate = today
        let lastStateDate = Self.dateLabel(max(reminderState.lastEyeAt, reminderState.lastPostureAt), zone: TimeZone.current.identifier)
        if lastStateDate != today {
            reminderState.lastReminder = .posture
            try? repository?.saveReminderState(deviceID: settings.deviceID, state: reminderState, updatedAt: .now)
            diagnosticLog.record("daily reminder slot reset; previous_date=\(lastStateDate); local_date=\(today); next_slot=posture", category: "reminder")
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

    func prepareForTermination(reason: String) async {
        guard !terminationPreparationStarted else { return }
        terminationPreparationStarted = true
        stop(reason: reason)
        if syncInProgress {
            diagnosticLog.record("quit requested while incremental sync is running; process termination will cancel active sync", category: "lifecycle")
            return
        }
        var uploadFinished = false
        let uploadTask = Task { @MainActor in
            await self.quickUpload(trigger: reason)
            uploadFinished = true
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !uploadFinished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !uploadFinished else { diagnosticLog.record("quit upload complete; hard_timeout=false", category: "lifecycle"); return }
        uploadTask.cancel()
        diagnosticLog.record("quit upload hard timeout reached; limit=3s; continuing termination=true", category: "lifecycle")
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
        syncWarnings = []
        defer { syncInProgress = false }
        let progress: SyncProgressHandler = { [weak self] message in
            self?.syncStatus = message
            await Task.yield()
        }
        let provider = settings.syncProvider ?? .none
        guard provider != .none else { syncStatus = "Sync off — choose a provider in Settings"; diagnosticLog.record("sync skipped; provider=none", category: "sync"); return }
        if provider == .oneDrive {
            guard let clientID = oneDriveClientID else { syncStatus = "OneDrive developer Client ID is not configured"; diagnosticLog.record("sync blocked; provider=oneDrive; missing_client_id", category: "sync"); return }
            guard OneDriveCredentialStore.load(service: oneDriveCredentialService) != nil else { syncStatus = "OneDrive account sign-in required"; diagnosticLog.record("sync blocked; provider=oneDrive; account_not_signed_in", category: "sync"); return }
            syncStatus = "Connecting to OneDrive…"; diagnosticLog.record("sync begin; provider=oneDrive; local_device=\(settings.deviceID.prefix(8))", category: "sync")
            do {
                let result = try await OneDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, credentialService: oneDriveCredentialService).synchronize(settings: settings, progress: progress)
                diagnosticLog.record("OneDrive sync complete; uploaded=\(result.uploaded); downloaded=\(result.downloaded); upload_cursor=\(result.uploadCursor ?? "none"); discovered=[\(result.discoveredDeviceIDs.map { String($0.prefix(8)) }.sorted().joined(separator: ","))]; download_cursors=[\(result.downloadCursors.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))=\($0.value)" }.joined(separator: ","))]", category: "sync")
                result.warnings.forEach { diagnosticLog.record($0, category: "sync-warning") }
                await runWeeklyActionIfDue()
                syncStatus = completionStatus(uploaded: result.uploaded, downloaded: result.downloaded)
                await refresh()
            } catch { syncStatus = "OneDrive sync failed: \(error.localizedDescription)"; diagnosticLog.record("sync failed; stage=incremental; provider=oneDrive; local_device=\(settings.deviceID.prefix(8)); \(DiagnosticLog.describe(error))", category: "sync") }
            return
        }
        if provider == .googleDrive {
            guard let clientID = googleDriveClientID else { syncStatus = "Google Drive developer OAuth Client ID is not configured"; diagnosticLog.record("sync blocked; provider=googleDrive; missing_client_id", category: "sync"); return }
            guard GoogleDriveCredentialStore.load(service: googleDriveCredentialService) != nil else { syncStatus = "Google Drive account sign-in required"; return }
            syncStatus = "Connecting to Google Drive…"; diagnosticLog.record("sync begin; provider=googleDrive; local_device=\(settings.deviceID.prefix(8))", category: "sync")
            do {
                let result = try await GoogleDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, clientSecret: googleDriveClientSecret ?? "", credentialService: googleDriveCredentialService).synchronize(settings: settings, progress: progress)
                diagnosticLog.record("Google Drive sync complete; uploaded=\(result.uploaded); downloaded=\(result.downloaded); upload_cursor=\(result.uploadCursor ?? "none"); discovered=[\(result.discoveredDeviceIDs.map { String($0.prefix(8)) }.sorted().joined(separator: ","))]; download_cursors=[\(result.downloadCursors.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))=\($0.value)" }.joined(separator: ","))]", category: "sync")
                result.warnings.forEach { diagnosticLog.record($0, category: "sync-warning") }
                await runWeeklyActionIfDue()
                syncStatus = completionStatus(uploaded: result.uploaded, downloaded: result.downloaded)
                await refresh()
            } catch { syncStatus = "Google Drive sync failed: \(error.localizedDescription)"; diagnosticLog.record("sync failed; stage=incremental; provider=googleDrive; local_device=\(settings.deviceID.prefix(8)); \(DiagnosticLog.describe(error))", category: "sync") }
            return
        }
        guard provider == .iCloudDrive else { return }
        syncStatus = "Connecting to iCloud Drive…"; diagnosticLog.record("sync begin; provider=iCloudDrive; local_device=\(settings.deviceID.prefix(8))", category: "sync")
        do {
            guard let folder = await Task.detached(priority: .utility, operation: { Self.iCloudFolder(containerID: self.iCloudContainer) }).value else {
                iCloudAccountLabel = "Not signed in"; syncStatus = "iCloud Drive unavailable — sign in to Apple Account in System Settings"; return
            }
            iCloudAccountLabel = "System Apple Account"
            let sync = CloudFolderSync(repository: repository, deviceID: settings.deviceID)
            syncStatus = "Uploading device settings…"
            try await sync.uploadSettings(folder: folder, settings: settings)
            let result = try await sync.incrementalSync(folder: folder, uploadCursorTarget: "iCloudDrive", progress: progress)
            diagnosticLog.record("iCloud Drive sync complete; uploaded=\(result.uploaded); downloaded=\(result.downloaded); upload_cursor=\(result.uploadCursor ?? "none"); discovered=[\(result.discoveredDeviceIDs.map { String($0.prefix(8)) }.sorted().joined(separator: ","))]; download_cursors=[\(result.downloadCursors.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))=\($0.value)" }.joined(separator: ","))]", category: "sync")
            result.warnings.forEach { diagnosticLog.record($0, category: "sync-warning") }
            await runWeeklyActionIfDue()
            syncStatus = completionStatus(uploaded: result.uploaded, downloaded: result.downloaded)
            await refresh()
        } catch { syncStatus = "iCloud Drive sync failed: \(error.localizedDescription)"; diagnosticLog.record("sync failed; stage=incremental; provider=iCloudDrive; local_device=\(settings.deviceID.prefix(8)); \(DiagnosticLog.describe(error))", category: "sync") }
    }

    private func quickUpload(trigger: String) async {
        guard let repository else { return }
        guard !quickUploadInProgress else { diagnosticLog.record("quick upload coalesced; trigger=\(trigger)", category: "sync"); return }
        if syncInProgress { diagnosticLog.record("quick upload covered by running incremental sync; trigger=\(trigger)", category: "sync"); return }
        let provider = settings.syncProvider ?? .none
        guard provider != .none, isConnected(provider) else { diagnosticLog.record("quick upload skipped; trigger=\(trigger); provider=\(provider.rawValue); configured=false", category: "sync"); return }
        quickUploadInProgress = true; defer { quickUploadInProgress = false }
        do {
            let now = Date(), currentKey = STGTime.utcDateKey(for: now), state = try repository.quickSyncState(deviceID: settings.deviceID)
            var keys = state.pendingUTCDateKeys
            if let modified = try repository.bitmapUpdatedAt(deviceID: settings.deviceID, utcDate: currentKey), modified > state.lastUploadAt { keys.insert(currentKey) }
            guard !keys.isEmpty else { try repository.completeQuickUpload(deviceID: settings.deviceID, utcDateKeys: [], at: now); diagnosticLog.record("quick upload skipped; trigger=\(trigger); no_changed_bitmap=true", category: "sync"); return }
            diagnosticLog.record("quick upload begin; trigger=\(trigger); provider=\(provider.rawValue); dates=\(keys.sorted().joined(separator: ","))", category: "sync")
            let count: Int
            switch provider {
            case .oneDrive:
                guard let clientID = oneDriveClientID else { throw STGError.invalidDocument("OneDrive Client ID is missing") }
                count = try await OneDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, credentialService: oneDriveCredentialService).quickUpload(utcDateKeys: keys)
            case .googleDrive:
                guard let clientID = googleDriveClientID else { throw STGError.invalidDocument("Google Drive Client ID is missing") }
                count = try await GoogleDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, clientSecret: googleDriveClientSecret ?? "", credentialService: googleDriveCredentialService).quickUpload(utcDateKeys: keys)
            case .iCloudDrive:
                guard let folder = Self.iCloudFolder(containerID: iCloudContainer) else { throw STGError.invalidDocument("iCloud Drive is unavailable") }
                count = try await CloudFolderSync(repository: repository, deviceID: settings.deviceID).quickUpload(folder: folder, utcDates: keys)
            case .none: return
            }
            try repository.completeQuickUpload(deviceID: settings.deviceID, utcDateKeys: keys, at: now)
            diagnosticLog.record("quick upload complete; trigger=\(trigger); provider=\(provider.rawValue); files=\(count)", category: "sync")
        } catch { diagnosticLog.record("quick upload failed; trigger=\(trigger); error=\(error.localizedDescription)", category: "sync") }
    }

    func refresh() async {
        guard let repository else { return }
        let deviceID = settings.deviceID
        let deviceName = settings.deviceName
        let deviceUpdatedAt = settings.updatedAt
        let timeZoneID = currentReportTimeZone
        let provider = settings.syncProvider ?? .none
        let syncEnabled = isConnected(provider)
        let runtimeContinuousMinutes = reminderState.continuousMinutes
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
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current; formatter.dateFormat = "yyyy-MM-dd"
                try repository.updateRuntimeState(
                    deviceID: deviceID,
                    continuousMinutes: runtimeContinuousMinutes,
                    localDailyMinutes: localCount,
                    aggregateDailyMinutes: aggregateCount,
                    localDate: formatter.string(from: now),
                    at: now
                )
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
        let deviceID = settings.deviceID, deviceName = settings.deviceName, kind = settings.deviceKind, zone = currentReportTimeZone, dailyLimit = settings.dailyPlanMinutes
        let includeSynced = isConnected(settings.syncProvider ?? .none)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let range = try repository.refreshStatistics(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: kind, dailyLimitMinutes: dailyLimit, timeZoneID: zone, includeSyncedDevices: includeSynced)
                let summary = try repository.statisticsSummary(reference: instant, timeZoneID: zone)
                return (try repository.dayReport(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: kind, instant: instant, timeZoneID: zone, includeSyncedDevices: includeSynced), summary, range)
            }.value
            statisticsSummary = result.1
            diagnosticLog.record("statistics refresh complete; range=\(result.2.lowerBound)...\(result.2.upperBound); trigger=report_open; last_statistics_updated=true", category: "report")
            diagnosticLog.record("selected day report complete; date=\(Self.dateLabel(instant, zone: zone)); devices=\(result.0.count); totals=[\(result.0.map { "\($0.deviceID.prefix(8))=\($0.usedMinutes)m" }.joined(separator: ","))]", category: "report")
            return result.0
        } catch { syncStatus = "Report failed: \(error.localizedDescription)"; diagnosticLog.record(syncStatus, category: "report"); return [] }
    }

    func multiDayReport(from start: Date, through end: Date) async -> [DailyUsagePoint] {
        guard let repository else { return [] }
        let deviceID = settings.deviceID, deviceName = settings.deviceName, kind = settings.deviceKind, zone = currentReportTimeZone, dailyLimit = settings.dailyPlanMinutes
        let includeSynced = isConnected(settings.syncProvider ?? .none)
        do {
            let points = try await Task.detached(priority: .userInitiated) {
                _ = try repository.refreshStatistics(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: kind, dailyLimitMinutes: dailyLimit, timeZoneID: zone, includeSyncedDevices: includeSynced)
                return try repository.multiDayReport(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: kind, start: start, end: end, timeZoneID: zone, includeSyncedDevices: includeSynced)
            }.value
            diagnosticLog.record("multi-day report complete; start=\(Self.dateLabel(start, zone: zone)); end=\(Self.dateLabel(end, zone: zone)); points=\(points.count); series=\(Set(points.map(\.deviceID)).count)", category: "report")
            return points
        } catch { syncStatus = "Multi-day report failed: \(error.localizedDescription)"; diagnosticLog.record(syncStatus, category: "report"); return [] }
    }

    func periodReport(kind: String, from start: Date, through end: Date) async -> [PeriodUsagePoint] {
        guard let repository else { return [] }
        let deviceID = settings.deviceID, deviceName = settings.deviceName, deviceKind = settings.deviceKind, zone = currentReportTimeZone, dailyLimit = settings.dailyPlanMinutes
        let includeSynced = isConnected(settings.syncProvider ?? .none)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                _ = try repository.refreshStatistics(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: deviceKind, dailyLimitMinutes: dailyLimit, timeZoneID: zone, includeSyncedDevices: includeSynced)
                let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(identifier: zone) ?? .current; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
                return try repository.periodUsage(kind: kind, from: formatter.string(from: min(start, end)), through: formatter.string(from: max(start, end)))
            }.value
            diagnosticLog.record("period report complete; kind=\(kind); points=\(result.count)", category: "report")
            return result
        } catch { diagnosticLog.record("period report failed; kind=\(kind); error=\(error.localizedDescription)", category: "report"); return [] }
    }

    private func runWeeklyActionIfDue() async {
        guard let repository else { return }
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = STGTime.utc
        let today = calendar.startOfDay(for: .now)
        guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: today),
              let lastSunday = calendar.date(byAdding: .day, value: -1, to: currentWeek.start) else { return }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = STGTime.utc; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let first = formatter.date(from: "2025-01-01")!
        let totalCursorText = try? repository.latestOpenRouterWeekEnd()
        let totalStart = totalCursorText.flatMap(formatter.date(from:)).flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? first
        let start = totalStart
        let cloudDue: Bool
        do { cloudDue = try repository.weeklyCloudActionDue() }
        catch { diagnosticLog.record("weekly cloud due check failed; \(DiagnosticLog.describe(error))", category: "sync"); return }
        let trackingDue = start <= lastSunday
        guard cloudDue || trackingDue else { return }
        diagnosticLog.record("weekly action begin; cloud_due=\(cloudDue); tracking_due=\(trackingDue); openrouter_start=\(formatter.string(from: start)); openrouter_end=\(formatter.string(from: lastSunday)); latest_week_cursor=\(totalCursorText ?? "none")", category: "sync")
        var cloudCompleted = false
        if cloudDue {
            syncStatus = "Updating weekly archive…"
            do {
                let previousMonday = calendar.date(byAdding: .day, value: -6, to: lastSunday) ?? lastSunday
                let maintenance = try await performWeeklyCloudMaintenance(currentWeekStart: formatter.string(from: currentWeek.start), previousWeekStart: formatter.string(from: previousMonday), previousWeekEnd: formatter.string(from: lastSunday))
                try repository.completeWeeklyAction(deviceID: settings.deviceID); cloudCompleted = true
                diagnosticLog.record("weekly cloud maintenance complete; bitmap_uploaded=\(maintenance.uploaded); daily_deleted=\(maintenance.deletedDaily); weekly_moved=\(maintenance.movedWeekly); history_ready=true; completion_recorded=true", category: "sync")
            } catch {
                syncWarnings.append("Weekly archive failed")
                diagnosticLog.record("weekly cloud maintenance failed; completion_not_recorded=true; \(DiagnosticLog.describe(error))", category: "sync")
            }
        }
        if trackingDue {
            syncStatus = "Updating tracking data…"
            do {
                let rows = try await OpenRouterTrackingService.shared.weeklyHistory(startDate: formatter.string(from: start), endDate: formatter.string(from: lastSunday))
                if rows.isEmpty { throw STGError.invalidDocument("OpenRouter returned no weekly model-activity rows; detail cursor was not advanced") }
                try repository.upsertOpenRouterWeeks(rows); try repository.completeOpenRouterDetailWeek(through: formatter.string(from: lastSunday))
                diagnosticLog.record("weekly tracking complete; openrouter_rows=\(rows.count); weeks=\(Set(rows.map(\.weekStart)).count); completion_recorded=true", category: "sync")
            } catch {
                syncWarnings.append("Tracking update failed")
                diagnosticLog.record("weekly tracking failed; start=\(formatter.string(from: start)); end=\(formatter.string(from: lastSunday)); completion_not_recorded=true; \(DiagnosticLog.describe(error))", category: "sync")
            }
        }
        if cloudCompleted { await runYearlyActionIfDue() }
    }

    private func completionStatus(uploaded: Int, downloaded: Int) -> String {
        let base = "Synced · \(uploaded) activity files uploaded, \(downloaded) downloaded"
        return syncWarnings.isEmpty ? base : base + " · " + syncWarnings.joined(separator: " · ")
    }

    private func performWeeklyCloudMaintenance(currentWeekStart: String, previousWeekStart: String, previousWeekEnd: String) async throws -> (uploaded: Int, deletedDaily: Int, movedWeekly: Int) {
        guard let repository else { throw STGError.database("database unavailable") }
        switch settings.syncProvider ?? .none {
        case .iCloudDrive:
            guard let folder = Self.iCloudFolder(containerID: iCloudContainer) else { throw STGError.invalidDocument("iCloud Drive is unavailable") }
            return try await CloudFolderSync(repository: repository, deviceID: settings.deviceID).weeklyMaintenance(folder: folder, currentWeekStart: currentWeekStart, previousWeekStart: previousWeekStart, previousWeekEnd: previousWeekEnd)
        case .oneDrive:
            guard let clientID = oneDriveClientID else { throw STGError.invalidDocument("OneDrive Client ID is missing") }
            return try await OneDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, credentialService: oneDriveCredentialService).weeklyMaintenance(currentWeekStart: currentWeekStart, previousWeekStart: previousWeekStart, previousWeekEnd: previousWeekEnd)
        case .googleDrive:
            guard let clientID = googleDriveClientID else { throw STGError.invalidDocument("Google Drive Client ID is missing") }
            return try await GoogleDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, clientSecret: googleDriveClientSecret ?? "", credentialService: googleDriveCredentialService).weeklyMaintenance(currentWeekStart: currentWeekStart, previousWeekStart: previousWeekStart, previousWeekEnd: previousWeekEnd)
        case .none:
            throw STGError.invalidDocument("private cloud is not configured")
        }
    }

    private func runYearlyActionIfDue() async {
        guard let repository, (try? repository.yearlyActionDue(deviceID: settings.deviceID)) == true else { return }
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: .now)
        let year = currentYear - 1, cleanupYear = currentYear - 2
        let start = String(format: "%04d-01-01", year), end = String(format: "%04d-12-31", year)
        do {
            let rows = try await OpenRouterTrackingService.shared.weeklyHistory(startDate: start, endDate: end)
            if !rows.isEmpty { try repository.upsertOpenRouterWeeks(rows) }
            let result: (uploaded: Int, deletedBitmaps: Int, deletedWeekly: Int)
            switch settings.syncProvider ?? .none {
            case .iCloudDrive:
                guard let folder = Self.iCloudFolder(containerID: iCloudContainer) else { throw STGError.invalidDocument("iCloud Drive is unavailable") }
                result = try await CloudFolderSync(repository: repository, deviceID: settings.deviceID).yearlyMaintenance(folder: folder, year: year, trackingCleanupYear: cleanupYear)
            case .oneDrive:
                guard let clientID = oneDriveClientID else { throw STGError.invalidDocument("OneDrive Client ID is missing") }
                result = try await OneDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, credentialService: oneDriveCredentialService).yearlyMaintenance(year: year, trackingCleanupYear: cleanupYear)
            case .googleDrive:
                guard let clientID = googleDriveClientID else { throw STGError.invalidDocument("Google Drive Client ID is missing") }
                result = try await GoogleDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, clientSecret: googleDriveClientSecret ?? "", credentialService: googleDriveCredentialService).yearlyMaintenance(year: year, trackingCleanupYear: cleanupYear)
            case .none:
                return
            }
            try repository.completeYearlyAction(deviceID: settings.deviceID)
            diagnosticLog.record("yearly action complete; year=\(year); uploaded=\(result.uploaded); deleted_bitmaps=\(result.deletedBitmaps); deleted_weekly=\(result.deletedWeekly)", category: "sync")
        } catch {
            diagnosticLog.record("yearly action failed; year=\(year); stage=archive; \(DiagnosticLog.describe(error))", category: "sync")
        }
    }

    func openRouterWeeks(models: [String]) -> [OpenRouterWeeklyRankingRow] {
        (try? repository?.openRouterWeeks(models: models)) ?? []
    }

    func latestOpenRouterTopModels(metric: OpenRouterWeeklyMetric) -> [String] {
        (try? repository?.latestOpenRouterTopModels(metric: metric, limit: 10)) ?? []
    }
    var latestTrackingTopTwo: String { let names = (try? repository?.latestOpenRouterTopModels(metric: .totalTokens, limit: 2)) ?? []; return names.isEmpty ? String(localized: "Weekly data will appear after sync.") : names.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") }

    private static func dateLabel(_ date: Date, zone: String) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: zone) ?? .current; formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date) }

    private func tick() async {
        guard let repository else { return }
        let now = Date()
        let today = Self.dateLabel(now, zone: currentReportTimeZone)
        if today != reminderStateLocalDate {
            let previousDate = reminderStateLocalDate
            reminderStateLocalDate = today
            reminderState.lastReminder = .posture
            try? repository.saveReminderState(deviceID: settings.deviceID, state: reminderState, updatedAt: now)
            diagnosticLog.record("daily reminder slot reset; previous_date=\(previousDate); local_date=\(today); next_slot=posture", category: "reminder")
        }
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
            try repository.updateRuntimeState(deviceID: settings.deviceID, continuousMinutes: reminderState.continuousMinutes, localDailyMinutes: localMinutes, aggregateDailyMinutes: allMinutes, localDate: Self.dateLabel(now, zone: currentReportTimeZone), at: now)
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
        if notificationName == NSWorkspace.sessionDidResignActiveNotification.rawValue {
            diagnosticLog.record("incremental sync requested; trigger=screen_lock", category: "sync")
            Task { await synchronize() }
        } else {
            Task { await quickUpload(trigger: "sleep_or_display_sleep") }
        }
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

    func exportAppData() {
        guard let repository else { syncStatus = "Database unavailable"; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "STG Data.stgdata"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try repository.exportDatabaseSnapshot(to: destination.appendingPathComponent("stg.sqlite"))
            try JSONEncoder.stg.encode(settings).write(to: destination.appendingPathComponent("global-settings.json"), options: .atomic)
            diagnosticLog.record("database and global data exported; destination=\(destination.lastPathComponent)", category: "diagnostics")
        } catch { syncStatus = "Data export failed: \(error.localizedDescription)" }
    }

    func requestOneDriveSignIn() {
        guard let clientID = oneDriveClientID else {
            syncStatus = "OneDrive sign-in unavailable: Microsoft Entra Client ID is missing"
            diagnosticLog.record("OneDrive sign-in blocked; missing_client_id", category: "sync")
            return
        }
        syncStatus = "Opening Microsoft account sign-in…"
        diagnosticLog.record("OneDrive sign-in begin", category: "sync")
        Task {
            do {
                let client = OneDriveClient(clientID: clientID)
                let request = try await client.authorizationRequest(callbackScheme: "msauth.com.timbertrail.screentimeguardian.ios")
                let callback = try await webAuthentication.authenticate(url: request.authorizationURL, callbackScheme: request.callbackScheme)
                let credential = try await client.credential(callbackURL: callback, request: request)
                let account = try await client.account(using: credential)
                // Do not make a partially validated sign-in look connected.
                try OneDriveCredentialStore.save(credential, service: oneDriveCredentialService)
                oneDriveAccountLabel = "\(account.displayName) (\(account.email))"
                UserDefaults.standard.set(oneDriveAccountLabel, forKey: "oneDriveAccountLabel")
                syncStatus = "OneDrive signed in as \(oneDriveAccountLabel)"
                diagnosticLog.record("OneDrive sign-in complete; account=authorized", category: "sync")
            } catch { webAuthentication.cancel(); syncStatus = error.localizedDescription; diagnosticLog.record("OneDrive sign-in failed: \(error.localizedDescription)", category: "sync") }
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
                let account = try await client.account(using: credential)
                // Persist only after both token exchange and account validation succeed.
                try GoogleDriveCredentialStore.save(credential, service: googleDriveCredentialService)
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
