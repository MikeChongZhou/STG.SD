import Foundation

public actor CloudFolderSync {
    public struct Result: Sendable {
        public var uploaded = 0
        public var downloaded = 0
        public var discoveredDeviceIDs: Set<String> = []
        public var downloadCursors: [String: String] = [:]
        public var uploadCursor: String?
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

    public func incrementalSync(folder: URL, now: Date = .now, days: Int = 14, uploadCursorTarget: String = "cloudFolder") throws -> Result {
        let sync = folder.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        var result = Result()
        let files = try FileManager.default.contentsOfDirectory(at: sync, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            if let id = Self.deviceID(from: file.lastPathComponent) { result.discoveredDeviceIDs.insert(id) }
        }

        for file in files where file.lastPathComponent.hasSuffix("_setting.json") {
            do {
                let document = try decoder.decode(SettingDocument.self, from: Data(contentsOf: file))
                guard document.deviceID == Self.deviceID(from: file.lastPathComponent), document.deviceID != deviceID else { continue }
                try repository.upsertDevice(document.deviceRecord)
            } catch { continue }
        }

        let uploadKeys = try STGTime.incrementalUploadUTCDateKeys(cursor: repository.incrementalUploadCursor(syncTarget: uploadCursorTarget), now: now, initialDays: days)
        for key in uploadKeys {
            let document = try repository.document(deviceID: deviceID, utcDate: key)
            try atomicWrite(encoder.encode(document), to: sync.appendingPathComponent("\(deviceID)_bitmap_\(key).json"))
            try repository.saveIncrementalUploadCursor(syncTarget: uploadCursorTarget, latestUTCDate: key)
            result.uploadCursor = key
            result.uploaded += 1
        }

        let remoteIDs = result.discoveredDeviceIDs.filter { $0 != deviceID && $0 != "alldevices" }
        for remoteID in remoteIDs {
            let cursor = try repository.incrementalDownloadCursor(remoteDeviceID: remoteID)
            let candidates = files.compactMap { file -> (URL, String)? in
                guard Self.deviceID(from: file.lastPathComponent) == remoteID,
                      let date = Self.bitmapUTCDate(from: file.lastPathComponent),
                      cursor == nil || date >= cursor! else { return nil }
                return (file, date)
            }.sorted { $0.1 < $1.1 }
            for (file, expectedDate) in candidates {
                do {
                    let document = try decoder.decode(BitmapDocument.self, from: Data(contentsOf: file))
                    guard document.deviceID == remoteID, document.utcDate == expectedDate else { throw STGError.invalidDocument("iCloud bitmap identity mismatch") }
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

    public func quickUpload(folder: URL, utcDates: Set<String>) throws -> Int {
        let sync = folder.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        var count = 0
        for key in utcDates {
            let document = try repository.document(deviceID: deviceID, utcDate: key)
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
        let remoteIDs = knownDeviceIDs.isEmpty
            ? Set(files.compactMap { Self.deviceID(from: $0.lastPathComponent) }.filter { $0 != deviceID && $0 != "alldevices" })
            : Set(knownDeviceIDs)
        var result = QuickSyncResult(discoveredDeviceIDs: remoteIDs)

        for remoteID in remoteIDs {
            for key in downloadUTCDateKeys {
                let name = "\(remoteID)_bitmap_\(key).json"
                let url = sync.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    let document = try decoder.decode(BitmapDocument.self, from: Data(contentsOf: url))
                    guard document.deviceID == remoteID, document.utcDate == key else { throw STGError.invalidDocument("iCloud bitmap identity mismatch") }
                    try repository.upsertIfNewer(deviceID: remoteID, utcDate: key, bitmap: document.bitmap(), updatedAt: document.updatedAt)
                    _ = try repository.rebuildAllDevices(utcDate: key)
                    result.downloaded += 1
                } catch { result.failed += 1 }
            }
        }

        for key in uploadUTCDateKeys.sorted() {
            let document = try repository.document(deviceID: deviceID, utcDate: key)
            try atomicWrite(encoder.encode(document), to: sync.appendingPathComponent("\(deviceID)_bitmap_\(key).json"))
            result.uploaded += 1
        }
        return result
    }

    public func uploadSettings(folder: URL, settings: STGSettings) throws {
        let sync = folder.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        try repository.upsertDevice(SettingDocument(settings).deviceRecord)
        try atomicWrite(encoder.encode(SettingDocument(settings)), to: sync.appendingPathComponent("\(deviceID)_setting.json"))
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

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}
