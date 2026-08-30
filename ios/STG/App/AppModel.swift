import AuthenticationServices
import BackgroundTasks
import Foundation
import STGCore
import UserNotifications
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = SharedEnvironment.loadAppSettings()
    @Published var localMinutes = 0
    @Published var allMinutes = 0
    @Published var dayBitmaps: [DeviceDayBitmap] = []
    @Published var syncStatus = "Sync off — choose a provider in Settings"
    @Published var oneDriveAccountLabel = SharedEnvironment.defaults.string(forKey: "oneDriveAccountLabel") ?? "Not signed in"
    @Published var oneDriveUserCode: String?
    @Published var googleDriveAccountLabel = SharedEnvironment.defaults.string(forKey: "googleDriveAccountLabel") ?? "Not signed in"
    @Published var iCloudAccountLabel = FileManager.default.ubiquityIdentityToken == nil ? "Not signed in" : "System Apple Account"
    @Published private(set) var verifiedSyncProvider: SyncProvider?
    private let repository: BitmapRepository?
    private let webAuthentication = IOSWebAuthenticationPresenter()
    private var syncInProgress = false
    private static let verifiedSyncProviderKey = "privateCloudVerifiedProvider"
    var testLogURL: URL { SharedEnvironment.diagnosticLog.fileURL }

    var privateCloudAccountConnected: Bool { isConnected(settings.syncProvider ?? .none) }
    var privateCloudSetupComplete: Bool {
        let provider = settings.syncProvider ?? .none
        return provider != .none && provider == verifiedSyncProvider && isConnected(provider)
    }

    func prepareTestLogExport() -> URL? {
        SharedEnvironment.diagnosticLog.record("test log export requested", category: "diagnostics")
        do { return try SharedEnvironment.diagnosticLog.makeExportSnapshot() }
        catch { syncStatus = "Log export failed: \(error.localizedDescription)"; return nil }
    }

    func finishTestLogExport(completed: Bool) {
        if completed { SharedEnvironment.diagnosticLog.clear() }
    }

    init() {
        verifiedSyncProvider = SharedEnvironment.defaults.string(forKey: Self.verifiedSyncProviderKey).flatMap(SyncProvider.init(rawValue:))
        SharedEnvironment.migrateCloudCredentialsToSharedKeychain()
        do { repository = try SharedEnvironment.repository() }
        catch { repository = nil; syncStatus = "Database unavailable: \(error.localizedDescription)" }
        let provider = settings.syncProvider ?? .none
        if provider != .none { syncStatus = isConnected(provider) ? "\(syncProviderName(provider)) connected" : "\(syncProviderName(provider)) account sign-in required" }
        SharedEnvironment.diagnosticLog.record("launch; repository=\(repository == nil ? "unavailable" : "ready"); provider=\(provider.rawValue); device=\(settings.deviceID.prefix(8))", category: "lifecycle")
        registerBackgroundHandler()
    }

    func refresh() async {
        guard let repository else { return }
        let deviceID = settings.deviceID
        let deviceName = settings.deviceName
        let deviceUpdatedAt = settings.updatedAt
        let timeZoneID = settings.reportTimeZone
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
                var bitmaps = [DeviceDayBitmap(deviceID: "alldevices", displayName: "All devices", minutes: aggregate, isAggregate: true, usedMinutes: aggregateCount)]
                for id in ids {
                    let name = id == deviceID ? deviceName : (deviceNames[id] ?? "Other device")
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
            syncStatus = "Refresh failed: \(error.localizedDescription)"
            SharedEnvironment.diagnosticLog.record(syncStatus, category: "database")
        }
    }

    func reportDay(at instant: Date) async -> [DeviceDayBitmap] {
        guard let repository else { return [] }
        let deviceID = settings.deviceID, deviceName = settings.deviceName, kind = settings.deviceKind, zone = settings.reportTimeZone
        let includeSynced = isConnected(settings.syncProvider ?? .none)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try repository.dayReport(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: kind, instant: instant, timeZoneID: zone, includeSyncedDevices: includeSynced)
            }.value
            SharedEnvironment.diagnosticLog.record("selected day report complete; date=\(reportDateLabel(instant, timeZoneID: zone)); devices=\(result.count); totals=[\(result.map { "\($0.deviceID.prefix(8))=\($0.usedMinutes)m" }.joined(separator: ","))]", category: "report")
            return result
        } catch {
            syncStatus = "Report failed: \(error.localizedDescription)"
            SharedEnvironment.diagnosticLog.record(syncStatus, category: "report")
            return []
        }
    }

    func multiDayReport(from start: Date, through end: Date) async -> [DailyUsagePoint] {
        guard let repository else { return [] }
        let deviceID = settings.deviceID, deviceName = settings.deviceName, kind = settings.deviceKind, zone = settings.reportTimeZone
        let includeSynced = isConnected(settings.syncProvider ?? .none)
        do {
            let points = try await Task.detached(priority: .userInitiated) {
                try repository.multiDayReport(localDeviceID: deviceID, localDeviceName: deviceName, localDeviceKind: kind, start: start, end: end, timeZoneID: zone, includeSyncedDevices: includeSynced)
            }.value
            SharedEnvironment.diagnosticLog.record("multi-day report complete; start=\(reportDateLabel(start, timeZoneID: zone)); end=\(reportDateLabel(end, timeZoneID: zone)); points=\(points.count); series=\(Set(points.map(\.deviceID)).count)", category: "report")
            return points
        } catch {
            syncStatus = "Multi-day report failed: \(error.localizedDescription)"
            SharedEnvironment.diagnosticLog.record(syncStatus, category: "report")
            return []
        }
    }

    func save() {
        settings.updatedAt = .now
        do {
            try SharedEnvironment.saveSettings(settings)
            try repository?.upsertDevice(DeviceRecord(deviceID: settings.deviceID, name: settings.deviceName, kind: settings.deviceKind, updatedAt: settings.updatedAt))
            SharedEnvironment.diagnosticLog.record("settings saved; plan=\(settings.dailyPlanMinutes)m; timezone=\(settings.reportTimeZone); provider=\((settings.syncProvider ?? .none).rawValue); meeting=\(settings.meetingMode)")
        }
        catch { syncStatus = error.localizedDescription; SharedEnvironment.diagnosticLog.record("settings save failed: \(error.localizedDescription)", category: "error") }
    }

    func sync() async {
        guard let repository else { return }
        guard !syncInProgress else { SharedEnvironment.diagnosticLog.record("sync request coalesced; another sync is running", category: "sync"); return }
        syncInProgress = true
        defer { syncInProgress = false }
        let provider = settings.syncProvider ?? .none
        guard provider != .none else {
            syncStatus = "Sync off — choose a provider in Settings"
            SharedEnvironment.diagnosticLog.record("sync skipped; provider=none", category: "sync")
            return
        }
        if provider == .oneDrive {
            guard let clientID = oneDriveClientID else { syncStatus = "OneDrive developer Client ID is not configured"; SharedEnvironment.diagnosticLog.record("sync blocked; provider=oneDrive; missing_client_id", category: "sync"); return }
            guard OneDriveCredentialStore.load(service: SharedEnvironment.oneDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup) != nil else { syncStatus = "OneDrive account sign-in required"; SharedEnvironment.diagnosticLog.record("sync blocked; provider=oneDrive; account_not_signed_in", category: "sync"); return }
            syncStatus = "Syncing OneDrive…"; SharedEnvironment.diagnosticLog.record("sync begin; provider=oneDrive; local_device=\(settings.deviceID.prefix(8))", category: "sync")
            do {
                let result = try await OneDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, credentialService: SharedEnvironment.oneDriveCredentialService, credentialAccessGroup: SharedEnvironment.keychainAccessGroup).synchronize(settings: settings)
                syncStatus = "Uploaded \(result.uploaded), downloaded \(result.downloaded)"
                markPrivateCloudVerified(.oneDrive)
                SharedEnvironment.diagnosticLog.record("OneDrive sync complete; uploaded=\(result.uploaded); downloaded=\(result.downloaded); upload_cursor=\(result.uploadCursor ?? "none"); discovered=[\(result.discoveredDeviceIDs.map { String($0.prefix(8)) }.sorted().joined(separator: ","))]; download_cursors=[\(result.downloadCursors.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))=\($0.value)" }.joined(separator: ","))]", category: "sync")
                await runWeeklyActionIfDue()
                await refresh()
            } catch { syncStatus = "OneDrive sync failed: \(error.localizedDescription)"; SharedEnvironment.diagnosticLog.record(syncStatus, category: "sync") }
            return
        }
        if provider == .googleDrive {
            guard let clientID = googleDriveClientID else { syncStatus = "Google Drive developer OAuth Client ID is not configured"; SharedEnvironment.diagnosticLog.record("sync blocked; provider=googleDrive; missing_client_id", category: "sync"); return }
            guard GoogleDriveCredentialStore.load(service: SharedEnvironment.googleDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup) != nil else { syncStatus = "Google Drive account sign-in required"; return }
            syncStatus = "Syncing Google Drive…"; SharedEnvironment.diagnosticLog.record("sync begin; provider=googleDrive; local_device=\(settings.deviceID.prefix(8))", category: "sync")
            do {
                let result = try await GoogleDriveSync(repository: repository, deviceID: settings.deviceID, clientID: clientID, credentialService: SharedEnvironment.googleDriveCredentialService, credentialAccessGroup: SharedEnvironment.keychainAccessGroup).synchronize(settings: settings)
                syncStatus = "Uploaded \(result.uploaded), downloaded \(result.downloaded)"
                markPrivateCloudVerified(.googleDrive)
                SharedEnvironment.diagnosticLog.record("Google Drive sync complete; uploaded=\(result.uploaded); downloaded=\(result.downloaded); upload_cursor=\(result.uploadCursor ?? "none"); discovered=[\(result.discoveredDeviceIDs.map { String($0.prefix(8)) }.sorted().joined(separator: ","))]; download_cursors=[\(result.downloadCursors.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))=\($0.value)" }.joined(separator: ","))]", category: "sync")
                await runWeeklyActionIfDue()
                await refresh()
            } catch { syncStatus = "Google Drive sync failed: \(error.localizedDescription)"; SharedEnvironment.diagnosticLog.record(syncStatus, category: "sync") }
            return
        }
        guard provider == .iCloudDrive else { return }
        syncStatus = "Syncing…"
        SharedEnvironment.diagnosticLog.record("sync begin; provider=iCloudDrive; local_device=\(settings.deviceID.prefix(8))", category: "sync")
        do {
            guard let folder = await Task.detached(priority: .utility, operation: { SharedEnvironment.cloudFolder() }).value else {
                iCloudAccountLabel = "Not signed in"; syncStatus = "iCloud Drive unavailable — sign in to Apple Account in Settings"; return
            }
            iCloudAccountLabel = "System Apple Account"
            let coordinator = CloudFolderSync(repository: repository, deviceID: settings.deviceID)
            try await coordinator.uploadSettings(folder: folder, settings: settings)
            let result = try await coordinator.incrementalSync(folder: folder, uploadCursorTarget: "iCloudDrive")
            syncStatus = "Uploaded \(result.uploaded), downloaded \(result.downloaded)"
            markPrivateCloudVerified(.iCloudDrive)
            let discovered = result.discoveredDeviceIDs.map { String($0.prefix(8)) }.sorted().joined(separator: ",")
            SharedEnvironment.diagnosticLog.record("sync complete; uploaded=\(result.uploaded); downloaded=\(result.downloaded); upload_cursor=\(result.uploadCursor ?? "none"); discovered=[\(discovered)]; download_cursors=[\(result.downloadCursors.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))=\($0.value)" }.joined(separator: ","))]", category: "sync")
            await runWeeklyActionIfDue()
            await refresh()
        } catch {
            syncStatus = "Sync failed: \(error.localizedDescription)"
            SharedEnvironment.diagnosticLog.record(syncStatus, category: "sync")
        }
    }

    private func runWeeklyActionIfDue() async {
        guard let repository else { return }
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
            try repository.completeWeeklyAction()
            SharedEnvironment.diagnosticLog.record("weekly action complete; openrouter_rows=\(values.count); weeks=\(Set(values.map(\.weekStart)).count); completion_recorded=true", category: "sync")
        } catch { SharedEnvironment.diagnosticLog.record("weekly action failed; completion_not_recorded=true; error=\(error.localizedDescription)", category: "sync") }
    }

    func openRouterWeeks(models: [String]) -> [OpenRouterWeeklyRankingRow] { (try? repository?.openRouterWeeks(models: models)) ?? [] }
    func latestOpenRouterTopModels() -> [String] { (try? repository?.latestOpenRouterTopModels(limit: 10)) ?? [] }

    func requestOneDriveSignIn() {
        guard let clientID = oneDriveClientID else {
            syncStatus = "OneDrive sign-in unavailable: Microsoft Entra Client ID is missing"
            SharedEnvironment.diagnosticLog.record("OneDrive sign-in blocked; missing_client_id", category: "sync"); return
        }
        syncStatus = "Requesting Microsoft sign-in code…"; SharedEnvironment.diagnosticLog.record("OneDrive sign-in begin", category: "sync")
        Task {
            do {
                let client = OneDriveClient(clientID: clientID)
                let code = try await client.requestDeviceCode(); oneDriveUserCode = code.userCode
                SharedEnvironment.diagnosticLog.record("OneDrive device code issued; expires_in=\(code.expiresIn)s; polling_interval=\(code.interval)s", category: "sync")
                UIPasteboard.general.string = code.userCode
                webAuthentication.present(url: code.verificationURL)
                syncStatus = "Enter code \(code.userCode) in Microsoft sign-in; code copied"
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
                syncStatus = "OneDrive signed in as \(oneDriveAccountLabel)"
                SharedEnvironment.diagnosticLog.record("OneDrive sign-in complete; account=authorized", category: "sync")
                await sync()
            } catch {
                webAuthentication.cancel(); oneDriveUserCode = nil
                let detail = error.localizedDescription
                syncStatus = detail
                SharedEnvironment.diagnosticLog.record("OneDrive sign-in failed; detail=\(detail); type=\(String(reflecting: type(of: error)))", category: "sync")
            }
        }
    }

    func signOutOneDrive() {
        OneDriveCredentialStore.remove(service: SharedEnvironment.oneDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup)
        OneDriveCredentialStore.remove(service: SharedEnvironment.oneDriveCredentialService)
        oneDriveAccountLabel = "Not signed in"; SharedEnvironment.defaults.removeObject(forKey: "oneDriveAccountLabel")
        clearPrivateCloudVerification(ifMatching: .oneDrive)
        syncStatus = "OneDrive signed out"; SharedEnvironment.diagnosticLog.record("OneDrive signed out", category: "sync")
    }

    private var oneDriveClientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "STGOneDriveClientID") as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    func requestGoogleDriveSignIn() {
        guard let clientID = googleDriveClientID else {
            syncStatus = "Google Drive sign-in unavailable: OAuth Client ID is missing"; SharedEnvironment.diagnosticLog.record("Google Drive sign-in blocked; missing_client_id", category: "sync"); return
        }
        syncStatus = "Opening Google account sign-in…"; SharedEnvironment.diagnosticLog.record("Google Drive sign-in begin", category: "sync")
        Task {
            do {
                let client = GoogleDriveClient(clientID: clientID)
                let request = try await client.authorizationRequest(callbackScheme: googleCallbackScheme)
                let callback = try await webAuthentication.authenticate(url: request.authorizationURL, callbackScheme: request.callbackScheme)
                let credential = try await client.credential(callbackURL: callback, request: request)
                try GoogleDriveCredentialStore.save(credential, service: SharedEnvironment.googleDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup)
                let account = try await client.account(using: credential)
                googleDriveAccountLabel = "\(account.displayName) (\(account.email))"; SharedEnvironment.defaults.set(googleDriveAccountLabel, forKey: "googleDriveAccountLabel")
                syncStatus = "Google Drive signed in as \(googleDriveAccountLabel)"; SharedEnvironment.diagnosticLog.record("Google Drive sign-in complete; account=authorized", category: "sync")
                await sync()
            } catch { syncStatus = error.localizedDescription; SharedEnvironment.diagnosticLog.record("Google Drive sign-in failed: \(error.localizedDescription)", category: "sync") }
        }
    }

    func signOutGoogleDrive() {
        let credential = GoogleDriveCredentialStore.load(service: SharedEnvironment.googleDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup)
        GoogleDriveCredentialStore.remove(service: SharedEnvironment.googleDriveCredentialService, accessGroup: SharedEnvironment.keychainAccessGroup)
        GoogleDriveCredentialStore.remove(service: SharedEnvironment.googleDriveCredentialService)
        googleDriveAccountLabel = "Not signed in"; SharedEnvironment.defaults.removeObject(forKey: "googleDriveAccountLabel")
        clearPrivateCloudVerification(ifMatching: .googleDrive)
        syncStatus = "Google Drive signed out"; SharedEnvironment.diagnosticLog.record("Google Drive signed out", category: "sync")
        if let credential, let clientID = googleDriveClientID { Task { await GoogleDriveClient(clientID: clientID).revoke(credential) } }
    }

    func connect(to provider: SyncProvider) {
        switch provider {
        case .none: syncStatus = "Sync off"
        case .iCloudDrive:
            if FileManager.default.ubiquityIdentityToken != nil {
                iCloudAccountLabel = "System Apple Account"; syncStatus = "iCloud Drive connected"
                Task { await sync() }
            } else {
                iCloudAccountLabel = "Not signed in"; syncStatus = "Sign in to Apple Account in iOS Settings"
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
        guard let repository else { return }
        let deviceID = settings.deviceID
        do {
            let count = try await Task.detached { try repository.clearLocalDay(deviceID: deviceID, instant: .now, timeZoneID: TimeZone.current.identifier) }.value
            SharedEnvironment.diagnosticLog.record("user cleared today's estimate; removed_minutes=\(count)", category: "screen-time")
            await refresh()
        } catch { syncStatus = "Reset failed: \(error.localizedDescription)" }
    }

    func clearImportedDevices() async {
        guard let repository else { return }
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
