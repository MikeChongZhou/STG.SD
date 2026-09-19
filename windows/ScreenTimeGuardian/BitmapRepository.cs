using Microsoft.Data.Sqlite;

namespace ScreenTimeGuardian;

internal sealed record DeviceRecord(string DeviceID, string Name, string Kind, DateTimeOffset UpdatedAt);
internal sealed record ReminderStateRecord(DateTimeOffset LastEyeAt, DateTimeOffset LastPostureAt, string? LastReminder);

internal sealed partial class BitmapRepository : IDisposable
{
    private const int SchemaVersion = 7;
    private const string CanonicalSchemaSql = """
        CREATE TABLE IF NOT EXISTS bitmap(device_id TEXT NOT NULL,utc_date TEXT NOT NULL,bits BLOB NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(device_id,utc_date));
        CREATE TABLE IF NOT EXISTS device(device_id TEXT PRIMARY KEY,name TEXT NOT NULL,kind TEXT NOT NULL,updated_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS reminder_state(device_id TEXT PRIMARY KEY,last_eye_at INTEGER NOT NULL,last_posture_at INTEGER NOT NULL,last_reminder TEXT,updated_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_state(device_id TEXT PRIMARY KEY,last_quick_upload_at INTEGER NOT NULL DEFAULT 0,last_quick_bidirectional_at INTEGER NOT NULL DEFAULT 0,last_incremental_sync_at INTEGER NOT NULL DEFAULT 0,last_statistics_at INTEGER NOT NULL DEFAULT 0,last_weekly_action_at INTEGER NOT NULL DEFAULT 0,last_yearly_action_at INTEGER NOT NULL DEFAULT 0,last_posture_at INTEGER NOT NULL DEFAULT 0,last_eye_at INTEGER NOT NULL DEFAULT 0,bitmap_updated_at INTEGER NOT NULL DEFAULT 0,continuous_minutes INTEGER NOT NULL DEFAULT 0,local_daily_minutes INTEGER NOT NULL DEFAULT 0,aggregate_daily_minutes INTEGER NOT NULL DEFAULT 0,state_local_date TEXT);
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
        """;
    private readonly SqliteConnection connection;
    private readonly object gate = new();

    public BitmapRepository(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (!File.Exists(path)) OpenRouterTemplate.CopyDatabaseTo(path);
        connection = new($"Data Source={path}");
        connection.Open();
        Execute("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=3000;");
        CreateCanonicalSchema();
        MigrateToCanonicalSchemaIfNeeded();
        ImportBundledOpenRouterSeedIfNeeded();
    }

    private void ImportBundledOpenRouterSeedIfNeeded()
    {
        using (var marker = connection.CreateCommand())
        {
            marker.CommandText = "PRAGMA application_id";
            var markerMatches = Convert.ToInt32(marker.ExecuteScalar()) == OpenRouterTemplate.ApplicationId;
            using var metadata = connection.CreateCommand(); metadata.CommandText = "SELECT COUNT(*) FROM openrouter_weekly WHERE prompt_tokens<0 AND as_of IS NULL";
            if (markerMatches && Convert.ToInt64(metadata.ExecuteScalar()) == 0) return;
        }
        var templatePath = Path.Combine(Path.GetTempPath(), $"stg-template-{Guid.NewGuid():N}.sqlite");
        OpenRouterTemplate.CopyDatabaseTo(templatePath);
        try
        {
            using (var attach = connection.CreateCommand()) { attach.CommandText = "ATTACH DATABASE $path AS bundled_seed"; attach.Parameters.AddWithValue("$path", templatePath); attach.ExecuteNonQuery(); }
            using var transaction = connection.BeginTransaction();
            using (var copy = connection.CreateCommand()) { copy.Transaction = transaction; copy.CommandText = "INSERT OR IGNORE INTO openrouter_weekly(week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete,updated_at) SELECT week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete,updated_at FROM bundled_seed.openrouter_weekly; UPDATE openrouter_weekly SET as_of=(SELECT seed.as_of FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model),missing_dates=(SELECT seed.missing_dates FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model),is_complete=(SELECT seed.is_complete FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model),updated_at=MAX(updated_at,COALESCE((SELECT seed.updated_at FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model),0)) WHERE prompt_tokens<0 AND as_of IS NULL AND EXISTS(SELECT 1 FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model)"; copy.ExecuteNonQuery(); }
            transaction.Commit();
            Execute($"PRAGMA application_id={OpenRouterTemplate.ApplicationId}");
            using var detach = connection.CreateCommand(); detach.CommandText = "DETACH DATABASE bundled_seed"; detach.ExecuteNonQuery();
        }
        finally { try { File.Delete(templatePath); } catch { } }
    }

    private void CreateCanonicalSchema() => Execute(CanonicalSchemaSql);
    private void CreateCanonicalSchema(SqliteTransaction transaction) => Execute(CanonicalSchemaSql, transaction);

    private void MigrateToCanonicalSchemaIfNeeded()
    {
        using var versionCommand = connection.CreateCommand(); versionCommand.CommandText = "PRAGMA user_version";
        var version = Convert.ToInt32(versionCommand.ExecuteScalar());
        if (version >= SchemaVersion) return;
        if (version < 6)
        {
            using var legacy = connection.BeginTransaction();
            var tables = new[] { "bitmap", "device", "reminder_state", "sync_state", "pending_quick_upload", "incremental_download_cursor", "incremental_upload_cursor", "maintenance_state", "openrouter_weekly" };
            foreach (var table in tables) Execute($"ALTER TABLE {table} RENAME TO {table}_legacy", legacy);
            CreateCanonicalSchema(legacy);
            const string Seconds = "CASE WHEN ABS({0})>=100000000000 THEN CAST({0}/1000 AS INTEGER) ELSE CAST({0} AS INTEGER) END";
            Execute($"INSERT INTO bitmap SELECT device_id,utc_date,bits,{string.Format(Seconds, "updated_at")} FROM bitmap_legacy", legacy);
            Execute($"INSERT INTO device SELECT device_id,name,kind,{string.Format(Seconds, "updated_at")} FROM device_legacy", legacy);
            Execute($"INSERT INTO reminder_state SELECT device_id,{string.Format(Seconds, "last_eye_at")},{string.Format(Seconds, "last_posture_at")},last_reminder,{string.Format(Seconds, "updated_at")} FROM reminder_state_legacy", legacy);
            Execute($"INSERT INTO sync_state(device_id,last_quick_upload_at,last_quick_bidirectional_at) SELECT device_id,{string.Format(Seconds, "last_quick_upload_at")},{string.Format(Seconds, "last_quick_bidirectional_at")} FROM sync_state_legacy", legacy);
            Execute($"INSERT INTO pending_quick_upload SELECT device_id,utc_date,{string.Format(Seconds, "queued_at")} FROM pending_quick_upload_legacy", legacy);
            Execute($"INSERT INTO incremental_download_cursor SELECT remote_device_id,latest_utc_date,{string.Format(Seconds, "updated_at")} FROM incremental_download_cursor_legacy", legacy);
            Execute($"INSERT INTO incremental_upload_cursor SELECT sync_target,latest_utc_date,{string.Format(Seconds, "updated_at")} FROM incremental_upload_cursor_legacy", legacy);
            Execute("INSERT INTO maintenance_state SELECT action,completed_at,CAST(strftime('%s','now') AS INTEGER) FROM maintenance_state_legacy", legacy);
            Execute("INSERT OR REPLACE INTO openrouter_weekly(week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price) SELECT window_start,window_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price FROM openrouter_weekly_legacy", legacy);
            foreach (var table in tables) Execute($"DROP TABLE {table}_legacy", legacy);
            Execute("PRAGMA user_version=6", legacy);
            legacy.Commit();
        }
        using var transaction = connection.BeginTransaction();
        foreach (var definition in new[] { "last_incremental_sync_at INTEGER NOT NULL DEFAULT 0", "last_statistics_at INTEGER NOT NULL DEFAULT 0", "last_weekly_action_at INTEGER NOT NULL DEFAULT 0", "last_yearly_action_at INTEGER NOT NULL DEFAULT 0", "last_posture_at INTEGER NOT NULL DEFAULT 0", "last_eye_at INTEGER NOT NULL DEFAULT 0", "bitmap_updated_at INTEGER NOT NULL DEFAULT 0", "continuous_minutes INTEGER NOT NULL DEFAULT 0", "local_daily_minutes INTEGER NOT NULL DEFAULT 0", "aggregate_daily_minutes INTEGER NOT NULL DEFAULT 0", "state_local_date TEXT" }) AddColumnIfMissing("sync_state", definition, transaction);
        foreach (var definition in new[] { "revenue REAL", "as_of TEXT", "missing_dates TEXT NOT NULL DEFAULT '[]'", "is_complete INTEGER NOT NULL DEFAULT 1", "updated_at INTEGER NOT NULL DEFAULT 0" }) AddColumnIfMissing("openrouter_weekly", definition, transaction);
        CreateCanonicalSchema(transaction);
        Execute("INSERT OR IGNORE INTO statistics_state(id,last_statistics_at,dirty_from_date,updated_at) VALUES(1,0,NULL,CAST(strftime('%s','now') AS INTEGER))", transaction);
        Execute("UPDATE openrouter_weekly SET revenue=CASE WHEN prompt_tokens>=0 AND completion_tokens>=0 AND prompt_price IS NOT NULL AND completion_price IS NOT NULL THEN prompt_tokens*prompt_price+completion_tokens*completion_price ELSE NULL END WHERE revenue IS NULL", transaction);
        Execute("UPDATE openrouter_weekly SET updated_at=CAST(strftime('%s','now') AS INTEGER) WHERE updated_at=0", transaction);
        Execute($"PRAGMA user_version={SchemaVersion}", transaction);
        transaction.Commit();
    }

    public MinuteBitmap Bitmap(string deviceID, string utcDate)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT bits FROM bitmap WHERE device_id=$id AND utc_date=$date";
            command.Parameters.AddWithValue("$id", deviceID);
            command.Parameters.AddWithValue("$date", utcDate);
            var result = command.ExecuteScalar();
            return result is byte[] bytes ? new(bytes) : new();
        }
    }

    public (MinuteBitmap Bitmap, DateTimeOffset UpdatedAt)? StoredBitmap(string deviceID, string utcDate)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT bits,updated_at FROM bitmap WHERE device_id=$id AND utc_date=$date";
            command.Parameters.AddWithValue("$id", deviceID);
            command.Parameters.AddWithValue("$date", utcDate);
            using var reader = command.ExecuteReader();
            if (!reader.Read()) return null;
            return (new MinuteBitmap((byte[])reader[0]), DateTimeOffset.FromUnixTimeSeconds(reader.GetInt64(1)));
        }
    }

    public bool Mark(string deviceID, DateTimeOffset instant)
    {
        lock (gate)
        {
            var date = TimeModel.UtcDate(instant);
            var value = Bitmap(deviceID, date);
            var changed = value.Mark(TimeModel.UtcMinute(instant));
            if (changed) Upsert(deviceID, date, value, instant);
            return changed;
        }
    }

    public void Upsert(string deviceID, string date, MinuteBitmap bitmap, DateTimeOffset? updated = null)
    {
        lock (gate)
        {
            var modifiedAt = updated ?? DateTimeOffset.UtcNow;
            using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO bitmap(device_id,utc_date,bits,updated_at) VALUES($id,$date,$bits,$time) ON CONFLICT(device_id,utc_date) DO UPDATE SET bits=excluded.bits,updated_at=excluded.updated_at";
            command.Parameters.AddWithValue("$id", deviceID);
            command.Parameters.AddWithValue("$date", date);
            command.Parameters.AddWithValue("$bits", bitmap.Data);
            command.Parameters.AddWithValue("$time", modifiedAt.ToUnixTimeSeconds());
            command.ExecuteNonQuery();
            if (!string.Equals(deviceID, "alldevices", StringComparison.OrdinalIgnoreCase))
            {
                using var sync = connection.CreateCommand();
                sync.CommandText = "INSERT INTO sync_state(device_id,bitmap_updated_at) VALUES($id,$updated) ON CONFLICT(device_id) DO UPDATE SET bitmap_updated_at=MAX(sync_state.bitmap_updated_at,excluded.bitmap_updated_at)";
                sync.Parameters.AddWithValue("$id", deviceID);
                sync.Parameters.AddWithValue("$updated", modifiedAt.ToUnixTimeSeconds());
                sync.ExecuteNonQuery();
            }
            MarkStatisticsDirty(date, modifiedAt);
        }
    }

    public void UpsertIfNewer(string deviceID, string date, MinuteBitmap bitmap, DateTimeOffset updated)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO bitmap(device_id,utc_date,bits,updated_at) VALUES($id,$date,$bits,$time) ON CONFLICT(device_id,utc_date) DO UPDATE SET bits=excluded.bits,updated_at=excluded.updated_at WHERE excluded.updated_at>=bitmap.updated_at";
            command.Parameters.AddWithValue("$id", deviceID);
            command.Parameters.AddWithValue("$date", date);
            command.Parameters.AddWithValue("$bits", bitmap.Data);
            command.Parameters.AddWithValue("$time", updated.ToUnixTimeSeconds());
            if (command.ExecuteNonQuery() > 0)
            {
                if (!string.Equals(deviceID, "alldevices", StringComparison.OrdinalIgnoreCase))
                {
                    using var sync = connection.CreateCommand();
                    sync.CommandText = "INSERT INTO sync_state(device_id,bitmap_updated_at) VALUES($id,$updated) ON CONFLICT(device_id) DO UPDATE SET bitmap_updated_at=MAX(sync_state.bitmap_updated_at,excluded.bitmap_updated_at)";
                    sync.Parameters.AddWithValue("$id", deviceID);
                    sync.Parameters.AddWithValue("$updated", updated.ToUnixTimeSeconds());
                    sync.ExecuteNonQuery();
                }
                MarkStatisticsDirty(date, updated);
            }
        }
    }

    public void MergeBitmap(string deviceID, string date, MinuteBitmap bitmap, DateTimeOffset updated)
    {
        lock (gate)
        {
            var stored = StoredBitmap(deviceID, date);
            var merged = stored?.Bitmap ?? new MinuteBitmap();
            merged.Union(bitmap);
            var mergedUpdatedAt = stored is null || updated > stored.Value.UpdatedAt ? updated : stored.Value.UpdatedAt;
            Upsert(deviceID, date, merged, mergedUpdatedAt);
        }
    }

    public void UpsertDevice(DeviceRecord device)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO device(device_id,name,kind,updated_at) VALUES($id,$name,$kind,$time) ON CONFLICT(device_id) DO UPDATE SET name=excluded.name,kind=excluded.kind,updated_at=excluded.updated_at WHERE excluded.updated_at>=device.updated_at";
            command.Parameters.AddWithValue("$id", device.DeviceID);
            command.Parameters.AddWithValue("$name", device.Name);
            command.Parameters.AddWithValue("$kind", device.Kind);
            command.Parameters.AddWithValue("$time", device.UpdatedAt.ToUnixTimeSeconds());
            command.ExecuteNonQuery();
        }
    }

    public IReadOnlyDictionary<string, DeviceRecord> Devices()
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT device_id,name,kind,updated_at FROM device ORDER BY name COLLATE NOCASE,device_id";
            using var reader = command.ExecuteReader();
            var result = new Dictionary<string, DeviceRecord>(StringComparer.OrdinalIgnoreCase);
            while (reader.Read())
            {
                var record = new DeviceRecord(reader.GetString(0), reader.GetString(1), reader.GetString(2), DateTimeOffset.FromUnixTimeSeconds(reader.GetInt64(3)));
                result[record.DeviceID] = record;
            }
            return result;
        }
    }

    public IReadOnlyList<string> DeviceIDs()
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT DISTINCT device_id FROM bitmap WHERE device_id<>'alldevices' ORDER BY device_id";
            using var reader = command.ExecuteReader();
            var result = new List<string>();
            while (reader.Read()) result.Add(reader.GetString(0));
            return result;
        }
    }

    public MinuteBitmap RebuildAll(string date)
    {
        lock (gate)
        {
            var result = new MinuteBitmap();
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT bits FROM bitmap WHERE device_id<>'alldevices' AND utc_date=$date";
            command.Parameters.AddWithValue("$date", date);
            using var reader = command.ExecuteReader();
            while (reader.Read()) result.Union(new((byte[])reader[0]));
            reader.Close();
            Upsert("alldevices", date, result);
            return result;
        }
    }

    public bool[] LocalDayBitmap(string deviceID, DateTimeOffset instant, string zone) =>
        TimeModel.LocalDayMinutes(instant, zone)
            .Select(value => Bitmap(deviceID, TimeModel.UtcDate(value))[TimeModel.UtcMinute(value)])
            .ToArray();

    public bool[] LocalClockDayBitmap(string deviceID, DateTimeOffset instant, string zone)
    {
        var result = new bool[MinuteBitmap.MinuteCount];
        foreach (var value in TimeModel.LocalDayMinutes(instant, zone))
        {
            if (Bitmap(deviceID, TimeModel.UtcDate(value))[TimeModel.UtcMinute(value)])
                result[TimeModel.LocalClockMinute(value, zone)] = true;
        }
        return result;
    }

    public int LocalDayMinutes(string deviceID, DateTimeOffset instant, string zone) => LocalDayBitmap(deviceID, instant, zone).Count(value => value);

    public string? IncrementalDownloadCursor(string remoteDeviceID)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT latest_utc_date FROM incremental_download_cursor WHERE remote_device_id=$id";
            command.Parameters.AddWithValue("$id", remoteDeviceID);
            return command.ExecuteScalar() as string;
        }
    }

    public void SaveIncrementalDownloadCursor(string remoteDeviceID, string latestUtcDate)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO incremental_download_cursor(remote_device_id,latest_utc_date,updated_at) VALUES($id,$date,$time) ON CONFLICT(remote_device_id) DO UPDATE SET latest_utc_date=CASE WHEN excluded.latest_utc_date>incremental_download_cursor.latest_utc_date THEN excluded.latest_utc_date ELSE incremental_download_cursor.latest_utc_date END,updated_at=excluded.updated_at";
            command.Parameters.AddWithValue("$id", remoteDeviceID);
            command.Parameters.AddWithValue("$date", latestUtcDate);
            command.Parameters.AddWithValue("$time", DateTimeOffset.UtcNow.ToUnixTimeSeconds());
            command.ExecuteNonQuery();
        }
    }

    public IReadOnlyDictionary<string, string> IncrementalDownloadCursors()
    {
        lock (gate)
        {
            using var command = connection.CreateCommand(); command.CommandText = "SELECT remote_device_id,latest_utc_date FROM incremental_download_cursor ORDER BY remote_device_id";
            using var reader = command.ExecuteReader(); var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            while (reader.Read()) result[reader.GetString(0)] = reader.GetString(1);
            return result;
        }
    }

    public string? IncrementalUploadCursor(string syncTarget)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand(); command.CommandText = "SELECT latest_utc_date FROM incremental_upload_cursor WHERE sync_target=$target";
            command.Parameters.AddWithValue("$target", syncTarget); return command.ExecuteScalar() as string;
        }
    }

    public void SaveIncrementalUploadCursor(string syncTarget, string latestUtcDate)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO incremental_upload_cursor(sync_target,latest_utc_date,updated_at) VALUES($target,$date,$time) ON CONFLICT(sync_target) DO UPDATE SET latest_utc_date=CASE WHEN excluded.latest_utc_date>incremental_upload_cursor.latest_utc_date THEN excluded.latest_utc_date ELSE incremental_upload_cursor.latest_utc_date END,updated_at=excluded.updated_at";
            command.Parameters.AddWithValue("$target", syncTarget); command.Parameters.AddWithValue("$date", latestUtcDate); command.Parameters.AddWithValue("$time", DateTimeOffset.UtcNow.ToUnixTimeSeconds()); command.ExecuteNonQuery();
        }
    }

    public ReminderStateRecord LoadReminderState(string deviceID)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT last_eye_at,last_posture_at,last_reminder FROM reminder_state WHERE device_id=$id";
            command.Parameters.AddWithValue("$id", deviceID);
            using var reader = command.ExecuteReader();
            if (!reader.Read()) return new(DateTimeOffset.MinValue, DateTimeOffset.MinValue, null);
            var lastReminder = reader.IsDBNull(2) ? null : reader.GetString(2);
            if (lastReminder != "eye" && lastReminder != "posture") lastReminder = null;
            return new(
                reader.GetInt64(0) == 0 ? DateTimeOffset.MinValue : DateTimeOffset.FromUnixTimeSeconds(reader.GetInt64(0)),
                reader.GetInt64(1) == 0 ? DateTimeOffset.MinValue : DateTimeOffset.FromUnixTimeSeconds(reader.GetInt64(1)),
                lastReminder);
        }
    }

    public void SaveReminderState(string deviceID, ReminderStateRecord state, DateTimeOffset? updated = null)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO reminder_state(device_id,last_eye_at,last_posture_at,last_reminder,updated_at) VALUES($id,$eye,$posture,$reminder,$updated) ON CONFLICT(device_id) DO UPDATE SET last_eye_at=excluded.last_eye_at,last_posture_at=excluded.last_posture_at,last_reminder=excluded.last_reminder,updated_at=excluded.updated_at";
            command.Parameters.AddWithValue("$id", deviceID);
            command.Parameters.AddWithValue("$eye", state.LastEyeAt == DateTimeOffset.MinValue ? 0 : state.LastEyeAt.ToUnixTimeSeconds());
            command.Parameters.AddWithValue("$posture", state.LastPostureAt == DateTimeOffset.MinValue ? 0 : state.LastPostureAt.ToUnixTimeSeconds());
            command.Parameters.AddWithValue("$reminder", (object?)state.LastReminder ?? DBNull.Value);
            command.Parameters.AddWithValue("$updated", (updated ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds());
            command.ExecuteNonQuery();
            using var sync = connection.CreateCommand();
            sync.CommandText = "INSERT INTO sync_state(device_id,last_eye_at,last_posture_at) VALUES($id,$eye,$posture) ON CONFLICT(device_id) DO UPDATE SET last_eye_at=excluded.last_eye_at,last_posture_at=excluded.last_posture_at";
            sync.Parameters.AddWithValue("$id", deviceID); sync.Parameters.AddWithValue("$eye", state.LastEyeAt == DateTimeOffset.MinValue ? 0 : state.LastEyeAt.ToUnixTimeSeconds()); sync.Parameters.AddWithValue("$posture", state.LastPostureAt == DateTimeOffset.MinValue ? 0 : state.LastPostureAt.ToUnixTimeSeconds()); sync.ExecuteNonQuery();
        }
    }

    public void UpdateRuntimeState(string deviceID, int continuousMinutes, int localDailyMinutes, int aggregateDailyMinutes, DateOnly localDate, DateTimeOffset? updated = null)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO sync_state(device_id,continuous_minutes,local_daily_minutes,aggregate_daily_minutes,state_local_date,bitmap_updated_at) VALUES($id,$continuous,$local,$aggregate,$date,$updated) ON CONFLICT(device_id) DO UPDATE SET continuous_minutes=excluded.continuous_minutes,local_daily_minutes=excluded.local_daily_minutes,aggregate_daily_minutes=excluded.aggregate_daily_minutes,state_local_date=excluded.state_local_date,bitmap_updated_at=MAX(sync_state.bitmap_updated_at,excluded.bitmap_updated_at)";
            command.Parameters.AddWithValue("$id", deviceID); command.Parameters.AddWithValue("$continuous", Math.Max(0, continuousMinutes)); command.Parameters.AddWithValue("$local", Math.Max(0, localDailyMinutes)); command.Parameters.AddWithValue("$aggregate", Math.Max(0, aggregateDailyMinutes)); command.Parameters.AddWithValue("$date", localDate.ToString("yyyy-MM-dd")); command.Parameters.AddWithValue("$updated", (updated ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds()); command.ExecuteNonQuery();
        }
    }

    public string? LatestOpenRouterWeekEnd()
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT MAX(week_end) FROM openrouter_weekly";
            return command.ExecuteScalar() as string;
        }
    }

    public string? LatestOpenRouterDetailWeekEnd()
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT completed_at FROM maintenance_state WHERE action='openrouter_detail'";
            return command.ExecuteScalar() as string;
        }
    }

    public void CompleteOpenRouterDetailWeek(string weekEnd)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO maintenance_state(action,completed_at,updated_at) VALUES('openrouter_detail',$completed,$updated) ON CONFLICT(action) DO UPDATE SET completed_at=excluded.completed_at,updated_at=excluded.updated_at";
            command.Parameters.AddWithValue("$completed", weekEnd); command.Parameters.AddWithValue("$updated", DateTimeOffset.UtcNow.ToUnixTimeSeconds()); command.ExecuteNonQuery();
        }
    }

    public bool WeeklyActionDue(DateTimeOffset now)
    {
        var today = DateOnly.FromDateTime(now.UtcDateTime);
        var monday = today.AddDays(-(((int)today.DayOfWeek + 6) % 7));
        lock (gate)
        {
            using (var initialize = connection.CreateCommand())
            {
                initialize.CommandText = "INSERT OR IGNORE INTO maintenance_state(action,completed_at,updated_at) VALUES('weekly',$monday,$updated)";
                initialize.Parameters.AddWithValue("$monday", monday.ToString("yyyy-MM-dd")); initialize.Parameters.AddWithValue("$updated", DateTimeOffset.UtcNow.ToUnixTimeSeconds()); initialize.ExecuteNonQuery();
            }
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT completed_at FROM maintenance_state WHERE action='weekly'";
            var completed = command.ExecuteScalar() as string;
            var parsed = DateTimeOffset.TryParse(completed, out var completedAt)
                ? DateOnly.FromDateTime(completedAt.UtcDateTime)
                : DateOnly.TryParse(completed, out var completedDay) ? completedDay : DateOnly.MinValue;
            using var detail = connection.CreateCommand();
            detail.CommandText = "SELECT completed_at FROM maintenance_state WHERE action='openrouter_detail'";
            var detailedThrough = detail.ExecuteScalar() as string;
            var previousSunday = monday.AddDays(-1);
            var detailedDate = DateOnly.TryParse(detailedThrough, out var detailDate) ? detailDate : DateOnly.MinValue;
            return parsed < monday || detailedDate < previousSunday;
        }
    }

    public bool WeeklyCloudActionDue(DateTimeOffset now)
    {
        var today = DateOnly.FromDateTime(now.UtcDateTime);
        var monday = today.AddDays(-(((int)today.DayOfWeek + 6) % 7));
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT completed_at FROM maintenance_state WHERE action='weekly'";
            var completed = command.ExecuteScalar() as string;
            var parsed = DateTimeOffset.TryParse(completed, out var completedAt)
                ? DateOnly.FromDateTime(completedAt.UtcDateTime)
                : DateOnly.TryParse(completed, out var completedDay) ? completedDay : DateOnly.MinValue;
            return parsed < monday;
        }
    }

    public void CompleteWeeklyAction(DateTimeOffset now)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO maintenance_state(action,completed_at,updated_at) VALUES('weekly',$completed,$updated) ON CONFLICT(action) DO UPDATE SET completed_at=excluded.completed_at,updated_at=excluded.updated_at";
            command.Parameters.AddWithValue("$completed", now.UtcDateTime.ToString("O")); command.Parameters.AddWithValue("$updated", now.ToUnixTimeSeconds()); command.ExecuteNonQuery();
        }
    }

    public void UpsertOpenRouterWeeks(IEnumerable<WeeklyRankingRow> rows)
    {
        lock (gate)
        {
            using var transaction = connection.BeginTransaction();
            foreach (var row in rows)
            {
                using var command = connection.CreateCommand(); command.Transaction = transaction;
                command.CommandText = "INSERT INTO openrouter_weekly(week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete,updated_at) VALUES($start,$end,$model,$rank,$prompt,$completion,$total,$promptPrice,$completionPrice,$revenue,$asOf,$missing,$complete,$updated) ON CONFLICT(week_start,model) DO UPDATE SET week_end=excluded.week_end,rank=excluded.rank,prompt_tokens=excluded.prompt_tokens,completion_tokens=excluded.completion_tokens,total_tokens=excluded.total_tokens,prompt_price=excluded.prompt_price,completion_price=excluded.completion_price,revenue=excluded.revenue,as_of=excluded.as_of,missing_dates=excluded.missing_dates,is_complete=excluded.is_complete,updated_at=excluded.updated_at";
                command.Parameters.AddWithValue("$start", row.WindowStart.ToString("yyyy-MM-dd")); command.Parameters.AddWithValue("$end", row.WindowEnd.ToString("yyyy-MM-dd")); command.Parameters.AddWithValue("$model", row.Model); command.Parameters.AddWithValue("$rank", row.Rank); command.Parameters.AddWithValue("$prompt", row.PromptTokens); command.Parameters.AddWithValue("$completion", row.CompletionTokens); command.Parameters.AddWithValue("$total", row.TotalTokens); command.Parameters.AddWithValue("$promptPrice", (object?)row.PromptPricePerToken ?? DBNull.Value); command.Parameters.AddWithValue("$completionPrice", (object?)row.CompletionPricePerToken ?? DBNull.Value); command.Parameters.AddWithValue("$revenue", (object?)row.RevenueUSD ?? DBNull.Value); command.Parameters.AddWithValue("$asOf", row.AsOf is null ? DBNull.Value : row.AsOf.Value.UtcDateTime.ToString("O")); command.Parameters.AddWithValue("$missing", System.Text.Json.JsonSerializer.Serialize(row.MissingDates ?? [])); command.Parameters.AddWithValue("$complete", row.IsComplete ? 1 : 0); command.Parameters.AddWithValue("$updated", DateTimeOffset.UtcNow.ToUnixTimeSeconds()); command.ExecuteNonQuery();
            }
            transaction.Commit();
        }
    }

    public IReadOnlyList<WeeklyRankingRow> OpenRouterWeeks(IEnumerable<string> models)
    {
        var selected = models.ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (selected.Count == 0) return [];
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT week_start,week_end,rank,model,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,as_of,missing_dates,is_complete FROM openrouter_weekly ORDER BY week_start,rank";
            using var reader = command.ExecuteReader(); var result = new List<WeeklyRankingRow>();
            while (reader.Read())
            {
                var model = reader.GetString(3); if (!selected.Contains(model)) continue;
                var missing = reader.IsDBNull(10) ? [] : System.Text.Json.JsonSerializer.Deserialize<List<string>>(reader.GetString(10)) ?? [];
                result.Add(new WeeklyRankingRow(DateOnly.Parse(reader.GetString(0)), DateOnly.Parse(reader.GetString(1)), reader.GetInt32(2), model, reader.GetInt64(4), reader.GetInt64(5), reader.GetInt64(6), reader.IsDBNull(7) ? null : reader.GetDouble(7), reader.IsDBNull(8) ? null : reader.GetDouble(8), reader.IsDBNull(9) ? null : DateTimeOffset.Parse(reader.GetString(9)), missing, reader.GetInt32(11) != 0));
            }
            return result;
        }
    }

    public IReadOnlyList<string> LatestOpenRouterTopModels(WeeklyMetric metric, int limit = 10)
    {
        lock (gate)
        {
            var (requirement, order) = metric switch
            {
                WeeklyMetric.Rank => ("1=1", "rank ASC"),
                WeeklyMetric.InputTokens => ("prompt_tokens>=0", "prompt_tokens DESC, rank ASC"),
                WeeklyMetric.OutputTokens => ("completion_tokens>=0", "completion_tokens DESC, rank ASC"),
                WeeklyMetric.TotalTokens => ("total_tokens>=0", "total_tokens DESC, rank ASC"),
                WeeklyMetric.InputPrice => ("prompt_price IS NOT NULL", "prompt_price DESC, rank ASC"),
                WeeklyMetric.OutputPrice => ("completion_price IS NOT NULL", "completion_price DESC, rank ASC"),
                WeeklyMetric.Revenue => ("prompt_tokens>=0 AND completion_tokens>=0 AND prompt_price IS NOT NULL AND completion_price IS NOT NULL", "(prompt_tokens*prompt_price+completion_tokens*completion_price) DESC, rank ASC"),
                _ => ("total_tokens>=0", "total_tokens DESC, rank ASC")
            };
            using var command = connection.CreateCommand();
            command.CommandText = $"SELECT model FROM openrouter_weekly WHERE week_start=(SELECT MAX(week_start) FROM openrouter_weekly) AND {requirement} ORDER BY {order}, model ASC LIMIT $limit";
            command.Parameters.AddWithValue("$limit", Math.Max(1, limit));
            using var reader = command.ExecuteReader(); var result = new List<string>();
            while (reader.Read()) result.Add(reader.GetString(0));
            return result;
        }
    }

    private void Execute(string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private void Execute(string sql, SqliteTransaction transaction)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private void AddColumnIfMissing(string table, string definition, SqliteTransaction transaction)
    {
        var column = definition.Split(' ', 2)[0];
        using var query = connection.CreateCommand(); query.Transaction = transaction; query.CommandText = $"PRAGMA table_info({table})";
        using var reader = query.ExecuteReader(); var exists = false;
        while (reader.Read()) if (reader.GetString(1).Equals(column, StringComparison.Ordinal)) { exists = true; break; }
        reader.Close();
        if (!exists) Execute($"ALTER TABLE {table} ADD COLUMN {definition}", transaction);
    }

    private void MarkStatisticsDirty(string utcDate, DateTimeOffset at)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "INSERT INTO statistics_state(id,last_statistics_at,dirty_from_date,updated_at) VALUES(1,0,$date,$time) ON CONFLICT(id) DO UPDATE SET dirty_from_date=CASE WHEN statistics_state.dirty_from_date IS NULL OR excluded.dirty_from_date<statistics_state.dirty_from_date THEN excluded.dirty_from_date ELSE statistics_state.dirty_from_date END,updated_at=excluded.updated_at";
        command.Parameters.AddWithValue("$date", utcDate); command.Parameters.AddWithValue("$time", at.ToUnixTimeSeconds()); command.ExecuteNonQuery();
    }

    public void Dispose() => connection.Dispose();
}
