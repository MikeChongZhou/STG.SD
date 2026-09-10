using System.Globalization;
using System.Security.Cryptography;

namespace ScreenTimeGuardian;

internal sealed partial class BitmapRepository
{
    public void ExportDatabaseSnapshot(string destination)
    {
        lock (gate) { using var target = new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={destination}"); target.Open(); connection.BackupDatabase(target); }
    }
    public IReadOnlyList<BitmapDocument> BitmapArchive(string deviceID, DateOnly start, DateOnly end)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT utc_date,bits,updated_at FROM bitmap WHERE device_id=$id AND utc_date>=$start AND utc_date<=$end ORDER BY utc_date";
            command.Parameters.AddWithValue("$id", deviceID); command.Parameters.AddWithValue("$start", $"{start:yyyy-MM-dd}"); command.Parameters.AddWithValue("$end", $"{end:yyyy-MM-dd}");
            using var reader = command.ExecuteReader(); var rows = new List<BitmapDocument>();
            while (reader.Read()) rows.Add(new BitmapDocument(deviceID, reader.GetString(0), new MinuteBitmap((byte[])reader[1]).ToBase64(), DateTimeOffset.FromUnixTimeSeconds(reader.GetInt64(2)), []));
            return rows;
        }
    }

    public int DeleteBitmapRows(string deviceID, DateOnly start, DateOnly end)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand(); command.CommandText = "DELETE FROM bitmap WHERE device_id IN ($id,'alldevices') AND utc_date>=$start AND utc_date<=$end";
            command.Parameters.AddWithValue("$id", deviceID); command.Parameters.AddWithValue("$start", $"{start:yyyy-MM-dd}"); command.Parameters.AddWithValue("$end", $"{end:yyyy-MM-dd}"); return command.ExecuteNonQuery();
        }
    }

    public IReadOnlyList<WeeklyRankingRow> OpenRouterArchive(int year)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand(); command.CommandText = "SELECT week_start,week_end,rank,model,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,as_of,missing_dates,is_complete FROM openrouter_weekly WHERE week_start>=$start AND week_start<=$end ORDER BY week_start,rank";
            command.Parameters.AddWithValue("$start", $"{year:0000}-01-01"); command.Parameters.AddWithValue("$end", $"{year:0000}-12-31"); using var reader = command.ExecuteReader(); var rows = new List<WeeklyRankingRow>();
            while (reader.Read())
            {
                var missing = reader.IsDBNull(10) ? [] : System.Text.Json.JsonSerializer.Deserialize<List<string>>(reader.GetString(10)) ?? [];
                rows.Add(new(DateOnly.Parse(reader.GetString(0), CultureInfo.InvariantCulture), DateOnly.Parse(reader.GetString(1), CultureInfo.InvariantCulture), reader.GetInt32(2), reader.GetString(3), reader.GetInt64(4), reader.GetInt64(5), reader.GetInt64(6), reader.IsDBNull(7) ? null : reader.GetDouble(7), reader.IsDBNull(8) ? null : reader.GetDouble(8), reader.IsDBNull(9) ? null : DateTimeOffset.Parse(reader.GetString(9), CultureInfo.InvariantCulture), missing, reader.GetInt32(11) != 0));
            }
            return rows;
        }
    }

    public int DeleteOpenRouterWeeks(int throughYear)
    {
        lock (gate) { using var command = connection.CreateCommand(); command.CommandText = "DELETE FROM openrouter_weekly WHERE week_start<=$end"; command.Parameters.AddWithValue("$end", $"{throughYear:0000}-12-31"); return command.ExecuteNonQuery(); }
    }

    public bool YearlyActionDue(string deviceID, DateTimeOffset? value = null)
    {
        var currentYear = (value ?? DateTimeOffset.UtcNow).UtcDateTime.Year; lock (gate)
        {
            using var command = connection.CreateCommand(); command.CommandText = "SELECT last_yearly_action_at FROM sync_state WHERE device_id=$id"; command.Parameters.AddWithValue("$id", deviceID); var raw = command.ExecuteScalar();
            if (raw is null || raw is DBNull || Convert.ToInt64(raw) == 0) return true;
            return DateTimeOffset.FromUnixTimeSeconds(Convert.ToInt64(raw)).UtcDateTime.Year < currentYear;
        }
    }

    public void RecordArchive(string id, string kind, DateOnly start, DateOnly end, string? localPath, string? cloudPath, string? checksum, DateTimeOffset? uploadedAt, string status)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand(); command.CommandText = "INSERT INTO archive_manifest(archive_id,kind,period_start,period_end,local_path,cloud_path,checksum,created_at,uploaded_at,status) VALUES($id,$kind,$start,$end,$local,$cloud,$checksum,$created,$uploaded,$status) ON CONFLICT(archive_id) DO UPDATE SET local_path=excluded.local_path,cloud_path=excluded.cloud_path,checksum=excluded.checksum,uploaded_at=excluded.uploaded_at,status=excluded.status";
            command.Parameters.AddWithValue("$id", id); command.Parameters.AddWithValue("$kind", kind); command.Parameters.AddWithValue("$start", $"{start:yyyy-MM-dd}"); command.Parameters.AddWithValue("$end", $"{end:yyyy-MM-dd}"); command.Parameters.AddWithValue("$local", (object?)localPath ?? DBNull.Value); command.Parameters.AddWithValue("$cloud", (object?)cloudPath ?? DBNull.Value); command.Parameters.AddWithValue("$checksum", (object?)checksum ?? DBNull.Value); command.Parameters.AddWithValue("$created", DateTimeOffset.UtcNow.ToUnixTimeSeconds()); command.Parameters.AddWithValue("$uploaded", uploadedAt is null ? DBNull.Value : uploadedAt.Value.ToUnixTimeSeconds()); command.Parameters.AddWithValue("$status", status); command.ExecuteNonQuery();
        }
    }
}
