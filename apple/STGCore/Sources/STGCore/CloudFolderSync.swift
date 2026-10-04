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
        let lastSync = try repository.lastIncrementalSync(deviceID: deviceID)
        func changedSinceLastSync(_ file: URL) throws -> Bool {
            guard let lastSync else { return true }
            let modifiedAt = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return modifiedAt.map { $0 > lastSync } ?? true
        }
        let downloadIDs = result.discoveredDeviceIDs.filter {
            $0 != "alldevices" && ($0 != deviceID || existingUploadCursor == nil)
        }
        let totalDownloads = try downloadIDs.reduce(into: 0) { total, remoteID in
            let restoringThisDevice = remoteID == deviceID
            let cursor = remoteID == deviceID ? nil : try repository.incrementalDownloadCursor(remoteDeviceID: remoteID)
            total += files.filter { file in
                guard Self.deviceID(from: file.lastPathComponent) == remoteID,
                      let date = Self.bitmapUTCDate(from: file.lastPathComponent),
                      (restoringThisDevice || ((try? changedSinceLastSync(file)) ?? true)) else { return false }
                return cursor == nil || date >= cursor!
            }.count
        }
        if totalDownloads == 0 { await progress?("Downloading device data — nothing new…") }
        for remoteID in downloadIDs {
            let restoringThisDevice = remoteID == deviceID
            let cursor: String?
            if restoringThisDevice { cursor = nil }
            else { cursor = try repository.incrementalDownloadCursor(remoteDeviceID: remoteID) }
            let candidates = files.compactMap { file -> (URL, String)? in
                guard Self.deviceID(from: file.lastPathComponent) == remoteID,
                      let date = Self.bitmapUTCDate(from: file.lastPathComponent),
                      cursor == nil || date >= cursor!,
                      (restoringThisDevice || ((try? changedSinceLastSync(file)) ?? true)) else { return nil }
                return (file, date)
            }.sorted { $0.1 < $1.1 }
            for (file, expectedDate) in candidates {
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
                    result.downloaded += 1
                } catch { result.warnings.append("bitmap_import_failed; device=\(remoteID.prefix(8)); utc_date=\(expectedDate); file=\(file.lastPathComponent); cursor_not_advanced=true; \(DiagnosticLog.describe(error))"); break }
            }
        }

        let uploadKeys = try STGTime.incrementalUploadUTCDateKeys(cursor: existingUploadCursor, now: now, initialDays: days)
        let uploadItems = try uploadKeys.compactMap { key -> (String, BitmapDocument)? in
            guard let document = try repository.documentIfPresent(deviceID: deviceID, utcDate: key) else { return nil }
            return (key, document)
        }
        if uploadItems.isEmpty { await progress?("Uploading local changes — nothing new…") }
        for (index, item) in uploadItems.enumerated() {
            let (key, document) = item
            await progress?("Uploading local changes — \(index + 1) of \(uploadItems.count)…")
            try atomicWrite(encoder.encode(document), to: sync.appendingPathComponent("\(deviceID)_bitmap_\(key).json"))
            try repository.saveIncrementalUploadCursor(syncTarget: uploadCursorTarget, latestUTCDate: key)
            result.uploadCursor = key
            result.uploaded += 1
        }
        try repository.completeIncrementalSync(deviceID: deviceID, at: now)
        return result
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
            let archive = try repository.bitmapArchive(deviceID: deviceID, kind: "week", from: weekStart, through: weekEnd)
            let weekName = "\(deviceID)_week_\(weekStart)_\(weekEnd).json"
            let data = try encoder.encode(archive)
            try atomicWrite(data, to: sync.appendingPathComponent(weekName)); uploaded += 1
            for daily in dailyFiles where daily.weekStart == weekStart {
                try FileManager.default.removeItem(at: daily.url); deleted += 1
            }
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try repository.recordArchive(id: weekName, kind: "week", from: weekStart, through: weekEnd, cloudPath: "sync/\(weekName)", checksum: checksum, uploadedAt: .now, status: "uploaded")
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
