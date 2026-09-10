import AuthenticationServices
import BackgroundTasks
import Foundation
import STGCore
import UserNotifications
import UIKit

@MainActor
final class AppModel: ObservableObject {
    private let constructionStartedAt = ProcessInfo.processInfo.systemUptime
    @Published var settings = SharedEnvironment.loadAppSettings()
    @Published var localMinutes = 0
    @Published var allMinutes = 0
    @Published var dayBitmaps: [DeviceDayBitmap] = []
    @Published var statisticsSummary = UsageStatisticsSummary()
    @Published var syncStatus = "Sync is off."
    @Published var oneDriveAccountLabel = SharedEnvironment.defaults.string(forKey: "oneDriveAccountLabel") ?? "Not signed in"
    @Published var oneDriveUserCode: String?
    @Published var googleDriveAccountLabel = SharedEnvironment.defaults.string(forKey: "googleDriveAccountLabel") ?? "Not signed in"
    @Published var iCloudAccountLabel = "Checking…"
    @Published private(set) var trackingHistoryPreparing = true
    @Published private(set) var verifiedSyncProvider: SyncProvider?
    private var repository: BitmapRepository?
    private var repositoryTask: Task<(BitmapRepository?, String?, Int), Never>?
    private let webAuthentication = IOSWebAuthenticationPresenter()
    private var syncInProgress = false
    private var deferredStartupBegan = false
    private var firstFrameRecorded = false
    private static let verifiedSyncProviderKey = "privateCloudVerifiedProvider"
    var testLogURL: URL { SharedEnvironment.diagnosticLog.fileURL }
    var currentReportTimeZone: String { TimeZone.current.identifier }

    var privateCloudAccountConnected: Bool { isConnected(settings.syncProvider ?? .none) }
    var privateCloudSetupComplete: Bool {
        let provider = settings.syncProvider ?? .none
        return provider != .none && provider == verifiedSyncProvider && isConnected(provider)
    }

    func prepareTestLogExport() -> URL? {
        SharedEnvironment.diagnosticLog.record("test log export requested", category: "diagnostics")
        do { return try SharedEnvironment.diagnosticLog.makeExportSnapshot() }
        catch { syncStatus = "Couldn’t export the test log."; SharedEnvironment.diagnosticLog.record("test log export failed; error=\(error.localizedDescription)", category: "diagnostics"); return nil }
    }

    func finishTestLogExport(completed: Bool) {
        if completed { SharedEnvironment.diagnosticLog.clear() }
    }

    func prepareDataExport() async -> [URL]? {
        guard let repository = await readyRepository() else { syncStatus = "Database unavailable."; return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("STG-data-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = directory.appendingPathComponent("stg.sqlite")
            try repository.exportDatabaseSnapshot(to: database)
            let settingsURL = directory.appendingPathComponent("global-settings.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(settings).write(to: settingsURL, options: .atomic)
            SharedEnvironment.diagnosticLog.record("database and global data export prepared", category: "diagnostics")
            return [database, settingsURL]
        } catch {
            syncStatus = "Couldn’t export app data."
            SharedEnvironment.diagnosticLog.record("database and global data export failed; error=\(error.localizedDescription)", category: "diagnostics")
            return nil
        }
    }

    init() {
        verifiedSyncProvider = SharedEnvironment.defaults.string(forKey: Self.verifiedSyncProviderKey).flatMap(SyncProvider.init(rawValue:))
        settings.reportTimeZone = TimeZone.current.identifier
        let provider = settings.syncProvider ?? .none
        if provider != .none { syncStatus = "Checking \(syncProviderName(provider))…" }
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - constructionStartedAt) * 1_000)
        SharedEnvironment.diagnosticLog.record("launch shell ready; elapsed=\(elapsed)ms; repository=deferred; provider=\(provider.rawValue); device=\(settings.deviceID.prefix(8))", category: "lifecycle")
        registerBackgroundHandler()
    }

    func recordFirstFrame() {
        guard !firstFrameRecorded else { return }
        firstFrameRecorded = true
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - constructionStartedAt) * 1_000)
        SharedEnvironment.diagnosticLog.record("first UI frame presented; elapsed_since_model_init=\(elapsed)ms", category: "lifecycle")
    }

    private func readyRepository() async -> BitmapRepository? {
        if let repository { return repository }
        if let repositoryTask {
            let result = await repositoryTask.value
            return finishRepositoryBootstrap(result)
        }

        SharedEnvironment.diagnosticLog.record("database bootstrap begin; execution=background", category: "lifecycle")
        let task = Task.detached(priority: .userInitiated) { () -> (BitmapRepository?, String?, Int) in
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let repository = try SharedEnvironment.repository()
                return (repository, nil, Int((ProcessInfo.processInfo.systemUptime - started) * 1_000))
            } catch {
                return (nil, error.localizedDescription, Int((ProcessInfo.processInfo.systemUptime - started) * 1_000))
            }
        }
        repositoryTask = task
        return finishRepositoryBootstrap(await task.value)
    }

    private func finishRepositoryBootstrap(_ result: (BitmapRepository?, String?, Int)) -> BitmapRepository? {
        if let repository { return repository }
        repositoryTask = nil
        repository = result.0
        if let error = result.1 {
            syncStatus = "The database is unavailable."
            SharedEnvironment.diagnosticLog.record("database bootstrap failed; duration=\(result.2)ms; error=\(error)", category: "database")
        } else {
            SharedEnvironment.diagnosticLog.record("database bootstrap complete; duration=\(result.2)ms", category: "lifecycle")
        }
        return repository
    }

    /// Starts nonessential cold-launch work after SwiftUI has presented its
    /// first frame. Nothing here may delay the setup UI.
    func beginDeferredStartup() {
        guard !deferredStartupBegan else { return }
        deferredStartupBegan = true
        let provider = settings.syncProvider ?? .none
        SharedEnvironment.diagnosticLog.record("deferred startup begin; tracking_seed=background; cloud_state=background", category: "lifecycle")
        Task { @MainActor [weak self] in
            guard let self, let repository = await self.readyRepository() else {
                self?.trackingHistoryPreparing = false
                return
            }
            let result = await Task.detached(priority: .utility) {
                var importedSeed = false
                var seedError: String?
                do { importedSeed = try repository.importBundledOpenRouterSeedIfNeeded() }
                catch { seedError = error.localizedDescription }

                SharedEnvironment.migrateCloudCredentialsToSharedKeychain()
                let iCloudAvailable = FileManager.default.ubiquityIdentityToken != nil
                let providerConnected: Bool
                switch provider {
                case .none: providerConnected = false
                case .iCloudDrive: providerConnected = iCloudAvailable
                case .oneDrive:
                    providerConnected = OneDriveCredentialStore.load(service: SharedEnvironment.oneDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup) != nil
                case .googleDrive:
                    providerConnected = GoogleDriveCredentialStore.load(service: SharedEnvironment.googleDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup) != nil
                }
                return (importedSeed, seedError, iCloudAvailable, providerConnected)
            }.value
            self.trackingHistoryPreparing = false
            self.iCloudAccountLabel = result.2 ? "Apple Account on This Device" : "Not signed in"
            if provider != .none {
                self.syncStatus = result.3 ? "\(syncProviderName(provider)) is connected." : "Sign in to \(syncProviderName(provider)) to sync."
            }
            if let error = result.1 {
                SharedEnvironment.diagnosticLog.record("deferred tracking seed import failed; error=\(error)", category: "tracking")
            } else {
                SharedEnvironment.diagnosticLog.record("deferred tracking seed ready; imported=\(result.0)", category: "tracking")
            }
            SharedEnvironment.diagnosticLog.record("deferred startup complete; iCloud_available=\(result.2); provider_connected=\(result.3)", category: "lifecycle")
        }
    }

    func refresh() async {
        guard let repository = await readyRepository() else { return }
        let deviceID = settings.deviceID
        let deviceName = settings.deviceName
        let deviceUpdatedAt = settings.updatedAt
        let timeZoneID = currentReportTimeZone
        let provider = settings.syncProvider ?? .none
        let syncEnabled = isConnected(provider)
        SharedEnvironment.diagnosticLog.record("refresh begin; local_device=\(deviceID.prefix(8)); timezone=\(timeZoneID); sync_enabled=\(syncEnabled); database=\(SharedEnvironment.databaseURL.path)", category: "report")
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let now = Date()
                try repository.upsertDevice(DeviceRecord(deviceID: deviceID, name: deviceName, kind: .ios, updatedAt: deviceUpdatedAt))
                let deviceNames = Dictionary(uniqueKeysWithValues: try repository.deviceRecords().map { ($0.deviceID, $0.name) })
                let local = try repository.localClockDayBitmap(deviceID: deviceID, instant: now, timeZoneID: timeZoneID)
                let localCount = try repository.localDayMinutes(deviceID: deviceID, instant: now, timeZoneID: timeZoneID)
                let databaseIDs = try repository.deviceIDs()
                let databaseCounts = try databaseIDs.map { id in
                    (id, try repository.localDayMinutes(deviceID: id, instant: now, timeZoneID: timeZoneID))
                }
                let storedAggregateCount = try repository.localDayMinutes(deviceID: "alldevices", instant: now, timeZoneID: timeZoneID)
                let aggregate: [Bool]
                let aggregateCount: Int
                var ids: [String]
                if syncEnabled {
                    for key in STGTime.utcDateKeys(overlapping: STGTime.localDayInterval(containing: now, timeZoneID: timeZoneID)) { _ = try repository.rebuildAllDevices(utcDate: key) }
                    aggregate = try repository.localClockDayBitmap(deviceID: "alldevices", instant: now, timeZoneID: timeZoneID)
                    aggregateCount = try repository.localDayMinutes(deviceID: "alldevices", instant: now, timeZoneID: timeZoneID)
                    ids = try repository.deviceIDs()
                } else {
                    aggregate = local
                    aggregateCount = localCount
                    ids = [deviceID]
                }
                if !ids.contains(deviceID) { ids.insert(deviceID, at: 0) }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
                formatter.dateFormat = "yyyy-MM-dd"
                try repository.updateRuntimeState(
                    deviceID: deviceID,
                    continuousMinutes: 0,
                    localDailyMinutes: localCount,
                    aggregateDailyMinutes: aggregateCount,
                    localDate: formatter.string(from: now),
                    at: now
                )
                var bitmaps = [DeviceDayBitmap(deviceID: "alldevices", displayName: "All Devices", minutes: aggregate, isAggregate: true, usedMinutes: aggregateCount)]
                for id in ids {
                    let name = id == deviceID ? deviceName : (deviceNames[id] ?? "Other Device")
                    let clock = id == deviceID ? local : try repository.localClockDayBitmap(deviceID: id, instant: now, timeZoneID: timeZoneID)
                    let count = id == deviceID ? localCount : try repository.localDayMinutes(deviceID: id, instant: now, timeZoneID: timeZoneID)
                    bitmaps.append(DeviceDayBitmap(deviceID: id, displayName: name, minutes: clock, usedMinutes: count))
                }
                return (bitmaps, databaseCounts, storedAggregateCount)
            }.value
            let snapshot = result.0
            dayBitmaps = snapshot
            allMinutes = snapshot.first?.usedMinutes ?? 0
            localMinutes = snapshot.first(where: { $0.deviceID == deviceID })?.usedMinutes ?? 0
            let databaseDetails = result.1.map { "\($0.0.prefix(8))=\($0.1)m" }.joined(separator: ",")
            SharedEnvironment.diagnosticLog.record("database snapshot; local_device=\(deviceID.prefix(8)); rows=[\(databaseDetails)]; stored_aggregate=\(result.2)m", category: "report")
            let details = snapshot.map { "\($0.deviceID.prefix(8))=\($0.usedMinutes)m" }.joined(separator: ",")
            SharedEnvironment.diagnosticLog.record("refresh complete; local_device=\(deviceID.prefix(8)); aggregate_mode=\(syncEnabled ? "database_union" : "local_only"); displayed=[\(details)]", category: "report")
        } catch {
            syncStatus = "Couldn’t refresh. Try again."
            SharedEnvironment.diagnosticLog.record("refresh failed; error=\(error.localizedDescription)", category: "database")
        }
    }

    func reportDay(at instant: Date) async -> [DeviceDayBitmap] {
        guard let repository = await readyRepository() else { return [] }
        let deviceID = settings.deviceID, deviceName = settings.deviceName, kind = settings.deviceKind, zone = currentReportTimeZone, dailyLimit = settings.dailyPlanMinutes
        let includeSynced = isConnected(settings.syncProvider ?? .none)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let range = try repository.refreshStatistics(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: kind, dailyLimitMinutes: dailyLimit, timeZoneID: zone, includeSyncedDevices: includeSynced)
                let summary = try repository.statisticsSummary(reference: instant, timeZoneID: zone)
                return (try repository.dayReport(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: kind, instant: instant, timeZoneID: zone, includeSyncedDevices: includeSynced), summary, range)
            }.value
            statisticsSummary = result.1
            SharedEnvironment.diagnosticLog.record("statistics refresh complete; range=\(result.2.lowerBound)...\(result.2.upperBound); trigger=report_open; last_statistics_updated=true", category: "report")
            SharedEnvironment.diagnosticLog.record("selected day report complete; date=\(reportDateLabel(instant, timeZoneID: zone)); devices=\(result.0.count); totals=[\(result.0.map { "\($0.deviceID.prefix(8))=\($0.usedMinutes)m" }.joined(separator: ","))]", category: "report")
            return result.0
        } catch {
            syncStatus = "Couldn’t load the report. Try again."
            SharedEnvironment.diagnosticLog.record("report failed; error=\(error.localizedDescription)", category: "report")
            return []
        }
    }

    func multiDayReport(from start: Date, through end: Date) async -> [DailyUsagePoint] {
        guard let repository = await readyRepository() else { return [] }
        let deviceID = settings.deviceID, deviceName = settings.deviceName, kind = settings.deviceKind, zone = currentReportTimeZone, dailyLimit = settings.dailyPlanMinutes
        let includeSynced = isConnected(settings.syncProvider ?? .none)
        do {
            let points = try await Task.detached(priority: .userInitiated) {
                _ = try repository.refreshStatistics(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: kind, dailyLimitMinutes: dailyLimit, timeZoneID: zone, includeSyncedDevices: includeSynced)
                return try repository.multiDayReport(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: kind, start: start, end: end, timeZoneID: zone, includeSyncedDevices: includeSynced)
            }.value
            SharedEnvironment.diagnosticLog.record("multi-day report complete; start=\(reportDateLabel(start, timeZoneID: zone)); end=\(reportDateLabel(end, timeZoneID: zone)); points=\(points.count); series=\(Set(points.map(\.deviceID)).count)", category: "report")
            return points
        } catch {
            syncStatus = "Couldn’t load the date-range report. Try again."
            SharedEnvironment.diagnosticLog.record("multi-day report failed; error=\(error.localizedDescription)", category: "report")
            return []
        }
    }

    func periodReport(kind: String, from start: Date, through end: Date) async -> [PeriodUsagePoint] {
        guard let repository = await readyRepository() else { return [] }
        let deviceID = settings.deviceID, deviceName = settings.deviceName, deviceKind = settings.deviceKind, zone = currentReportTimeZone, dailyLimit = settings.dailyPlanMinutes
        let includeSynced = isConnected(settings.syncProvider ?? .none)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                _ = try repository.refreshStatistics(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: deviceKind, dailyLimitMinutes: dailyLimit, timeZoneID: zone, includeSyncedDevices: includeSynced)
                let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(identifier: zone) ?? .current; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
                return try repository.periodUsage(kind: kind, from: formatter.string(from: min(start, end)), through: formatter.string(from: max(start, end)))
            }.value
            SharedEnvironment.diagnosticLog.record("period report complete; kind=\(kind); points=\(result.count)", category: "report")
            return result
        } catch { SharedEnvironment.diagnosticLog.record("period report failed; kind=\(kind); error=\(error.localizedDescription)", category: "report"); return [] }
    }

    func save() {
        settings.reportTimeZone = currentReportTimeZone
        settings.updatedAt = .now
        do {
            try SharedEnvironment.saveSettings(settings)
            try repository?.upsertDevice(DeviceRecord(deviceID: settings.deviceID, name: settings.deviceName, kind: settings.deviceKind, updatedAt: settings.updatedAt))
            SharedEnvironment.diagnosticLog.record("settings saved; plan=\(settings.dailyPlanMinutes)m; timezone=\(settings.reportTimeZone); provider=\((settings.syncProvider ?? .none).rawValue); meeting=\(settings.meetingMode)")
        }
        catch { syncStatus = "Couldn’t save your settings."; SharedEnvironment.diagnosticLog.record("settings save failed: \(error.localizedDescription)", category: "error") }
    }

    func sync() async {
        guard let repository = await readyRepository() else { return }
        guard !syncInProgress else { SharedEnvironment.diagnosticLog.record("sync request coalesced; another sync is running", category: "sync"); return }
        syncInProgress = true
        defer { syncInProgress = false }
        let provider = settings.syncProvider ?? .none
        guard provider != .none else {
            syncStatus = "Sync is off."
            SharedEnvironment.diagnosticLog.record("sync skipped; provider=none", category: "sync")
            return
        }
        if provider == .oneDrive {
            guard let clientID = oneDriveClientID else { syncStatus = "OneDrive isn’t configured in this build."; SharedEnvironment.diagnosticLog.record("sync blocked; provider=oneDrive; missing_client_id", category: "sync"); return }
            guard OneDriveCredentialStore.load(service: SharedEnvironment.oneDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup) != nil else { syncStatus = "Sign in to OneDrive to sync."; SharedEnvironment.diagnosticLog.record("sync blocked; provider=oneDrive; account_not_signed_in", category: "sync"); return }
            syncStatus = "Syncing with OneDrive…"; SharedEnvironment.diagnosticLog.record("sync begin; provider=oneDrive; local_device=\(settings.deviceID.prefix(8))", category: "sync")
            do {
                let result = try await OneDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, credentialService: SharedEnvironment.oneDriveCredentialService, credentialAccessGroup: SharedEnvironment.keychainAccessGroup).synchronize(settings: settings)
                syncStatus = "Synced: \(result.uploaded) uploaded, \(result.downloaded) downloaded"
                markPrivateCloudVerified(.oneDrive)
                SharedEnvironment.diagnosticLog.record("OneDrive sync complete; uploaded=\(result.uploaded); downloaded=\(result.downloaded); upload_cursor=\(result.uploadCursor ?? "none"); discovered=[\(result.discoveredDeviceIDs.map { String($0.prefix(8)) }.sorted().joined(separator: ","))]; download_cursors=[\(result.downloadCursors.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))=\($0.value)" }.joined(separator: ","))]", category: "sync")
                await runWeeklyActionIfDue()
                await refresh()
            } catch { syncStatus = "OneDrive sync failed. Try again."; SharedEnvironment.diagnosticLog.record("OneDrive sync failed; error=\(error.localizedDescription)", category: "sync") }
            return
        }
        if provider == .googleDrive {
            guard let clientID = googleDriveClientID else { syncStatus = "Google Drive isn’t configured in this build."; SharedEnvironment.diagnosticLog.record("sync blocked; provider=googleDrive; missing_client_id", category: "sync"); return }
            guard GoogleDriveCredentialStore.load(service: SharedEnvironment.googleDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup) != nil else { syncStatus = "Sign in to Google Drive to sync."; return }
            syncStatus = "Syncing with Google Drive…"; SharedEnvironment.diagnosticLog.record("sync begin; provider=googleDrive; local_device=\(settings.deviceID.prefix(8))", category: "sync")
            do {
                let result = try await GoogleDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, credentialService: SharedEnvironment.googleDriveCredentialService, credentialAccessGroup: SharedEnvironment.keychainAccessGroup).synchronize(settings: settings)
                syncStatus = "Synced: \(result.uploaded) uploaded, \(result.downloaded) downloaded"
                markPrivateCloudVerified(.googleDrive)
                SharedEnvironment.diagnosticLog.record("Google Drive sync complete; uploaded=\(result.uploaded); downloaded=\(result.downloaded); upload_cursor=\(result.uploadCursor ?? "none"); discovered=[\(result.discoveredDeviceIDs.map { String($0.prefix(8)) }.sorted().joined(separator: ","))]; download_cursors=[\(result.downloadCursors.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))=\($0.value)" }.joined(separator: ","))]", category: "sync")
                await runWeeklyActionIfDue()
                await refresh()
            } catch { syncStatus = "Google Drive sync failed. Try again."; SharedEnvironment.diagnosticLog.record("Google Drive sync failed; error=\(error.localizedDescription)", category: "sync") }
            return
        }
        guard provider == .iCloudDrive else { return }
        syncStatus = "Syncing with iCloud Drive…"
        SharedEnvironment.diagnosticLog.record("sync begin; provider=iCloudDrive; local_device=\(settings.deviceID.prefix(8))", category: "sync")
        do {
            guard let folder = await Task.detached(priority: .utility, operation: { SharedEnvironment.cloudFolder() }).value else {
                iCloudAccountLabel = "Not signed in"; syncStatus = "iCloud Drive is unavailable. Sign in to your Apple Account and turn on iCloud Drive in Settings."; return
            }
            iCloudAccountLabel = "Apple Account on This Device"
            let coordinator = CloudFolderSync(repository: repository, deviceID: settings.deviceID)
            try await coordinator.uploadSettings(folder: folder, settings: settings)
            let result = try await coordinator.incrementalSync(folder: folder, uploadCursorTarget: "iCloudDrive")
            syncStatus = "Synced: \(result.uploaded) uploaded, \(result.downloaded) downloaded"
            markPrivateCloudVerified(.iCloudDrive)
            let discovered = result.discoveredDeviceIDs.map { String($0.prefix(8)) }.sorted().joined(separator: ",")
            SharedEnvironment.diagnosticLog.record("sync complete; uploaded=\(result.uploaded); downloaded=\(result.downloaded); upload_cursor=\(result.uploadCursor ?? "none"); discovered=[\(discovered)]; download_cursors=[\(result.downloadCursors.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))=\($0.value)" }.joined(separator: ","))]", category: "sync")
            await runWeeklyActionIfDue()
            await refresh()
        } catch {
            syncStatus = "Sync failed. Try again."
            SharedEnvironment.diagnosticLog.record("iCloud Drive sync failed; error=\(error.localizedDescription)", category: "sync")
        }
    }

    private func runWeeklyActionIfDue() async {
        guard let repository = await readyRepository() else { return }
        do { guard try repository.weeklyActionDue() else { return } }
        catch { SharedEnvironment.diagnosticLog.record("weekly action due check failed: \(error.localizedDescription)", category: "sync"); return }
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = STGTime.utc
        let today = calendar.startOfDay(for: .now)
        guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: today),
              let lastSunday = calendar.date(byAdding: .day, value: -1, to: currentWeek.start) else { return }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = STGTime.utc; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let first = formatter.date(from: "2025-01-01")!
        let totalCursorText = try? repository.latestOpenRouterWeekEnd()
        let totalStart = totalCursorText.flatMap(formatter.date(from:)).flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? first
        let start = totalStart
        SharedEnvironment.diagnosticLog.record("weekly action begin; openrouter_start=\(formatter.string(from: start)); openrouter_end=\(formatter.string(from: lastSunday)); latest_week_cursor=\(totalCursorText ?? "none")", category: "sync")
        do {
            let values = start <= lastSunday ? try await OpenRouterTrackingService.shared.weeklyHistory(startDate: formatter.string(from: start), endDate: formatter.string(from: lastSunday)) : []
            if start <= lastSunday && values.isEmpty { throw STGError.invalidDocument("OpenRouter returned no weekly model-activity rows; detail cursor was not advanced") }
            try repository.upsertOpenRouterWeeks(values)
            try repository.completeOpenRouterDetailWeek(through: formatter.string(from: lastSunday))
            let previousMonday = calendar.date(byAdding: .day, value: -6, to: lastSunday) ?? lastSunday
            let maintenance = try await performWeeklyCloudMaintenance(currentWeekStart: formatter.string(from: currentWeek.start), previousWeekStart: formatter.string(from: previousMonday), previousWeekEnd: formatter.string(from: lastSunday))
            try repository.completeWeeklyAction(deviceID: settings.deviceID)
            SharedEnvironment.diagnosticLog.record("weekly action complete; openrouter_rows=\(values.count); weeks=\(Set(values.map(\.weekStart)).count); bitmap_uploaded=\(maintenance.uploaded); daily_deleted=\(maintenance.deletedDaily); weekly_moved=\(maintenance.movedWeekly); completion_recorded=true", category: "sync")
            await runYearlyActionIfDue()
        } catch { SharedEnvironment.diagnosticLog.record("weekly action failed; completion_not_recorded=true; error=\(error.localizedDescription)", category: "sync") }
    }

    private func performWeeklyCloudMaintenance(currentWeekStart: String, previousWeekStart: String, previousWeekEnd: String) async throws -> (uploaded: Int, deletedDaily: Int, movedWeekly: Int) {
        guard let repository = await readyRepository() else { throw STGError.database("database unavailable") }
        switch settings.syncProvider ?? .none {
        case .iCloudDrive:
            guard let folder = SharedEnvironment.cloudFolder() else { throw STGError.invalidDocument("iCloud Drive is unavailable") }
            return try await CloudFolderSync(repository: repository, deviceID: settings.deviceID).weeklyMaintenance(folder: folder, currentWeekStart: currentWeekStart, previousWeekStart: previousWeekStart, previousWeekEnd: previousWeekEnd)
        case .oneDrive:
            guard let clientID = oneDriveClientID else { throw STGError.invalidDocument("OneDrive Client ID is missing") }
            return try await OneDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, credentialService: SharedEnvironment.oneDriveCredentialService, credentialAccessGroup: SharedEnvironment.keychainAccessGroup).weeklyMaintenance(currentWeekStart: currentWeekStart, previousWeekStart: previousWeekStart, previousWeekEnd: previousWeekEnd)
        case .googleDrive:
            guard let clientID = googleDriveClientID else { throw STGError.invalidDocument("Google Drive Client ID is missing") }
            return try await GoogleDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, credentialService: SharedEnvironment.googleDriveCredentialService, credentialAccessGroup: SharedEnvironment.keychainAccessGroup).weeklyMaintenance(currentWeekStart: currentWeekStart, previousWeekStart: previousWeekStart, previousWeekEnd: previousWeekEnd)
        case .none: throw STGError.invalidDocument("private cloud is not configured")
        }
    }

    private func runYearlyActionIfDue() async {
        guard let repository = await readyRepository(), (try? repository.yearlyActionDue(deviceID: settings.deviceID)) == true else { return }
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: .now), year = currentYear - 1, cleanupYear = currentYear - 2
        let start = String(format: "%04d-01-01", year), end = String(format: "%04d-12-31", year)
        do {
            let rows = try await OpenRouterTrackingService.shared.weeklyHistory(startDate: start, endDate: end); if !rows.isEmpty { try repository.upsertOpenRouterWeeks(rows) }
            let result: (uploaded: Int, deletedBitmaps: Int, deletedWeekly: Int)
            switch settings.syncProvider ?? .none {
            case .iCloudDrive:
                guard let folder = SharedEnvironment.cloudFolder() else { throw STGError.invalidDocument("iCloud Drive is unavailable") }
                result = try await CloudFolderSync(repository: repository, deviceID: settings.deviceID).yearlyMaintenance(folder: folder, year: year, trackingCleanupYear: cleanupYear)
            case .oneDrive:
                guard let clientID = oneDriveClientID else { throw STGError.invalidDocument("OneDrive Client ID is missing") }
                result = try await OneDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, credentialService: SharedEnvironment.oneDriveCredentialService, credentialAccessGroup: SharedEnvironment.keychainAccessGroup).yearlyMaintenance(year: year, trackingCleanupYear: cleanupYear)
            case .googleDrive:
                guard let clientID = googleDriveClientID else { throw STGError.invalidDocument("Google Drive Client ID is missing") }
                result = try await GoogleDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, credentialService: SharedEnvironment.googleDriveCredentialService, credentialAccessGroup: SharedEnvironment.keychainAccessGroup).yearlyMaintenance(year: year, trackingCleanupYear: cleanupYear)
            case .none: return
            }
            try repository.completeYearlyAction(deviceID: settings.deviceID)
            SharedEnvironment.diagnosticLog.record("yearly action complete; year=\(year); uploaded=\(result.uploaded); deleted_bitmaps=\(result.deletedBitmaps); deleted_weekly=\(result.deletedWeekly)", category: "sync")
        } catch { SharedEnvironment.diagnosticLog.record("yearly action failed; year=\(year); error=\(error.localizedDescription)", category: "sync") }
    }

    func openRouterWeeks(models: [String]) -> [OpenRouterWeeklyRankingRow] { (try? repository?.openRouterWeeks(models: models)) ?? [] }
    func latestOpenRouterTopModels(metric: OpenRouterWeeklyMetric) -> [String] { (try? repository?.latestOpenRouterTopModels(metric: metric, limit: 10)) ?? [] }
    var latestTrackingTopTwo: String { let names = (try? repository?.latestOpenRouterTopModels(metric: .totalTokens, limit: 2)) ?? []; return names.isEmpty ? String(localized: "Weekly data will appear after sync.") : names.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") }

    func requestOneDriveSignIn() {
        guard let clientID = oneDriveClientID else {
            syncStatus = "OneDrive isn’t configured in this build."
            SharedEnvironment.diagnosticLog.record("OneDrive sign-in blocked; missing_client_id", category: "sync"); return
        }
        syncStatus = "Requesting a Microsoft sign-in code…"; SharedEnvironment.diagnosticLog.record("OneDrive sign-in begin", category: "sync")
        Task {
            do {
                let client = OneDriveClient(clientID: clientID)
                let code = try await client.requestDeviceCode(); oneDriveUserCode = code.userCode
                SharedEnvironment.diagnosticLog.record("OneDrive device code issued; expires_in=\(code.expiresIn)s; polling_interval=\(code.interval)s", category: "sync")
                UIPasteboard.general.string = code.userCode
                webAuthentication.present(url: code.verificationURL)
                syncStatus = "Sign-in code \(code.userCode) copied. Complete sign-in in your browser."
                let credential = try await client.waitForAuthorization(code)
                SharedEnvironment.diagnosticLog.record("OneDrive authorization complete; refresh_token_present=\(!credential.refreshToken.isEmpty)", category: "sync")
                webAuthentication.cancel()
                try OneDriveCredentialStore.save(credential, service: SharedEnvironment.oneDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup)
                guard OneDriveCredentialStore.load(service: SharedEnvironment.oneDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup) != nil else {
                    throw STGError.invalidDocument("Microsoft credential was written but could not be read from the shared Keychain access group")
                }
                SharedEnvironment.diagnosticLog.record("OneDrive credential stored; access_group=shared", category: "sync")
                let account = try await client.account(using: credential)
                SharedEnvironment.diagnosticLog.record("OneDrive account profile loaded", category: "sync")
                oneDriveAccountLabel = "\(account.displayName) (\(account.email))"; oneDriveUserCode = nil
                SharedEnvironment.defaults.set(oneDriveAccountLabel, forKey: "oneDriveAccountLabel")
                syncStatus = "Signed in to OneDrive as \(oneDriveAccountLabel)."
                SharedEnvironment.diagnosticLog.record("OneDrive sign-in complete; account=authorized", category: "sync")
                await sync()
            } catch {
                webAuthentication.cancel(); oneDriveUserCode = nil
                let detail = error.localizedDescription
                syncStatus = "OneDrive sign-in failed. Try again."
                SharedEnvironment.diagnosticLog.record("OneDrive sign-in failed; detail=\(detail); type=\(String(reflecting: type(of: error)))", category: "sync")
            }
        }
    }

    func signOutOneDrive() {
        OneDriveCredentialStore.remove(service: SharedEnvironment.oneDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup)
        OneDriveCredentialStore.remove(service: SharedEnvironment.oneDriveCredentialService)
        oneDriveAccountLabel = "Not signed in"; SharedEnvironment.defaults.removeObject(forKey: "oneDriveAccountLabel")
        clearPrivateCloudVerification(ifMatching: .oneDrive)
        syncStatus = "Signed out of OneDrive."; SharedEnvironment.diagnosticLog.record("OneDrive signed out", category: "sync")
    }

    private var oneDriveClientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "STGOneDriveClientID") as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    func requestGoogleDriveSignIn() {
        guard let clientID = googleDriveClientID else {
            syncStatus = "Google Drive isn’t configured in this build."; SharedEnvironment.diagnosticLog.record("Google Drive sign-in blocked; missing_client_id", category: "sync"); return
        }
        syncStatus = "Opening Google Drive sign-in…"; SharedEnvironment.diagnosticLog.record("Google Drive sign-in begin", category: "sync")
        Task {
            do {
                let client = GoogleDriveClient(clientID: clientID)
                let request = try await client.authorizationRequest(callbackScheme: googleCallbackScheme)
                let callback = try await webAuthentication.authenticate(url: request.authorizationURL, callbackScheme: request.callbackScheme)
                let credential = try await client.credential(callbackURL: callback, request: request)
                try GoogleDriveCredentialStore.save(credential, service: SharedEnvironment.googleDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup)
                let account = try await client.account(using: credential)
                googleDriveAccountLabel = "\(account.displayName) (\(account.email))"; SharedEnvironment.defaults.set(googleDriveAccountLabel, forKey: "googleDriveAccountLabel")
                syncStatus = "Signed in to Google Drive as \(googleDriveAccountLabel)."; SharedEnvironment.diagnosticLog.record("Google Drive sign-in complete; account=authorized", category: "sync")
                await sync()
            } catch { syncStatus = "Google Drive sign-in failed. Try again."; SharedEnvironment.diagnosticLog.record("Google Drive sign-in failed: \(error.localizedDescription)", category: "sync") }
        }
    }

    func signOutGoogleDrive() {
        let credential = GoogleDriveCredentialStore.load(service: SharedEnvironment.googleDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup)
        GoogleDriveCredentialStore.remove(service: SharedEnvironment.googleDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup)
        GoogleDriveCredentialStore.remove(service: SharedEnvironment.googleDriveCredentialService)
        googleDriveAccountLabel = "Not signed in"; SharedEnvironment.defaults.removeObject(forKey: "googleDriveAccountLabel")
        clearPrivateCloudVerification(ifMatching: .googleDrive)
        syncStatus = "Signed out of Google Drive."; SharedEnvironment.diagnosticLog.record("Google Drive signed out", category: "sync")
        if let credential, let clientID = googleDriveClientID { Task { await GoogleDriveClient(clientID: clientID).revoke(credential) } }
    }

    func connect(to provider: SyncProvider) {
        switch provider {
        case .none: syncStatus = "Sync is off."
        case .iCloudDrive:
            if FileManager.default.ubiquityIdentityToken != nil {
                iCloudAccountLabel = "Apple Account on This Device"; syncStatus = "iCloud Drive is connected."
                Task { await sync() }
            } else {
                iCloudAccountLabel = "Not signed in"; syncStatus = "Sign in to your Apple Account and turn on iCloud Drive in Settings."
                openAppleAccountSettings()
            }
        case .oneDrive: if OneDriveCredentialStore.load(service: SharedEnvironment.oneDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup) == nil { requestOneDriveSignIn() }
        case .googleDrive: if GoogleDriveCredentialStore.load(service: SharedEnvironment.googleDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup) == nil { requestGoogleDriveSignIn() }
        }
    }

    func selectSyncProvider(_ provider: SyncProvider) {
        if (settings.syncProvider ?? .none) != provider {
            verifiedSyncProvider = nil
            SharedEnvironment.defaults.removeObject(forKey: Self.verifiedSyncProviderKey)
        }
        settings.syncProvider = provider
        settings.cloudFolderPath = nil
        save()
    }

    func openAppleAccountSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func isConnected(_ provider: SyncProvider) -> Bool {
        switch provider {
        case .none: false
        case .iCloudDrive: FileManager.default.ubiquityIdentityToken != nil
        case .oneDrive: OneDriveCredentialStore.load(service: SharedEnvironment.oneDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup) != nil
        case .googleDrive: GoogleDriveCredentialStore.load(service: SharedEnvironment.googleDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup) != nil
        }
    }

    private func markPrivateCloudVerified(_ provider: SyncProvider) {
        guard (settings.syncProvider ?? .none) == provider else { return }
        verifiedSyncProvider = provider
        SharedEnvironment.defaults.set(provider.rawValue, forKey: Self.verifiedSyncProviderKey)
        SharedEnvironment.diagnosticLog.record("private cloud setup verified; provider=\(provider.rawValue); initial_incremental_sync=success", category: "sync")
    }

    private func clearPrivateCloudVerification(ifMatching provider: SyncProvider) {
        guard verifiedSyncProvider == provider else { return }
        verifiedSyncProvider = nil
        SharedEnvironment.defaults.removeObject(forKey: Self.verifiedSyncProviderKey)
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

    func clearTodayEstimate() async {
        guard let repository = await readyRepository() else { return }
        let deviceID = settings.deviceID
        do {
            let count = try await Task.detached { try repository.clearLocalDay(deviceID: deviceID, instant: .now, timeZoneID: TimeZone.current.identifier) }.value
            SharedEnvironment.diagnosticLog.record("user cleared today's estimate; removed_minutes=\(count)", category: "screen-time")
            await refresh()
        } catch { syncStatus = "Reset failed: \(error.localizedDescription)" }
    }

    func clearImportedDevices() async {
        guard let repository = await readyRepository() else { return }
        let deviceID = settings.deviceID
        do {
            let count = try await Task.detached { try repository.deleteOtherDeviceData(localDeviceID: deviceID) }.value
            SharedEnvironment.diagnosticLog.record("user removed imported device rows; rows=\(count)", category: "sync")
            await refresh()
        } catch { syncStatus = "Device cleanup failed: \(error.localizedDescription)" }
    }

    private func registerBackgroundHandler() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.timbertrail.screentimeguardian.ios.refresh", using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { return }
            SharedEnvironment.diagnosticLog.record("background refresh started", category: "lifecycle")
            let operation = Task { @MainActor in
                await self.sync()
                refresh.setTaskCompleted(success: !Task.isCancelled)
                self.scheduleBackgroundRefresh()
            }
            refresh.expirationHandler = { operation.cancel() }
        }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.timbertrail.screentimeguardian.ios.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { SharedEnvironment.diagnosticLog.record("background schedule failed: \(error.localizedDescription)", category: "lifecycle") }
    }
}

private func reportDateLabel(_ date: Date, timeZoneID: String) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current; formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
}

@MainActor
private final class IOSWebAuthenticationPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
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
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
