namespace ScreenTimeGuardian;

internal static class TimeModel
{
    public static string UtcDate(DateTimeOffset instant) => instant.UtcDateTime.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
    public static int UtcMinute(DateTimeOffset instant) => instant.UtcDateTime.Hour * 60 + instant.UtcDateTime.Minute;
    public static int LocalClockMinute(DateTimeOffset instant, string timeZoneID)
    {
        var local = TimeZoneInfo.ConvertTime(instant, FindZone(timeZoneID));
        return local.Hour * 60 + local.Minute;
    }
    public static DateOnly LocalDate(DateTimeOffset instant, string timeZoneID) => DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(instant, FindZone(timeZoneID)).DateTime);
    public static IEnumerable<DateTimeOffset> LocalDayMinutes(DateTimeOffset instant, string timeZoneID)
    {
        var zone = FindZone(timeZoneID); var local = TimeZoneInfo.ConvertTime(instant, zone); var date = local.Date;
        var start = new DateTimeOffset(date, zone.GetUtcOffset(date)).ToUniversalTime();
        var nextDate = date.AddDays(1); var end = new DateTimeOffset(nextDate, zone.GetUtcOffset(nextDate)).ToUniversalTime();
        for (var cursor = start; cursor < end; cursor = cursor.AddMinutes(1)) yield return cursor;
    }
    public static DateTimeOffset LocalDateInstant(DateOnly date, string timeZoneID)
    {
        var zone = FindZone(timeZoneID); var localNoon = date.ToDateTime(new TimeOnly(12, 0), DateTimeKind.Unspecified);
        return new DateTimeOffset(localNoon, zone.GetUtcOffset(localNoon)).ToUniversalTime();
    }
    public static IReadOnlyList<string> IncrementalUploadUtcDates(string? cursor, DateTimeOffset now, int initialDays = 14)
    {
        var today = DateOnly.FromDateTime(now.UtcDateTime);
        DateOnly start;
        if (cursor is null || !DateOnly.TryParseExact(cursor, "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out start))
            start = today.AddDays(-(Math.Clamp(initialDays, 1, 14) - 1));
        if (start > today) start = today;
        var result = new List<string>();
        for (var date = start; date <= today; date = date.AddDays(1)) result.Add(date.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture));
        return result;
    }
    private static TimeZoneInfo FindZone(string id) { try { return TimeZoneInfo.FindSystemTimeZoneById(id); } catch { return TimeZoneInfo.Local; } }
}
