using Microsoft.Win32;
using System.Net.Http;

namespace ScreenTimeGuardian;

internal static class GoogleOAuthProtocol
{
    private const string RegistryPath = @"Software\Classes\" + CloudConfiguration.GoogleCallbackScheme;

    public static void Register()
    {
        using var key = Registry.CurrentUser.CreateSubKey(RegistryPath);
        key.SetValue(null, "URL:Screen Time Guardian Google OAuth callback");
        key.SetValue("URL Protocol", "");
        using var command = key.CreateSubKey(@"shell\open\command");
        command.SetValue(null, $"\"{Environment.ProcessPath}\" \"%1\"");
    }

    public static void Unregister()
    {
        Registry.CurrentUser.DeleteSubKeyTree(RegistryPath, false);
    }

    public static async Task RelayAsync(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var callback) ||
            callback.Scheme != CloudConfiguration.GoogleCallbackScheme || callback.AbsolutePath != "/oauth2redirect") return;
        var state = callback.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(part => part.Split('=', 2)).FirstOrDefault(part => part[0] == "state")?.ElementAtOrDefault(1);
        state = Uri.UnescapeDataString(state ?? "");
        if (!int.TryParse(state.Split('.')[0], out var port) || port is < 1 or > 65535) return;
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        await http.GetAsync($"http://127.0.0.1:{port}/?callback={Uri.EscapeDataString(value)}");
    }
}
