import Foundation

public actor GoogleDriveSync {
    public struct Result: Sendable { public var uploaded = 0; public var downloaded = 0; public var discoveredDeviceIDs: Set<String> = []; public var downloadCursors: [String: String] = [:]; public var uploadCursor: String? }
    private let repository: BitmapRepository
    private let deviceID: String
    private let client: GoogleDriveClient
    private let credentialService: String
    private let credentialAccessGroup: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(repository: BitmapRepository, deviceID: String, clientID: String, clientSecret: String = "", credentialService: String, credentialAccessGroup: String? = nil, session: URLSession = .shared) {
        self.repository = repository; self.deviceID = deviceID; client = GoogleDriveClient(clientID: clientID, clientSecret: clientSecret, session: session); self.credentialService = credentialService; self.credentialAccessGroup = credentialAccessGroup
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    public func synchronize(settings: STGSettings, now: Date = .now, days: Int = 14) async throws -> Result {
        var credential = try await validCredential()
        try repository.upsertDevice(SettingDocument(settings).deviceRecord)
        var files = try await client.listFiles(using: credential)
        var filesByName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.id) })
        let settingsName = "\(deviceID)_setting.json"
        try await client.upload(name: settingsName, data: encoder.encode(SettingDocument(settings)), existingFileID: filesByName[settingsName], using: credential)
        var result = Result()
        let uploadTarget = "googleDrive"
        let uploadKeys = try STGTime.incrementalUploadUTCDateKeys(cursor: repository.incrementalUploadCursor(syncTarget: uploadTarget), now: now, initialDays: days)
        for key in uploadKeys {
            let name = "\(deviceID)_bitmap_\(key).json"
            try await client.upload(name: name, data: encoder.encode(repository.document(deviceID: deviceID, utcDate: key)), existingFileID: filesByName[name], using: credential)
            try repository.saveIncrementalUploadCursor(syncTarget: uploadTarget, latestUTCDate: key)
            result.uploadCursor = key
            result.uploaded += 1
        }
        credential = try await validCredential()
        files = try await client.listFiles(using: credential)
        filesByName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.id) })
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
            let candidates = files.compactMap { file -> (GoogleDriveFile, String)? in
                guard CloudFolderSync.deviceID(from: file.name) == remoteID,
                      let date = CloudFolderSync.bitmapUTCDate(from: file.name),
                      cursor == nil || date >= cursor! else { return nil }
                return (file, date)
            }.sorted { $0.1 < $1.1 }
            for (file, expectedDate) in candidates {
                do {
                    let document = try decoder.decode(BitmapDocument.self, from: try await client.download(fileID: file.id, using: credential))
                    guard document.deviceID == remoteID, document.utcDate == expectedDate else { throw STGError.invalidDocument("Google Drive bitmap identity mismatch") }
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
        let requestedNames: Set<String>?
        if knownDeviceIDs.isEmpty {
            requestedNames = nil
        } else {
            let remoteNames = downloadUTCDateKeys.flatMap { key in knownDeviceIDs.map { "\($0)_bitmap_\(key).json" } }
            let localNames = uploadUTCDateKeys.map { "\(deviceID)_bitmap_\($0).json" }
            requestedNames = Set(remoteNames).union(localNames)
        }
        let files = try await client.listFiles(names: requestedNames, using: credential)
        let remoteIDs = knownDeviceIDs.isEmpty
            ? Set(files.compactMap { CloudFolderSync.deviceID(from: $0.name) }.filter { $0 != deviceID && $0 != "alldevices" })
            : Set(knownDeviceIDs)
        var result = QuickSyncResult(discoveredDeviceIDs: remoteIDs)
        let wantedRemoteNames = Set(downloadUTCDateKeys.flatMap { key in remoteIDs.map { "\($0)_bitmap_\(key).json" } })
        for file in files where wantedRemoteNames.contains(file.name) {
            do {
                try await importRemote(data: client.download(fileID: file.id, using: credential), expectedName: file.name)
                result.downloaded += 1
            } catch { result.failed += 1 }
        }

        credential = try await validCredential()
        let filesByName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.id) })
        for key in uploadUTCDateKeys.sorted() {
            let name = "\(deviceID)_bitmap_\(key).json"
            try await client.upload(name: name, data: encoder.encode(repository.document(deviceID: deviceID, utcDate: key)), existingFileID: filesByName[name], using: credential)
            result.uploaded += 1
        }
        return result
    }

    public func quickUpload(utcDateKeys: Set<String>) async throws -> Int {
        var credential = try await validCredential()
        let names = Set(utcDateKeys.map { "\(deviceID)_bitmap_\($0).json" })
        let files = try await client.listFiles(names: names, using: credential)
        let filesByName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.id) })
        credential = try await validCredential()
        var uploaded = 0
        for key in utcDateKeys.sorted() {
            let name = "\(deviceID)_bitmap_\(key).json"
            try await client.upload(name: name, data: encoder.encode(repository.document(deviceID: deviceID, utcDate: key)), existingFileID: filesByName[name], using: credential)
            uploaded += 1
        }
        return uploaded
    }

    private func importRemote(data: Data, expectedName: String) throws {
        guard let remoteID = CloudFolderSync.deviceID(from: expectedName), remoteID != deviceID else { return }
        let document = try decoder.decode(BitmapDocument.self, from: data)
        guard document.deviceID == remoteID, expectedName == "\(remoteID)_bitmap_\(document.utcDate).json" else {
            throw STGError.invalidDocument("Google Drive bitmap identity mismatch")
        }
        try repository.upsertIfNewer(deviceID: remoteID, utcDate: document.utcDate, bitmap: document.bitmap(), updatedAt: document.updatedAt)
        _ = try repository.rebuildAllDevices(utcDate: document.utcDate)
    }

    private func validCredential() async throws -> GoogleDriveCredential {
        guard let stored = GoogleDriveCredentialStore.load(service: credentialService, accessGroup: credentialAccessGroup) else { throw STGError.invalidDocument("Google Drive account is not signed in") }
        let current = try await client.refreshed(stored)
        if current.accessToken != stored.accessToken { try GoogleDriveCredentialStore.save(current, service: credentialService, accessGroup: credentialAccessGroup) }
        return current
    }
}
