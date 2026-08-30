using Microsoft.Win32;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ScreenTimeGuardian;

internal sealed class AppSettings
{
    [JsonPropertyName("device_id")] public string DeviceID { get; set; } = DeviceIdentity.Get();
    [JsonPropertyName("device_name")] public string DeviceName { get; set; } = Environment.MachineName;
    [JsonPropertyName("device_kind")] public string DeviceKind { get; set; } = "windows";
    [JsonPropertyName("daily_plan_minutes")] public int DailyPlanMinutes { get; set; } = 600;
    [JsonPropertyName("report_time_zone")] public string ReportTimeZone { get; set; } = TimeZoneInfo.Local.Id;
    [JsonPropertyName("eye_close_countdown_minutes")] public int EyeCountdown { get; set; } = 1;
    [JsonPropertyName("posture_close_countdown_minutes")] public int PostureCountdown { get; set; } = 2;
    [JsonPropertyName("daily_close_countdown_minutes")] public int DailyCountdown { get; set; } = 3;
    [JsonPropertyName("launch_at_login")] public bool LaunchAtLogin { get; set; } = true;
    [JsonPropertyName("meeting_mode")] public bool MeetingMode { get; set; }
    [JsonIgnore] public SyncProvider SyncProvider { get; set; } = SyncProvider.None;
    [JsonPropertyName("updated_at")] public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
    [JsonPropertyName("reserved")] public Dictionary<string, string> Reserved { get; set; } = [];
}

internal sealed class SettingsStore
{
    private readonly string path; private readonly string localPath;
    public SettingsStore(string folder) { path = Path.Combine(folder, "settings.json"); localPath = Path.Combine(folder, "local-settings.json"); }
    public AppSettings Load() { AppSettings value; try { value = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), JsonOptions.Default) ?? new(); } catch { value = new(); } try { value.SyncProvider = JsonSerializer.Deserialize<LocalSettings>(File.ReadAllText(localPath), JsonOptions.Default)?.SyncProvider ?? SyncProvider.None; } catch { } return value; }
    public void Save(AppSettings value) { Directory.CreateDirectory(Path.GetDirectoryName(path)!); value.UpdatedAt = DateTimeOffset.UtcNow; File.WriteAllText(path, JsonSerializer.Serialize(value, JsonOptions.Default)); File.WriteAllText(localPath, JsonSerializer.Serialize(new LocalSettings(value.SyncProvider), JsonOptions.Default)); }
    private sealed record LocalSettings(SyncProvider SyncProvider);
}

[JsonConverter(typeof(JsonStringEnumConverter))]
internal enum SyncProvider { None, ICloudDrive, OneDrive, GoogleDrive }

internal static class DeviceIdentity
{
    public static string Get()
    {
        try { using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography"); return Convert.ToString(key?.GetValue("MachineGuid"))?.ToLowerInvariant() ?? Guid.NewGuid().ToString(); }
        catch { return Guid.NewGuid().ToString(); }
    }
}

internal static class JsonOptions
{
    public static readonly JsonSerializerOptions Default = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower, WriteIndented = true };
}
