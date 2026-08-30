using Microsoft.Win32;

namespace ScreenTimeGuardian;

internal sealed record MeetingDetectionResult(bool IsMeeting, IReadOnlyList<string> Reasons, IReadOnlySet<string> ActiveApplications);

internal static class MeetingDetector
{
    private static readonly IReadOnlyDictionary<string, string> KnownClients = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["teams"] = "Microsoft Teams",
        ["msteams"] = "Microsoft Teams",
        ["feishu"] = "Feishu",
        ["lark"] = "Lark",
        ["wemeet"] = "Tencent Meeting",
        ["zoom"] = "Zoom",
        ["dingtalk"] = "DingTalk",
        ["chrome"] = "Google Chrome web meeting",
        ["msedge"] = "Microsoft Edge web meeting"
    };

    public static MeetingDetectionResult Check()
    {
        var microphone = CapabilityUsers("microphone");
        var camera = CapabilityUsers("webcam");
        var active = microphone.Union(camera, StringComparer.OrdinalIgnoreCase).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var reasons = new List<string>();
        foreach (var application in active.Order(StringComparer.OrdinalIgnoreCase))
        {
            var match = KnownClients.FirstOrDefault(value => application.Contains(value.Key, StringComparison.OrdinalIgnoreCase));
            var display = string.IsNullOrWhiteSpace(match.Value) ? FriendlyName(application) : match.Value;
            var hardware = microphone.Contains(application) && camera.Contains(application) ? "microphone and camera" : microphone.Contains(application) ? "microphone" : "camera";
            reasons.Add($"{display} is using the {hardware}");
        }
        return new(active.Count > 0, reasons, active);
    }

    private static HashSet<string> CapabilityUsers(string capability)
    {
        var active = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var rootPath = $@"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\{capability}";
        try
        {
            using var root = Registry.CurrentUser.OpenSubKey(rootPath);
            if (root is null) return active;
            foreach (var subkeyName in root.GetSubKeyNames())
            {
                if (subkeyName.Equals("NonPackaged", StringComparison.OrdinalIgnoreCase))
                {
                    using var nonPackaged = root.OpenSubKey(subkeyName);
                    if (nonPackaged is null) continue;
                    foreach (var encodedPath in nonPackaged.GetSubKeyNames())
                    {
                        using var application = nonPackaged.OpenSubKey(encodedPath);
                        if (IsActive(application)) active.Add(FriendlyName(encodedPath));
                    }
                }
                else
                {
                    using var application = root.OpenSubKey(subkeyName);
                    if (IsActive(application)) active.Add(subkeyName.ToLowerInvariant());
                }
            }
        }
        catch { }
        return active;
    }

    private static bool IsActive(RegistryKey? key)
    {
        if (key?.GetValue("LastUsedTimeStop") is not object value) return false;
        try { return Convert.ToInt64(value) == 0; } catch { return false; }
    }

    private static string FriendlyName(string raw)
    {
        var name = raw.Split('#', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? raw;
        return string.IsNullOrWhiteSpace(name) ? "Unknown application" : name.ToLowerInvariant();
    }
}
