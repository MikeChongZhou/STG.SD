import Foundation
import CryptoKit

public actor CloudFolderSync {
    public struct Result: Sendable {
        public var uploaded = 0
        public var downloaded = 0
        public var discoveredDeviceIDs: Set<String> = []
        public var downloadCursors: [String: String] = [:]
        public var uploadCursor: String?
        public var warnings: [String] = []
    }

    private let repository: BitmapRepository
    private let deviceID: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(repository: BitmapRepository, deviceID: String) {
        self.repository = repository; self.deviceID = deviceID
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    public func incrementalSync(folder: URL, now: Date = .now, days: Int = 14, uploadCursorTarget: String = "cloudFolder", progress: SyncProgressHandler? = nil) async throws -> Result {
        await progress?("Preparing cloud folders…")
        let sync = folder.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("history", isDirectory: true), withIntermediateDirectories: true)
        var result = Result()
        await progress?("Scanning remote devices…")
        let files = try FileManager.default.contentsOfDirectory(at: sync, includingPropertiesForKeys: [.contentModificationDateKey])
        for file in files where file.pathExtension == "json" {
            if let id = Self.deviceID(from: file.lastPathComponent) { result.discoveredDeviceIDs.insert(id) }
        }

        let knownDevices = Dictionary(uniqueKeysWithValues: try repository.deviceRecords().map { ($0.deviceID, $0) })
        for file in files where file.lastPathComponent.hasSuffix("_setting.json") {
            do {
                guard let remoteID = Self.deviceID(from: file.lastPathComponent), remoteID != deviceID else { continue }
                let modifiedAt = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if let modifiedAt, let known = knownDevices[remoteID], modifiedAt <= known.updatedAt { continue }
                await progress?("Updating device information…")
                let document = try decoder.decode(SettingDocument.self, from: Data(contentsOf: file))
                guard document.deviceID == remoteID else { continue }
                var record = document.deviceRecord
                record.updatedAt = modifiedAt ?? document.updatedAt
                try repository.upsertDevice(record)
            } catch { result.warnings.append("settings_import_failed; file=\(file.lastPathComponent); \(DiagnosticLog.describe(error))"); continue }
        }

        let existingUploadCursor = try repository.incrementalUploadCursor(syncTarget: uploadCursorTarget)
        let isInitialCloudRestore = existingUploadCursor == nil
        func changedSinceLastImport(_ file: URL, remoteID: String, utcDate: String) throws -> Bool {
            if isInitialCloudRestore {
                if remoteID == deviceID { return true }
                return try repository.documentIfPresent(deviceID: remoteID, utcDate: utcDate) == nil
            }
            if remoteID == deviceID { return false }
            guard let modifiedAt = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return true }
            guard let importedAt = try repository.remoteBitmapFileModifiedAt(remoteDeviceID: remoteID, utcDate: utcDate) else { return true }
            return modifiedAt > importedAt
        }
        // A device's cloud copy is also a recovery source for that same device.
        // Bitmap merging is monotonic, so a newer cloud copy can safely restore
        // minutes after a reinstall or a partially missing local database.
        let downloadIDs = result.discoveredDeviceIDs.filter { $0 != "alldevices" }
        let totalDownloads = downloadIDs.reduce(into: 0) { total, remoteID in
            total += files.filter { file in
                guard Self.deviceID(from: file.lastPathComponent) == remoteID,
                      let date = Self.bitmapUTCDate(from: file.lastPathComponent),
                      ((try? changedSinceLastImport(file, remoteID: remoteID, utcDate: date)) ?? true) else { return false }
                return true
            }.count
        }
        if totalDownloads == 0 { await progress?("Downloading device data — nothing new…") }
        for remoteID in downloadIDs {
            let restoringThisDevice = remoteID == deviceID
            let candidates = files.compactMap { file -> (URL, String, Date?)? in
                guard Self.deviceID(from: file.lastPathComponent) == remoteID,
                      let date = Self.bitmapUTCDate(from: file.lastPathComponent),
                      ((try? changedSinceLastImport(file, remoteID: remoteID, utcDate: date)) ?? true) else { return nil }
                return (file, date, try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            }.sorted { $0.1 < $1.1 }
            for (file, expectedDate, modifiedAt) in candidates {
                await progress?("Downloading device data — \(result.downloaded + 1) of \(totalDownloads)…")
                do {
                    let document = try decoder.decode(BitmapDocument.self, from: Data(contentsOf: file))
                    guard document.deviceID == remoteID, document.utcDate == expectedDate else { throw STGError.invalidDocument("iCloud bitmap identity mismatch") }
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
                    try repository.saveRemoteBitmapFileModifiedAt(remoteDeviceID: remoteID, utcDate: expectedDate, modifiedAt: modifiedAt ?? document.updatedAt)
                    result.downloaded += 1
                } catch { result.warnings.append("bitmap_import_failed; device=\(remoteID.prefix(8)); utc_date=\(expectedDate); file=\(file.lastPathComponent); cursor_not_advanced=true; \(DiagnosticLog.describe(error))"); break }
            }
        }

        let currentWeek = Self.weekStart(containing: STGTime.utcDateKey(for: now))!
        let archiveCutoff = Self.weekArchiveCutoff(previousWeekStart: currentWeek)
        var reconciledArchives = 0
        var archiveDownloads = 0
        var archivedWeeks = Set<String>()
        if isInitialCloudRestore {
            let history = folder.appendingPathComponent("history", isDirectory: true)
            let archives = try [sync, history].flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            for file in archives where file.lastPathComponent.contains("_week_") && file.pathExtension == "json" {
                let archive = try BitmapArchiveDocument.decodeCloud(Data(contentsOf: file))
                guard file.lastPathComponent.hasPrefix("\(archive.deviceID)_week_") else { throw STGError.invalidDocument("iCloud weekly archive identity mismatch") }
                _ = try repository.importBitmapArchive(archive, mergeSameDevice: true)
                archiveDownloads += 1
                if archive.deviceID == deviceID { archivedWeeks.insert(archive.periodStart) }
            }
            let dates = try repository.bitmapUTCDates(deviceID: deviceID)
            let weeks = Set(dates.compactMap(Self.weekStart(containing:)).filter { $0 < currentWeek })
            for week in weeks.sorted() where archivedWeeks.contains(week) || week < archiveCutoff {
                guard let end = Self.weekEnd(fromStart: week) else { continue }
                let name = "\(deviceID)_week_\(week)_\(end).json"
                let root = sync.appendingPathComponent(name), old = history.appendingPathComponent(name)
                let destination = FileManager.default.fileExists(atPath: root.path) ? root : old
                let archive = try repository.bitmapArchive(deviceID: deviceID, kind: "week", from: week, through: end)
                try atomicWrite(encoder.encode(archive), to: destination)
                archivedWeeks.insert(week); reconciledArchives += 1
            }
        }
        let uploadKeys = try (isInitialCloudRestore
            ? repository.bitmapUTCDates(deviceID: deviceID).filter { date in
                guard let week = Self.weekStart(containing: date) else { return false }
                return !archivedWeeks.contains(week) && week >= archiveCutoff
            }
            : STGTime.incrementalUploadUTCDateKeys(cursor: existingUploadCursor, now: now, initialDays: days))
        let uploadItems = try uploadKeys.compactMap { key -> (String, BitmapDocument)? in
            guard let document = try repository.documentIfPresent(deviceID: deviceID, utcDate: key) else { return nil }
            return (key, document)
        }
        if uploadItems.isEmpty { await progress?("Uploading local changes — nothing new…") }
        for (index, item) in uploadItems.enumerated() {
            let (key, document) = item
            await progress?("Uploading local changes — \(index + 1) of \(uploadItems.count)…")
            let destination = sync.appendingPathComponent("\(deviceID)_bitmap_\(key).json")
            try atomicWrite(encoder.encode(document), to: destination)
            if !isInitialCloudRestore { try repository.saveIncrementalUploadCursor(syncTarget: uploadCursorTarget, latestUTCDate: key) }
            result.uploadCursor = key
            result.uploaded += 1
        }
        if isInitialCloudRestore && result.warnings.isEmpty && (result.uploadCursor != nil || reconciledArchives > 0 || archiveDownloads > 0 || result.downloaded > 0) {
            let cursor = result.uploadCursor ?? STGTime.utcDateKey(for: now)
            try repository.saveIncrementalUploadCursor(syncTarget: uploadCursorTarget, latestUTCDate: cursor)
            result.uploadCursor = cursor
        }
        if isInitialCloudRestore && !result.warnings.isEmpty { result.uploadCursor = nil }
        if result.warnings.isEmpty { try repository.completeIncrementalSync(deviceID: deviceID, at: now) }
        return result
    }

    public func alignAllData(folder: URL, progress: SyncProgressHandler? = nil) async throws -> CloudAlignmentResult {
        let sync = folder.appendingPathComponent("sync", isDirectory: true)
        let history = folder.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let files = try [sync, history].flatMap { directory in
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map {
                CloudAlignmentFile(id: $0.path, name: $0.lastPathComponent, folder: directory.lastPathComponent)
            }
        }
        return try await CloudDataAlignment.reconcile(repository: repository, localDeviceID: deviceID, files: files,
            download: { try Data(contentsOf: URL(fileURLWithPath: $0.id)) },
            upload: { folderName, name, data, _ in
                let destination = folder.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(name)
                try data.write(to: destination, options: .atomic)
            }, progress: progress)
    }

    public func quickUpload(folder: URL, utcDates: Set<String>) throws -> Int {
        let sync = folder.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        var count = 0
        for key in utcDates {
            guard let document = try repository.documentIfPresent(deviceID: deviceID, utcDate: key) else { continue }
            try atomicWrite(encoder.encode(document), to: sync.appendingPathComponent("\(deviceID)_bitmap_\(key).json"))
            count += 1
        }
        return count
    }

    public func quickBidirectional(folder: URL, downloadUTCDateKeys: Set<String>, uploadUTCDateKeys: Set<String>) throws -> QuickSyncResult {
        let sync = folder.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: sync, includingPropertiesForKeys: nil)
        let knownDeviceIDs = try repository.deviceIDs().filter { $0 != deviceID && $0 != "alldevices" }
        let discoveredRemoteIDs = Set(files.compactMap { Self.deviceID(from: $0.lastPathComponent) }.filter { $0 != deviceID && $0 != "alldevices" })
        let remoteIDs = Set(knownDeviceIDs).union(discoveredRemoteIDs)
        let downloadIDs = remoteIDs.union([deviceID])
        var result = QuickSyncResult(discoveredDeviceIDs: remoteIDs)

        for remoteID in downloadIDs {
            for key in downloadUTCDateKeys {
                let name = "\(remoteID)_bitmap_\(key).json"
                let url = sync.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    let document = try decoder.decode(BitmapDocument.self, from: Data(contentsOf: url))
                    guard document.deviceID == remoteID, document.utcDate == key else { throw STGError.invalidDocument("iCloud bitmap identity mismatch") }
                    if remoteID == deviceID {
                        try repository.mergeBitmap(deviceID: remoteID, utcDate: key, bitmap: document.bitmap(), updatedAt: document.updatedAt)
                    } else {
                        try repository.upsertIfNewer(deviceID: remoteID, utcDate: key, bitmap: document.bitmap(), updatedAt: document.updatedAt)
                    }
                    _ = try repository.rebuildAllDevices(utcDate: key)
                    result.downloaded += 1
                } catch { result.failed += 1 }
            }
        }

        for key in uploadUTCDateKeys.sorted() {
            guard let document = try repository.documentIfPresent(deviceID: deviceID, utcDate: key) else { continue }
            try atomicWrite(encoder.encode(document), to: sync.appendingPathComponent("\(deviceID)_bitmap_\(key).json"))
            result.uploaded += 1
        }
        return result
    }

    public func uploadSettings(folder: URL, settings: STGSettings) throws {
        let sync = folder.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        try repository.upsertDevice(SettingDocument(settings).deviceRecord)
        let destination = sync.appendingPathComponent("\(deviceID)_setting.json")
        if FileManager.default.fileExists(atPath: destination.path),
           let modifiedAt = try destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           modifiedAt >= settings.updatedAt { return }
        try atomicWrite(encoder.encode(SettingDocument(settings)), to: destination)
    }

    public func weeklyMaintenance(folder: URL, currentWeekStart: String, previousWeekStart: String, previousWeekEnd: String) throws -> (uploaded: Int, deletedDaily: Int, movedWeekly: Int) {
        let sync = folder.appendingPathComponent("sync", isDirectory: true), history = folder.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let initialFiles = try FileManager.default.contentsOfDirectory(at: sync, includingPropertiesForKeys: nil)
        let dailyFiles = initialFiles.compactMap { file -> (url: URL, date: String, weekStart: String)? in
            let name = file.lastPathComponent
            guard Self.deviceID(from: name) == deviceID, let date = Self.bitmapUTCDate(from: name), date < currentWeekStart,
                  let weekStart = Self.weekStart(containing: date) else { return nil }
            return (file, date, weekStart)
        }
        let weekStarts = Set(dailyFiles.map(\.weekStart)).union([previousWeekStart]).sorted()
        var uploaded = 0, deleted = 0
        for weekStart in weekStarts {
            guard let weekEnd = Self.weekEnd(fromStart: weekStart) else { continue }
            let weekName = "\(deviceID)_week_\(weekStart)_\(weekEnd).json"
            let existing = sync.appendingPathComponent(weekName)
            let archived = history.appendingPathComponent(weekName)
            let remoteURL = FileManager.default.fileExists(atPath: archived.path) && !FileManager.default.fileExists(atPath: existing.path) ? archived : existing
            for cloudURL in [existing, archived] where FileManager.default.fileExists(atPath: cloudURL.path) {
                let remote = try BitmapArchiveDocument.decodeCloud(Data(contentsOf: cloudURL))
                guard remote.deviceID == deviceID, remote.kind == "week" else { throw STGError.invalidDocument("iCloud weekly archive identity mismatch") }
                _ = try repository.importBitmapArchive(remote, mergeSameDevice: true)
            }
            let archive = try repository.bitmapArchive(deviceID: deviceID, kind: "week", from: weekStart, through: weekEnd)
            let data = try encoder.encode(archive)
            try atomicWrite(data, to: remoteURL); uploaded += 1
            for daily in dailyFiles where daily.weekStart == weekStart {
                try FileManager.default.removeItem(at: daily.url); deleted += 1
            }
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try repository.recordArchive(id: weekName, kind: "week", from: weekStart, through: weekEnd, cloudPath: "\(remoteURL.deletingLastPathComponent().lastPathComponent)/\(weekName)", checksum: checksum, uploadedAt: .now, status: "uploaded")
        }
        let archiveCutoff = Self.weekArchiveCutoff(previousWeekStart: previousWeekStart)
        var moved = 0
        for file in try FileManager.default.contentsOfDirectory(at: sync, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            if name.hasPrefix("\(deviceID)_week_"), name.hasSuffix(".json"),
                      let end = Self.weekEnd(from: name), end < archiveCutoff {
                let destination = history.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: file, to: destination); moved += 1
            }
        }
        return (uploaded, deleted, moved)
    }

    public func yearlyMaintenance(folder: URL, year: Int, trackingCleanupYear: Int) throws -> (uploaded: Int, deletedBitmaps: Int, deletedWeekly: Int) {
        let history = folder.appendingPathComponent("history", isDirectory: true); try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let start = String(format: "%04d-01-01", year), end = String(format: "%04d-12-31", year)
        let archive = try repository.bitmapArchive(deviceID: deviceID, kind: "year", from: start, through: end)
        let encoded = try encoder.encode(archive); let compressed = try (encoded as NSData).compressed(using: .zlib) as Data
        let bitmapName = "\(deviceID)_year_\(year).json.zlib"; try atomicWrite(compressed, to: history.appendingPathComponent(bitmapName))
        let checksum = SHA256.hash(data: compressed).map { String(format: "%02x", $0) }.joined()
        try repository.recordArchive(id: bitmapName, kind: "year", from: start, through: end, cloudPath: "history/\(bitmapName)", checksum: checksum, uploadedAt: .now, status: "uploaded")
        try repository.deleteBitmapRows(deviceID: deviceID, from: start, through: end)

        let trackingStart = String(format: "%04d-01-01", year), trackingEnd = String(format: "%04d-12-31", year)
        let trackingDeleteThrough = String(format: "%04d-12-31", trackingCleanupYear)
        let tracking = try repository.openRouterArchive(from: trackingStart, through: trackingEnd)
        if !tracking.rows.isEmpty {
            let trackingData = try (encoder.encode(tracking) as NSData).compressed(using: .zlib) as Data
            let name = "openrouter_year_\(year).json.zlib"; try atomicWrite(trackingData, to: history.appendingPathComponent(name))
            try repository.recordArchive(id: name, kind: "openrouter_year", from: trackingStart, through: trackingEnd, cloudPath: "history/\(name)", checksum: SHA256.hash(data: trackingData).map { String(format: "%02x", $0) }.joined(), uploadedAt: .now, status: "uploaded")
            try repository.deleteOpenRouterWeeks(through: trackingDeleteThrough)
        }
        var deletedWeekly = 0
        for file in try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            if name.hasPrefix("\(deviceID)_week_\(year)-") { try FileManager.default.removeItem(at: file); deletedWeekly += 1 }
        }
        return (tracking.rows.isEmpty ? 1 : 2, archive.rows.count, deletedWeekly)
    }

    public static func deviceID(from filename: String) -> String? {
        if let range = filename.range(of: "_bitmap_") { return String(filename[..<range.lowerBound]) }
        if filename.hasSuffix("_setting.json") { return String(filename.dropLast("_setting.json".count)) }
        return nil
    }

    public static func bitmapUTCDate(from filename: String) -> String? {
        guard let range = filename.range(of: "_bitmap_"), filename.hasSuffix(".json") else { return nil }
        let value = String(filename[range.upperBound...].dropLast(".json".count))
        guard value.count == 10,
              value[value.index(value.startIndex, offsetBy: 4)] == "-",
              value[value.index(value.startIndex, offsetBy: 7)] == "-" else { return nil }
        return value
    }

    public static func weekEnd(from filename: String) -> String? {
        guard let range = filename.range(of: "_week_"), filename.hasSuffix(".json") else { return nil }
        let value = String(filename[range.upperBound...].dropLast(5)); let pieces = value.split(separator: "_")
        if pieces.count == 2 { return String(pieces[1]) }
        guard pieces.count == 1 else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = STGTime.utc; formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: String(pieces[0])), let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: 6, to: start) else { return nil }
        return formatter.string(from: end)
    }

    public static func weekArchiveCutoff(previousWeekStart: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = STGTime.utc; formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: previousWeekStart), let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -7, to: start) else { return previousWeekStart }
        return formatter.string(from: cutoff)
    }

    public static func weekStart(containing date: String) -> String? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = STGTime.utc; formatter.dateFormat = "yyyy-MM-dd"
        guard let value = formatter.date(from: date) else { return nil }
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = STGTime.utc
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: value) else { return nil }
        return formatter.string(from: interval.start)
    }

    public static func weekEnd(fromStart start: String) -> String? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = STGTime.utc; formatter.dateFormat = "yyyy-MM-dd"
        guard let value = formatter.date(from: start) else { return nil }
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = STGTime.utc
        guard let end = calendar.date(byAdding: .day, value: 6, to: value) else { return nil }
        return formatter.string(from: end)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}
