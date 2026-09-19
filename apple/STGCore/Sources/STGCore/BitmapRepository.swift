import Foundation
import SQLite3

public final class BitmapRepository: @unchecked Sendable {
    private static let schemaVersion = 7
    private let queue = DispatchQueue(label: "com.stg.bitmap-database")
    private var database: OpaquePointer?
    private let databaseURL: URL

    public init(url: URL, importsBundledOpenRouterSeed: Bool = true, installsBundledDatabaseTemplate: Bool = true) throws {
        databaseURL = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if installsBundledDatabaseTemplate, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.copyItem(at: OpenRouterSeed.databaseURL(), to: url)
        }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw STGError.database("open failed")
        }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA busy_timeout=3000;")
        try createCanonicalSchema()
        try migrateToCanonicalSchemaIfNeeded()
        if importsBundledOpenRouterSeed { _ = try importBundledOpenRouterSeedIfNeededUnlocked() }
    }

    deinit { sqlite3_close(database) }

    /// Imports the bundled historical tracking data on demand. Callers that
    /// need a fast first frame can construct the repository with
    /// `importsBundledOpenRouterSeed: false` and invoke this from a background
    /// task after their initial UI is visible.
    @discardableResult
    public func importBundledOpenRouterSeedIfNeeded() throws -> Bool {
        try queue.sync { try importBundledOpenRouterSeedIfNeededUnlocked() }
    }

    private func importBundledOpenRouterSeedIfNeededUnlocked() throws -> Bool {
        var marker: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA application_id", -1, &marker, nil) == SQLITE_OK else { throw error() }
        let alreadyImported = sqlite3_step(marker) == SQLITE_ROW && sqlite3_column_int(marker, 0) == OpenRouterSeed.applicationID
        sqlite3_finalize(marker)
        var metadataCheck: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM openrouter_weekly WHERE prompt_tokens<0 AND as_of IS NULL", -1, &metadataCheck, nil) == SQLITE_OK else { throw error() }
        let missingSeedMetadata = sqlite3_step(metadataCheck) == SQLITE_ROW && sqlite3_column_int64(metadataCheck, 0) > 0
        sqlite3_finalize(metadataCheck)
        guard !alreadyImported || missingSeedMetadata else { return false }

        let seedURL = try OpenRouterSeed.databaseURL()
        var attach: OpaquePointer?
        guard sqlite3_prepare_v2(database, "ATTACH DATABASE ? AS bundled_seed", -1, &attach, nil) == SQLITE_OK else { throw error() }
        bind(seedURL.path, at: 1, to: attach)
        guard sqlite3_step(attach) == SQLITE_DONE else { sqlite3_finalize(attach); throw error() }
        sqlite3_finalize(attach)
        defer { try? execute("DETACH DATABASE bundled_seed;") }
        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("""
                INSERT OR IGNORE INTO openrouter_weekly(
                    week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete,updated_at
                ) SELECT week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete,updated_at
                  FROM bundled_seed.openrouter_weekly;
                UPDATE openrouter_weekly
                   SET as_of=(SELECT seed.as_of FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model),
                       missing_dates=(SELECT seed.missing_dates FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model),
                       is_complete=(SELECT seed.is_complete FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model),
                       updated_at=MAX(updated_at,COALESCE((SELECT seed.updated_at FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model),0))
                 WHERE prompt_tokens<0 AND as_of IS NULL
                   AND EXISTS(SELECT 1 FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model);
                """)
            try execute("COMMIT;")
            try execute("PRAGMA application_id=\(OpenRouterSeed.applicationID);")
            return true
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func createCanonicalSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS bitmap(device_id TEXT NOT NULL,utc_date TEXT NOT NULL,bits BLOB NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(device_id,utc_date));
            CREATE TABLE IF NOT EXISTS device(device_id TEXT PRIMARY KEY,name TEXT NOT NULL,kind TEXT NOT NULL,updated_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS reminder_state(device_id TEXT PRIMARY KEY,last_eye_at INTEGER NOT NULL,last_posture_at INTEGER NOT NULL,last_reminder TEXT,updated_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS sync_state(
                device_id TEXT PRIMARY KEY,
                last_quick_upload_at INTEGER NOT NULL DEFAULT 0,
                last_quick_bidirectional_at INTEGER NOT NULL DEFAULT 0,
                last_incremental_sync_at INTEGER NOT NULL DEFAULT 0,
                last_statistics_at INTEGER NOT NULL DEFAULT 0,
                last_weekly_action_at INTEGER NOT NULL DEFAULT 0,
                last_yearly_action_at INTEGER NOT NULL DEFAULT 0,
                last_posture_at INTEGER NOT NULL DEFAULT 0,
                last_eye_at INTEGER NOT NULL DEFAULT 0,
                bitmap_updated_at INTEGER NOT NULL DEFAULT 0,
                continuous_minutes INTEGER NOT NULL DEFAULT 0,
                local_daily_minutes INTEGER NOT NULL DEFAULT 0,
                aggregate_daily_minutes INTEGER NOT NULL DEFAULT 0,
                state_local_date TEXT
            );
            CREATE TABLE IF NOT EXISTS pending_quick_upload(device_id TEXT NOT NULL,utc_date TEXT NOT NULL,queued_at INTEGER NOT NULL,PRIMARY KEY(device_id,utc_date));
            CREATE TABLE IF NOT EXISTS incremental_download_cursor(remote_device_id TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS incremental_upload_cursor(sync_target TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS maintenance_state(action TEXT PRIMARY KEY,completed_at TEXT NOT NULL,updated_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS statistics_state(id INTEGER PRIMARY KEY CHECK(id=1),last_statistics_at INTEGER NOT NULL DEFAULT 0,dirty_from_date TEXT,updated_at INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS daily_statistics(device_id TEXT NOT NULL,report_date TEXT NOT NULL,minutes INTEGER NOT NULL,daily_limit_minutes INTEGER NOT NULL,source_updated_at INTEGER NOT NULL,calculated_at INTEGER NOT NULL,estimated INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(device_id,report_date));
            CREATE TABLE IF NOT EXISTS weekly_statistics(device_id TEXT NOT NULL,iso_year INTEGER NOT NULL,iso_week INTEGER NOT NULL,period_start TEXT NOT NULL,period_end TEXT NOT NULL,average_daily_minutes REAL NOT NULL,included_days INTEGER NOT NULL,excluded_days INTEGER NOT NULL,calculated_at INTEGER NOT NULL,estimated INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(device_id,iso_year,iso_week));
            CREATE TABLE IF NOT EXISTS monthly_statistics(device_id TEXT NOT NULL,year INTEGER NOT NULL,month INTEGER NOT NULL,period_start TEXT NOT NULL,period_end TEXT NOT NULL,average_daily_minutes REAL NOT NULL,included_days INTEGER NOT NULL,excluded_days INTEGER NOT NULL,calculated_at INTEGER NOT NULL,estimated INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(device_id,year,month));
            CREATE TABLE IF NOT EXISTS yearly_statistics(device_id TEXT NOT NULL,year INTEGER NOT NULL,period_start TEXT NOT NULL,period_end TEXT NOT NULL,average_daily_minutes REAL NOT NULL,included_days INTEGER NOT NULL,excluded_days INTEGER NOT NULL,calculated_at INTEGER NOT NULL,estimated INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(device_id,year));
            CREATE TABLE IF NOT EXISTS openrouter_weekly(week_start TEXT NOT NULL,week_end TEXT NOT NULL,model TEXT NOT NULL,rank INTEGER NOT NULL,prompt_tokens INTEGER NOT NULL,completion_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,prompt_price REAL,completion_price REAL,revenue REAL,as_of TEXT,missing_dates TEXT NOT NULL DEFAULT '[]',is_complete INTEGER NOT NULL DEFAULT 1,updated_at INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(week_start,model));
            CREATE TABLE IF NOT EXISTS archive_manifest(archive_id TEXT PRIMARY KEY,kind TEXT NOT NULL,period_start TEXT NOT NULL,period_end TEXT NOT NULL,local_path TEXT,cloud_path TEXT,checksum TEXT,created_at INTEGER NOT NULL,uploaded_at INTEGER,status TEXT NOT NULL);
            """)
    }

    private func migrateToCanonicalSchemaIfNeeded() throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { throw error() }
        let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
        sqlite3_finalize(statement)
        guard version < Self.schemaVersion else { return }

        if version < 6 {
          try execute("BEGIN IMMEDIATE;")
          do {
            let tables = ["bitmap", "device", "reminder_state", "sync_state", "pending_quick_upload", "incremental_download_cursor", "incremental_upload_cursor", "maintenance_state", "openrouter_weekly"]
            for table in tables { try execute("ALTER TABLE \(table) RENAME TO \(table)_legacy;") }
            try createCanonicalSchema()
            try execute("INSERT INTO bitmap SELECT device_id,utc_date,bits,CAST(updated_at AS INTEGER) FROM bitmap_legacy;")
            try execute("INSERT INTO device SELECT device_id,name,kind,CAST(updated_at AS INTEGER) FROM device_legacy;")
            try execute("INSERT INTO reminder_state SELECT device_id,CAST(last_eye_at AS INTEGER),CAST(last_posture_at AS INTEGER),last_reminder,CAST(updated_at AS INTEGER) FROM reminder_state_legacy;")
            try execute("INSERT INTO sync_state(device_id,last_quick_upload_at,last_quick_bidirectional_at) SELECT device_id,CAST(last_quick_upload_at AS INTEGER),CAST(last_quick_bidirectional_at AS INTEGER) FROM sync_state_legacy;")
            try execute("INSERT INTO pending_quick_upload SELECT device_id,utc_date,CAST(queued_at AS INTEGER) FROM pending_quick_upload_legacy;")
            try execute("INSERT INTO incremental_download_cursor SELECT remote_device_id,latest_utc_date,CAST(updated_at AS INTEGER) FROM incremental_download_cursor_legacy;")
            try execute("INSERT INTO incremental_upload_cursor SELECT sync_target,latest_utc_date,CAST(updated_at AS INTEGER) FROM incremental_upload_cursor_legacy;")
            try execute("INSERT INTO maintenance_state SELECT action,completed_at,CAST(strftime('%s','now') AS INTEGER) FROM maintenance_state_legacy;")
            try execute("INSERT INTO openrouter_weekly(week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price) SELECT week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price FROM openrouter_weekly_legacy;")
            for table in tables { try execute("DROP TABLE \(table)_legacy;") }
            try execute("PRAGMA user_version=6;")
            try execute("COMMIT;")
          } catch {
            try? execute("ROLLBACK;")
            throw error
          }
        }

        if version < 7 {
            try execute("BEGIN IMMEDIATE;")
            do {
                let syncColumns = [
                    "last_incremental_sync_at INTEGER NOT NULL DEFAULT 0",
                    "last_statistics_at INTEGER NOT NULL DEFAULT 0",
                    "last_weekly_action_at INTEGER NOT NULL DEFAULT 0",
                    "last_yearly_action_at INTEGER NOT NULL DEFAULT 0",
                    "last_posture_at INTEGER NOT NULL DEFAULT 0",
                    "last_eye_at INTEGER NOT NULL DEFAULT 0",
                    "bitmap_updated_at INTEGER NOT NULL DEFAULT 0",
                    "continuous_minutes INTEGER NOT NULL DEFAULT 0",
                    "local_daily_minutes INTEGER NOT NULL DEFAULT 0",
                    "aggregate_daily_minutes INTEGER NOT NULL DEFAULT 0",
                    "state_local_date TEXT"
                ]
                for definition in syncColumns { try addColumnIfMissing(table: "sync_state", definition: definition) }
                let trackingColumns = [
                    "revenue REAL", "as_of TEXT", "missing_dates TEXT NOT NULL DEFAULT '[]'",
                    "is_complete INTEGER NOT NULL DEFAULT 1", "updated_at INTEGER NOT NULL DEFAULT 0"
                ]
                for definition in trackingColumns { try addColumnIfMissing(table: "openrouter_weekly", definition: definition) }
                try createCanonicalSchema()
                try execute("INSERT OR IGNORE INTO statistics_state(id,last_statistics_at,dirty_from_date,updated_at) VALUES(1,0,NULL,CAST(strftime('%s','now') AS INTEGER));")
                try execute("UPDATE openrouter_weekly SET revenue=CASE WHEN prompt_tokens>=0 AND completion_tokens>=0 AND prompt_price IS NOT NULL AND completion_price IS NOT NULL THEN prompt_tokens*prompt_price+completion_tokens*completion_price ELSE NULL END WHERE revenue IS NULL;")
                try execute("UPDATE openrouter_weekly SET updated_at=CAST(strftime('%s','now') AS INTEGER) WHERE updated_at=0;")
                try execute("PRAGMA user_version=7;")
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
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
            sqlite3_bind_int64(statement, 4, epochSeconds(device.updatedAt))
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
            sqlite3_bind_int64(statement, 4, epochSeconds(updatedAt))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            if sqlite3_changes(database) > 0 { try markStatisticsDirtyUnlocked(utcDate: utcDate, at: updatedAt) }
        }
    }

    /// Merges two histories for the same physical device. Bitmap minutes are
    /// monotonic within a UTC day, so union is safer than last-writer-wins when
    /// a reinstall has already recorded new minutes before its first sync.
    public func mergeBitmap(deviceID: String, utcDate: String, bitmap: MinuteBitmap, updatedAt: Date) throws {
        try queue.sync {
            var merged = try bitmapUnlocked(deviceID: deviceID, utcDate: utcDate)
            merged.formUnion(bitmap)
            let timestampSQL = "SELECT updated_at FROM bitmap WHERE device_id=? AND utc_date=?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, timestampSQL, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement); bind(utcDate, at: 2, to: statement)
            let existingUpdatedAt: Date
            if sqlite3_step(statement) == SQLITE_ROW {
                existingUpdatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            } else {
                existingUpdatedAt = .distantPast
            }
            try upsertUnlocked(
                deviceID: deviceID,
                utcDate: utcDate,
                bitmap: merged,
                updatedAt: max(existingUpdatedAt, updatedAt)
            )
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
        var existing = try dailyStatisticsReport(start: start, end: end, timeZoneID: timeZoneID)
        if existing.isEmpty {
            _ = try refreshStatistics(localDeviceID: localDeviceID, localDeviceName: localDeviceName, localDeviceKind: localDeviceKind, dailyLimitMinutes: 600, timeZoneID: timeZoneID, includeSyncedDevices: includeSyncedDevices)
            existing = try dailyStatisticsReport(start: start, end: end, timeZoneID: timeZoneID)
        }
        return existing
    }

    private func dailyStatisticsReport(start: Date, end: Date, timeZoneID: String) throws -> [DailyUsagePoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let lower = formatter.string(from: min(start, end)), upper = formatter.string(from: max(start, end))
        return try queue.sync {
            let names = try deviceNamesUnlocked()
            let sql = "SELECT device_id,report_date,minutes,estimated FROM daily_statistics WHERE report_date>=? AND report_date<=? ORDER BY report_date,device_id"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(lower, at: 1, to: statement); bind(upper, at: 2, to: statement)
            var result: [DailyUsagePoint] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let idText = sqlite3_column_text(statement, 0), let dateText = sqlite3_column_text(statement, 1) {
                let id = String(cString: idText), label = String(cString: dateText)
                guard let day = formatter.date(from: label) else { continue }
                let representative = calendar.date(byAdding: .hour, value: 12, to: day) ?? day
                result.append(DailyUsagePoint(date: representative, dateLabel: label, deviceID: id,
                    displayName: id == "alldevices" ? "All devices" : (names[id] ?? "Other device"),
                    minutes: Int(sqlite3_column_int(statement, 2)), isAggregate: id == "alldevices",
                    estimated: sqlite3_column_int(statement, 3) != 0))
            }
            return result
        }
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
                bind(deviceID, at: 1, to: statement); bind(key, at: 2, to: statement); sqlite3_bind_int64(statement, 3, epochSeconds(at))
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

    public func completeIncrementalSync(deviceID: String, at: Date = .now) throws {
        try queue.sync { try updateSyncStateFieldUnlocked(deviceID: deviceID, field: "last_incremental_sync_at", at: at) }
    }

    public func completeStatistics(deviceID: String, at: Date = .now) throws {
        try queue.sync { try updateSyncStateFieldUnlocked(deviceID: deviceID, field: "last_statistics_at", at: at) }
    }

    public func completeYearlyAction(deviceID: String, at: Date = .now) throws {
        try queue.sync { try updateSyncStateFieldUnlocked(deviceID: deviceID, field: "last_yearly_action_at", at: at) }
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
            sqlite3_bind_int64(statement, 3, epochSeconds(at))
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
            sqlite3_bind_int64(statement, 3, epochSeconds(at))
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
            let sql = "INSERT INTO maintenance_state(action,completed_at,updated_at) VALUES('openrouter_detail',?,?) ON CONFLICT(action) DO UPDATE SET completed_at=excluded.completed_at,updated_at=excluded.updated_at"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(weekEnd, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, epochSeconds(.now))
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
            guard sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO maintenance_state(action,completed_at,updated_at) VALUES('weekly',?,?)", -1, &initialize, nil) == SQLITE_OK else { throw error() }
            bind(mondayKey, at: 1, to: initialize); sqlite3_bind_int64(initialize, 2, epochSeconds(now)); guard sqlite3_step(initialize) == SQLITE_DONE else { sqlite3_finalize(initialize); throw error() }; sqlite3_finalize(initialize)

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

    public func weeklyCloudActionDue(now: Date = .now) throws -> Bool {
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = STGTime.utc
        let today = calendar.startOfDay(for: now), monday = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = STGTime.utc; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let mondayKey = formatter.string(from: monday)
        return try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT completed_at FROM maintenance_state WHERE action='weekly'", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            var completed = ""
            if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) { completed = String(cString: text) }
            return String(completed.prefix(10)) < mondayKey
        }
    }

    public func completeWeeklyAction(deviceID: String? = nil, at: Date = .now) throws {
        try queue.sync {
            let sql = "INSERT INTO maintenance_state(action,completed_at,updated_at) VALUES('weekly',?,?) ON CONFLICT(action) DO UPDATE SET completed_at=excluded.completed_at,updated_at=excluded.updated_at"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(ISO8601DateFormatter().string(from: at), at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, epochSeconds(at))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            if let deviceID { try updateSyncStateFieldUnlocked(deviceID: deviceID, field: "last_weekly_action_at", at: at) }
        }
    }

    public func upsertOpenRouterWeeks(_ rows: [OpenRouterWeeklyRankingRow]) throws {
        guard !rows.isEmpty else { return }
        try queue.sync {
            try execute("BEGIN IMMEDIATE;")
            do {
                let sql = "INSERT INTO openrouter_weekly(week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(week_start,model) DO UPDATE SET week_end=excluded.week_end,rank=excluded.rank,prompt_tokens=excluded.prompt_tokens,completion_tokens=excluded.completion_tokens,total_tokens=excluded.total_tokens,prompt_price=excluded.prompt_price,completion_price=excluded.completion_price,revenue=excluded.revenue,as_of=excluded.as_of,missing_dates=excluded.missing_dates,is_complete=excluded.is_complete,updated_at=excluded.updated_at"
                for row in rows {
                    var statement: OpaquePointer?
                    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
                    bind(row.weekStart, at: 1, to: statement); bind(row.weekEnd, at: 2, to: statement); bind(row.modelPermaslug, at: 3, to: statement)
                    sqlite3_bind_int(statement, 4, Int32(row.rank)); sqlite3_bind_int64(statement, 5, row.promptTokens); sqlite3_bind_int64(statement, 6, row.completionTokens); sqlite3_bind_int64(statement, 7, row.totalTokens)
                    if let value = row.promptPricePerToken { sqlite3_bind_double(statement, 8, value) } else { sqlite3_bind_null(statement, 8) }
                    if let value = row.completionPricePerToken { sqlite3_bind_double(statement, 9, value) } else { sqlite3_bind_null(statement, 9) }
                    if let value = row.revenueUSD { sqlite3_bind_double(statement, 10, value) } else { sqlite3_bind_null(statement, 10) }
                    if let value = row.asOf { bind(value, at: 11, to: statement) } else { sqlite3_bind_null(statement, 11) }
                    let missing = (try? String(data: JSONEncoder().encode(row.missingDates), encoding: .utf8)) ?? "[]"
                    bind(missing, at: 12, to: statement); sqlite3_bind_int(statement, 13, row.isComplete ? 1 : 0); sqlite3_bind_int64(statement, 14, epochSeconds(row.updatedAt))
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
            let sql = "SELECT week_start,week_end,rank,model,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete,updated_at FROM openrouter_weekly WHERE model IN (\(placeholders)) ORDER BY week_start,rank"
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
                    completionPricePerToken: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 8),
                    persistedRevenueUSD: sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 9),
                    asOf: sqlite3_column_text(statement, 10).map { String(cString: $0) },
                    missingDates: sqlite3_column_text(statement, 11).flatMap { try? JSONDecoder().decode([String].self, from: Data(String(cString: $0).utf8)) } ?? [],
                    isComplete: sqlite3_column_int(statement, 12) != 0,
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 13)))))
            }
            return result
        }
    }

    public func latestOpenRouterTopModels(metric: OpenRouterWeeklyMetric = .totalTokens, limit: Int = 10) throws -> [String] {
        try queue.sync {
            let order: String
            let requirement: String
            switch metric {
            case .rank: order = "rank ASC"; requirement = "1=1"
            case .promptTokens: order = "prompt_tokens DESC, rank ASC"; requirement = "prompt_tokens>=0"
            case .completionTokens: order = "completion_tokens DESC, rank ASC"; requirement = "completion_tokens>=0"
            case .totalTokens: order = "total_tokens DESC, rank ASC"; requirement = "total_tokens>=0"
            case .promptPrice: order = "prompt_price DESC, rank ASC"; requirement = "prompt_price IS NOT NULL"
            case .completionPrice: order = "completion_price DESC, rank ASC"; requirement = "completion_price IS NOT NULL"
            case .revenue:
                order = "(prompt_tokens*prompt_price+completion_tokens*completion_price) DESC, rank ASC"
                requirement = "prompt_tokens>=0 AND completion_tokens>=0 AND prompt_price IS NOT NULL AND completion_price IS NOT NULL"
            }
            let sql = "SELECT model FROM openrouter_weekly WHERE week_start=(SELECT MAX(week_start) FROM openrouter_weekly) AND \(requirement) ORDER BY \(order), model ASC LIMIT ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
            var result: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) { result.append(String(cString: text)) }
            return result
        }
    }

    /// Rebuilds every daily row touched since the previous statistics pass and
    /// then replaces only the intersecting ISO-week, month, and year rows.
    /// `dirty_from_date` is written by every bitmap mutation, including cloud
    /// imports, so late-arriving history cannot leave an old aggregate stale.
    @discardableResult
    public func refreshStatistics(localDeviceID: String, localDeviceName: String, localDeviceKind: DeviceKind,
                                  dailyLimitMinutes: Int, timeZoneID: String, now: Date = .now,
                                  includeSyncedDevices: Bool = true) throws -> ClosedRange<String> {
        try upsertDevice(DeviceRecord(deviceID: localDeviceID, name: localDeviceName, kind: localDeviceKind))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        let end = calendar.startOfDay(for: now)
        let state = try statisticsCursor()
        var candidates: [Date] = []
        if state.lastStatisticsAt > 0 {
            candidates.append(calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(state.lastStatisticsAt))))
        }
        if let dirty = state.dirtyFromDate, let utc = try? STGTime.utcDayStart(dirty),
           let conservative = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: utc)) {
            candidates.append(conservative)
        }
        if candidates.isEmpty, let earliest = try earliestBitmapUTCDate(), let utc = try? STGTime.utcDayStart(earliest),
           let conservative = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: utc)) {
            candidates.append(conservative)
        }
        var start = candidates.min() ?? end
        if start > end { start = end }

        let devices = try deviceRecords()
        var ids = includeSyncedDevices ? try deviceIDs() : [localDeviceID]
        if !ids.contains(localDeviceID) { ids.append(localDeviceID) }
        ids = Array(Set(ids)).sorted()
        let reportIDs = ["alldevices"] + ids
        let iosIDs = Set(devices.filter { $0.kind == .ios }.map(\.deviceID))
        let aggregateEstimated = !iosIDs.intersection(ids).isEmpty
        let formatter = Self.statisticsDateFormatter(timeZone: calendar.timeZone)
        var affectedWeeks: [String: DateInterval] = [:]
        var affectedMonths: [String: DateInterval] = [:]
        var affectedYears: [String: DateInterval] = [:]
        var day = start
        while day <= end {
            let representative = calendar.date(byAdding: .hour, value: 12, to: day) ?? day
            let label = formatter.string(from: representative)
            let utcKeys = STGTime.utcDateKeys(overlapping: STGTime.localDayInterval(containing: representative, timeZoneID: timeZoneID))
            if includeSyncedDevices { for key in utcKeys { _ = try rebuildAllDevices(utcDate: key) } }
            for id in reportIDs {
                let sourceID = id == "alldevices" && !includeSyncedDevices ? localDeviceID : id
                let minutes = try localDayMinutes(deviceID: sourceID, instant: representative, timeZoneID: timeZoneID)
                let estimated = id == "alldevices" ? aggregateEstimated : iosIDs.contains(id)
                let sourceUpdatedAt = try latestBitmapUpdatedAt(deviceID: sourceID, utcDateKeys: utcKeys)
                try upsertDailyStatistic(deviceID: id, reportDate: label, minutes: minutes,
                                         dailyLimitMinutes: dailyLimitMinutes, sourceUpdatedAt: sourceUpdatedAt,
                                         calculatedAt: now, estimated: estimated)
            }
            if let interval = calendar.dateInterval(of: .weekOfYear, for: representative) {
                let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: representative)
                affectedWeeks["\(components.yearForWeekOfYear ?? 0)-\(components.weekOfYear ?? 0)"] = interval
            }
            if let interval = calendar.dateInterval(of: .month, for: representative) {
                let components = calendar.dateComponents([.year, .month], from: representative)
                affectedMonths["\(components.year ?? 0)-\(components.month ?? 0)"] = interval
            }
            if let interval = calendar.dateInterval(of: .year, for: representative) {
                let year = calendar.component(.year, from: representative)
                affectedYears[String(year)] = interval
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        for interval in affectedWeeks.values {
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: interval.start)
            for id in reportIDs { try rebuildPeriodStatistic(table: "weekly_statistics", deviceID: id, interval: interval, calendar: calendar, now: now, primaryA: components.yearForWeekOfYear ?? 0, primaryB: components.weekOfYear) }
        }
        for interval in affectedMonths.values {
            let components = calendar.dateComponents([.year, .month], from: interval.start)
            for id in reportIDs { try rebuildPeriodStatistic(table: "monthly_statistics", deviceID: id, interval: interval, calendar: calendar, now: now, primaryA: components.year ?? 0, primaryB: components.month) }
        }
        for interval in affectedYears.values {
            let year = calendar.component(.year, from: interval.start)
            for id in reportIDs { try rebuildPeriodStatistic(table: "yearly_statistics", deviceID: id, interval: interval, calendar: calendar, now: now, primaryA: year, primaryB: nil) }
        }
        try finishStatisticsRefresh(deviceID: localDeviceID, at: now)
        return formatter.string(from: start)...formatter.string(from: end)
    }

    public func statisticsSummary(reference: Date = .now, timeZoneID: String, deviceID: String = "alldevices") throws -> UsageStatisticsSummary {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: reference)
        let priorWeekDate = calendar.date(byAdding: .weekOfYear, value: -1, to: reference) ?? reference
        let priorWeek = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: priorWeekDate)
        let month = calendar.dateComponents([.year, .month], from: reference)
        let priorMonthDate = calendar.date(byAdding: .month, value: -1, to: reference) ?? reference
        let priorMonth = calendar.dateComponents([.year, .month], from: priorMonthDate)
        let year = calendar.component(.year, from: reference)
        return UsageStatisticsSummary(
            thisWeekAverageMinutes: try periodAverage(table: "weekly_statistics", deviceID: deviceID, a: week.yearForWeekOfYear ?? 0, b: week.weekOfYear),
            lastWeekAverageMinutes: try periodAverage(table: "weekly_statistics", deviceID: deviceID, a: priorWeek.yearForWeekOfYear ?? 0, b: priorWeek.weekOfYear),
            thisMonthAverageMinutes: try periodAverage(table: "monthly_statistics", deviceID: deviceID, a: month.year ?? 0, b: month.month),
            lastMonthAverageMinutes: try periodAverage(table: "monthly_statistics", deviceID: deviceID, a: priorMonth.year ?? 0, b: priorMonth.month),
            thisYearAverageMinutes: try periodAverage(table: "yearly_statistics", deviceID: deviceID, a: year, b: nil),
            containsEstimatedIOSData: try aggregateContainsIOSData()
        )
    }

    public func periodUsage(kind: String, from start: String, through end: String) throws -> [PeriodUsagePoint] {
        let table: String
        switch kind { case "week": table = "weekly_statistics"; case "month": table = "monthly_statistics"; default: throw STGError.database("invalid statistics period") }
        return try queue.sync {
            let names = try deviceNamesUnlocked()
            let sql = "SELECT device_id,period_start,period_end,average_daily_minutes,included_days,excluded_days,estimated FROM \(table) WHERE period_end>=? AND period_start<=? ORDER BY period_start,device_id"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(start, at: 1, to: statement); bind(end, at: 2, to: statement)
            var result: [PeriodUsagePoint] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let idText = sqlite3_column_text(statement, 0), let startText = sqlite3_column_text(statement, 1), let endText = sqlite3_column_text(statement, 2) {
                let id = String(cString: idText), periodStart = String(cString: startText), periodEnd = String(cString: endText)
                result.append(PeriodUsagePoint(periodKind: kind, periodLabel: kind == "week" ? "\(periodStart) – \(periodEnd)" : String(periodStart.prefix(7)), periodStart: periodStart, periodEnd: periodEnd, deviceID: id, displayName: id == "alldevices" ? "All devices" : (names[id] ?? "Other device"), averageDailyMinutes: sqlite3_column_double(statement, 3), includedDays: Int(sqlite3_column_int(statement, 4)), excludedDays: Int(sqlite3_column_int(statement, 5)), estimated: sqlite3_column_int(statement, 6) != 0))
            }
            return result
        }
    }

    public func bitmapArchive(deviceID: String, kind: String, from start: String, through end: String, createdAt: Date = .now) throws -> BitmapArchiveDocument {
        let rows: [BitmapDocument] = try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT utc_date,bits,updated_at FROM bitmap WHERE device_id=? AND utc_date>=? AND utc_date<=? ORDER BY utc_date", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement); bind(start, at: 2, to: statement); bind(end, at: 3, to: statement)
            var result: [BitmapDocument] = []
            while sqlite3_step(statement) == SQLITE_ROW, let dateText = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) {
                let count = Int(sqlite3_column_bytes(statement, 1)); let data = Data(bytes: bytes, count: count)
                let bitmap = try MinuteBitmap(data: data)
                result.append(BitmapDocument(deviceID: deviceID, utcDate: String(cString: dateText), bitmap: bitmap, updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))))
            }
            return result
        }
        return BitmapArchiveDocument(kind: kind, deviceID: deviceID, periodStart: start, periodEnd: end, rows: rows, createdAt: createdAt)
    }

    public func deleteBitmapRows(deviceID: String, from start: String, through end: String) throws {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM bitmap WHERE device_id IN (?, 'alldevices') AND utc_date>=? AND utc_date<=?", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement); bind(start, at: 2, to: statement); bind(end, at: 3, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    public func openRouterArchive(from start: String, through end: String, createdAt: Date = .now) throws -> OpenRouterArchiveDocument {
        let rows: [OpenRouterWeeklyRankingRow] = try queue.sync {
            var statement: OpaquePointer?
            let sql = "SELECT week_start,week_end,rank,model,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete,updated_at FROM openrouter_weekly WHERE week_end>=? AND week_start<=? ORDER BY week_start,rank"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }; bind(start, at: 1, to: statement); bind(end, at: 2, to: statement)
            var result: [OpenRouterWeeklyRankingRow] = []
            while sqlite3_step(statement) == SQLITE_ROW, let weekStart = sqlite3_column_text(statement, 0), let weekEnd = sqlite3_column_text(statement, 1), let model = sqlite3_column_text(statement, 3) {
                result.append(OpenRouterWeeklyRankingRow(weekStart: String(cString: weekStart), weekEnd: String(cString: weekEnd), rank: Int(sqlite3_column_int(statement, 2)), modelPermaslug: String(cString: model), promptTokens: sqlite3_column_int64(statement, 4), completionTokens: sqlite3_column_int64(statement, 5), totalTokens: sqlite3_column_int64(statement, 6), promptPricePerToken: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 7), completionPricePerToken: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 8), persistedRevenueUSD: sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 9), asOf: sqlite3_column_text(statement, 10).map { String(cString: $0) }, missingDates: sqlite3_column_text(statement, 11).flatMap { try? JSONDecoder().decode([String].self, from: Data(String(cString: $0).utf8)) } ?? [], isComplete: sqlite3_column_int(statement, 12) != 0, updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 13)))))
            }
            return result
        }
        return OpenRouterArchiveDocument(periodStart: start, periodEnd: end, rows: rows, createdAt: createdAt)
    }

    public func deleteOpenRouterWeeks(through end: String) throws {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM openrouter_weekly WHERE week_end<=?", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }; bind(end, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    public func recordArchive(id: String, kind: String, from start: String, through end: String, localPath: String? = nil, cloudPath: String? = nil, checksum: String? = nil, uploadedAt: Date? = nil, status: String) throws {
        try queue.sync {
            var statement: OpaquePointer?
            let sql = "INSERT INTO archive_manifest(archive_id,kind,period_start,period_end,local_path,cloud_path,checksum,created_at,uploaded_at,status) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(archive_id) DO UPDATE SET local_path=excluded.local_path,cloud_path=excluded.cloud_path,checksum=excluded.checksum,uploaded_at=excluded.uploaded_at,status=excluded.status"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(id, at: 1, to: statement); bind(kind, at: 2, to: statement); bind(start, at: 3, to: statement); bind(end, at: 4, to: statement)
            if let localPath { bind(localPath, at: 5, to: statement) } else { sqlite3_bind_null(statement, 5) }
            if let cloudPath { bind(cloudPath, at: 6, to: statement) } else { sqlite3_bind_null(statement, 6) }
            if let checksum { bind(checksum, at: 7, to: statement) } else { sqlite3_bind_null(statement, 7) }
            sqlite3_bind_int64(statement, 8, epochSeconds(.now)); if let uploadedAt { sqlite3_bind_int64(statement, 9, epochSeconds(uploadedAt)) } else { sqlite3_bind_null(statement, 9) }; bind(status, at: 10, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    public func yearlyActionDue(now: Date = .now, deviceID: String) throws -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = STGTime.utc
        let startOfYear = calendar.dateInterval(of: .year, for: now)?.start ?? now
        return try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT last_yearly_action_at FROM sync_state WHERE device_id=?", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }; bind(deviceID, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return true }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)) < startOfYear
        }
    }

    public func exportDatabaseSnapshot(to destination: URL) throws {
        try queue.sync {
            try execute("PRAGMA wal_checkpoint(FULL);")
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
            try execute("VACUUM INTO '\(escaped)';")
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
            sqlite3_bind_int64(statement, 2, epochSeconds(state.lastEyeAt))
            sqlite3_bind_int64(statement, 3, epochSeconds(state.lastPostureAt))
            if let value = state.lastReminder, value == .eye || value == .posture {
                bind(value.rawValue, at: 4, to: statement)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_bind_int64(statement, 5, epochSeconds(updatedAt))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            try updateSyncStateFieldUnlocked(deviceID: deviceID, field: "last_eye_at", at: state.lastEyeAt)
            try updateSyncStateFieldUnlocked(deviceID: deviceID, field: "last_posture_at", at: state.lastPostureAt)
        }
    }

    public func updateRuntimeState(deviceID: String, continuousMinutes: Int, localDailyMinutes: Int, aggregateDailyMinutes: Int, localDate: String, at: Date = .now) throws {
        try queue.sync {
            let sql = "INSERT INTO sync_state(device_id,continuous_minutes,local_daily_minutes,aggregate_daily_minutes,state_local_date,bitmap_updated_at) VALUES(?,?,?,?,?,?) ON CONFLICT(device_id) DO UPDATE SET continuous_minutes=excluded.continuous_minutes,local_daily_minutes=excluded.local_daily_minutes,aggregate_daily_minutes=excluded.aggregate_daily_minutes,state_local_date=excluded.state_local_date,bitmap_updated_at=MAX(sync_state.bitmap_updated_at,excluded.bitmap_updated_at)"
            var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }; defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement); sqlite3_bind_int(statement, 2, Int32(max(0, continuousMinutes))); sqlite3_bind_int(statement, 3, Int32(max(0, localDailyMinutes))); sqlite3_bind_int(statement, 4, Int32(max(0, aggregateDailyMinutes))); bind(localDate, at: 5, to: statement); sqlite3_bind_int64(statement, 6, epochSeconds(at)); guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
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
        guard let document = try documentIfPresent(deviceID: deviceID, utcDate: utcDate) else {
            throw STGError.invalidDocument("No stored bitmap for \(deviceID) on \(utcDate)")
        }
        return document
    }

    /// Returns only a bitmap row that is actually stored locally. Sync must not
    /// turn a missing row into a new, empty cloud document after reinstall.
    public func documentIfPresent(deviceID: String, utcDate: String) throws -> BitmapDocument? {
        try queue.sync {
            let sql = "SELECT bits,updated_at FROM bitmap WHERE device_id=? AND utc_date=?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement); bind(utcDate, at: 2, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let bitmap = try MinuteBitmap(data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            return BitmapDocument(deviceID: deviceID, utcDate: utcDate, bitmap: bitmap, updatedAt: updatedAt)
        }
    }

    private func statisticsCursor() throws -> (lastStatisticsAt: Int64, dirtyFromDate: String?) {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT last_statistics_at,dirty_from_date FROM statistics_state WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return (0, nil) }
            let dirty = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            return (sqlite3_column_int64(statement, 0), dirty)
        }
    }

    private func earliestBitmapUTCDate() throws -> String? {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT MIN(utc_date) FROM bitmap WHERE device_id<>'alldevices'", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }

    private func latestBitmapUpdatedAt(deviceID: String, utcDateKeys: [String]) throws -> Date {
        guard !utcDateKeys.isEmpty else { return .distantPast }
        return try queue.sync {
            let placeholders = Array(repeating: "?", count: utcDateKeys.count).joined(separator: ",")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT MAX(updated_at) FROM bitmap WHERE device_id=? AND utc_date IN (\(placeholders))", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement)
            for (index, key) in utcDateKeys.enumerated() { bind(key, at: Int32(index + 2), to: statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return .distantPast }
            return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
        }
    }

    private func upsertDailyStatistic(deviceID: String, reportDate: String, minutes: Int, dailyLimitMinutes: Int,
                                      sourceUpdatedAt: Date, calculatedAt: Date, estimated: Bool) throws {
        try queue.sync {
            let sql = "INSERT INTO daily_statistics(device_id,report_date,minutes,daily_limit_minutes,source_updated_at,calculated_at,estimated) VALUES(?,?,?,?,?,?,?) ON CONFLICT(device_id,report_date) DO UPDATE SET minutes=excluded.minutes,daily_limit_minutes=excluded.daily_limit_minutes,source_updated_at=excluded.source_updated_at,calculated_at=excluded.calculated_at,estimated=excluded.estimated"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement); bind(reportDate, at: 2, to: statement)
            sqlite3_bind_int(statement, 3, Int32(minutes)); sqlite3_bind_int(statement, 4, Int32(max(1, dailyLimitMinutes)))
            sqlite3_bind_int64(statement, 5, epochSeconds(sourceUpdatedAt)); sqlite3_bind_int64(statement, 6, epochSeconds(calculatedAt)); sqlite3_bind_int(statement, 7, estimated ? 1 : 0)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    private func rebuildPeriodStatistic(table: String, deviceID: String, interval: DateInterval, calendar: Calendar,
                                        now: Date, primaryA: Int, primaryB: Int?) throws {
        let formatter = Self.statisticsDateFormatter(timeZone: calendar.timeZone)
        let start = formatter.string(from: interval.start)
        let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
        let end = formatter.string(from: inclusiveEnd)
        let values: [(minutes: Int, limit: Int, estimated: Bool)] = try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT minutes,daily_limit_minutes,estimated FROM daily_statistics WHERE device_id=? AND report_date>=? AND report_date<=? ORDER BY report_date", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement); bind(start, at: 2, to: statement); bind(end, at: 3, to: statement)
            var rows: [(Int, Int, Bool)] = []
            while sqlite3_step(statement) == SQLITE_ROW { rows.append((Int(sqlite3_column_int(statement, 0)), Int(sqlite3_column_int(statement, 1)), sqlite3_column_int(statement, 2) != 0)) }
            return rows
        }
        let included = values.filter { Double($0.minutes) >= Double($0.limit) * 0.60 }
        let average = included.isEmpty ? 0 : Double(included.reduce(0) { $0 + $1.minutes }) / Double(included.count)
        let estimated = values.contains(where: \.estimated)
        try queue.sync {
            let sql: String
            if table == "weekly_statistics" {
                sql = "INSERT INTO weekly_statistics(device_id,iso_year,iso_week,period_start,period_end,average_daily_minutes,included_days,excluded_days,calculated_at,estimated) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(device_id,iso_year,iso_week) DO UPDATE SET period_start=excluded.period_start,period_end=excluded.period_end,average_daily_minutes=excluded.average_daily_minutes,included_days=excluded.included_days,excluded_days=excluded.excluded_days,calculated_at=excluded.calculated_at,estimated=excluded.estimated"
            } else if table == "monthly_statistics" {
                sql = "INSERT INTO monthly_statistics(device_id,year,month,period_start,period_end,average_daily_minutes,included_days,excluded_days,calculated_at,estimated) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(device_id,year,month) DO UPDATE SET period_start=excluded.period_start,period_end=excluded.period_end,average_daily_minutes=excluded.average_daily_minutes,included_days=excluded.included_days,excluded_days=excluded.excluded_days,calculated_at=excluded.calculated_at,estimated=excluded.estimated"
            } else {
                sql = "INSERT INTO yearly_statistics(device_id,year,period_start,period_end,average_daily_minutes,included_days,excluded_days,calculated_at,estimated) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(device_id,year) DO UPDATE SET period_start=excluded.period_start,period_end=excluded.period_end,average_daily_minutes=excluded.average_daily_minutes,included_days=excluded.included_days,excluded_days=excluded.excluded_days,calculated_at=excluded.calculated_at,estimated=excluded.estimated"
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement); sqlite3_bind_int(statement, 2, Int32(primaryA))
            var index: Int32 = 3
            if let primaryB { sqlite3_bind_int(statement, index, Int32(primaryB)); index += 1 }
            bind(start, at: index, to: statement); bind(end, at: index + 1, to: statement)
            sqlite3_bind_double(statement, index + 2, average); sqlite3_bind_int(statement, index + 3, Int32(included.count)); sqlite3_bind_int(statement, index + 4, Int32(values.count - included.count)); sqlite3_bind_int64(statement, index + 5, epochSeconds(now)); sqlite3_bind_int(statement, index + 6, estimated ? 1 : 0)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    private func finishStatisticsRefresh(deviceID: String, at: Date) throws {
        try queue.sync {
            let seconds = epochSeconds(at)
            var state: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO statistics_state(id,last_statistics_at,dirty_from_date,updated_at) VALUES(1,?,NULL,?) ON CONFLICT(id) DO UPDATE SET last_statistics_at=excluded.last_statistics_at,dirty_from_date=NULL,updated_at=excluded.updated_at", -1, &state, nil) == SQLITE_OK else { throw error() }
            sqlite3_bind_int64(state, 1, seconds); sqlite3_bind_int64(state, 2, seconds)
            guard sqlite3_step(state) == SQLITE_DONE else { sqlite3_finalize(state); throw error() }
            sqlite3_finalize(state)
            try updateSyncStateFieldUnlocked(deviceID: deviceID, field: "last_statistics_at", at: at)
        }
    }

    private func periodAverage(table: String, deviceID: String, a: Int, b: Int?) throws -> Double? {
        try queue.sync {
            let columns: String
            if table == "weekly_statistics" { columns = "iso_year=? AND iso_week=?" }
            else if table == "monthly_statistics" { columns = "year=? AND month=?" }
            else if table == "yearly_statistics" { columns = "year=?" }
            else { throw STGError.database("invalid statistics table") }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT average_daily_minutes FROM \(table) WHERE device_id=? AND \(columns)", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement); sqlite3_bind_int(statement, 2, Int32(a)); if let b { sqlite3_bind_int(statement, 3, Int32(b)) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_double(statement, 0)
        }
    }

    private func aggregateContainsIOSData() throws -> Bool {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT EXISTS(SELECT 1 FROM device d JOIN bitmap b ON b.device_id=d.device_id WHERE d.kind='ios')", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) != 0
        }
    }

    private func deviceNamesUnlocked() throws -> [String: String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT device_id,name FROM device", -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW, let id = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) { result[String(cString: id)] = String(cString: name) }
        return result
    }

    private static func statisticsDateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; return formatter
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
        sqlite3_bind_int64(statement, 4, epochSeconds(updatedAt))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        try markStatisticsDirtyUnlocked(utcDate: utcDate, at: updatedAt)
        if deviceID != "alldevices" { try updateSyncStateFieldUnlocked(deviceID: deviceID, field: "bitmap_updated_at", at: updatedAt) }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func addColumnIfMissing(table: String, definition: String) throws {
        let column = definition.split(separator: " ", maxSplits: 1).first.map(String.init) ?? definition
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { throw error() }
        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 1) {
            if String(cString: text) == column { exists = true; break }
        }
        sqlite3_finalize(statement)
        if !exists { try execute("ALTER TABLE \(table) ADD COLUMN \(definition);") }
    }

    private func markStatisticsDirtyUnlocked(utcDate: String, at: Date) throws {
        let sql = """
        INSERT INTO statistics_state(id,last_statistics_at,dirty_from_date,updated_at) VALUES(1,0,?,?)
        ON CONFLICT(id) DO UPDATE SET
          dirty_from_date=CASE WHEN statistics_state.dirty_from_date IS NULL OR excluded.dirty_from_date<statistics_state.dirty_from_date THEN excluded.dirty_from_date ELSE statistics_state.dirty_from_date END,
          updated_at=excluded.updated_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        bind(utcDate, at: 1, to: statement); sqlite3_bind_int64(statement, 2, epochSeconds(at))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func updateSyncStateFieldUnlocked(deviceID: String, field: String, at: Date) throws {
        let allowed = ["last_incremental_sync_at", "last_statistics_at", "last_weekly_action_at", "last_yearly_action_at", "last_posture_at", "last_eye_at", "bitmap_updated_at"]
        guard allowed.contains(field) else { throw STGError.database("invalid sync state field") }
        let sql = "INSERT INTO sync_state(device_id,\(field)) VALUES(?,?) ON CONFLICT(device_id) DO UPDATE SET \(field)=excluded.\(field)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        bind(deviceID, at: 1, to: statement); sqlite3_bind_int64(statement, 2, epochSeconds(at))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
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
        sqlite3_bind_int64(statement, 2, uploadAt.map(epochSeconds) ?? 0)
        sqlite3_bind_int64(statement, 3, bidirectionalAt.map(epochSeconds) ?? 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func epochSeconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970) }

    private func error() -> STGError { STGError.database(String(cString: sqlite3_errmsg(database))) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
