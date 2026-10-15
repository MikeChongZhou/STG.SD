import Foundation
import CryptoKit

public actor OneDriveSync {
    public struct Result: Sendable { public var uploaded = 0; public var downloaded = 0; public var discoveredDeviceIDs: Set<String> = []; public var downloadCursors: [String: String] = [:]; public var uploadCursor: String?; public var warnings: [String] = [] }
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

    public func synchronize(settings: STGSettings, now: Date = .now, days: Int = 14, progress: SyncProgressHandler? = nil) async throws -> Result {
        var credential = try await validCredential()
        await progress?("Preparing cloud folders…")
        try repository.upsertDevice(SettingDocument(settings).deviceRecord)
        await progress?("Scanning remote devices…")
        let files = try await client.listFiles(using: credential)
        let settingsName = "\(deviceID)_setting.json"
        let remoteSettings = files.first { $0.name == settingsName }
        if remoteSettings == nil || remoteSettings?.modifiedAt == nil || remoteSettings!.modifiedAt! < settings.updatedAt {
            await progress?("Uploading device settings…")
            try await client.upload(name: settingsName, data: encoder.encode(SettingDocument(settings)), using: credential)
        }
        var result = Result()
        let uploadTarget = "oneDrive"
        let existingUploadCursor = try repository.incrementalUploadCursor(syncTarget: uploadTarget)
        credential = try await validCredential()
        let knownDevices = Dictionary(uniqueKeysWithValues: try repository.deviceRecords().map { ($0.deviceID, $0) })
        for file in files where file.name.hasSuffix(".json") {
            if let id = CloudFolderSync.deviceID(from: file.name) { result.discoveredDeviceIDs.insert(id) }
        }
        for file in files where file.name.hasSuffix("_setting.json") {
            do {
                guard let remoteID = CloudFolderSync.deviceID(from: file.name), remoteID != deviceID else { continue }
                if let modifiedAt = file.modifiedAt, let known = knownDevices[remoteID], modifiedAt <= known.updatedAt { continue }
                await progress?("Updating device information…")
                let document = try decoder.decode(SettingDocument.self, from: try await client.download(fileID: file.id, using: credential))
                guard document.deviceID == remoteID else { continue }
                var record = document.deviceRecord
                record.updatedAt = file.modifiedAt ?? document.updatedAt
                try repository.upsertDevice(record)
            } catch { result.warnings.append("settings_import_failed; provider=oneDrive; file=\(file.name); \(DiagnosticLog.describe(error))"); continue }
        }
        let isInitialCloudRestore = existingUploadCursor == nil
        func changedSinceLastImport(_ file: OneDriveFile, remoteID: String, utcDate: String) throws -> Bool {
            if isInitialCloudRestore {
                if remoteID == deviceID { return true }
                return try repository.documentIfPresent(deviceID: remoteID, utcDate: utcDate) == nil
            }
            if remoteID == deviceID { return false }
            guard let modifiedAt = file.modifiedAt else { return true }
            guard let importedAt = try repository.remoteBitmapFileModifiedAt(remoteDeviceID: remoteID, utcDate: utcDate) else { return true }
            return modifiedAt > importedAt
        }
        // Import state belongs to a cloud file, not to the whole sync run. A
        // later scan can therefore restore an older day whose individual file
        // changed after its first scan.
        let downloadIDs = result.discoveredDeviceIDs.filter { $0 != "alldevices" }
        let totalDownloads = downloadIDs.reduce(into: 0) { total, remoteID in
            total += files.filter { file in
                guard CloudFolderSync.deviceID(from: file.name) == remoteID,
                      let date = CloudFolderSync.bitmapUTCDate(from: file.name),
                      ((try? changedSinceLastImport(file, remoteID: remoteID, utcDate: date)) ?? true) else { return false }
                return true
            }.count
        }
        if totalDownloads == 0 { await progress?("Downloading device data — nothing new…") }
        for remoteID in downloadIDs {
            let restoringThisDevice = remoteID == deviceID
            let candidates = files.compactMap { file -> (OneDriveFile, String)? in
                guard CloudFolderSync.deviceID(from: file.name) == remoteID,
                      let date = CloudFolderSync.bitmapUTCDate(from: file.name),
                      ((try? changedSinceLastImport(file, remoteID: remoteID, utcDate: date)) ?? true) else { return nil }
                return (file, date)
            }.sorted { $0.1 < $1.1 }
            for (file, expectedDate) in candidates {
                await progress?("Downloading device data — \(result.downloaded + 1) of \(totalDownloads)…")
                do {
                    let document = try decoder.decode(BitmapDocument.self, from: try await client.download(fileID: file.id, using: credential))
                    guard document.deviceID == remoteID, document.utcDate == expectedDate else { throw STGError.invalidDocument("OneDrive bitmap identity mismatch") }
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
                    try repository.saveRemoteBitmapFileModifiedAt(remoteDeviceID: remoteID, utcDate: expectedDate, modifiedAt: file.modifiedAt ?? document.updatedAt)
                    result.downloaded += 1
                } catch { result.warnings.append("bitmap_import_failed; provider=oneDrive; device=\(remoteID.prefix(8)); utc_date=\(expectedDate); file=\(file.name); cursor_not_advanced=true; \(DiagnosticLog.describe(error))"); break }
            }
        }
        let currentWeek = CloudFolderSync.weekStart(containing: STGTime.utcDateKey(for: now))!
        let archiveCutoff = CloudFolderSync.weekArchiveCutoff(previousWeekStart: currentWeek)
        var archivedWeeks = Set<String>()
        var archiveUploads = 0
        var archiveDownloads = 0
        if isInitialCloudRestore {
            let historyID = try await client.ensureFolder(name: "history", using: credential)
            let historyFiles = try await client.listFiles(folderID: historyID, using: credential)
            for file in files + historyFiles where file.name.contains("_week_") && file.name.hasSuffix(".json") {
                let archive = try BitmapArchiveDocument.decodeCloud(try await client.download(fileID: file.id, using: credential))
                guard file.name.hasPrefix("\(archive.deviceID)_week_") else { throw STGError.invalidDocument("OneDrive weekly archive identity mismatch") }
                _ = try repository.importBitmapArchive(archive, mergeSameDevice: true)
                archiveDownloads += 1
                if archive.deviceID == deviceID { archivedWeeks.insert(archive.periodStart) }
            }
            let weeks = Set(try repository.bitmapUTCDates(deviceID: deviceID).compactMap(CloudFolderSync.weekStart(containing:)).filter { $0 < currentWeek })
            for week in weeks.sorted() where archivedWeeks.contains(week) || week < archiveCutoff {
                guard let end = CloudFolderSync.weekEnd(fromStart: week) else { continue }
                let name = "\(deviceID)_week_\(week)_\(end).json"
                let rootFile = files.first { $0.name == name }
                let historyFile = historyFiles.first { $0.name == name }
                let archive = try repository.bitmapArchive(deviceID: deviceID, kind: "week", from: week, through: end)
                let data = try encoder.encode(archive)
                if rootFile != nil { try await client.upload(name: name, data: data, using: credential) }
                else if historyFile != nil || week < archiveCutoff { try await client.upload(name: name, data: data, folderID: historyID, using: credential) }
                else { try await client.upload(name: name, data: data, using: credential) }
                archivedWeeks.insert(week); archiveUploads += 1
            }
        }
        let uploadKeys = try (isInitialCloudRestore
            ? repository.bitmapUTCDates(deviceID: deviceID).filter { date in
                guard let week = CloudFolderSync.weekStart(containing: date) else { return false }
                return !archivedWeeks.contains(week) && week >= archiveCutoff
            }
            : STGTime.incrementalUploadUTCDateKeys(cursor: existingUploadCursor, now: now, initialDays: days))
        let uploadItems = try uploadKeys.compactMap { key -> (String, BitmapDocument)? in
            guard let document = try repository.documentIfPresent(deviceID: deviceID, utcDate: key) else { return nil }
            return (key, document)
        }
        credential = try await validCredential()
        if uploadItems.isEmpty { await progress?("Uploading local changes — nothing new…") }
        for (index, item) in uploadItems.enumerated() {
            let (key, document) = item
            await progress?("Uploading local changes — \(index + 1) of \(uploadItems.count)…")
            let name = "\(deviceID)_bitmap_\(key).json"
            try await client.upload(name: name, data: encoder.encode(document), using: credential)
            if !isInitialCloudRestore { try repository.saveIncrementalUploadCursor(syncTarget: uploadTarget, latestUTCDate: key) }
            result.uploadCursor = key
            result.uploaded += 1
        }
        if isInitialCloudRestore && result.warnings.isEmpty && (result.uploadCursor != nil || archiveUploads > 0 || archiveDownloads > 0 || result.downloaded > 0) {
            let cursor = result.uploadCursor ?? STGTime.utcDateKey(for: now)
            try repository.saveIncrementalUploadCursor(syncTarget: uploadTarget, latestUTCDate: cursor)
            result.uploadCursor = cursor
        }
        if isInitialCloudRestore && !result.warnings.isEmpty { result.uploadCursor = nil }
        if result.warnings.isEmpty { try repository.completeIncrementalSync(deviceID: deviceID, at: now) }
        return result
    }

    public func alignAllData(progress: SyncProgressHandler? = nil) async throws -> CloudAlignmentResult {
        let credential = try await validCredential()
        let historyID = try await client.ensureFolder(name: "history", using: credential)
        let root = try await client.listFiles(using: credential).map { CloudAlignmentFile(id: $0.id, name: $0.name, folder: "sync") }
        let history = try await client.listFiles(folderID: historyID, using: credential).map { CloudAlignmentFile(id: $0.id, name: $0.name, folder: "history") }
        return try await CloudDataAlignment.reconcile(repository: repository, localDeviceID: deviceID, files: root + history,
            download: { file in let credential = try await self.validCredential(); return try await self.client.download(fileID: file.id, using: credential) },
            upload: { folder, name, data, _ in
                let credential = try await self.validCredential()
                if folder == "history" { try await self.client.upload(name: name, data: data, folderID: historyID, using: credential) }
                else { try await self.client.upload(name: name, data: data, using: credential) }
            }, progress: progress)
    }

    public func quickBidirectional(downloadUTCDateKeys: Set<String>, uploadUTCDateKeys: Set<String>) async throws -> QuickSyncResult {
        var credential = try await validCredential()
        let knownDeviceIDs = try repository.deviceIDs().filter { $0 != deviceID && $0 != "alldevices" }
        var result = QuickSyncResult(discoveredDeviceIDs: Set(knownDeviceIDs))

        if knownDeviceIDs.isEmpty {
            let files = try await client.listFiles(using: credential)
            let allDeviceIDs = Set(files.compactMap { CloudFolderSync.deviceID(from: $0.name) }.filter { $0 != "alldevices" })
            let remoteIDs = Set(allDeviceIDs.filter { $0 != deviceID })
            result.discoveredDeviceIDs.formUnion(remoteIDs)
            let wanted = Set(downloadUTCDateKeys.flatMap { key in allDeviceIDs.map { "\($0)_bitmap_\(key).json" } })
            for file in files where wanted.contains(file.name) {
                do {
                    try await importRemote(data: client.download(fileID: file.id, using: credential), expectedName: file.name)
                    result.downloaded += 1
                } catch { result.failed += 1 }
            }
        } else {
            for remoteID in Set(knownDeviceIDs).union([deviceID]) {
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
            guard let document = try repository.documentIfPresent(deviceID: deviceID, utcDate: key) else { continue }
            try await client.upload(name: "\(deviceID)_bitmap_\(key).json", data: encoder.encode(document), using: credential)
            result.uploaded += 1
        }
        return result
    }

    public func quickUpload(utcDateKeys: Set<String>) async throws -> Int {
        let credential = try await validCredential()
        var uploaded = 0
        for key in utcDateKeys.sorted() {
            guard let document = try repository.documentIfPresent(deviceID: deviceID, utcDate: key) else { continue }
            try await client.upload(name: "\(deviceID)_bitmap_\(key).json", data: encoder.encode(document), using: credential)
            uploaded += 1
        }
        return uploaded
    }

    public func weeklyMaintenance(currentWeekStart: String, previousWeekStart: String, previousWeekEnd: String) async throws -> (uploaded: Int, deletedDaily: Int, movedWeekly: Int) {
        let credential = try await validCredential(), files = try await client.listFiles(using: credential), historyID = try await client.ensureFolder(name: "history", using: credential)
        let dailyFiles = files.compactMap { file -> (file: OneDriveFile, date: String, weekStart: String)? in
            guard CloudFolderSync.deviceID(from: file.name) == deviceID, let date = CloudFolderSync.bitmapUTCDate(from: file.name), date < currentWeekStart,
                  let weekStart = CloudFolderSync.weekStart(containing: date) else { return nil }
            return (file, date, weekStart)
        }
        let weekStarts = Set(dailyFiles.map(\.weekStart)).union([previousWeekStart]).sorted()
        let historyFiles = try await client.listFiles(folderID: historyID, using: credential)
        var uploaded = 0, deleted = 0
        for weekStart in weekStarts {
            guard let weekEnd = CloudFolderSync.weekEnd(fromStart: weekStart) else { continue }
            let name = "\(deviceID)_week_\(weekStart)_\(weekEnd).json"
            let rootFile = files.first { $0.name == name }
            let historyFile = historyFiles.first { $0.name == name }
            for existing in [rootFile, historyFile].compactMap({ $0 }) {
                let remote = try BitmapArchiveDocument.decodeCloud(try await client.download(fileID: existing.id, using: credential))
                guard remote.deviceID == deviceID, remote.kind == "week" else { throw STGError.invalidDocument("OneDrive weekly archive identity mismatch") }
                _ = try repository.importBitmapArchive(remote, mergeSameDevice: true)
            }
            let archive = try repository.bitmapArchive(deviceID: deviceID, kind: "week", from: weekStart, through: weekEnd)
            let data = try encoder.encode(archive)
            if rootFile == nil && historyFile != nil { try await client.upload(name: name, data: data, folderID: historyID, using: credential) }
            else { try await client.upload(name: name, data: data, using: credential) }
            uploaded += 1
            for daily in dailyFiles where daily.weekStart == weekStart { try await client.delete(fileID: daily.file.id, using: credential); deleted += 1 }
            try repository.recordArchive(id: name, kind: "week", from: weekStart, through: weekEnd, cloudPath: "\(rootFile == nil && historyFile != nil ? "history" : "sync")/\(name)", checksum: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), uploadedAt: .now, status: "uploaded")
        }
        let archiveCutoff = CloudFolderSync.weekArchiveCutoff(previousWeekStart: previousWeekStart)
        var moved = 0
        for file in try await client.listFiles(using: credential) {
            if file.name.hasPrefix("\(deviceID)_week_"), let end = CloudFolderSync.weekEnd(from: file.name), end < archiveCutoff {
                let oldData = try await client.download(fileID: file.id, using: credential); try await client.upload(name: file.name, data: oldData, folderID: historyID, using: credential); try await client.delete(fileID: file.id, using: credential); moved += 1
            }
        }
        return (uploaded, deleted, moved)
    }

    public func yearlyMaintenance(year: Int, trackingCleanupYear: Int) async throws -> (uploaded: Int, deletedBitmaps: Int, deletedWeekly: Int) {
        let credential = try await validCredential(), historyID = try await client.ensureFolder(name: "history", using: credential)
        let start = String(format: "%04d-01-01", year), end = String(format: "%04d-12-31", year)
        let archive = try repository.bitmapArchive(deviceID: deviceID, kind: "year", from: start, through: end)
        let compressed = try (encoder.encode(archive) as NSData).compressed(using: .zlib) as Data
        let bitmapName = "\(deviceID)_year_\(year).json.zlib"; try await client.upload(name: bitmapName, data: compressed, folderID: historyID, using: credential)
        try repository.recordArchive(id: bitmapName, kind: "year", from: start, through: end, cloudPath: "history/\(bitmapName)", checksum: SHA256.hash(data: compressed).map { String(format: "%02x", $0) }.joined(), uploadedAt: .now, status: "uploaded")
        try repository.deleteBitmapRows(deviceID: deviceID, from: start, through: end)
        let trackingStart = String(format: "%04d-01-01", year), trackingEnd = String(format: "%04d-12-31", year), trackingDeleteThrough = String(format: "%04d-12-31", trackingCleanupYear), tracking = try repository.openRouterArchive(from: trackingStart, through: trackingEnd)
        if !tracking.rows.isEmpty {
            let data = try (encoder.encode(tracking) as NSData).compressed(using: .zlib) as Data, name = "openrouter_year_\(year).json.zlib"
            try await client.upload(name: name, data: data, folderID: historyID, using: credential); try repository.recordArchive(id: name, kind: "openrouter_year", from: trackingStart, through: trackingEnd, cloudPath: "history/\(name)", checksum: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), uploadedAt: .now, status: "uploaded"); try repository.deleteOpenRouterWeeks(through: trackingDeleteThrough)
        }
        var removed = 0
        for file in try await client.listFiles(folderID: historyID, using: credential) where file.name.hasPrefix("\(deviceID)_week_\(year)-") { try await client.delete(fileID: file.id, using: credential); removed += 1 }
        return (tracking.rows.isEmpty ? 1 : 2, archive.rows.count, removed)
    }

    private func importRemote(data: Data, expectedName: String) throws {
        guard let remoteID = CloudFolderSync.deviceID(from: expectedName) else { return }
        let document = try decoder.decode(BitmapDocument.self, from: data)
        guard document.deviceID == remoteID, expectedName == "\(remoteID)_bitmap_\(document.utcDate).json" else {
            throw STGError.invalidDocument("OneDrive bitmap identity mismatch")
        }
        if remoteID == deviceID {
            try repository.mergeBitmap(deviceID: remoteID, utcDate: document.utcDate, bitmap: document.bitmap(), updatedAt: document.updatedAt)
        } else {
            try repository.upsertIfNewer(deviceID: remoteID, utcDate: document.utcDate, bitmap: document.bitmap(), updatedAt: document.updatedAt)
        }
        _ = try repository.rebuildAllDevices(utcDate: document.utcDate)
    }

    private func validCredential() async throws -> OneDriveCredential {
        guard let stored = OneDriveCredentialStore.load(service: credentialService, accessGroup: credentialAccessGroup) else { throw STGError.invalidDocument("OneDrive account is not signed in") }
        let current = try await client.refreshed(stored)
        if current.accessToken != stored.accessToken { try OneDriveCredentialStore.save(current, service: credentialService, accessGroup: credentialAccessGroup) }
        return current
    }
}
