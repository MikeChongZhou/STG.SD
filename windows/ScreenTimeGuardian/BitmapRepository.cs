using Microsoft.Data.Sqlite;

namespace ScreenTimeGuardian;

internal sealed record DeviceRecord(string DeviceID, string Name, string Kind, DateTimeOffset UpdatedAt);
internal sealed record ReminderStateRecord(DateTimeOffset LastEyeAt, DateTimeOffset LastPostureAt, string? LastReminder);

internal sealed class BitmapRepository : IDisposable
{
    private readonly SqliteConnection connection;
    private readonly object gate = new();

    public BitmapRepository(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        connection = new($"Data Source={path}");
        connection.Open();
        Execute("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=3000; CREATE TABLE IF NOT EXISTS bitmap(device_id TEXT NOT NULL,utc_date TEXT NOT NULL,bits BLOB NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(device_id,utc_date)); CREATE TABLE IF NOT EXISTS device(device_id TEXT PRIMARY KEY,name TEXT NOT NULL,kind TEXT NOT NULL,updated_at INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS reminder_state(device_id TEXT PRIMARY KEY,last_eye_at INTEGER NOT NULL,last_posture_at INTEGER NOT NULL,last_reminder TEXT,updated_at INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS incremental_download_cursor(remote_device_id TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS incremental_upload_cursor(sync_target TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS maintenance_state(action TEXT PRIMARY KEY,completed_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS openrouter_weekly(window_start TEXT NOT NULL,window_end TEXT NOT NULL,model TEXT NOT NULL,rank INTEGER NOT NULL,prompt_tokens INTEGER NOT NULL,completion_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,prompt_price REAL,completion_price REAL,as_of TEXT NOT NULL,PRIMARY KEY(window_start,window_end,model));");
        ImportBundledOpenRouterSeedIfNeeded();
    }

    private void ImportBundledOpenRouterSeedIfNeeded()
    {
        using (var marker = connection.CreateCommand())
        {
            marker.CommandText = "SELECT 1 FROM maintenance_state WHERE action=$action LIMIT 1";
            marker.Parameters.AddWithValue("$action", OpenRouterSeed.Marker);
            if (marker.ExecuteScalar() is not null) return;
        }
        var seed = OpenRouterSeed.Load();
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "INSERT OR IGNORE INTO openrouter_weekly(window_start,window_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,as_of) VALUES($start,$end,$model,$rank,-1,-1,$total,NULL,NULL,$asOf)";
        var start = command.Parameters.Add("$start", Microsoft.Data.Sqlite.SqliteType.Text);
        var end = command.Parameters.Add("$end", Microsoft.Data.Sqlite.SqliteType.Text);
        var model = command.Parameters.Add("$model", Microsoft.Data.Sqlite.SqliteType.Text);
        var rank = command.Parameters.Add("$rank", Microsoft.Data.Sqlite.SqliteType.Integer);
        var total = command.Parameters.Add("$total", Microsoft.Data.Sqlite.SqliteType.Integer);
        var asOf = command.Parameters.Add("$asOf", Microsoft.Data.Sqlite.SqliteType.Text);
        foreach (var row in seed.Rows)
        {
            start.Value = row.WindowStart; end.Value = row.WindowEnd; model.Value = row.Model;
            rank.Value = row.Rank; total.Value = row.TotalTokens; asOf.Value = seed.AsOf;
            command.ExecuteNonQuery();
        }
        using var saveMarker = connection.CreateCommand();
        saveMarker.Transaction = transaction;
        saveMarker.CommandText = "INSERT INTO maintenance_state(action,completed_at) VALUES($action,$asOf) ON CONFLICT(action) DO UPDATE SET completed_at=excluded.completed_at";
        saveMarker.Parameters.AddWithValue("$action", OpenRouterSeed.Marker);
        saveMarker.Parameters.AddWithValue("$asOf", seed.AsOf);
        saveMarker.ExecuteNonQuery();
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
            using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO bitmap(device_id,utc_date,bits,updated_at) VALUES($id,$date,$bits,$time) ON CONFLICT(device_id,utc_date) DO UPDATE SET bits=excluded.bits,updated_at=excluded.updated_at";
            command.Parameters.AddWithValue("$id", deviceID);
            command.Parameters.AddWithValue("$date", date);
            command.Parameters.AddWithValue("$bits", bitmap.Data);
            command.Parameters.AddWithValue("$time", (updated ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds());
            command.ExecuteNonQuery();
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
            command.Parameters.AddWithValue("$time", device.UpdatedAt.ToUnixTimeMilliseconds());
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
                var record = new DeviceRecord(reader.GetString(0), reader.GetString(1), reader.GetString(2), DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(3)));
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
            command.Parameters.AddWithValue("$time", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
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
            command.Parameters.AddWithValue("$target", syncTarget); command.Parameters.AddWithValue("$date", latestUtcDate); command.Parameters.AddWithValue("$time", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()); command.ExecuteNonQuery();
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
                DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(0)),
                DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(1)),
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
            command.Parameters.AddWithValue("$eye", state.LastEyeAt.ToUnixTimeMilliseconds());
            command.Parameters.AddWithValue("$posture", state.LastPostureAt.ToUnixTimeMilliseconds());
            command.Parameters.AddWithValue("$reminder", (object?)state.LastReminder ?? DBNull.Value);
            command.Parameters.AddWithValue("$updated", (updated ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds());
            command.ExecuteNonQuery();
        }
    }

    public string? LatestOpenRouterWeekEnd()
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT MAX(window_end) FROM openrouter_weekly";
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
            command.CommandText = "INSERT INTO maintenance_state(action,completed_at) VALUES('openrouter_detail',$completed) ON CONFLICT(action) DO UPDATE SET completed_at=excluded.completed_at";
            command.Parameters.AddWithValue("$completed", weekEnd); command.ExecuteNonQuery();
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
                initialize.CommandText = "INSERT OR IGNORE INTO maintenance_state(action,completed_at) VALUES('weekly',$monday)";
                initialize.Parameters.AddWithValue("$monday", monday.ToString("yyyy-MM-dd")); initialize.ExecuteNonQuery();
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

    public void CompleteWeeklyAction(DateTimeOffset now)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO maintenance_state(action,completed_at) VALUES('weekly',$completed) ON CONFLICT(action) DO UPDATE SET completed_at=excluded.completed_at";
            command.Parameters.AddWithValue("$completed", now.UtcDateTime.ToString("O")); command.ExecuteNonQuery();
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
                command.CommandText = "INSERT INTO openrouter_weekly(window_start,window_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,as_of) VALUES($start,$end,$model,$rank,$prompt,$completion,$total,$promptPrice,$completionPrice,$asOf) ON CONFLICT(window_start,window_end,model) DO UPDATE SET rank=excluded.rank,prompt_tokens=excluded.prompt_tokens,completion_tokens=excluded.completion_tokens,total_tokens=excluded.total_tokens,prompt_price=excluded.prompt_price,completion_price=excluded.completion_price,as_of=excluded.as_of";
                command.Parameters.AddWithValue("$start", row.WindowStart.ToString("yyyy-MM-dd")); command.Parameters.AddWithValue("$end", row.WindowEnd.ToString("yyyy-MM-dd")); command.Parameters.AddWithValue("$model", row.Model); command.Parameters.AddWithValue("$rank", row.Rank); command.Parameters.AddWithValue("$prompt", row.PromptTokens); command.Parameters.AddWithValue("$completion", row.CompletionTokens); command.Parameters.AddWithValue("$total", row.TotalTokens); command.Parameters.AddWithValue("$promptPrice", (object?)row.PromptPricePerToken ?? DBNull.Value); command.Parameters.AddWithValue("$completionPrice", (object?)row.CompletionPricePerToken ?? DBNull.Value); command.Parameters.AddWithValue("$asOf", DateTimeOffset.UtcNow.ToString("O")); command.ExecuteNonQuery();
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
            command.CommandText = "SELECT window_start,window_end,rank,model,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price FROM openrouter_weekly ORDER BY window_start,rank";
            using var reader = command.ExecuteReader(); var result = new List<WeeklyRankingRow>();
            while (reader.Read())
            {
                var model = reader.GetString(3); if (!selected.Contains(model)) continue;
                result.Add(new WeeklyRankingRow(DateOnly.Parse(reader.GetString(0)), DateOnly.Parse(reader.GetString(1)), reader.GetInt32(2), model, reader.GetInt64(4), reader.GetInt64(5), reader.GetInt64(6), reader.IsDBNull(7) ? null : reader.GetDouble(7), reader.IsDBNull(8) ? null : reader.GetDouble(8)));
            }
            return result;
        }
    }

    public IReadOnlyList<string> LatestOpenRouterTopModels(int limit = 10)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT model FROM openrouter_weekly WHERE window_start=(SELECT MAX(window_start) FROM openrouter_weekly) ORDER BY rank LIMIT $limit";
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

    public void Dispose() => connection.Dispose();
}
