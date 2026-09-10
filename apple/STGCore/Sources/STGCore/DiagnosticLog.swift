import Foundation

public final class DiagnosticLog: @unchecked Sendable {
    public let fileURL: URL
    private let queue = DispatchQueue(label: "com.timbertrail.screentimeguardian.diagnostic-log")
    private let formatter: ISO8601DateFormatter
    private let maximumBytes: Int64 = 1_024 * 1_024
    private let trimBytes = 800 * 1_024
    private var previousURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("stg-test.previous.log") }

    public init(directory: URL, filename: String = "stg-test.log") {
        fileURL = directory.appendingPathComponent(filename)
        formatter = ISO8601DateFormatter()
        queue.sync {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: Data())
            }
        }
    }

    public func record(_ message: String, category: String = "app") {
        queue.sync {
            if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber,
               size.int64Value >= maximumBytes,
               let existing = try? Data(contentsOf: fileURL) {
                let drop = min(trimBytes, existing.count)
                try? existing.dropFirst(drop).write(to: fileURL, options: .atomic)
            }
            let line = "\(formatter.string(from: Date())) [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch { }
        }
    }

    public func data() -> Data {
        queue.sync { combinedData() }
    }

    public func makeExportSnapshot() throws -> URL {
        try queue.sync {
            let snapshot = fileURL.deletingLastPathComponent().appendingPathComponent("stg-test-export.log")
            try combinedData().write(to: snapshot, options: .atomic)
            return snapshot
        }
    }

    public func clear() {
        queue.sync { try? Data().write(to: fileURL, options: .atomic); try? FileManager.default.removeItem(at: previousURL) }
    }

    private func combinedData() -> Data {
        (try? Data(contentsOf: fileURL)) ?? Data()
    }
}
