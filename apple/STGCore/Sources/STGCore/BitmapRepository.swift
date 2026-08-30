import Foundation
import SQLite3

public final class BitmapRepository: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.stg.bitmap-database")
    private var database: OpaquePointer?

    public init(url: URL, importsBundledOpenRouterSeed: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw STGError.database("open failed")
        }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA busy_timeout=3000;")
        try execute("""
            CREATE TABLE IF NOT EXISTS bitmap (
              device_id TEXT NOT NULL,
              utc_date TEXT NOT NULL,
              bits BLOB NOT NULL,
              updated_at REAL NOT NULL,
              PRIMARY KEY(device_id, utc_date)
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS device (
              device_id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              kind TEXT NOT NULL,
              updated_at REAL NOT NULL
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS reminder_state (
              device_id TEXT PRIMARY KEY,
              last_eye_at REAL NOT NULL,
              last_posture_at REAL NOT NULL,
              last_reminder TEXT,
              updated_at REAL NOT NULL
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS sync_state (
              device_id TEXT PRIMARY KEY,
              last_quick_upload_at REAL NOT NULL DEFAULT 0,
              last_quick_bidirectional_at REAL NOT NULL DEFAULT 0
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS pending_quick_upload (
              device_id TEXT NOT NULL,
              utc_date TEXT NOT NULL,
              queued_at REAL NOT NULL,
              PRIMARY KEY(device_id, utc_date)
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS incremental_download_cursor (
              remote_device_id TEXT PRIMARY KEY,
              latest_utc_date TEXT NOT NULL,
              updated_at REAL NOT NULL
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS incremental_upload_cursor (
              sync_target TEXT PRIMARY KEY,
              latest_utc_date TEXT NOT NULL,
              updated_at REAL NOT NULL
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS maintenance_state (
              action TEXT PRIMARY KEY,
              completed_at TEXT NOT NULL
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS openrouter_weekly (
              week_start TEXT NOT NULL,
              week_end TEXT NOT NULL,
              model TEXT NOT NULL,
              rank INTEGER NOT NULL,
              prompt_tokens INTEGER NOT NULL,
              completion_tokens INTEGER NOT NULL,
              total_tokens INTEGER NOT NULL,
              prompt_price REAL,
              completion_price REAL,
              PRIMARY KEY(week_start, model)
            );
            """)
        if importsBundledOpenRouterSeed { try importBundledOpenRouterSeedIfNeeded() }
    }

    deinit { sqlite3_close(database) }

    private func importBundledOpenRouterSeedIfNeeded() throws {
        var marker: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM maintenance_state WHERE action=? LIMIT 1", -1, &marker, nil) == SQLITE_OK else { throw error() }
        bind(OpenRouterSeed.marker, at: 1, to: marker)
        let alreadyImported = sqlite3_step(marker) == SQLITE_ROW
        sqlite3_finalize(marker)
        guard !alreadyImported else { return }

        let seed = try OpenRouterSeed.load()
        try execute("BEGIN IMMEDIATE;")
        do {
            let sql = "INSERT OR IGNORE INTO openrouter_weekly(week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price) VALUES(?,?,?,?,?,?,?,NULL,NULL)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            for row in seed.rows {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                bind(row.weekStart, at: 1, to: statement); bind(row.weekEnd, at: 2, to: statement); bind(row.model, at: 3, to: statement)
                sqlite3_bind_int(statement, 4, Int32(row.rank))
                // The historical dataset publishes total tokens only. -1 means unavailable,
                // and prevents the UI from presenting fabricated input/output values.
                sqlite3_bind_int64(statement, 5, -1); sqlite3_bind_int64(statement, 6, -1)
                sqlite3_bind_int64(statement, 7, row.totalTokens)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            }
            var saveMarker: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO maintenance_state(action,completed_at) VALUES(?,?) ON CONFLICT(action) DO UPDATE SET completed_at=excluded.completed_at", -1, &saveMarker, nil) == SQLITE_OK else { throw error() }
            bind(OpenRouterSeed.marker, at: 1, to: saveMarker); bind(seed.asOf, at: 2, to: saveMarker)
            guard sqlite3_step(saveMarker) == SQLITE_DONE else { sqlite3_finalize(saveMarker); throw error() }
            sqlite3_finalize(saveMarker)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func bitmap(deviceID: String, utcDate: String) throws -> MinuteBitmap {
        try queue.sync {
            let sql = "SELECT bits FROM bitmap WHERE device_id=? AND utc_date=?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement); bind(utcDate, at: 2, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return MinuteBitmap() }
            let size = Int(sqlite3_column_bytes(statement, 0))
            guard let bytes = sqlite3_column_blob(statement, 0) else { return MinuteBitmap() }
            return try MinuteBitmap(data: Data(bytes: bytes, count: size))
        }
    }

    @discardableResult
    public func mark(deviceID: String, instant: Date, updatedAt: Date? = nil) throws -> Bool {
        let key = STGTime.utcDateKey(for: instant)
        let minute = STGTime.utcMinute(for: instant)
        return try queue.sync {
            var current = try bitmapUnlocked(deviceID: deviceID, utcDate: key)
            let changed = current.mark(minute)
            if changed { try upsertUnlocked(deviceID: deviceID, utcDate: key, bitmap: current, updatedAt: updatedAt ?? instant) }
            return changed
        }
    }

    public func upsertDevice(_ device: DeviceRecord) throws {
        try queue.sync {
            let sql = "INSERT INTO device(device_id,name,kind,updated_at) VALUES(?,?,?,?) ON CONFLICT(device_id) DO UPDATE SET name=excluded.name,kind=excluded.kind,updated_at=excluded.updated_at WHERE excluded.updated_at>=device.updated_at"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(device.deviceID, at: 1, to: statement); bind(device.name, at: 2, to: statement); bind(device.kind.rawValue, at: 3, to: statement)
            sqlite3_bind_double(statement, 4, device.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    public func deviceRecords() throws -> [DeviceRecord] {
        try queue.sync {
            let sql = "SELECT device_id,name,kind,updated_at FROM device ORDER BY name COLLATE NOCASE,device_id"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            var result: [DeviceRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let idText = sqlite3_column_text(statement, 0),
                  let nameText = sqlite3_column_text(statement, 1),
                  let kindText = sqlite3_column_text(statement, 2),
                  let kind = DeviceKind(rawValue: String(cString: kindText)) {
                result.append(DeviceRecord(
                    deviceID: String(cString: idText),
                    name: String(cString: nameText),
                    kind: kind,
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                ))
            }
            return result
        }
    }

    public func upsert(deviceID: String, utcDate: String, bitmap: MinuteBitmap, updatedAt: Date = .now) throws {
        try queue.sync { try upsertUnlocked(deviceID: deviceID, utcDate: utcDate, bitmap: bitmap, updatedAt: updatedAt) }
    }

    public func upsertIfNewer(deviceID: String, utcDate: String, bitmap: MinuteBitmap, updatedAt: Date) throws {
        try queue.sync {
            let sql = "INSERT INTO bitmap(device_id,utc_date,bits,updated_at) VALUES(?,?,?,?) ON CONFLICT(device_id,utc_date) DO UPDATE SET bits=excluded.bits,updated_at=excluded.updated_at WHERE excluded.updated_at>=bitmap.updated_at"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement); bind(utcDate, at: 2, to: statement)
            _ = bitmap.data.withUnsafeBytes { buffer in sqlite3_bind_blob(statement, 3, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT) }
            sqlite3_bind_double(statement, 4, updatedAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    public func rebuildAllDevices(utcDate: String) throws -> MinuteBitmap {
        try queue.sync {
            let sql = "SELECT bits FROM bitmap WHERE device_id<>? AND utc_date=?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind("alldevices", at: 1, to: statement); bind(utcDate, at: 2, to: statement)
            var aggregate = MinuteBitmap()
            while sqlite3_step(statement) == SQLITE_ROW {
                let size = Int(sqlite3_column_bytes(statement, 0))
                if let bytes = sqlite3_column_blob(statement, 0), let bitmap = try? MinuteBitmap(data: Data(bytes: bytes, count: size)) {
                    aggregate.formUnion(bitmap)
                }
            }
            try upsertUnlocked(deviceID: "alldevices", utcDate: utcDate, bitmap: aggregate, updatedAt: .now)
            return aggregate
        }
    }

    public func localDayMinutes(deviceID: String, instant: Date, timeZoneID: String) throws -> Int {
        try localDayBitmap(deviceID: deviceID, instant: instant, timeZoneID: timeZoneID).lazy.filter { $0 }.count
    }

    public func localDayBitmap(deviceID: String, instant: Date, timeZoneID: String) throws -> [Bool] {
        let interval = STGTime.localDayInterval(containing: instant, timeZoneID: timeZoneID)
        var rows: [String: MinuteBitmap] = [:]
        var result: [Bool] = []
        result.reserveCapacity(Int(interval.duration / 60))
        var cursor = interval.start
        while cursor < interval.end {
            let key = STGTime.utcDateKey(for: cursor)
            if rows[key] == nil { rows[key] = try bitmap(deviceID: deviceID, utcDate: key) }
            result.append(rows[key]?[STGTime.utcMinute(for: cursor)] == true)
            cursor = cursor.addingTimeInterval(60)
        }
        return result
    }

    /// A fixed-size wall-clock projection used only by the four-row report.
    /// Calculations continue to use `localDayBitmap`, whose size reflects the
    /// actual 23/24/25-hour local day.
    public func localClockDayBitmap(deviceID: String, instant: Date, timeZoneID: String) throws -> [Bool] {
        let interval = STGTime.localDayInterval(containing: instant, timeZoneID: timeZoneID)
        var rows: [String: MinuteBitmap] = [:]
        // The report is a clock-face bitmap, not an elapsed-time strip. Always
        // return 1,440 positions so 16:51 is rendered at 16:51 even on DST
        // transition days. Repeated fall-back minutes are unioned; missing
        // spring-forward minutes remain clear.
        var result = [Bool](repeating: false, count: MinuteBitmap.minuteCount)
        var cursor = interval.start
        while cursor < interval.end {
            let key = STGTime.utcDateKey(for: cursor)
            if rows[key] == nil { rows[key] = try bitmap(deviceID: deviceID, utcDate: key) }
            if rows[key]?[STGTime.utcMinute(for: cursor)] == true {
                result[STGTime.localClockMinute(for: cursor, timeZoneID: timeZoneID)] = true
            }
            cursor = cursor.addingTimeInterval(60)
        }
        return result
    }

    public func dayReport(localDeviceID: String, localDeviceName: String, localDeviceKind: DeviceKind, instant: Date, timeZoneID: String, includeSyncedDevices: Bool) throws -> [DeviceDayBitmap] {
        try upsertDevice(DeviceRecord(deviceID: localDeviceID, name: localDeviceName, kind: localDeviceKind))
        let names = Dictionary(uniqueKeysWithValues: try deviceRecords().map { ($0.deviceID, $0.name) })
        let local = try localClockDayBitmap(deviceID: localDeviceID, instant: instant, timeZoneID: timeZoneID)
        let localCount = try localDayMinutes(deviceID: localDeviceID, instant: instant, timeZoneID: timeZoneID)
        let aggregate: [Bool]
        let aggregateCount: Int
        var ids: [String]
        if includeSyncedDevices {
            for key in STGTime.utcDateKeys(overlapping: STGTime.localDayInterval(containing: instant, timeZoneID: timeZoneID)) { _ = try rebuildAllDevices(utcDate: key) }
            aggregate = try localClockDayBitmap(deviceID: "alldevices", instant: instant, timeZoneID: timeZoneID)
            aggregateCount = try localDayMinutes(deviceID: "alldevices", instant: instant, timeZoneID: timeZoneID)
            ids = try deviceIDs()
        } else {
            aggregate = local; aggregateCount = localCount; ids = [localDeviceID]
        }
        if !ids.contains(localDeviceID) { ids.insert(localDeviceID, at: 0) }
        var result = [DeviceDayBitmap(deviceID: "alldevices", displayName: "All devices", minutes: aggregate, isAggregate: true, usedMinutes: aggregateCount)]
        for id in ids {
            let name = id == localDeviceID ? localDeviceName : (names[id] ?? "Other device")
            let clock = id == localDeviceID ? local : try localClockDayBitmap(deviceID: id, instant: instant, timeZoneID: timeZoneID)
            let count = id == localDeviceID ? localCount : try localDayMinutes(deviceID: id, instant: instant, timeZoneID: timeZoneID)
            result.append(DeviceDayBitmap(deviceID: id, displayName: name, minutes: clock, usedMinutes: count))
        }
        return result
    }

    public func multiDayReport(localDeviceID: String, localDeviceName: String, localDeviceKind: DeviceKind, start: Date, end: Date, timeZoneID: String, includeSyncedDevices: Bool) throws -> [DailyUsagePoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        var cursor = calendar.startOfDay(for: min(start, end))
        let finalDay = calendar.startOfDay(for: max(start, end))
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        var result: [DailyUsagePoint] = []
        while cursor <= finalDay {
            let representative = calendar.date(byAdding: .hour, value: 12, to: cursor) ?? cursor
            let label = formatter.string(from: representative)
            for bitmap in try dayReport(localDeviceID: localDeviceID, localDeviceName: localDeviceName, localDeviceKind: localDeviceKind, instant: representative, timeZoneID: timeZoneID, includeSyncedDevices: includeSyncedDevices) {
                result.append(DailyUsagePoint(date: representative, dateLabel: label, deviceID: bitmap.deviceID, displayName: bitmap.displayName, minutes: bitmap.usedMinutes, isAggregate: bitmap.isAggregate))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    public func deviceIDs() throws -> [String] {
        try queue.sync {
            let sql = "SELECT DISTINCT device_id FROM bitmap WHERE device_id<>? ORDER BY device_id"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind("alldevices", at: 1, to: statement)
            var result: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                result.append(String(cString: text))
            }
            return result
        }
    }

    public func bitmapUpdatedAt(deviceID: String, utcDate: String) throws -> Date? {
        try queue.sync {
            let sql = "SELECT updated_at FROM bitmap WHERE device_id=? AND utc_date=?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement); bind(utcDate, at: 2, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
    }

    public func quickSyncState(deviceID: String) throws -> QuickSyncState {
        try queue.sync {
            var lastUpload = Date.distantPast
            var lastBidirectional = Date.distantPast
            var stateStatement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT last_quick_upload_at,last_quick_bidirectional_at FROM sync_state WHERE device_id=?", -1, &stateStatement, nil) == SQLITE_OK else { throw error() }
            bind(deviceID, at: 1, to: stateStatement)
            if sqlite3_step(stateStatement) == SQLITE_ROW {
                lastUpload = Date(timeIntervalSince1970: sqlite3_column_double(stateStatement, 0))
                lastBidirectional = Date(timeIntervalSince1970: sqlite3_column_double(stateStatement, 1))
            }
            sqlite3_finalize(stateStatement)

            var pending: Set<String> = []
            var pendingStatement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT utc_date FROM pending_quick_upload WHERE device_id=? ORDER BY utc_date", -1, &pendingStatement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(pendingStatement) }
            bind(deviceID, at: 1, to: pendingStatement)
            while sqlite3_step(pendingStatement) == SQLITE_ROW, let text = sqlite3_column_text(pendingStatement, 0) { pending.insert(String(cString: text)) }
            return QuickSyncState(lastUploadAt: lastUpload, lastBidirectionalAt: lastBidirectional, pendingUTCDateKeys: pending)
        }
    }

    public func queueQuickUpload(deviceID: String, utcDateKeys: Set<String>, at: Date = .now) throws {
        guard !utcDateKeys.isEmpty else { return }
        try queue.sync {
            let sql = "INSERT INTO pending_quick_upload(device_id,utc_date,queued_at) VALUES(?,?,?) ON CONFLICT(device_id,utc_date) DO UPDATE SET queued_at=excluded.queued_at"
            for key in utcDateKeys {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
                bind(deviceID, at: 1, to: statement); bind(key, at: 2, to: statement); sqlite3_bind_double(statement, 3, at.timeIntervalSince1970)
                let result = sqlite3_step(statement); sqlite3_finalize(statement)
                guard result == SQLITE_DONE else { throw error() }
            }
        }
    }

    public func completeQuickUpload(deviceID: String, utcDateKeys: Set<String>, at: Date = .now) throws {
        try queue.sync {
            try upsertSyncStateUnlocked(deviceID: deviceID, uploadAt: at, bidirectionalAt: nil)
            guard !utcDateKeys.isEmpty else { return }
            for key in utcDateKeys {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "DELETE FROM pending_quick_upload WHERE device_id=? AND utc_date=?", -1, &statement, nil) == SQLITE_OK else { throw error() }
                bind(deviceID, at: 1, to: statement); bind(key, at: 2, to: statement)
                let result = sqlite3_step(statement); sqlite3_finalize(statement)
                guard result == SQLITE_DONE else { throw error() }
            }
        }
    }

    public func completeQuickBidirectional(deviceID: String, at: Date = .now) throws {
        try queue.sync { try upsertSyncStateUnlocked(deviceID: deviceID, uploadAt: nil, bidirectionalAt: at) }
    }

    /// Latest remote UTC date successfully imported on this device. The date
    /// is intentionally inclusive on the next incremental pass so an updated
    /// bitmap for the current day is downloaded again.
    public func incrementalDownloadCursor(remoteDeviceID: String) throws -> String? {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT latest_utc_date FROM incremental_download_cursor WHERE remote_device_id=?", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(remoteDeviceID, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }

    public func saveIncrementalDownloadCursor(remoteDeviceID: String, latestUTCDate: String, at: Date = .now) throws {
        try queue.sync {
            let sql = "INSERT INTO incremental_download_cursor(remote_device_id,latest_utc_date,updated_at) VALUES(?,?,?) ON CONFLICT(remote_device_id) DO UPDATE SET latest_utc_date=CASE WHEN excluded.latest_utc_date>incremental_download_cursor.latest_utc_date THEN excluded.latest_utc_date ELSE incremental_download_cursor.latest_utc_date END,updated_at=excluded.updated_at"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(remoteDeviceID, at: 1, to: statement); bind(latestUTCDate, at: 2, to: statement)
            sqlite3_bind_double(statement, 3, at.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    public func incrementalDownloadCursors() throws -> [String: String] {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT remote_device_id,latest_utc_date FROM incremental_download_cursor ORDER BY remote_device_id", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            var result: [String: String] = [:]
            while sqlite3_step(statement) == SQLITE_ROW,
                  let id = sqlite3_column_text(statement, 0),
                  let date = sqlite3_column_text(statement, 1) {
                result[String(cString: id)] = String(cString: date)
            }
            return result
        }
    }

    public func incrementalUploadCursor(syncTarget: String) throws -> String? {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT latest_utc_date FROM incremental_upload_cursor WHERE sync_target=?", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(syncTarget, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }

    public func saveIncrementalUploadCursor(syncTarget: String, latestUTCDate: String, at: Date = .now) throws {
        try queue.sync {
            let sql = "INSERT INTO incremental_upload_cursor(sync_target,latest_utc_date,updated_at) VALUES(?,?,?) ON CONFLICT(sync_target) DO UPDATE SET latest_utc_date=CASE WHEN excluded.latest_utc_date>incremental_upload_cursor.latest_utc_date THEN excluded.latest_utc_date ELSE incremental_upload_cursor.latest_utc_date END,updated_at=excluded.updated_at"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(syncTarget, at: 1, to: statement); bind(latestUTCDate, at: 2, to: statement)
            sqlite3_bind_double(statement, 3, at.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    public func latestOpenRouterWeekEnd() throws -> String? {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT MAX(week_end) FROM openrouter_weekly", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }

    /// The bundled seed contains total tokens only. This cursor tracks weeks
    /// refreshed from model-activity with prompt/completion token details.
    public func latestOpenRouterDetailWeekEnd() throws -> String? {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT completed_at FROM maintenance_state WHERE action='openrouter_detail'", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }

    public func completeOpenRouterDetailWeek(through weekEnd: String) throws {
        try queue.sync {
            let sql = "INSERT INTO maintenance_state(action,completed_at) VALUES('openrouter_detail',?) ON CONFLICT(action) DO UPDATE SET completed_at=excluded.completed_at"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(weekEnd, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    public func weeklyActionDue(now: Date = .now) throws -> Bool {
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = STGTime.utc
        let today = calendar.startOfDay(for: now)
        let monday = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = STGTime.utc; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let mondayKey = formatter.string(from: monday)
        return try queue.sync {
            var initialize: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO maintenance_state(action,completed_at) VALUES('weekly',?)", -1, &initialize, nil) == SQLITE_OK else { throw error() }
            bind(mondayKey, at: 1, to: initialize); guard sqlite3_step(initialize) == SQLITE_DONE else { sqlite3_finalize(initialize); throw error() }; sqlite3_finalize(initialize)

            var state: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT completed_at FROM maintenance_state WHERE action='weekly'", -1, &state, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(state) }
            var completed = ""
            if sqlite3_step(state) == SQLITE_ROW, let text = sqlite3_column_text(state, 0) { completed = String(cString: text) }
            let previousSunday = calendar.date(byAdding: .day, value: -1, to: monday) ?? monday
            let previousSundayKey = formatter.string(from: previousSunday)
            var detail: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT completed_at FROM maintenance_state WHERE action='openrouter_detail'", -1, &detail, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(detail) }
            var detailedThrough = ""
            if sqlite3_step(detail) == SQLITE_ROW, let text = sqlite3_column_text(detail, 0) { detailedThrough = String(cString: text) }
            return String(completed.prefix(10)) < mondayKey || String(detailedThrough.prefix(10)) < previousSundayKey
        }
    }

    public func completeWeeklyAction(at: Date = .now) throws {
        try queue.sync {
            let sql = "INSERT INTO maintenance_state(action,completed_at) VALUES('weekly',?) ON CONFLICT(action) DO UPDATE SET completed_at=excluded.completed_at"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(ISO8601DateFormatter().string(from: at), at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    public func upsertOpenRouterWeeks(_ rows: [OpenRouterWeeklyRankingRow]) throws {
        guard !rows.isEmpty else { return }
        try queue.sync {
            try execute("BEGIN IMMEDIATE;")
            do {
                let sql = "INSERT INTO openrouter_weekly(week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(week_start,model) DO UPDATE SET week_end=excluded.week_end,rank=excluded.rank,prompt_tokens=excluded.prompt_tokens,completion_tokens=excluded.completion_tokens,total_tokens=excluded.total_tokens,prompt_price=excluded.prompt_price,completion_price=excluded.completion_price"
                for row in rows {
                    var statement: OpaquePointer?
                    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
                    bind(row.weekStart, at: 1, to: statement); bind(row.weekEnd, at: 2, to: statement); bind(row.modelPermaslug, at: 3, to: statement)
                    sqlite3_bind_int(statement, 4, Int32(row.rank)); sqlite3_bind_int64(statement, 5, row.promptTokens); sqlite3_bind_int64(statement, 6, row.completionTokens); sqlite3_bind_int64(statement, 7, row.totalTokens)
                    if let value = row.promptPricePerToken { sqlite3_bind_double(statement, 8, value) } else { sqlite3_bind_null(statement, 8) }
                    if let value = row.completionPricePerToken { sqlite3_bind_double(statement, 9, value) } else { sqlite3_bind_null(statement, 9) }
                    guard sqlite3_step(statement) == SQLITE_DONE else { sqlite3_finalize(statement); throw error() }
                    sqlite3_finalize(statement)
                }
                try execute("COMMIT;")
            } catch { try? execute("ROLLBACK;"); throw error }
        }
    }

    public func openRouterWeeks(models: [String]) throws -> [OpenRouterWeeklyRankingRow] {
        guard !models.isEmpty else { return [] }
        return try queue.sync {
            let placeholders = Array(repeating: "?", count: models.count).joined(separator: ",")
            let sql = "SELECT week_start,week_end,rank,model,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price FROM openrouter_weekly WHERE model IN (\(placeholders)) ORDER BY week_start,rank"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            for (index, model) in models.enumerated() { bind(model, at: Int32(index + 1), to: statement) }
            var result: [OpenRouterWeeklyRankingRow] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let start = sqlite3_column_text(statement, 0), let end = sqlite3_column_text(statement, 1), let model = sqlite3_column_text(statement, 3) {
                result.append(OpenRouterWeeklyRankingRow(
                    weekStart: String(cString: start), weekEnd: String(cString: end), rank: Int(sqlite3_column_int(statement, 2)), modelPermaslug: String(cString: model),
                    promptTokens: sqlite3_column_int64(statement, 4), completionTokens: sqlite3_column_int64(statement, 5), totalTokens: sqlite3_column_int64(statement, 6),
                    promptPricePerToken: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 7),
                    completionPricePerToken: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 8)))
            }
            return result
        }
    }

    public func latestOpenRouterTopModels(limit: Int = 10) throws -> [String] {
        try queue.sync {
            let sql = "SELECT model FROM openrouter_weekly WHERE week_start=(SELECT MAX(week_start) FROM openrouter_weekly) ORDER BY rank LIMIT ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
            var result: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) { result.append(String(cString: text)) }
            return result
        }
    }

    public func reminderState(deviceID: String) throws -> ReminderState {
        try queue.sync {
            let sql = "SELECT last_eye_at,last_posture_at,last_reminder FROM reminder_state WHERE device_id=?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return ReminderState() }
            let lastReminder: ReminderKind?
            if let text = sqlite3_column_text(statement, 2),
               let value = ReminderKind(rawValue: String(cString: text)),
               value == .eye || value == .posture {
                lastReminder = value
            } else {
                lastReminder = nil
            }
            return ReminderState(
                lastEyeAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                lastPostureAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                lastReminder: lastReminder
            )
        }
    }

    public func saveReminderState(deviceID: String, state: ReminderState, updatedAt: Date = .now) throws {
        try queue.sync {
            let sql = "INSERT INTO reminder_state(device_id,last_eye_at,last_posture_at,last_reminder,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(device_id) DO UPDATE SET last_eye_at=excluded.last_eye_at,last_posture_at=excluded.last_posture_at,last_reminder=excluded.last_reminder,updated_at=excluded.updated_at"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement)
            sqlite3_bind_double(statement, 2, state.lastEyeAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, state.lastPostureAt.timeIntervalSince1970)
            if let value = state.lastReminder, value == .eye || value == .posture {
                bind(value.rawValue, at: 4, to: statement)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_bind_double(statement, 5, updatedAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    public func clearLocalDay(deviceID: String, instant: Date, timeZoneID: String) throws -> Int {
        let interval = STGTime.localDayInterval(containing: instant, timeZoneID: timeZoneID)
        var rows: [String: MinuteBitmap] = [:]
        var cleared = 0
        var cursor = interval.start
        while cursor < interval.end {
            let key = STGTime.utcDateKey(for: cursor)
            if rows[key] == nil { rows[key] = try bitmap(deviceID: deviceID, utcDate: key) }
            let minute = STGTime.utcMinute(for: cursor)
            if rows[key]?[minute] == true { rows[key]?[minute] = false; cleared += 1 }
            cursor = cursor.addingTimeInterval(60)
        }
        for (key, bitmap) in rows { try upsert(deviceID: deviceID, utcDate: key, bitmap: bitmap) }
        for key in rows.keys { _ = try rebuildAllDevices(utcDate: key) }
        return cleared
    }

    public func deleteOtherDeviceData(localDeviceID: String) throws -> Int {
        try queue.sync {
            let sql = "DELETE FROM bitmap WHERE device_id<>? AND device_id<>?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(localDeviceID, at: 1, to: statement); bind("alldevices", at: 2, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            let deleted = Int(sqlite3_changes(database))
            try execute("DELETE FROM incremental_download_cursor;")
            return deleted
        }
    }

    public func document(deviceID: String, utcDate: String) throws -> BitmapDocument {
        BitmapDocument(deviceID: deviceID, utcDate: utcDate, bitmap: try bitmap(deviceID: deviceID, utcDate: utcDate))
    }

    private func bitmapUnlocked(deviceID: String, utcDate: String) throws -> MinuteBitmap {
        let sql = "SELECT bits FROM bitmap WHERE device_id=? AND utc_date=?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        bind(deviceID, at: 1, to: statement); bind(utcDate, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return MinuteBitmap() }
        return try MinuteBitmap(data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }

    private func upsertUnlocked(deviceID: String, utcDate: String, bitmap: MinuteBitmap, updatedAt: Date) throws {
        let sql = "INSERT INTO bitmap(device_id,utc_date,bits,updated_at) VALUES(?,?,?,?) ON CONFLICT(device_id,utc_date) DO UPDATE SET bits=excluded.bits,updated_at=excluded.updated_at"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        bind(deviceID, at: 1, to: statement); bind(utcDate, at: 2, to: statement)
        _ = bitmap.data.withUnsafeBytes { buffer in sqlite3_bind_blob(statement, 3, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT) }
        sqlite3_bind_double(statement, 4, updatedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func upsertSyncStateUnlocked(deviceID: String, uploadAt: Date?, bidirectionalAt: Date?) throws {
        let sql = """
        INSERT INTO sync_state(device_id,last_quick_upload_at,last_quick_bidirectional_at) VALUES(?,?,?)
        ON CONFLICT(device_id) DO UPDATE SET
          last_quick_upload_at=CASE WHEN excluded.last_quick_upload_at>0 THEN excluded.last_quick_upload_at ELSE sync_state.last_quick_upload_at END,
          last_quick_bidirectional_at=CASE WHEN excluded.last_quick_bidirectional_at>0 THEN excluded.last_quick_bidirectional_at ELSE sync_state.last_quick_bidirectional_at END
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        bind(deviceID, at: 1, to: statement)
        sqlite3_bind_double(statement, 2, uploadAt?.timeIntervalSince1970 ?? 0)
        sqlite3_bind_double(statement, 3, bidirectionalAt?.timeIntervalSince1970 ?? 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func error() -> STGError { STGError.database(String(cString: sqlite3_errmsg(database))) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
