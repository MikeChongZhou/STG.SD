import Foundation
import STGCore

actor ThresholdQuickSync {
    static let shared = ThresholdQuickSync()

    func bidirectional(settings: STGSettings, repository: BitmapRepository, threshold: Int, now: Date) async {
        let provider = settings.syncProvider ?? .none
        guard provider != .none else {
            SharedEnvironment.diagnosticLog.record("threshold quick sync skipped; event=\(threshold)m; provider=none", category: "sync")
            return
        }

        do {
            let state = try repository.quickSyncState(deviceID: settings.deviceID)
            let currentKey = STGTime.utcDateKey(for: now)
            let previousKey = STGTime.utcDateKey(for: now.addingTimeInterval(-86_400))
            let allowedKeys: Set<String> = [currentKey, previousKey]
            let pendingKeys = state.pendingUTCDateKeys.intersection(allowedKeys)
            let downloadKeys = pendingKeys.union([currentKey])
            var uploadKeys = pendingKeys
            let latestQuickUpload = max(state.lastBidirectionalAt, state.lastUploadAt)
            for key in downloadKeys {
                if let modifiedAt = try repository.bitmapUpdatedAt(deviceID: settings.deviceID, utcDate: key),
                   modifiedAt > latestQuickUpload {
                    uploadKeys.insert(key)
                }
            }

            SharedEnvironment.diagnosticLog.record(
                "threshold quick sync begin; event=\(threshold)m; provider=\(provider.rawValue); download_dates=\(list(downloadKeys)); upload_dates=\(list(uploadKeys)); pending=\(list(state.pendingUTCDateKeys))",
                category: "sync"
            )
            let result = try await synchronize(
                provider: provider,
                settings: settings,
                repository: repository,
                downloadKeys: downloadKeys,
                uploadKeys: uploadKeys
            )
            let completedAt = Date()
            try repository.completeQuickBidirectional(deviceID: settings.deviceID, at: completedAt)
            if !uploadKeys.isEmpty { try repository.completeQuickUpload(deviceID: settings.deviceID, utcDateKeys: uploadKeys, at: completedAt) }
            SharedEnvironment.diagnosticLog.record(
                "threshold quick sync complete; event=\(threshold)m; provider=\(provider.rawValue); uploaded=\(result.uploaded); downloaded=\(result.downloaded); failed=\(result.failed); discovered=[\(result.discoveredDeviceIDs.map { String($0.prefix(8)) }.sorted().joined(separator: ","))]",
                category: "sync"
            )
        } catch {
            SharedEnvironment.diagnosticLog.record("threshold quick sync failed; event=\(threshold)m; provider=\(provider.rawValue); error=\(error.localizedDescription)", category: "sync")
        }
    }

    func uploadChanged(settings: STGSettings, repository: BitmapRepository, threshold: Int, utcDateKeys: Set<String>) async {
        let provider = settings.syncProvider ?? .none
        guard provider != .none, !utcDateKeys.isEmpty else { return }
        do {
            try repository.queueQuickUpload(deviceID: settings.deviceID, utcDateKeys: utcDateKeys)
            SharedEnvironment.diagnosticLog.record("threshold quick upload begin; event=\(threshold)m; provider=\(provider.rawValue); dates=\(list(utcDateKeys))", category: "sync")
            let count = try await upload(provider: provider, settings: settings, repository: repository, utcDateKeys: utcDateKeys)
            try repository.completeQuickUpload(deviceID: settings.deviceID, utcDateKeys: utcDateKeys)
            SharedEnvironment.diagnosticLog.record("threshold quick upload complete; event=\(threshold)m; provider=\(provider.rawValue); files=\(count); dates=\(list(utcDateKeys))", category: "sync")
        } catch {
            SharedEnvironment.diagnosticLog.record("threshold quick upload queued; event=\(threshold)m; provider=\(provider.rawValue); dates=\(list(utcDateKeys)); error=\(error.localizedDescription)", category: "sync")
        }
    }

    private func synchronize(
        provider: SyncProvider,
        settings: STGSettings,
        repository: BitmapRepository,
        downloadKeys: Set<String>,
        uploadKeys: Set<String>
    ) async throws -> QuickSyncResult {
        switch provider {
        case .none:
            return QuickSyncResult()
        case .iCloudDrive:
            guard let folder = SharedEnvironment.cloudFolder() else { throw STGError.invalidDocument("iCloud Drive container is unavailable to the monitor extension") }
            return try await CloudFolderSync(repository: repository, deviceID: settings.deviceID).quickBidirectional(folder: folder, downloadUTCDateKeys: downloadKeys, uploadUTCDateKeys: uploadKeys)
        case .oneDrive:
            guard let clientID = configuredValue("STGOneDriveClientID") else { throw STGError.invalidDocument("OneDrive Client ID is missing from the monitor extension") }
            return try await OneDriveSync(
                repository: repository,
                deviceID: settings.deviceID,
                clientID: clientID,
                credentialService: SharedEnvironment.oneDriveCredentialService,
                credentialAccessGroup: SharedEnvironment.keychainAccessGroup,
                session: quickSession()
            ).quickBidirectional(downloadUTCDateKeys: downloadKeys, uploadUTCDateKeys: uploadKeys)
        case .googleDrive:
            guard let clientID = configuredValue("STGGoogleClientID") else { throw STGError.invalidDocument("Google Drive Client ID is missing from the monitor extension") }
            return try await GoogleDriveSync(
                repository: repository,
                deviceID: settings.deviceID,
                clientID: clientID,
                credentialService: SharedEnvironment.googleDriveCredentialService,
                credentialAccessGroup: SharedEnvironment.keychainAccessGroup,
                session: quickSession()
            ).quickBidirectional(downloadUTCDateKeys: downloadKeys, uploadUTCDateKeys: uploadKeys)
        }
    }

    private func upload(provider: SyncProvider, settings: STGSettings, repository: BitmapRepository, utcDateKeys: Set<String>) async throws -> Int {
        switch provider {
        case .none:
            return 0
        case .iCloudDrive:
            guard let folder = SharedEnvironment.cloudFolder() else { throw STGError.invalidDocument("iCloud Drive container is unavailable to the monitor extension") }
            return try await CloudFolderSync(repository: repository, deviceID: settings.deviceID).quickUpload(folder: folder, utcDates: utcDateKeys)
        case .oneDrive:
            guard let clientID = configuredValue("STGOneDriveClientID") else { throw STGError.invalidDocument("OneDrive Client ID is missing from the monitor extension") }
            return try await OneDriveSync(
                repository: repository,
                deviceID: settings.deviceID,
                clientID: clientID,
                credentialService: SharedEnvironment.oneDriveCredentialService,
                credentialAccessGroup: SharedEnvironment.keychainAccessGroup,
                session: quickSession()
            ).quickUpload(utcDateKeys: utcDateKeys)
        case .googleDrive:
            guard let clientID = configuredValue("STGGoogleClientID") else { throw STGError.invalidDocument("Google Drive Client ID is missing from the monitor extension") }
            return try await GoogleDriveSync(
                repository: repository,
                deviceID: settings.deviceID,
                clientID: clientID,
                credentialService: SharedEnvironment.googleDriveCredentialService,
                credentialAccessGroup: SharedEnvironment.keychainAccessGroup,
                session: quickSession()
            ).quickUpload(utcDateKeys: utcDateKeys)
        }
    }

    private func quickSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private func configuredValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func list(_ values: Set<String>) -> String { values.sorted().joined(separator: ",") }
}
