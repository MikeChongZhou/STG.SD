import Foundation

public actor OneDriveSync {
    public struct Result: Sendable { public var uploaded = 0; public var downloaded = 0; public var discoveredDeviceIDs: Set<String> = []; public var downloadCursors: [String: String] = [:]; public var uploadCursor: String? }
    private let repository: BitmapRepository
    private let deviceID: String
    private let client: OneDriveClient
    private let credentialService: String
    private let credentialAccessGroup: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(repository: BitmapRepository, deviceID: String, clientID: String, credentialService: String, credentialAccessGroup: String? = nil, session: URLSession = .shared) {
        self.repository = repository; self.deviceID = deviceID; self.client = OneDriveClient(clientID: clientID, session: session); self.credentialService = credentialService; self.credentialAccessGroup = credentialAccessGroup
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    public func synchronize(settings: STGSettings, now: Date = .now, days: Int = 14) async throws -> Result {
        var credential = try await validCredential()
        try repository.upsertDevice(SettingDocument(settings).deviceRecord)
        try await client.upload(name: "\(deviceID)_setting.json", data: encoder.encode(SettingDocument(settings)), using: credential)
        var result = Result()
        let uploadTarget = "oneDrive"
        let uploadKeys = try STGTime.incrementalUploadUTCDateKeys(cursor: repository.incrementalUploadCursor(syncTarget: uploadTarget), now: now, initialDays: days)
        for key in uploadKeys {
            try await client.upload(name: "\(deviceID)_bitmap_\(key).json", data: encoder.encode(repository.document(deviceID: deviceID, utcDate: key)), using: credential)
            try repository.saveIncrementalUploadCursor(syncTarget: uploadTarget, latestUTCDate: key)
            result.uploadCursor = key
            result.uploaded += 1
        }
        credential = try await validCredential()
        let files = try await client.listFiles(using: credential)
        for file in files where file.name.hasSuffix(".json") {
            if let id = CloudFolderSync.deviceID(from: file.name) { result.discoveredDeviceIDs.insert(id) }
        }
        for file in files where file.name.hasSuffix("_setting.json") {
            do {
                let document = try decoder.decode(SettingDocument.self, from: try await client.download(fileID: file.id, using: credential))
                guard document.deviceID == CloudFolderSync.deviceID(from: file.name), document.deviceID != deviceID else { continue }
                try repository.upsertDevice(document.deviceRecord)
            } catch { continue }
        }
        for remoteID in result.discoveredDeviceIDs where remoteID != deviceID && remoteID != "alldevices" {
            let cursor = try repository.incrementalDownloadCursor(remoteDeviceID: remoteID)
            let candidates = files.compactMap { file -> (OneDriveFile, String)? in
                guard CloudFolderSync.deviceID(from: file.name) == remoteID,
                      let date = CloudFolderSync.bitmapUTCDate(from: file.name),
                      cursor == nil || date >= cursor! else { return nil }
                return (file, date)
            }.sorted { $0.1 < $1.1 }
            for (file, expectedDate) in candidates {
                do {
                    let document = try decoder.decode(BitmapDocument.self, from: try await client.download(fileID: file.id, using: credential))
                    guard document.deviceID == remoteID, document.utcDate == expectedDate else { throw STGError.invalidDocument("OneDrive bitmap identity mismatch") }
                    try repository.upsertIfNewer(deviceID: remoteID, utcDate: document.utcDate, bitmap: document.bitmap(), updatedAt: document.updatedAt)
                    _ = try repository.rebuildAllDevices(utcDate: document.utcDate)
                    try repository.saveIncrementalDownloadCursor(remoteDeviceID: remoteID, latestUTCDate: expectedDate)
                    result.downloadCursors[remoteID] = expectedDate
                    result.downloaded += 1
                } catch { break }
            }
        }
        return result
    }

    public func quickBidirectional(downloadUTCDateKeys: Set<String>, uploadUTCDateKeys: Set<String>) async throws -> QuickSyncResult {
        var credential = try await validCredential()
        let knownDeviceIDs = try repository.deviceIDs().filter { $0 != deviceID && $0 != "alldevices" }
        var result = QuickSyncResult(discoveredDeviceIDs: Set(knownDeviceIDs))

        if knownDeviceIDs.isEmpty {
            let files = try await client.listFiles(using: credential)
            let remoteIDs = Set(files.compactMap { CloudFolderSync.deviceID(from: $0.name) }.filter { $0 != deviceID && $0 != "alldevices" })
            result.discoveredDeviceIDs.formUnion(remoteIDs)
            let wanted = Set(downloadUTCDateKeys.flatMap { key in remoteIDs.map { "\($0)_bitmap_\(key).json" } })
            for file in files where wanted.contains(file.name) {
                do {
                    try await importRemote(data: client.download(fileID: file.id, using: credential), expectedName: file.name)
                    result.downloaded += 1
                } catch { result.failed += 1 }
            }
        } else {
            for remoteID in knownDeviceIDs {
                for key in downloadUTCDateKeys {
                    let name = "\(remoteID)_bitmap_\(key).json"
                    do {
                        guard let data = try await client.download(name: name, using: credential) else { continue }
                        try importRemote(data: data, expectedName: name)
                        result.downloaded += 1
                    } catch { result.failed += 1 }
                }
            }
        }

        credential = try await validCredential()
        for key in uploadUTCDateKeys.sorted() {
            try await client.upload(name: "\(deviceID)_bitmap_\(key).json", data: encoder.encode(repository.document(deviceID: deviceID, utcDate: key)), using: credential)
            result.uploaded += 1
        }
        return result
    }

    public func quickUpload(utcDateKeys: Set<String>) async throws -> Int {
        let credential = try await validCredential()
        var uploaded = 0
        for key in utcDateKeys.sorted() {
            try await client.upload(name: "\(deviceID)_bitmap_\(key).json", data: encoder.encode(repository.document(deviceID: deviceID, utcDate: key)), using: credential)
            uploaded += 1
        }
        return uploaded
    }

    private func importRemote(data: Data, expectedName: String) throws {
        guard let remoteID = CloudFolderSync.deviceID(from: expectedName), remoteID != deviceID else { return }
        let document = try decoder.decode(BitmapDocument.self, from: data)
        guard document.deviceID == remoteID, expectedName == "\(remoteID)_bitmap_\(document.utcDate).json" else {
            throw STGError.invalidDocument("OneDrive bitmap identity mismatch")
        }
        try repository.upsertIfNewer(deviceID: remoteID, utcDate: document.utcDate, bitmap: document.bitmap(), updatedAt: document.updatedAt)
        _ = try repository.rebuildAllDevices(utcDate: document.utcDate)
    }

    private func validCredential() async throws -> OneDriveCredential {
        guard let stored = OneDriveCredentialStore.load(service: credentialService, accessGroup: credentialAccessGroup) else { throw STGError.invalidDocument("OneDrive account is not signed in") }
        let current = try await client.refreshed(stored)
        if current.accessToken != stored.accessToken { try OneDriveCredentialStore.save(current, service: credentialService, accessGroup: credentialAccessGroup) }
        return current
    }
}
