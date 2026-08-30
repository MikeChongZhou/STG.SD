using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace ScreenTimeGuardian;

internal static class CloudConfiguration
{
    public const string MicrosoftClientID = "a4ff927c-e45a-413e-b5c3-45b026719171";
    public const string GoogleClientID = "552360735383-030pcr7mduhf1d20kjslobh5dhacsg2o.apps.googleusercontent.com";
    public static string GoogleClientSecret =>
        Environment.GetEnvironmentVariable("STG_GOOGLE_CLIENT_SECRET") ??
        System.Reflection.Assembly.GetExecutingAssembly()
            .GetCustomAttributes(typeof(System.Reflection.AssemblyMetadataAttribute), false)
            .OfType<System.Reflection.AssemblyMetadataAttribute>()
            .FirstOrDefault(value => value.Key == "STGGoogleClientSecret")?.Value ??
        string.Empty;
    public const string OneDriveCredential = "ScreenTimeGuardian.OneDrive";
    public const string GoogleDriveCredential = "ScreenTimeGuardian.GoogleDrive";
}

internal sealed record CloudSyncResult(int Uploaded, int Downloaded, IReadOnlySet<string> Devices, IReadOnlyDictionary<string, string> DownloadCursors, string? UploadCursor);
internal sealed record RemoteFile(string ID, string Name);
internal sealed record BitmapDocument(
    [property: JsonPropertyName("device_id")] string DeviceID,
    [property: JsonPropertyName("utc_date")] string UtcDate,
    [property: JsonPropertyName("bitmap_base64")] string BitmapBase64,
    [property: JsonPropertyName("updated_at")] DateTimeOffset UpdatedAt,
    [property: JsonPropertyName("reserved")] Dictionary<string, string> Reserved);

internal interface IPrivateCloudDrive
{
    Task<IReadOnlyList<RemoteFile>> ListAsync(CancellationToken token);
    Task UploadAsync(string name, byte[] data, string? existingID, CancellationToken token);
    Task<byte[]> DownloadAsync(string id, CancellationToken token);
}

internal sealed class PrivateCloudSync(BitmapRepository repository, AppSettings settings, IPrivateCloudDrive drive)
{
    public async Task<CloudSyncResult> IncrementalAsync(CancellationToken token = default)
    {
        var remoteFiles = await drive.ListAsync(token);
        var byName = remoteFiles.GroupBy(value => value.Name, StringComparer.Ordinal).ToDictionary(value => value.Key, value => value.First(), StringComparer.Ordinal);
        var devices = remoteFiles.Select(value => ParseDevice(value.Name)).Where(value => value is not null).Cast<string>().ToHashSet(StringComparer.OrdinalIgnoreCase);
        var downloaded = 0;

        foreach (var file in remoteFiles.Where(value => value.Name.EndsWith("_setting.json", StringComparison.Ordinal)))
        {
            try
            {
                var remoteID = ParseDevice(file.Name);
                var document = JsonSerializer.Deserialize<AppSettings>(await drive.DownloadAsync(file.ID, token), JsonOptions.Default);
                if (remoteID is null || remoteID.Equals(settings.DeviceID, StringComparison.OrdinalIgnoreCase) || document is null || !document.DeviceID.Equals(remoteID, StringComparison.OrdinalIgnoreCase)) continue;
                repository.UpsertDevice(new(document.DeviceID, document.DeviceName, document.DeviceKind, document.UpdatedAt));
            }
            catch { }
        }

        var downloadCursors = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var remoteID in devices.Where(value => !value.Equals(settings.DeviceID, StringComparison.OrdinalIgnoreCase) && !value.Equals("alldevices", StringComparison.OrdinalIgnoreCase)))
        {
            var cursor = repository.IncrementalDownloadCursor(remoteID);
            var candidates = remoteFiles
                .Select(file => (File: file, Device: ParseDevice(file.Name), Date: ParseBitmapDate(file.Name)))
                .Where(value => value.Device?.Equals(remoteID, StringComparison.OrdinalIgnoreCase) == true && value.Date is not null && (cursor is null || string.CompareOrdinal(value.Date, cursor) >= 0))
                .OrderBy(value => value.Date, StringComparer.Ordinal);
            foreach (var candidate in candidates)
            {
                try
                {
                    var document = JsonSerializer.Deserialize<BitmapDocument>(await drive.DownloadAsync(candidate.File.ID, token), JsonOptions.Default);
                    if (document is null || !document.DeviceID.Equals(remoteID, StringComparison.OrdinalIgnoreCase) || document.UtcDate != candidate.Date) throw new InvalidDataException("Remote bitmap identity mismatch");
                    repository.Upsert(remoteID, document.UtcDate, MinuteBitmap.FromBase64(document.BitmapBase64), document.UpdatedAt);
                    repository.RebuildAll(document.UtcDate); repository.SaveIncrementalDownloadCursor(remoteID, document.UtcDate);
                    downloadCursors[remoteID] = document.UtcDate; downloaded++;
                }
                catch { break; }
            }
        }

        repository.UpsertDevice(new(settings.DeviceID, settings.DeviceName, settings.DeviceKind, settings.UpdatedAt));
        var uploaded = 0; string? uploadCursor = null;
        var uploadTarget = settings.SyncProvider.ToString();
        foreach (var date in TimeModel.IncrementalUploadUtcDates(repository.IncrementalUploadCursor(uploadTarget), DateTimeOffset.UtcNow))
        {
            token.ThrowIfCancellationRequested();
            var document = new BitmapDocument(settings.DeviceID, date, repository.Bitmap(settings.DeviceID, date).ToBase64(), DateTimeOffset.UtcNow, []);
            var name = $"{settings.DeviceID}_bitmap_{date}.json";
            await drive.UploadAsync(name, JsonSerializer.SerializeToUtf8Bytes(document, JsonOptions.Default), byName.GetValueOrDefault(name)?.ID, token);
            repository.SaveIncrementalUploadCursor(uploadTarget, date); uploadCursor = date; uploaded++;
        }
        var settingsName = $"{settings.DeviceID}_setting.json";
        await drive.UploadAsync(settingsName, JsonSerializer.SerializeToUtf8Bytes(settings, JsonOptions.Default), byName.GetValueOrDefault(settingsName)?.ID, token);
        return new(uploaded, downloaded, devices, downloadCursors, uploadCursor);
    }

    private static string? ParseDevice(string name)
    {
        var marker = name.IndexOf("_bitmap_", StringComparison.Ordinal);
        if (marker > 0) return name[..marker];
        return name.EndsWith("_setting.json", StringComparison.Ordinal) ? name[..^"_setting.json".Length] : null;
    }

    private static string? ParseBitmapDate(string name)
    {
        var marker = name.IndexOf("_bitmap_", StringComparison.Ordinal);
        if (marker <= 0 || !name.EndsWith(".json", StringComparison.Ordinal)) return null;
        var date = name[(marker + "_bitmap_".Length)..^5];
        return DateOnly.TryParseExact(date, "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out _) ? date : null;
    }
}

/// Uses the iCloud Drive sync root managed by iCloud for Windows. Apple does
/// not provide a third-party Apple Account OAuth flow on Windows, so account
/// authentication remains in Apple's iCloud for Windows app.
internal sealed class ICloudDriveClient : IPrivateCloudDrive
{
    private const string ContainerName = "Screen Time Guardian";
    private readonly string syncFolder;

    private ICloudDriveClient(string syncFolder) => this.syncFolder = syncFolder;

    public static bool IsAvailable => LocateExistingSyncFolder() is not null;
    public static string AccountLabel => IsAvailable ? "Apple-created Screen Time Guardian App Library" : "Shared STG iCloud folder not found";

    public static ICloudDriveClient Connect()
    {
        var roots = LocateDriveRoots();
        if (roots.Count == 0)
        {
            try { Process.Start(new ProcessStartInfo("https://support.apple.com/guide/icloud-windows/set-up-icloud-drive-icw0144825a5/icloud") { UseShellExecute = true }); } catch { }
            throw new InvalidOperationException("Install iCloud for Windows, sign in to your Apple Account, and turn on iCloud Drive, then try again.");
        }
        var folder = LocateExistingSyncFolder(roots);
        if (folder is null)
            throw new InvalidOperationException("No Apple-created Screen Time Guardian sync folder was found. First configure iCloud in the iOS or Mac app and complete one sync, then try again on Windows.");
        return new(folder);
    }

    public Task<IReadOnlyList<RemoteFile>> ListAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        IReadOnlyList<RemoteFile> result = Directory.EnumerateFiles(syncFolder, "*.json", SearchOption.TopDirectoryOnly)
            .Select(path => new RemoteFile(path, Path.GetFileName(path))).ToList();
        return Task.FromResult(result);
    }

    public async Task UploadAsync(string name, byte[] data, string? existingID, CancellationToken token)
    {
        var destination = SafeFile(name);
        var temporary = Path.Combine(syncFolder, $".{Guid.NewGuid():N}.tmp");
        await File.WriteAllBytesAsync(temporary, data, token);
        File.Move(temporary, destination, true);
    }

    public Task<byte[]> DownloadAsync(string id, CancellationToken token)
    {
        var path = Path.GetFullPath(id);
        var root = Path.GetFullPath(syncFolder) + Path.DirectorySeparatorChar;
        if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Invalid iCloud Drive file path");
        return File.ReadAllBytesAsync(path, token);
    }

    private string SafeFile(string name)
    {
        if (Path.GetFileName(name) != name) throw new InvalidDataException("Invalid iCloud Drive file name");
        return Path.Combine(syncFolder, name);
    }

    private static string? LocateExistingSyncFolder() => LocateExistingSyncFolder(LocateDriveRoots());

    private static string? LocateExistingSyncFolder(IReadOnlyList<string> roots)
    {
        var containerRoots = roots.Where(IsContainerRoot).ToList();
        var globalRoots = roots.Where(root => !IsContainerRoot(root)).ToList();
        var candidates = containerRoots.SelectMany(root => new[]
        {
            Path.Combine(root, "ScreenTimeGuardian", "sync"),
            Path.Combine(root, "Documents", "ScreenTimeGuardian", "sync")
        }).Concat(globalRoots.SelectMany(root => new[]
        {
            Path.Combine(root, ContainerName, "ScreenTimeGuardian", "sync"),
            Path.Combine(root, ContainerName, "Documents", "ScreenTimeGuardian", "sync")
        })).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

        // Use only the App Library and sync directory created by iOS/macOS.
        // Windows must never create a similarly named ordinary folder because
        // iCloud treats that as a different item from the Apple container.
        var populated = candidates.FirstOrDefault(folder => Directory.Exists(folder) &&
            (Directory.EnumerateFiles(folder, "*_setting.json").Any() || Directory.EnumerateFiles(folder, "*_bitmap_*.json").Any()));
        if (populated is not null) return populated;
        return candidates.FirstOrDefault(Directory.Exists);
    }

    private static bool IsContainerRoot(string root)
    {
        var name = Path.GetFileName(root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        if (name.Equals(ContainerName, StringComparison.OrdinalIgnoreCase)) return true;
        if (name.Contains("screentimeguardian", StringComparison.OrdinalIgnoreCase) ||
            name.Contains("timbertrail", StringComparison.OrdinalIgnoreCase)) return true;
        return Directory.Exists(Path.Combine(root, "Documents", "ScreenTimeGuardian"));
    }

    private static IReadOnlyList<string> LocateDriveRoots()
    {
        var result = new List<string>();
        foreach (var value in StandardCandidates().Concat(SyncRootCandidates()).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                if (!string.IsNullOrWhiteSpace(value) && Directory.Exists(value)) result.Add(Path.GetFullPath(value));
            }
            catch { }
        }
        return result;
    }

    private static IEnumerable<string> StandardCandidates()
    {
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        yield return Path.Combine(profile, "iCloud Drive");
        yield return Path.Combine(profile, "iCloudDrive");
    }

    private static IEnumerable<string> SyncRootCandidates()
    {
        using var manager = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager");
        if (manager is null) yield break;
        foreach (var name in manager.GetSubKeyNames().Where(value => value.Contains("icloud", StringComparison.OrdinalIgnoreCase)))
        {
            using var provider = manager.OpenSubKey(name);
            if (provider is null) continue;
            foreach (var valueName in new[] { "Path", "RootPath" })
                if (provider.GetValue(valueName) is string path) yield return Environment.ExpandEnvironmentVariables(path);
            using var roots = provider.OpenSubKey("UserSyncRoots");
            if (roots is null) continue;
            foreach (var valueName in roots.GetValueNames())
                if (roots.GetValue(valueName) is string path) yield return Environment.ExpandEnvironmentVariables(path);
        }
    }
}

internal sealed record OneDriveCredential(
    [property: JsonPropertyName("access_token")] string AccessToken,
    [property: JsonPropertyName("refresh_token")] string RefreshToken,
    [property: JsonPropertyName("expires_at")] DateTimeOffset ExpiresAt,
    [property: JsonPropertyName("account_label")] string AccountLabel);

internal sealed class OneDriveClient : IPrivateCloudDrive
{
    private const string Scope = "offline_access User.Read Files.ReadWrite.AppFolder";
    private readonly HttpClient http = new();
    private OneDriveCredential credential;

    private OneDriveClient(OneDriveCredential credential) => this.credential = credential;
    public static bool IsSignedIn => Load() is not null;
    public static string AccountLabel => Load()?.AccountLabel ?? "Not signed in";

    public static async Task<OneDriveClient> SignInAsync(System.Windows.Window? owner, CancellationToken token = default)
    {
        using var http = new HttpClient();
        var response = await http.PostAsync("https://login.microsoftonline.com/common/oauth2/v2.0/devicecode", Form(new() { ["client_id"] = CloudConfiguration.MicrosoftClientID, ["scope"] = Scope }), token);
        var data = await response.Content.ReadAsByteArrayAsync(token);
        Ensure(response, data, "Microsoft sign-in could not start");
        var code = JsonSerializer.Deserialize<DeviceCodeResponse>(data, JsonOptions.Default) ?? throw new InvalidOperationException("Microsoft returned an invalid sign-in response");
        using var signInCancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
        var dialog = new OneDriveAuthorizationForm(code.UserCode, code.VerificationURI) { Owner = owner };
        dialog.CancelRequested += (_, _) => signInCancellation.Cancel();
        dialog.Show();
        Process.Start(new ProcessStartInfo(code.VerificationURI) { UseShellExecute = true });
        try
        {
            var deadline = DateTimeOffset.UtcNow.AddSeconds(code.ExpiresIn);
            var interval = Math.Max(2, code.Interval);
            while (DateTimeOffset.UtcNow < deadline)
            {
                signInCancellation.Token.ThrowIfCancellationRequested();
                dialog.SetStatus("Waiting for Microsoft to confirm the sign-in…");
                await Task.Delay(TimeSpan.FromSeconds(interval), signInCancellation.Token);
                response = await http.PostAsync("https://login.microsoftonline.com/common/oauth2/v2.0/token", Form(new()
                {
                    ["client_id"] = CloudConfiguration.MicrosoftClientID,
                    ["grant_type"] = "urn:ietf:params:oauth:grant-type:device_code",
                    ["device_code"] = code.DeviceCode
                }), signInCancellation.Token);
                data = await response.Content.ReadAsByteArrayAsync(signInCancellation.Token);
                if (response.IsSuccessStatusCode)
                {
                    dialog.SetStatus("Microsoft sign-in confirmed. Finishing the OneDrive connection…");
                    var tokenResponse = JsonSerializer.Deserialize<TokenResponse>(data, JsonOptions.Default) ?? throw new InvalidOperationException("Microsoft returned an invalid token");
                    var temporary = new OneDriveCredential(tokenResponse.AccessToken, tokenResponse.RefreshToken ?? "", DateTimeOffset.UtcNow.AddSeconds(tokenResponse.ExpiresIn), "Microsoft account");
                    var client = new OneDriveClient(temporary);
                    client.Save();
                    try
                    {
                        var profile = await client.GetProfileAsync(signInCancellation.Token);
                        client.credential = temporary with { AccountLabel = profile }; client.Save();
                    }
                    catch { }
                    dialog.CloseAfterSuccess(); return client;
                }
                var oauth = TryOAuthError(data);
                if (oauth == "slow_down") { interval += 5; continue; }
                if (oauth == "authorization_pending") continue;
                throw new InvalidOperationException("Microsoft sign-in failed" + (oauth is null ? "." : $": {oauth}"));
            }
            throw new TimeoutException("Microsoft sign-in code expired");
        }
        catch { dialog.CloseAfterFailure(); throw; }
    }

    public static OneDriveClient FromStore() => new(Load() ?? throw new InvalidOperationException("Sign in to OneDrive in Settings first"));
    public static void SignOut() => CredentialStore.Delete(CloudConfiguration.OneDriveCredential);

    public async Task<IReadOnlyList<RemoteFile>> ListAsync(CancellationToken token)
    {
        var data = await GraphAsync(HttpMethod.Get, "/v1.0/me/drive/special/approot/children?$select=id,name", null, token);
        return (JsonSerializer.Deserialize<OneDriveFileList>(data, JsonOptions.Default)?.Value ?? []).Select(value => new RemoteFile(value.ID, value.Name)).ToList();
    }

    public async Task UploadAsync(string name, byte[] data, string? existingID, CancellationToken token) =>
        _ = await GraphAsync(HttpMethod.Put, $"/v1.0/me/drive/special/approot:/{Uri.EscapeDataString(name)}:/content", new ByteArrayContent(data), token);

    public Task<byte[]> DownloadAsync(string id, CancellationToken token) => GraphAsync(HttpMethod.Get, $"/v1.0/me/drive/items/{Uri.EscapeDataString(id)}/content", null, token);

    private async Task<string> GetProfileAsync(CancellationToken token)
    {
        var data = await GraphAsync(HttpMethod.Get, "/v1.0/me?$select=displayName,mail,userPrincipalName", null, token);
        var profile = JsonSerializer.Deserialize<MicrosoftProfile>(data, JsonOptions.Default);
        return profile?.Mail ?? profile?.UserPrincipalName ?? profile?.DisplayName ?? "Microsoft account";
    }

    private async Task<byte[]> GraphAsync(HttpMethod method, string path, HttpContent? content, CancellationToken token)
    {
        await RefreshAsync(token);
        using var request = new HttpRequestMessage(method, "https://graph.microsoft.com" + path) { Content = content };
        request.Headers.Authorization = new("Bearer", credential.AccessToken);
        if (content is not null) content.Headers.ContentType = new("application/json");
        var response = await http.SendAsync(request, token);
        var data = await response.Content.ReadAsByteArrayAsync(token);
        Ensure(response, data, "Microsoft Graph request failed");
        return data;
    }

    private async Task RefreshAsync(CancellationToken token)
    {
        if (credential.ExpiresAt > DateTimeOffset.UtcNow.AddMinutes(2)) return;
        var response = await http.PostAsync("https://login.microsoftonline.com/common/oauth2/v2.0/token", Form(new()
        {
            ["client_id"] = CloudConfiguration.MicrosoftClientID, ["grant_type"] = "refresh_token",
            ["refresh_token"] = credential.RefreshToken, ["scope"] = Scope
        }), token);
        var data = await response.Content.ReadAsByteArrayAsync(token);
        Ensure(response, data, "Microsoft session refresh failed; sign in again");
        var value = JsonSerializer.Deserialize<TokenResponse>(data, JsonOptions.Default) ?? throw new InvalidOperationException("Microsoft returned an invalid token");
        credential = credential with { AccessToken = value.AccessToken, RefreshToken = value.RefreshToken ?? credential.RefreshToken, ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(value.ExpiresIn) };
        Save();
    }

    private void Save() => CredentialStore.Write(CloudConfiguration.OneDriveCredential, JsonSerializer.Serialize(credential, JsonOptions.Default));
    private static OneDriveCredential? Load() { try { return JsonSerializer.Deserialize<OneDriveCredential>(CredentialStore.Read(CloudConfiguration.OneDriveCredential), JsonOptions.Default); } catch { return null; } }
    private static FormUrlEncodedContent Form(Dictionary<string, string> values) => new(values);
    private static string? TryOAuthError(byte[] data) { try { return JsonDocument.Parse(data).RootElement.GetProperty("error").GetString(); } catch { return null; } }
    private static void Ensure(HttpResponseMessage response, byte[] data, string fallback) { if (!response.IsSuccessStatusCode) throw new InvalidOperationException(ApiError(data) ?? $"{fallback} ({(int)response.StatusCode})"); }
    private static string? ApiError(byte[] data) { try { var root = JsonDocument.Parse(data).RootElement; if (root.TryGetProperty("error_description", out var description)) return description.GetString(); if (root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object && error.TryGetProperty("message", out var message)) return message.GetString(); } catch { } return null; }

    private sealed record DeviceCodeResponse([property: JsonPropertyName("device_code")] string DeviceCode, [property: JsonPropertyName("user_code")] string UserCode, [property: JsonPropertyName("verification_uri")] string VerificationURI, [property: JsonPropertyName("expires_in")] int ExpiresIn, [property: JsonPropertyName("interval")] int Interval);
    private sealed record TokenResponse([property: JsonPropertyName("access_token")] string AccessToken, [property: JsonPropertyName("refresh_token")] string? RefreshToken, [property: JsonPropertyName("expires_in")] int ExpiresIn);
    private sealed record OneDriveFile([property: JsonPropertyName("id")] string ID, [property: JsonPropertyName("name")] string Name);
    private sealed record OneDriveFileList([property: JsonPropertyName("value")] List<OneDriveFile> Value);
    private sealed record MicrosoftProfile(
        [property: JsonPropertyName("displayName")] string? DisplayName,
        [property: JsonPropertyName("mail")] string? Mail,
        [property: JsonPropertyName("userPrincipalName")] string? UserPrincipalName);
}

internal sealed record GoogleDriveCredential(string AccessToken, string RefreshToken, DateTimeOffset ExpiresAt, string AccountLabel);

internal sealed class GoogleDriveClient : IPrivateCloudDrive
{
    private const string Scope = "openid email profile https://www.googleapis.com/auth/drive.appdata";
    private readonly HttpClient http = new();
    private GoogleDriveCredential credential;
    private GoogleDriveClient(GoogleDriveCredential credential) => this.credential = credential;
    public static bool IsSignedIn => Load() is not null;
    public static string AccountLabel => Load()?.AccountLabel ?? "Not signed in";

    public static async Task<GoogleDriveClient> SignInAsync(CancellationToken token = default)
    {
        var verifier = Base64Url(RandomNumberGenerator.GetBytes(48));
        var challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        var state = Base64Url(RandomNumberGenerator.GetBytes(24));
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var redirect = $"http://127.0.0.1:{port}/";
        var url = "https://accounts.google.com/o/oauth2/v2/auth?" + Query(new()
        {
            ["client_id"] = CloudConfiguration.GoogleClientID, ["redirect_uri"] = redirect, ["response_type"] = "code",
            ["scope"] = Scope, ["code_challenge"] = challenge, ["code_challenge_method"] = "S256", ["state"] = state,
            ["access_type"] = "offline", ["prompt"] = "consent", ["include_granted_scopes"] = "true"
        });
        Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        try
        {
            using var connection = await listener.AcceptTcpClientAsync(token);
            using var stream = connection.GetStream();
            using var reader = new StreamReader(stream, Encoding.ASCII, false, 4096, true);
            var requestLine = await reader.ReadLineAsync(token) ?? "";
            var target = requestLine.Split(' ').ElementAtOrDefault(1) ?? "/";
            while (!string.IsNullOrEmpty(await reader.ReadLineAsync(token))) { }
            var callback = new Uri(new Uri(redirect), target);
            var values = ParseQuery(callback.Query);
            var valid = values.GetValueOrDefault("state") == state && !string.IsNullOrWhiteSpace(values.GetValueOrDefault("code"));
            var html = valid ? "<h2>Screen Time Guardian is connected.</h2><p>You may close this window.</p>" : "<h2>Screen Time Guardian could not connect.</h2><p>Return to the app and try again.</p>";
            var body = Encoding.UTF8.GetBytes($"<!doctype html><meta charset=utf-8><title>STG</title><body style='font-family:Segoe UI;padding:3rem'>{html}</body>");
            var header = Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
            await stream.WriteAsync(header, token); await stream.WriteAsync(body, token);
            if (!valid) throw new InvalidOperationException(values.GetValueOrDefault("error") ?? "Google sign-in response was invalid");

            using var http = new HttpClient();
            var response = await http.PostAsync("https://oauth2.googleapis.com/token", new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["client_id"] = CloudConfiguration.GoogleClientID, ["client_secret"] = CloudConfiguration.GoogleClientSecret,
                ["code"] = values["code"], ["code_verifier"] = verifier, ["grant_type"] = "authorization_code", ["redirect_uri"] = redirect
            }), token);
            var data = await response.Content.ReadAsByteArrayAsync(token);
            Ensure(response, data, "Google token request failed");
            var tokenValue = JsonSerializer.Deserialize<GoogleToken>(data, JsonOptions.Default) ?? throw new InvalidOperationException("Google returned an invalid token");
            var temporary = new GoogleDriveCredential(tokenValue.AccessToken, tokenValue.RefreshToken ?? "", DateTimeOffset.UtcNow.AddSeconds(tokenValue.ExpiresIn), "Google account");
            var client = new GoogleDriveClient(temporary);
            var profile = await client.ProfileAsync(token);
            client.credential = temporary with { AccountLabel = profile };
            client.Save();
            return client;
        }
        finally { listener.Stop(); }
    }

    public static GoogleDriveClient FromStore() => new(Load() ?? throw new InvalidOperationException("Sign in to Google Drive in Settings first"));
    public static void SignOut() => CredentialStore.Delete(CloudConfiguration.GoogleDriveCredential);

    public async Task<IReadOnlyList<RemoteFile>> ListAsync(CancellationToken token)
    {
        var url = "https://www.googleapis.com/drive/v3/files?" + Query(new() { ["spaces"] = "appDataFolder", ["fields"] = "files(id,name)", ["pageSize"] = "1000", ["q"] = "trashed = false" });
        var data = await AuthorizedAsync(HttpMethod.Get, url, null, token);
        return (JsonSerializer.Deserialize<GoogleFileList>(data, JsonOptions.Default)?.Files ?? []).Select(value => new RemoteFile(value.ID, value.Name)).ToList();
    }

    public async Task UploadAsync(string name, byte[] data, string? existingID, CancellationToken token)
    {
        if (existingID is not null)
        {
            var content = new ByteArrayContent(data); content.Headers.ContentType = new("application/json");
            _ = await AuthorizedAsync(HttpMethod.Patch, $"https://www.googleapis.com/upload/drive/v3/files/{Uri.EscapeDataString(existingID)}?uploadType=media", content, token);
            return;
        }
        var boundary = "stg-" + Guid.NewGuid().ToString("N");
        var multipart = new MultipartContent("related", boundary);
        var metadata = new StringContent(JsonSerializer.Serialize(new { name, parents = new[] { "appDataFolder" } }), Encoding.UTF8, "application/json");
        var payload = new ByteArrayContent(data); payload.Headers.ContentType = new("application/json");
        multipart.Add(metadata); multipart.Add(payload);
        _ = await AuthorizedAsync(HttpMethod.Post, "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart", multipart, token);
    }

    public Task<byte[]> DownloadAsync(string id, CancellationToken token) => AuthorizedAsync(HttpMethod.Get, $"https://www.googleapis.com/drive/v3/files/{Uri.EscapeDataString(id)}?alt=media", null, token);

    private async Task<string> ProfileAsync(CancellationToken token)
    {
        var data = await AuthorizedAsync(HttpMethod.Get, "https://openidconnect.googleapis.com/v1/userinfo", null, token);
        var profile = JsonSerializer.Deserialize<GoogleProfile>(data, JsonOptions.Default);
        return profile?.Email ?? profile?.Name ?? "Google account";
    }

    private async Task<byte[]> AuthorizedAsync(HttpMethod method, string url, HttpContent? content, CancellationToken token)
    {
        await RefreshAsync(token);
        using var request = new HttpRequestMessage(method, url) { Content = content };
        request.Headers.Authorization = new("Bearer", credential.AccessToken);
        var response = await http.SendAsync(request, token);
        var data = await response.Content.ReadAsByteArrayAsync(token);
        Ensure(response, data, "Google Drive request failed");
        return data;
    }

    private async Task RefreshAsync(CancellationToken token)
    {
        if (credential.ExpiresAt > DateTimeOffset.UtcNow.AddMinutes(2)) return;
        var response = await http.PostAsync("https://oauth2.googleapis.com/token", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["client_id"] = CloudConfiguration.GoogleClientID, ["client_secret"] = CloudConfiguration.GoogleClientSecret,
            ["refresh_token"] = credential.RefreshToken, ["grant_type"] = "refresh_token"
        }), token);
        var data = await response.Content.ReadAsByteArrayAsync(token);
        Ensure(response, data, "Google session refresh failed; sign in again");
        var value = JsonSerializer.Deserialize<GoogleToken>(data, JsonOptions.Default) ?? throw new InvalidOperationException("Google returned an invalid token");
        credential = credential with { AccessToken = value.AccessToken, RefreshToken = value.RefreshToken ?? credential.RefreshToken, ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(value.ExpiresIn) };
        Save();
    }

    private void Save() => CredentialStore.Write(CloudConfiguration.GoogleDriveCredential, JsonSerializer.Serialize(credential, JsonOptions.Default));
    private static GoogleDriveCredential? Load() { try { return JsonSerializer.Deserialize<GoogleDriveCredential>(CredentialStore.Read(CloudConfiguration.GoogleDriveCredential), JsonOptions.Default); } catch { return null; } }
    private static string Base64Url(byte[] data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static string Query(Dictionary<string, string> values) => string.Join("&", values.Select(value => $"{Uri.EscapeDataString(value.Key)}={Uri.EscapeDataString(value.Value)}"));
    private static Dictionary<string, string> ParseQuery(string query) => query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries).Select(value => value.Split('=', 2)).ToDictionary(value => Uri.UnescapeDataString(value[0]), value => Uri.UnescapeDataString(value.ElementAtOrDefault(1)?.Replace('+', ' ') ?? ""));
    private static void Ensure(HttpResponseMessage response, byte[] data, string fallback)
    {
        if (response.IsSuccessStatusCode) return;
        string? message = null;
        try
        {
            var root = JsonDocument.Parse(data).RootElement;
            if (root.TryGetProperty("error_description", out var description)) message = description.GetString();
            else if (root.TryGetProperty("error", out var error))
                message = error.ValueKind == JsonValueKind.String ? error.GetString() : error.TryGetProperty("message", out var detail) ? detail.GetString() : null;
        }
        catch { }
        throw new InvalidOperationException(message ?? $"{fallback} ({(int)response.StatusCode})");
    }
    private sealed record GoogleToken([property: JsonPropertyName("access_token")] string AccessToken, [property: JsonPropertyName("refresh_token")] string? RefreshToken, [property: JsonPropertyName("expires_in")] int ExpiresIn);
    private sealed record GoogleFile([property: JsonPropertyName("id")] string ID, [property: JsonPropertyName("name")] string Name);
    private sealed record GoogleFileList([property: JsonPropertyName("files")] List<GoogleFile> Files);
    private sealed record GoogleProfile(string? Name, string? Email);
}
