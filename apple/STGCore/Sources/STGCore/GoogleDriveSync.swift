import Foundation
import CryptoKit

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
        let existingUploadCursor = try repository.incrementalUploadCursor(syncTarget: uploadTarget)
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
        let downloadIDs = result.discoveredDeviceIDs.filter {
            $0 != "alldevices" && ($0 != deviceID || existingUploadCursor == nil)
        }
        for remoteID in downloadIDs {
            let restoringThisDevice = remoteID == deviceID
            let cursor: String?
            if restoringThisDevice { cursor = nil }
            else { cursor = try repository.incrementalDownloadCursor(remoteDeviceID: remoteID) }
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
                    if restoringThisDevice {
                        try repository.mergeBitmap(deviceID: remoteID, utcDate: document.utcDate, bitmap: document.bitmap(), updatedAt: document.updatedAt)
                    } else {
                        try repository.upsertIfNewer(deviceID: remoteID, utcDate: document.utcDate, bitmap: document.bitmap(), updatedAt: document.updatedAt)
                    }
                    _ = try repository.rebuildAllDevices(utcDate: document.utcDate)
                    if !restoringThisDevice {
                        try repository.saveIncrementalDownloadCursor(remoteDeviceID: remoteID, latestUTCDate: expectedDate)
                        result.downloadCursors[remoteID] = expectedDate
                    }
                    result.downloaded += 1
                } catch { break }
            }
        }
        let uploadKeys = try STGTime.incrementalUploadUTCDateKeys(cursor: existingUploadCursor, now: now, initialDays: days)
        credential = try await validCredential()
        for key in uploadKeys {
            guard let document = try repository.documentIfPresent(deviceID: deviceID, utcDate: key) else { continue }
            let name = "\(deviceID)_bitmap_\(key).json"
            try await client.upload(name: name, data: encoder.encode(document), existingFileID: filesByName[name], using: credential)
            try repository.saveIncrementalUploadCursor(syncTarget: uploadTarget, latestUTCDate: key)
            result.uploadCursor = key
            result.uploaded += 1
        }
        try repository.completeIncrementalSync(deviceID: deviceID, at: now)
        return result
    }

    public func quickBidirectional(downloadUTCDateKeys: Set<String>, uploadUTCDateKeys: Set<String>) async throws -> QuickSyncResult {
        var credential = try await validCredential()
        let knownDeviceIDs = try repository.deviceIDs().filter { $0 != deviceID && $0 != "alldevices" }
        let requestedNames: Set<String>?
        if knownDeviceIDs.isEmpty {
            requestedNames = nil
        } else {
            let downloadDeviceIDs = Set(knownDeviceIDs).union([deviceID])
            let remoteNames = downloadUTCDateKeys.flatMap { key in downloadDeviceIDs.map { "\($0)_bitmap_\(key).json" } }
            let localNames = uploadUTCDateKeys.map { "\(deviceID)_bitmap_\($0).json" }
            requestedNames = Set(remoteNames).union(localNames)
        }
        let files = try await client.listFiles(names: requestedNames, using: credential)
        let allDeviceIDs = knownDeviceIDs.isEmpty
            ? Set(files.compactMap { CloudFolderSync.deviceID(from: $0.name) }.filter { $0 != "alldevices" })
            : Set(knownDeviceIDs).union([deviceID])
        let remoteIDs = Set(allDeviceIDs.filter { $0 != deviceID })
        var result = QuickSyncResult(discoveredDeviceIDs: remoteIDs)
        let wantedRemoteNames = Set(downloadUTCDateKeys.flatMap { key in allDeviceIDs.map { "\($0)_bitmap_\(key).json" } })
        for file in files where wantedRemoteNames.contains(file.name) {
            do {
                try await importRemote(data: client.download(fileID: file.id, using: credential), expectedName: file.name)
                result.downloaded += 1
            } catch { result.failed += 1 }
        }

        credential = try await validCredential()
        let filesByName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.id) })
        for key in uploadUTCDateKeys.sorted() {
            guard let document = try repository.documentIfPresent(deviceID: deviceID, utcDate: key) else { continue }
            let name = "\(deviceID)_bitmap_\(key).json"
            try await client.upload(name: name, data: encoder.encode(document), existingFileID: filesByName[name], using: credential)
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
            guard let document = try repository.documentIfPresent(deviceID: deviceID, utcDate: key) else { continue }
            let name = "\(deviceID)_bitmap_\(key).json"
            try await client.upload(name: name, data: encoder.encode(document), existingFileID: filesByName[name], using: credential)
            uploaded += 1
        }
        return uploaded
    }

    public func weeklyMaintenance(currentWeekStart: String, previousWeekStart: String, previousWeekEnd: String) async throws -> (uploaded: Int, deletedDaily: Int, movedWeekly: Int) {
        let credential = try await validCredential(), files = try await client.listFiles(using: credential), historyID = try await client.ensureFolder(name: "history", using: credential)
        let archive = try repository.bitmapArchive(deviceID: deviceID, kind: "week", from: previousWeekStart, through: previousWeekEnd), name = "\(deviceID)_week_\(previousWeekStart)_\(previousWeekEnd).json", data = try encoder.encode(archive)
        try await client.upload(name: name, data: data, existingFileID: files.first(where: { $0.name == name })?.id, using: credential)
        let archiveCutoff = CloudFolderSync.weekArchiveCutoff(previousWeekStart: previousWeekStart)
        var deleted = 0, moved = 0
        let historyFiles = try await client.listFiles(parentID: historyID, using: credential)
        for file in files {
            if CloudFolderSync.deviceID(from: file.name) == deviceID, let date = CloudFolderSync.bitmapUTCDate(from: file.name), date < currentWeekStart {
                try await client.delete(fileID: file.id, using: credential); deleted += 1
            } else if file.name.hasPrefix("\(deviceID)_week_"), file.name != name, let end = CloudFolderSync.weekEnd(from: file.name), end < archiveCutoff {
                let oldData = try await client.download(fileID: file.id, using: credential); try await client.upload(name: file.name, data: oldData, existingFileID: historyFiles.first(where: { $0.name == file.name })?.id, parentID: historyID, using: credential); try await client.delete(fileID: file.id, using: credential); moved += 1
            }
        }
        try repository.recordArchive(id: name, kind: "week", from: previousWeekStart, through: previousWeekEnd, cloudPath: "sync/\(name)", checksum: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), uploadedAt: .now, status: "uploaded")
        return (1, deleted, moved)
    }

    public func yearlyMaintenance(year: Int, trackingCleanupYear: Int) async throws -> (uploaded: Int, deletedBitmaps: Int, deletedWeekly: Int) {
        let credential = try await validCredential(), historyID = try await client.ensureFolder(name: "history", using: credential), historyFiles = try await client.listFiles(parentID: historyID, using: credential)
        let start = String(format: "%04d-01-01", year), end = String(format: "%04d-12-31", year), archive = try repository.bitmapArchive(deviceID: deviceID, kind: "year", from: start, through: end)
        let compressed = try (encoder.encode(archive) as NSData).compressed(using: .zlib) as Data, bitmapName = "\(deviceID)_year_\(year).json.zlib"
        try await client.upload(name: bitmapName, data: compressed, existingFileID: historyFiles.first(where: { $0.name == bitmapName })?.id, parentID: historyID, using: credential)
        try repository.recordArchive(id: bitmapName, kind: "year", from: start, through: end, cloudPath: "history/\(bitmapName)", checksum: SHA256.hash(data: compressed).map { String(format: "%02x", $0) }.joined(), uploadedAt: .now, status: "uploaded"); try repository.deleteBitmapRows(deviceID: deviceID, from: start, through: end)
        let trackingStart = String(format: "%04d-01-01", year), trackingEnd = String(format: "%04d-12-31", year), trackingDeleteThrough = String(format: "%04d-12-31", trackingCleanupYear), tracking = try repository.openRouterArchive(from: trackingStart, through: trackingEnd)
        if !tracking.rows.isEmpty { let data = try (encoder.encode(tracking) as NSData).compressed(using: .zlib) as Data, name = "openrouter_year_\(year).json.zlib"; try await client.upload(name: name, data: data, existingFileID: historyFiles.first(where: { $0.name == name })?.id, parentID: historyID, using: credential); try repository.recordArchive(id: name, kind: "openrouter_year", from: trackingStart, through: trackingEnd, cloudPath: "history/\(name)", checksum: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), uploadedAt: .now, status: "uploaded"); try repository.deleteOpenRouterWeeks(through: trackingDeleteThrough) }
        var removed = 0; for file in historyFiles where file.name.hasPrefix("\(deviceID)_week_\(year)-") { try await client.delete(fileID: file.id, using: credential); removed += 1 }
        return (tracking.rows.isEmpty ? 1 : 2, archive.rows.count, removed)
    }

    private func importRemote(data: Data, expectedName: String) throws {
        guard let remoteID = CloudFolderSync.deviceID(from: expectedName) else { return }
        let document = try decoder.decode(BitmapDocument.self, from: data)
        guard document.deviceID == remoteID, expectedName == "\(remoteID)_bitmap_\(document.utcDate).json" else {
            throw STGError.invalidDocument("Google Drive bitmap identity mismatch")
        }
        if remoteID == deviceID {
            try repository.mergeBitmap(deviceID: remoteID, utcDate: document.utcDate, bitmap: document.bitmap(), updatedAt: document.updatedAt)
        } else {
            try repository.upsertIfNewer(deviceID: remoteID, utcDate: document.utcDate, bitmap: document.bitmap(), updatedAt: document.updatedAt)
        }
        _ = try repository.rebuildAllDevices(utcDate: document.utcDate)
    }

    private func validCredential() async throws -> GoogleDriveCredential {
        guard let stored = GoogleDriveCredentialStore.load(service: credentialService, accessGroup: credentialAccessGroup) else { throw STGError.invalidDocument("Google Drive account is not signed in") }
        let current = try await client.refreshed(stored)
        if current.accessToken != stored.accessToken { try GoogleDriveCredentialStore.save(current, service: credentialService, accessGroup: credentialAccessGroup) }
        return current
    }
}
