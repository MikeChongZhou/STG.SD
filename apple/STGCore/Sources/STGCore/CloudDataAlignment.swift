import Foundation
import STGCompression

public struct CloudAlignmentFile: Sendable {
    public let id: String
    public let name: String
    public let folder: String
    public init(id: String, name: String, folder: String) {
        self.id = id; self.name = name; self.folder = folder
    }
}

public struct CloudAlignmentResult: Sendable {
    public var downloaded = 0
    public var uploaded = 0
    public var rebuiltDates = 0
}

/// Explicit, exhaustive reconciliation. Normal incremental sync never calls this.
public enum CloudDataAlignment {
    public typealias Download = @Sendable (CloudAlignmentFile) async throws -> Data
    public typealias Upload = @Sendable (String, String, Data, CloudAlignmentFile?) async throws -> Void

    public static func reconcile(repository: BitmapRepository, localDeviceID: String,
                                 files: [CloudAlignmentFile], download: Download, upload: Upload,
                                 progress: SyncProgressHandler? = nil) async throws -> CloudAlignmentResult {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let daily = files.filter { $0.folder == "sync" && CloudFolderSync.deviceID(from: $0.name) != "alldevices" && CloudFolderSync.bitmapUTCDate(from: $0.name) != nil }
        let archives = files.filter { $0.name.contains("_week_") && $0.name.hasSuffix(".json") ||
                                      $0.folder == "history" && !$0.name.hasPrefix("openrouter_") && $0.name.contains("_year_") && ($0.name.hasSuffix(".json.gz") || $0.name.hasSuffix(".json.zlib")) }
        var devices = Set(try repository.deviceRecords().map(\.deviceID)); devices.insert(localDeviceID)
        var result = CloudAlignmentResult()
        var touched = Set<String>()
        var cloudDaily: [String: CloudAlignmentFile] = [:]
        var originalDaily: [String: String] = [:]
        var originalArchives: [(file: CloudAlignmentFile, archive: BitmapArchiveDocument, rawDeflate: Bool)] = []

        for (index, file) in daily.enumerated() {
            await progress?("Downloading daily data \(index + 1)/\(daily.count)…")
            let document: BitmapDocument
            do { document = try decoder.decode(BitmapDocument.self, from: await download(file)) }
            catch { throw fileError(error, file: file) }
            guard file.name == "\(document.deviceID)_bitmap_\(document.utcDate).json" else { throw STGError.invalidDocument("daily bitmap identity mismatch: \(file.name)") }
            try repository.mergeBitmap(deviceID: document.deviceID, utcDate: document.utcDate, bitmap: document.bitmap(), updatedAt: document.updatedAt)
            cloudDaily[file.name] = file; originalDaily[file.name] = document.bitmapBase64
            devices.insert(document.deviceID); touched.insert(document.utcDate); result.downloaded += 1
        }
        for (index, file) in archives.enumerated() {
            await progress?("Downloading history \(index + 1)/\(archives.count)…")
            let archive: BitmapArchiveDocument
            var rawDeflate = false
            do {
                let bytes = try await download(file)
                let unpacked = try unpack(bytes, name: file.name)
                rawDeflate = unpacked.rawDeflate
                archive = try BitmapArchiveDocument.decodeCloud(unpacked.data)
            } catch { throw fileError(error, file: file) }
            let marker = archive.kind == "week" ? "_week_" : "_year_"
            guard file.name.hasPrefix("\(archive.deviceID)\(marker)") else { throw STGError.invalidDocument("archive identity mismatch: \(file.name)") }
            _ = try repository.importBitmapArchive(archive, mergeSameDevice: true)
            originalArchives.append((file, archive, rawDeflate)); devices.insert(archive.deviceID)
            touched.formUnion(archive.rows.map(\.utcDate)); result.downloaded += 1
        }

        // A daily file stays in sync/. Its union is written only when minutes changed.
        for file in daily {
            let name = file.name
            guard let id = CloudFolderSync.deviceID(from: name),
                  let date = CloudFolderSync.bitmapUTCDate(from: name),
                  let merged = try repository.documentIfPresent(deviceID: id, utcDate: date) else { continue }
            if merged.bitmapBase64 != originalDaily[name] {
                try await upload("sync", name, encoder.encode(merged), file); result.uploaded += 1
            }
        }
        // Preserve each archive's location and compression format, including duplicate copies.
        for (file, original, rawDeflate) in originalArchives {
            let merged = try repository.bitmapArchive(deviceID: original.deviceID, kind: original.kind,
                                                      from: original.periodStart, through: original.periodEnd,
                                                      createdAt: original.createdAt)
            let oldRows = Dictionary(uniqueKeysWithValues: original.rows.map { ($0.utcDate, $0.bitmapBase64) })
            if merged.rows.count != original.rows.count || merged.rows.contains(where: { oldRows[$0.utcDate] != $0.bitmapBase64 }) {
                try await upload(file.folder, file.name, pack(encoder.encode(merged), name: file.name, rawDeflate: rawDeflate), file)
                result.uploaded += 1
            }
        }
        let currentWeek = CloudFolderSync.weekStart(containing: STGTime.utcDateKey(for: .now))!
        let recentCutoff = CloudFolderSync.weekArchiveCutoff(previousWeekStart: currentWeek)
        var newWeeks = Set<String>()
        for id in devices where id != "alldevices" {
            for date in try repository.bitmapUTCDates(deviceID: id) {
                let name = "\(id)_bitmap_\(date).json"
                if cloudDaily[name] != nil { continue }
                let covered = originalArchives.contains { $0.archive.deviceID == id && date >= $0.archive.periodStart && date <= $0.archive.periodEnd }
                if covered { continue }
                guard let document = try repository.documentIfPresent(deviceID: id, utcDate: date) else { continue }
                let existingDailyInWeek = daily.contains { file in
                    CloudFolderSync.deviceID(from: file.name) == id &&
                    CloudFolderSync.bitmapUTCDate(from: file.name).flatMap(CloudFolderSync.weekStart(containing:)) == CloudFolderSync.weekStart(containing: date)
                }
                if date >= recentCutoff || existingDailyInWeek {
                    try await upload("sync", name, encoder.encode(document), nil); result.uploaded += 1
                } else if let start = CloudFolderSync.weekStart(containing: date), let end = CloudFolderSync.weekEnd(fromStart: start) {
                    let key = "\(id)_week_\(start)_\(end).json"
                    if newWeeks.insert(key).inserted {
                        let archive = try repository.bitmapArchive(deviceID: id, kind: "week", from: start, through: end)
                        try await upload("history", key, encoder.encode(archive), nil); result.uploaded += 1
                    }
                }
            }
        }
        for date in touched { _ = try repository.rebuildAllDevices(utcDate: date) }
        result.rebuiltDates = touched.count
        return result
    }

    private static func unpack(_ data: Data, name: String) throws -> (data: Data, rawDeflate: Bool) {
        guard name.hasSuffix(".gz") || name.hasSuffix(".zlib") else { return (data, false) }
        if name.hasSuffix(".zlib"), let decoded = try? transform(data, decompress: true, format: 0) {
            return (decoded, false)
        }
        let rawDeflate = name.hasSuffix(".zlib")
        return (try transform(data, decompress: true, format: rawDeflate ? 2 : 1), rawDeflate)
    }

    private static func fileError(_ error: Error, file: CloudAlignmentFile) -> STGError {
        let detail: String
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            detail = "missing \((context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: "."))"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context), DecodingError.dataCorrupted(let context):
            detail = "invalid \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        default: detail = DiagnosticLog.describe(error)
        }
        return STGError.invalidDocument("\(file.folder)/\(file.name): \(detail)")
    }
    private static func pack(_ data: Data, name: String, rawDeflate: Bool) throws -> Data {
        guard name.hasSuffix(".gz") || name.hasSuffix(".zlib") else { return data }
        return try transform(data, decompress: false, format: rawDeflate ? 2 : (name.hasSuffix(".gz") ? 1 : 0))
    }
    private static func transform(_ data: Data, decompress: Bool, format: Int32) throws -> Data {
        var output: UnsafeMutablePointer<UInt8>?
        var count = 0
        let status = data.withUnsafeBytes { raw in
            stg_archive_transform(raw.bindMemory(to: UInt8.self).baseAddress, data.count, &output, &count,
                                  decompress ? 1 : 0, format)
        }
        guard status == 0, let output else { throw STGError.invalidDocument("archive compression failed (\(status))") }
        defer { stg_free_buffer(output) }
        return Data(bytes: output, count: count)
    }
}
