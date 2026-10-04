using System.Globalization;

namespace ScreenTimeGuardian;

internal sealed record UsageStatisticsSummary(double? ThisWeekAverageMinutes, double? LastWeekAverageMinutes,
    double? ThisMonthAverageMinutes, double? LastMonthAverageMinutes, double? ThisYearAverageMinutes,
    bool ContainsEstimatedIosData);

internal sealed record PeriodUsagePoint(string PeriodKind, string PeriodLabel, DateOnly PeriodStart, DateOnly PeriodEnd,
    string DeviceID, string DisplayName, double AverageDailyMinutes, int IncludedDays, int ExcludedDays, bool Estimated);

internal sealed record StatisticsDailyPoint(DateOnly Date, string DeviceID, string DisplayName, int Minutes, bool IsAggregate, bool Estimated);

internal sealed partial class BitmapRepository
{
    public void CompleteIncrementalSync(string deviceID, DateTimeOffset? at = null) => UpdateSyncTime(deviceID, "last_incremental_sync_at", at ?? DateTimeOffset.UtcNow);

    public DateTimeOffset? LastIncrementalSync(string deviceID)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand(); command.CommandText = "SELECT last_incremental_sync_at FROM sync_state WHERE device_id=$id";
            command.Parameters.AddWithValue("$id", deviceID);
            var value = command.ExecuteScalar();
            return value is long seconds && seconds > 0 ? DateTimeOffset.FromUnixTimeSeconds(seconds) : null;
        }
    }
    public void CompleteQuickUpload(string deviceID, DateTimeOffset? at = null) => UpdateSyncTime(deviceID, "last_quick_upload_at", at ?? DateTimeOffset.UtcNow);
    public void CompleteYearlyAction(string deviceID, DateTimeOffset? at = null) => UpdateSyncTime(deviceID, "last_yearly_action_at", at ?? DateTimeOffset.UtcNow);

    public void CompleteWeeklyActionState(string deviceID, DateTimeOffset? at = null) => UpdateSyncTime(deviceID, "last_weekly_action_at", at ?? DateTimeOffset.UtcNow);

    private void UpdateSyncTime(string deviceID, string field, DateTimeOffset at)
    {
        if (field is not ("last_incremental_sync_at" or "last_quick_upload_at" or "last_weekly_action_at" or "last_yearly_action_at")) throw new ArgumentException("Unsupported sync-state field", nameof(field));
        lock (gate)
        {
            using var command = connection.CreateCommand(); command.CommandText = $"INSERT INTO sync_state(device_id,{field}) VALUES($id,$time) ON CONFLICT(device_id) DO UPDATE SET {field}=excluded.{field}";
            command.Parameters.AddWithValue("$id", deviceID); command.Parameters.AddWithValue("$time", at.ToUnixTimeSeconds()); command.ExecuteNonQuery();
        }
    }
    public (DateOnly Start, DateOnly End) RefreshStatistics(AppSettings settings, DateTimeOffset? value = null, bool includeSyncedDevices = true)
    {
        lock (gate)
        {
            var now = value ?? DateTimeOffset.Now;
            var end = TimeModel.LocalDate(now, settings.ReportTimeZone);
            MigratePeriodAverages(end);
            long last = 0; string? dirty = null;
            using (var state = connection.CreateCommand())
            {
                state.CommandText = "SELECT last_statistics_at,dirty_from_date FROM statistics_state WHERE id=1";
                using var reader = state.ExecuteReader(); if (reader.Read()) { last = reader.GetInt64(0); dirty = reader.IsDBNull(1) ? null : reader.GetString(1); }
            }
            var candidates = new List<DateOnly>();
            if (last > 0) candidates.Add(TimeModel.LocalDate(DateTimeOffset.FromUnixTimeSeconds(last), settings.ReportTimeZone));
            if (DateOnly.TryParseExact(dirty, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var dirtyDate)) candidates.Add(dirtyDate.AddDays(-1));
            if (candidates.Count == 0)
            {
                using var earliest = connection.CreateCommand(); earliest.CommandText = "SELECT MIN(utc_date) FROM bitmap WHERE device_id<>'alldevices'";
                if (earliest.ExecuteScalar() is string text && DateOnly.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)) candidates.Add(date.AddDays(-1));
            }
            var start = candidates.Count == 0 ? end : candidates.Min(); if (start > end) start = end;
            UpsertDevice(new(settings.DeviceID, settings.DeviceName, settings.DeviceKind, settings.UpdatedAt));
            var devices = Devices(); var ids = includeSyncedDevices ? DeviceIDs().ToList() : [settings.DeviceID];
            if (!ids.Contains(settings.DeviceID, StringComparer.OrdinalIgnoreCase)) ids.Add(settings.DeviceID);
            ids = ids.Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase).ToList();
            var reportIDs = new[] { "alldevices" }.Concat(ids).ToArray();
            var iosIDs = devices.Values.Where(item => item.Kind.Equals("ios", StringComparison.OrdinalIgnoreCase)).Select(item => item.DeviceID).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var aggregateEstimated = ids.Any(iosIDs.Contains);
            var weeks = new HashSet<(int Year, int Week)>(); var months = new HashSet<(int Year, int Month)>(); var years = new HashSet<int>();
            for (var date = start; date <= end; date = date.AddDays(1))
            {
                var instant = TimeModel.LocalDateInstant(date, settings.ReportTimeZone);
                var utcDates = TimeModel.LocalDayMinutes(instant, settings.ReportTimeZone).Select(TimeModel.UtcDate).Distinct().ToArray();
                if (includeSyncedDevices) foreach (var key in utcDates) RebuildAll(key);
                foreach (var id in reportIDs)
                {
                    var source = id == "alldevices" && !includeSyncedDevices ? settings.DeviceID : id;
                    var minutes = LocalDayMinutes(source, instant, settings.ReportTimeZone);
                    var sourceUpdated = LatestBitmapUpdatedAt(source, utcDates);
                    UpsertDailyStatistic(id, date, minutes, Math.Max(1, settings.DailyPlanMinutes), sourceUpdated, now,
                        id == "alldevices" ? aggregateEstimated : iosIDs.Contains(id));
                }
                var dt = date.ToDateTime(TimeOnly.MinValue); weeks.Add((ISOWeek.GetYear(dt), ISOWeek.GetWeekOfYear(dt))); months.Add((date.Year, date.Month)); years.Add(date.Year);
            }
            foreach (var period in weeks)
            {
                var monday = DateOnly.FromDateTime(ISOWeek.ToDateTime(period.Year, period.Week, DayOfWeek.Monday));
                foreach (var id in reportIDs) RebuildPeriod("weekly_statistics", id, monday, monday.AddDays(6), period.Year, period.Week, now, end);
            }
            foreach (var period in months)
            {
                var first = new DateOnly(period.Year, period.Month, 1); var lastDay = first.AddMonths(1).AddDays(-1);
                foreach (var id in reportIDs) RebuildPeriod("monthly_statistics", id, first, lastDay, period.Year, period.Month, now, end);
            }
            foreach (var year in years)
            {
                foreach (var id in reportIDs) RebuildPeriod("yearly_statistics", id, new DateOnly(year, 1, 1), new DateOnly(year, 12, 31), year, null, now, end);
            }
            using (var transaction = connection.BeginTransaction())
            {
                Execute($"INSERT INTO statistics_state(id,last_statistics_at,dirty_from_date,updated_at) VALUES(1,{now.ToUnixTimeSeconds()},NULL,{now.ToUnixTimeSeconds()}) ON CONFLICT(id) DO UPDATE SET last_statistics_at=excluded.last_statistics_at,dirty_from_date=NULL,updated_at=excluded.updated_at", transaction);
                Execute($"INSERT INTO sync_state(device_id,last_statistics_at) VALUES('{Sql(settings.DeviceID)}',{now.ToUnixTimeSeconds()}) ON CONFLICT(device_id) DO UPDATE SET last_statistics_at=excluded.last_statistics_at", transaction);
                transaction.Commit();
            }
            return (start, end);
        }
    }

    public UsageStatisticsSummary StatisticsSummary(DateTimeOffset reference, string zone, string deviceID = "alldevices")
    {
        var local = TimeModel.LocalDate(reference, zone); var dt = local.ToDateTime(TimeOnly.MinValue); var previousWeek = local.AddDays(-7); var previousMonth = local.AddMonths(-1);
        return new(
            PeriodAverage("weekly_statistics", deviceID, ISOWeek.GetYear(dt), ISOWeek.GetWeekOfYear(dt)),
            PeriodAverage("weekly_statistics", deviceID, ISOWeek.GetYear(previousWeek.ToDateTime(TimeOnly.MinValue)), ISOWeek.GetWeekOfYear(previousWeek.ToDateTime(TimeOnly.MinValue))),
            PeriodAverage("monthly_statistics", deviceID, local.Year, local.Month),
            PeriodAverage("monthly_statistics", deviceID, previousMonth.Year, previousMonth.Month),
            PeriodAverage("yearly_statistics", deviceID, local.Year, null),
            Devices().Values.Any(item => item.Kind.Equals("ios", StringComparison.OrdinalIgnoreCase)));
    }

    public IReadOnlyList<PeriodUsagePoint> PeriodUsage(string kind, DateOnly start, DateOnly end)
    {
        var table = kind switch { "week" => "weekly_statistics", "month" => "monthly_statistics", _ => throw new ArgumentException("Unsupported statistics period", nameof(kind)) };
        lock (gate)
        {
            var names = Devices(); using var command = connection.CreateCommand();
            command.CommandText = $"SELECT device_id,period_start,period_end,average_daily_minutes,included_days,excluded_days,estimated FROM {table} WHERE period_end>=$start AND period_start<=$end ORDER BY period_start,device_id";
            command.Parameters.AddWithValue("$start", start.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)); command.Parameters.AddWithValue("$end", end.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
            using var reader = command.ExecuteReader(); var result = new List<PeriodUsagePoint>();
            while (reader.Read())
            {
                var id = reader.GetString(0); var from = DateOnly.ParseExact(reader.GetString(1), "yyyy-MM-dd", CultureInfo.InvariantCulture); var through = DateOnly.ParseExact(reader.GetString(2), "yyyy-MM-dd", CultureInfo.InvariantCulture);
                result.Add(new(kind, kind == "week" ? $"{from:yyyy-MM-dd} – {through:yyyy-MM-dd}" : $"{from:yyyy-MM}", from, through, id, id == "alldevices" ? "All devices" : names.GetValueOrDefault(id)?.Name ?? "Other device", reader.GetDouble(3), reader.GetInt32(4), reader.GetInt32(5), reader.GetInt32(6) != 0));
            }
            return result;
        }
    }

    public IReadOnlyList<StatisticsDailyPoint> DailyStatistics(DateOnly start, DateOnly end)
    {
        if (end < start) (start, end) = (end, start);
        lock (gate)
        {
            var names = Devices();
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT device_id,report_date,minutes,estimated FROM daily_statistics WHERE report_date>=$start AND report_date<=$end ORDER BY report_date,device_id";
            command.Parameters.AddWithValue("$start", start.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
            command.Parameters.AddWithValue("$end", end.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
            using var reader = command.ExecuteReader(); var result = new List<StatisticsDailyPoint>();
            while (reader.Read())
            {
                var id = reader.GetString(0); var date = DateOnly.ParseExact(reader.GetString(1), "yyyy-MM-dd", CultureInfo.InvariantCulture);
                result.Add(new(date, id, id == "alldevices" ? "All devices" : names.GetValueOrDefault(id)?.Name ?? "Other device", reader.GetInt32(2), id == "alldevices", reader.GetInt32(3) != 0));
            }
            return result;
        }
    }

    public bool ReportIncludesEstimatedIos(string deviceID = "alldevices")
    {
        var devices = Devices();
        return deviceID == "alldevices"
            ? devices.Values.Any(item => item.Kind.Equals("ios", StringComparison.OrdinalIgnoreCase))
            : devices.GetValueOrDefault(deviceID)?.Kind.Equals("ios", StringComparison.OrdinalIgnoreCase) == true;
    }

    private DateTimeOffset LatestBitmapUpdatedAt(string deviceID, IEnumerable<string> utcDates)
    {
        var latest = DateTimeOffset.MinValue;
        foreach (var date in utcDates) { var stored = StoredBitmap(deviceID, date); if (stored is not null && stored.Value.UpdatedAt > latest) latest = stored.Value.UpdatedAt; }
        return latest;
    }

    private void UpsertDailyStatistic(string deviceID, DateOnly date, int minutes, int limit, DateTimeOffset sourceUpdated, DateTimeOffset calculated, bool estimated)
    {
        using var command = connection.CreateCommand(); command.CommandText = "INSERT INTO daily_statistics(device_id,report_date,minutes,daily_limit_minutes,source_updated_at,calculated_at,estimated) VALUES($id,$date,$minutes,$limit,$source,$calculated,$estimated) ON CONFLICT(device_id,report_date) DO UPDATE SET minutes=excluded.minutes,daily_limit_minutes=excluded.daily_limit_minutes,source_updated_at=excluded.source_updated_at,calculated_at=excluded.calculated_at,estimated=excluded.estimated";
        command.Parameters.AddWithValue("$id", deviceID); command.Parameters.AddWithValue("$date", date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)); command.Parameters.AddWithValue("$minutes", minutes); command.Parameters.AddWithValue("$limit", limit); command.Parameters.AddWithValue("$source", sourceUpdated == DateTimeOffset.MinValue ? 0 : sourceUpdated.ToUnixTimeSeconds()); command.Parameters.AddWithValue("$calculated", calculated.ToUnixTimeSeconds()); command.Parameters.AddWithValue("$estimated", estimated ? 1 : 0); command.ExecuteNonQuery();
    }

    private void RebuildPeriod(string table, string deviceID, DateOnly start, DateOnly end, int a, int? b, DateTimeOffset now, DateOnly completedBefore)
    {
        using var query = connection.CreateCommand(); query.CommandText = "SELECT minutes,daily_limit_minutes,estimated FROM daily_statistics WHERE device_id=$id AND report_date>=$start AND report_date<=$end AND report_date<$today ORDER BY report_date"; query.Parameters.AddWithValue("$id", deviceID); query.Parameters.AddWithValue("$start", $"{start:yyyy-MM-dd}"); query.Parameters.AddWithValue("$end", $"{end:yyyy-MM-dd}");
        query.Parameters.AddWithValue("$today", completedBefore.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
        using var reader = query.ExecuteReader(); var rows = new List<(int Minutes, int Limit, bool Estimated)>(); while (reader.Read()) rows.Add((reader.GetInt32(0), reader.GetInt32(1), reader.GetInt32(2) != 0)); reader.Close();
        var included = rows.Where(row => deviceID != "alldevices" || row.Minutes >= row.Limit * .60).ToList(); var average = included.Count == 0 ? 0 : included.Average(row => row.Minutes); var estimated = rows.Any(row => row.Estimated);
        using var command = connection.CreateCommand();
        command.CommandText = table switch
        {
            "weekly_statistics" => "INSERT INTO weekly_statistics(device_id,iso_year,iso_week,period_start,period_end,average_daily_minutes,included_days,excluded_days,calculated_at,estimated) VALUES($id,$a,$b,$start,$end,$average,$included,$excluded,$time,$estimated) ON CONFLICT(device_id,iso_year,iso_week) DO UPDATE SET period_start=excluded.period_start,period_end=excluded.period_end,average_daily_minutes=excluded.average_daily_minutes,included_days=excluded.included_days,excluded_days=excluded.excluded_days,calculated_at=excluded.calculated_at,estimated=excluded.estimated",
            "monthly_statistics" => "INSERT INTO monthly_statistics(device_id,year,month,period_start,period_end,average_daily_minutes,included_days,excluded_days,calculated_at,estimated) VALUES($id,$a,$b,$start,$end,$average,$included,$excluded,$time,$estimated) ON CONFLICT(device_id,year,month) DO UPDATE SET period_start=excluded.period_start,period_end=excluded.period_end,average_daily_minutes=excluded.average_daily_minutes,included_days=excluded.included_days,excluded_days=excluded.excluded_days,calculated_at=excluded.calculated_at,estimated=excluded.estimated",
            _ => "INSERT INTO yearly_statistics(device_id,year,period_start,period_end,average_daily_minutes,included_days,excluded_days,calculated_at,estimated) VALUES($id,$a,$start,$end,$average,$included,$excluded,$time,$estimated) ON CONFLICT(device_id,year) DO UPDATE SET period_start=excluded.period_start,period_end=excluded.period_end,average_daily_minutes=excluded.average_daily_minutes,included_days=excluded.included_days,excluded_days=excluded.excluded_days,calculated_at=excluded.calculated_at,estimated=excluded.estimated"
        };
        command.Parameters.AddWithValue("$id", deviceID); command.Parameters.AddWithValue("$a", a); if (b is not null) command.Parameters.AddWithValue("$b", b.Value); command.Parameters.AddWithValue("$start", $"{start:yyyy-MM-dd}"); command.Parameters.AddWithValue("$end", $"{end:yyyy-MM-dd}"); command.Parameters.AddWithValue("$average", average); command.Parameters.AddWithValue("$included", included.Count); command.Parameters.AddWithValue("$excluded", rows.Count - included.Count); command.Parameters.AddWithValue("$time", now.ToUnixTimeSeconds()); command.Parameters.AddWithValue("$estimated", estimated ? 1 : 0); command.ExecuteNonQuery();
    }

    private void MigratePeriodAverages(DateOnly completedBefore)
    {
        using var create = connection.CreateCommand();
        create.CommandText = "CREATE TABLE IF NOT EXISTS statistics_rules(version INTEGER PRIMARY KEY)"; create.ExecuteNonQuery();
        using var check = connection.CreateCommand(); check.CommandText = "SELECT 1 FROM statistics_rules WHERE version=2";
        if (check.ExecuteScalar() is not null) return;
        using var transaction = connection.BeginTransaction();
        foreach (var table in new[] { "weekly_statistics", "monthly_statistics", "yearly_statistics" })
        {
            using var command = connection.CreateCommand(); command.Transaction = transaction;
            command.CommandText = $"""
                UPDATE {table} SET
                average_daily_minutes=COALESCE((SELECT AVG(minutes * 1.0) FROM daily_statistics d WHERE d.device_id={table}.device_id AND d.report_date>={table}.period_start AND d.report_date<={table}.period_end AND d.report_date<$today AND (d.device_id<>'alldevices' OR d.minutes>=d.daily_limit_minutes*0.60)),0),
                included_days=(SELECT COUNT(*) FROM daily_statistics d WHERE d.device_id={table}.device_id AND d.report_date>={table}.period_start AND d.report_date<={table}.period_end AND d.report_date<$today AND (d.device_id<>'alldevices' OR d.minutes>=d.daily_limit_minutes*0.60)),
                excluded_days=(SELECT COUNT(*) FROM daily_statistics d WHERE d.device_id={table}.device_id AND d.report_date>={table}.period_start AND d.report_date<={table}.period_end AND d.report_date<$today AND NOT ((d.device_id<>'alldevices' OR d.minutes>=d.daily_limit_minutes*0.60)))
                """;
            command.Parameters.AddWithValue("$today", completedBefore.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
            command.ExecuteNonQuery();
        }
        Execute("INSERT INTO statistics_rules(version) VALUES(2)", transaction);
        transaction.Commit();
    }

    private double? PeriodAverage(string table, string deviceID, int a, int? b)
    {
        lock (gate)
        {
            using var command = connection.CreateCommand(); command.CommandText = table switch { "weekly_statistics" => "SELECT average_daily_minutes FROM weekly_statistics WHERE included_days>0 AND device_id=$id AND iso_year=$a AND iso_week=$b", "monthly_statistics" => "SELECT average_daily_minutes FROM monthly_statistics WHERE included_days>0 AND device_id=$id AND year=$a AND month=$b", _ => "SELECT average_daily_minutes FROM yearly_statistics WHERE included_days>0 AND device_id=$id AND year=$a" };
            command.Parameters.AddWithValue("$id", deviceID); command.Parameters.AddWithValue("$a", a); if (b is not null) command.Parameters.AddWithValue("$b", b.Value); var value = command.ExecuteScalar(); return value is null || value is DBNull ? null : Convert.ToDouble(value, CultureInfo.InvariantCulture);
        }
    }

    private static string Sql(string value) => value.Replace("'", "''", StringComparison.Ordinal);
}
