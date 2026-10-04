using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.IO.Compression;
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

internal sealed record CloudSyncResult(int Uploaded, int Downloaded, IReadOnlySet<string> Devices, IReadOnlyDictionary<string, string> DownloadCursors, string? UploadCursor, IReadOnlyList<string> Warnings);
internal sealed record RemoteFile(string ID, string Name, DateTimeOffset? ModifiedAt = null);
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
    Task<IReadOnlyList<RemoteFile>> ListFolderAsync(string folder, CancellationToken token);
    Task UploadFolderAsync(string folder, string name, byte[] data, string? existingID, CancellationToken token);
    Task DeleteAsync(string id, CancellationToken token);
}

internal sealed class PrivateCloudSync(BitmapRepository repository, AppSettings settings, IPrivateCloudDrive drive)
{
    private sealed record BitmapArchive(string Kind, string DeviceID, string PeriodStart, string PeriodEnd, IReadOnlyList<BitmapDocument> Rows, DateTimeOffset CreatedAt);
    private sealed record TrackingArchive(string Kind, int Year, IReadOnlyList<WeeklyRankingRow> Rows, DateTimeOffset CreatedAt);

    public async Task<int> QuickUploadAsync(CancellationToken token = default)
    {
        var key = DateTimeOffset.UtcNow.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        var stored = repository.StoredBitmap(settings.DeviceID, key);
        if (stored is null) { repository.CompleteQuickUpload(settings.DeviceID); return 0; }
        var files = await drive.ListAsync(token);
        var name = $"{settings.DeviceID}_bitmap_{key}.json";
        var existing = files.FirstOrDefault(value => value.Name.Equals(name, StringComparison.Ordinal));
        var document = new BitmapDocument(settings.DeviceID, key, stored.Value.Bitmap.ToBase64(), stored.Value.UpdatedAt, []);
        await drive.UploadAsync(name, JsonSerializer.SerializeToUtf8Bytes(document, JsonOptions.Default), existing?.ID, token);
        repository.CompleteQuickUpload(settings.DeviceID);
        return 1;
    }

    public async Task<CloudSyncResult> IncrementalAsync(CancellationToken token = default, Action<string>? progress = null)
    {
        progress?.Invoke("Preparing cloud folders…");
        progress?.Invoke("Scanning remote devices…");
        var remoteFiles = await drive.ListAsync(token);
        var byName = remoteFiles.GroupBy(value => value.Name, StringComparer.Ordinal).ToDictionary(value => value.Key, value => value.First(), StringComparer.Ordinal);
        var devices = remoteFiles.Select(value => ParseDevice(value.Name)).Where(value => value is not null).Cast<string>().ToHashSet(StringComparer.OrdinalIgnoreCase);
        var knownDevices = repository.Devices();
        var downloaded = 0;
        var warnings = new List<string>();
        var uploadTarget = settings.SyncProvider.ToString();
        var existingUploadCursor = repository.IncrementalUploadCursor(uploadTarget);

        foreach (var file in remoteFiles.Where(value => value.Name.EndsWith("_setting.json", StringComparison.Ordinal)))
        {
            try
            {
                var remoteID = ParseDevice(file.Name);
                if (remoteID is null || remoteID.Equals(settings.DeviceID, StringComparison.OrdinalIgnoreCase)) continue;
                if (file.ModifiedAt is DateTimeOffset modifiedAt && knownDevices.TryGetValue(remoteID, out var known) && modifiedAt <= known.UpdatedAt) continue;
                progress?.Invoke("Updating device information…");
                var document = JsonSerializer.Deserialize<AppSettings>(await drive.DownloadAsync(file.ID, token), JsonOptions.Default);
                if (document is null || !document.DeviceID.Equals(remoteID, StringComparison.OrdinalIgnoreCase)) continue;
                repository.UpsertDevice(new(document.DeviceID, document.DeviceName, document.DeviceKind, file.ModifiedAt ?? document.UpdatedAt));
            }
            catch (Exception error) { warnings.Add($"settings_import_failed; provider={settings.SyncProvider}; file={file.Name}; {DiagnosticLog.Describe(error)}"); }
        }

        var downloadCursors = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var downloadIDs = devices.Where(value =>
            !value.Equals("alldevices", StringComparison.OrdinalIgnoreCase) &&
            (!value.Equals(settings.DeviceID, StringComparison.OrdinalIgnoreCase) || existingUploadCursor is null)).ToList();
        var totalDownloads = downloadIDs.Sum(remoteID =>
        {
            var cursor = remoteID.Equals(settings.DeviceID, StringComparison.OrdinalIgnoreCase) ? null : repository.IncrementalDownloadCursor(remoteID);
            return remoteFiles.Count(file => ParseDevice(file.Name)?.Equals(remoteID, StringComparison.OrdinalIgnoreCase) == true && ParseBitmapDate(file.Name) is string date && (cursor is null || string.CompareOrdinal(date, cursor) >= 0));
        });
        if (totalDownloads == 0) progress?.Invoke("Downloading device data — nothing new…");
        foreach (var remoteID in downloadIDs)
        {
            var restoringThisDevice = remoteID.Equals(settings.DeviceID, StringComparison.OrdinalIgnoreCase);
            var cursor = restoringThisDevice ? null : repository.IncrementalDownloadCursor(remoteID);
            var candidates = remoteFiles
                .Select(file => (File: file, Device: ParseDevice(file.Name), Date: ParseBitmapDate(file.Name)))
                .Where(value => value.Device?.Equals(remoteID, StringComparison.OrdinalIgnoreCase) == true && value.Date is not null && (cursor is null || string.CompareOrdinal(value.Date, cursor) >= 0))
                .OrderBy(value => value.Date, StringComparer.Ordinal);
            foreach (var candidate in candidates)
            {
                progress?.Invoke($"Downloading device data — {downloaded + 1} of {totalDownloads}…");
                try
                {
                    var document = JsonSerializer.Deserialize<BitmapDocument>(await drive.DownloadAsync(candidate.File.ID, token), JsonOptions.Default);
                    if (document is null || !document.DeviceID.Equals(remoteID, StringComparison.OrdinalIgnoreCase) || document.UtcDate != candidate.Date) throw new InvalidDataException("Remote bitmap identity mismatch");
                    if (restoringThisDevice)
                        repository.MergeBitmap(remoteID, document.UtcDate, MinuteBitmap.FromBase64(document.BitmapBase64), document.UpdatedAt);
                    else
                        repository.UpsertIfNewer(remoteID, document.UtcDate, MinuteBitmap.FromBase64(document.BitmapBase64), document.UpdatedAt);
                    repository.RebuildAll(document.UtcDate);
                    if (!restoringThisDevice)
                    {
                        repository.SaveIncrementalDownloadCursor(remoteID, document.UtcDate);
                        downloadCursors[remoteID] = document.UtcDate;
                    }
                    downloaded++;
                }
                catch (Exception error) { warnings.Add($"bitmap_import_failed; provider={settings.SyncProvider}; device={remoteID[..Math.Min(8, remoteID.Length)]}; utc_date={candidate.Date}; file={candidate.File.Name}; cursor_not_advanced=true; {DiagnosticLog.Describe(error)}"); break; }
            }
        }

        repository.UpsertDevice(new(settings.DeviceID, settings.DeviceName, settings.DeviceKind, settings.UpdatedAt));
        var uploaded = 0; string? uploadCursor = null;
        var uploadDates = TimeModel.IncrementalUploadUtcDates(existingUploadCursor, DateTimeOffset.UtcNow).Where(date => repository.StoredBitmap(settings.DeviceID, date) is not null).ToList();
        if (uploadDates.Count == 0) progress?.Invoke("Uploading local changes — nothing new…");
        foreach (var date in uploadDates)
        {
            token.ThrowIfCancellationRequested();
            var stored = repository.StoredBitmap(settings.DeviceID, date);
            if (stored is null) continue;
            progress?.Invoke($"Uploading local changes — {uploaded + 1} of {uploadDates.Count}…");
            var document = new BitmapDocument(settings.DeviceID, date, stored.Value.Bitmap.ToBase64(), stored.Value.UpdatedAt, []);
            var name = $"{settings.DeviceID}_bitmap_{date}.json";
            await drive.UploadAsync(name, JsonSerializer.SerializeToUtf8Bytes(document, JsonOptions.Default), byName.GetValueOrDefault(name)?.ID, token);
            repository.SaveIncrementalUploadCursor(uploadTarget, date); uploadCursor = date; uploaded++;
        }
        var settingsName = $"{settings.DeviceID}_setting.json";
        progress?.Invoke("Uploading device settings…");
        await drive.UploadAsync(settingsName, JsonSerializer.SerializeToUtf8Bytes(settings, JsonOptions.Default), byName.GetValueOrDefault(settingsName)?.ID, token);
        return new(uploaded, downloaded, devices, downloadCursors, uploadCursor, warnings);
    }

    public async Task<(int Uploaded, int DeletedDaily, int MovedWeekly)> WeeklyMaintenanceAsync(DateOnly currentWeekStart, DateOnly previousWeekStart, DateOnly previousWeekEnd, CancellationToken token = default)
    {
        var remote = await drive.ListAsync(token);
        var history = await drive.ListFolderAsync("history", token);
        var dailyFiles = remote.Select(file => (File: file, Date: ParseBitmapDate(file.Name), Device: ParseDevice(file.Name)))
            .Where(value => value.Device == settings.DeviceID && value.Date is not null && DateOnly.Parse(value.Date) < currentWeekStart)
            .Select(value => (value.File, Date: DateOnly.Parse(value.Date!), WeekStart: WeekStart(DateOnly.Parse(value.Date!)))).ToList();
        var weekStarts = dailyFiles.Select(value => value.WeekStart).Append(previousWeekStart).Distinct().Order().ToList();
        var uploaded = 0; var deleted = 0;
        foreach (var weekStart in weekStarts)
        {
            token.ThrowIfCancellationRequested();
            var weekEnd = weekStart.AddDays(6);
            var rows = repository.BitmapArchive(settings.DeviceID, weekStart, weekEnd);
            var archiveName = $"{settings.DeviceID}_week_{weekStart:yyyy-MM-dd}_{weekEnd:yyyy-MM-dd}.json";
            var archive = new BitmapArchive("weekly_bitmap", settings.DeviceID, $"{weekStart:yyyy-MM-dd}", $"{weekEnd:yyyy-MM-dd}", rows, DateTimeOffset.UtcNow);
            await drive.UploadAsync(archiveName, JsonSerializer.SerializeToUtf8Bytes(archive, JsonOptions.Default), remote.FirstOrDefault(value => value.Name == archiveName)?.ID, token); uploaded++;
            foreach (var daily in dailyFiles.Where(value => value.WeekStart == weekStart)) { await drive.DeleteAsync(daily.File.ID, token); deleted++; }
            repository.RecordArchive($"bitmap-week-{settings.DeviceID}-{weekStart:yyyy-MM-dd}", "weekly_bitmap", weekStart, weekEnd, null, archiveName, null, DateTimeOffset.UtcNow, "uploaded");
        }
        var moved = 0;
        remote = await drive.ListAsync(token);
        var archiveCutoff = previousWeekStart.AddDays(-7);
        foreach (var file in remote.Where(value => value.Name.StartsWith($"{settings.DeviceID}_week_", StringComparison.Ordinal) && ParseWeekEnd(value.Name) is DateOnly end && end < archiveCutoff))
        {
            var data = await drive.DownloadAsync(file.ID, token);
            await drive.UploadFolderAsync("history", file.Name, data, history.FirstOrDefault(value => value.Name == file.Name)?.ID, token);
            await drive.DeleteAsync(file.ID, token); moved++;
        }
        return (uploaded, deleted, moved);
    }

    private static DateOnly WeekStart(DateOnly date) => date.AddDays(-(((int)date.DayOfWeek + 6) % 7));

    public async Task<(int Uploaded, int DeletedBitmaps, int DeletedWeekly)> YearlyMaintenanceAsync(int year, int trackingCleanupYear, CancellationToken token = default)
    {
        var history = await drive.ListFolderAsync("history", token);
        var start = new DateOnly(year, 1, 1); var end = new DateOnly(year, 12, 31);
        var bitmapRows = repository.BitmapArchive(settings.DeviceID, start, end);
        var bitmapData = JsonSerializer.SerializeToUtf8Bytes(new BitmapArchive("yearly_bitmap", settings.DeviceID, $"{start:yyyy-MM-dd}", $"{end:yyyy-MM-dd}", bitmapRows, DateTimeOffset.UtcNow), JsonOptions.Default);
        var bitmapName = $"{settings.DeviceID}_year_{year}.json.gz";
        await drive.UploadFolderAsync("history", bitmapName, Gzip(bitmapData), history.FirstOrDefault(value => value.Name == bitmapName)?.ID, token);
        var trackingRows = repository.OpenRouterArchive(year);
        var trackingName = $"openrouter_year_{year}.json.gz";
        var trackingData = JsonSerializer.SerializeToUtf8Bytes(new TrackingArchive("openrouter_year", year, trackingRows, DateTimeOffset.UtcNow), JsonOptions.Default);
        await drive.UploadFolderAsync("history", trackingName, Gzip(trackingData), history.FirstOrDefault(value => value.Name == trackingName)?.ID, token);
        var deletedBitmaps = repository.DeleteBitmapRows(settings.DeviceID, start, end);
        var deletedWeekly = repository.DeleteOpenRouterWeeks(trackingCleanupYear);
        repository.RecordArchive($"bitmap-year-{settings.DeviceID}-{year}", "yearly_bitmap", start, end, null, $"history/{bitmapName}", null, DateTimeOffset.UtcNow, "uploaded");
        repository.RecordArchive($"openrouter-year-{year}", "openrouter_year", start, end, null, $"history/{trackingName}", null, DateTimeOffset.UtcNow, "uploaded");
        return (2, deletedBitmaps, deletedWeekly);
    }

    private static byte[] Gzip(byte[] data)
    {
        using var output = new MemoryStream();
        using (var gzip = new GZipStream(output, CompressionLevel.SmallestSize, true)) gzip.Write(data);
        return output.ToArray();
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

    private static DateOnly? ParseWeekEnd(string name)
    {
        var marker = name.IndexOf("_week_", StringComparison.Ordinal);
        if (marker <= 0 || !name.EndsWith(".json", StringComparison.Ordinal)) return null;
        var pieces = name[(marker + "_week_".Length)..^5].Split('_');
        var value = pieces.Length == 2 ? pieces[1] : pieces.Length == 1 ? pieces[0] : null;
        if (value is null || !DateOnly.TryParseExact(value, "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var date)) return null;
        return pieces.Length == 1 ? date.AddDays(6) : date;
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

    public static string DiscoverySummary()
    {
        var roots = LocateDriveRoots();
        var folder = LocateExistingSyncFolder(roots);
        return $"roots=[{string.Join("|", roots)}]; selected_sync_folder={folder ?? "none"}";
    }

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
            .Select(path => new RemoteFile(path, Path.GetFileName(path), File.GetLastWriteTimeUtc(path))).ToList();
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

    public Task<IReadOnlyList<RemoteFile>> ListFolderAsync(string folder, CancellationToken token)
    {
        token.ThrowIfCancellationRequested(); var path = SafeFolder(folder); Directory.CreateDirectory(path);
        return Task.FromResult<IReadOnlyList<RemoteFile>>(Directory.EnumerateFiles(path, "*", SearchOption.TopDirectoryOnly).Select(value => new RemoteFile(value, Path.GetFileName(value), File.GetLastWriteTimeUtc(value))).ToList());
    }

    public async Task UploadFolderAsync(string folder, string name, byte[] data, string? existingID, CancellationToken token)
    {
        var directory = SafeFolder(folder); Directory.CreateDirectory(directory); var destination = Path.Combine(directory, Path.GetFileName(name));
        await File.WriteAllBytesAsync(destination, data, token);
    }

    public Task DeleteAsync(string id, CancellationToken token) { token.ThrowIfCancellationRequested(); var path = Path.GetFullPath(id); var root = Path.GetFullPath(syncFolder) + Path.DirectorySeparatorChar; if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Invalid iCloud Drive file path"); File.Delete(path); return Task.CompletedTask; }

    private string SafeFolder(string name) { if (Path.GetFileName(name) != name) throw new InvalidDataException("Invalid iCloud Drive folder name"); return Path.Combine(Directory.GetParent(syncFolder)?.FullName ?? syncFolder, name); }

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
            Path.Combine(root, "sync"),
            Path.Combine(root, "ScreenTimeGuardian", "sync"),
            Path.Combine(root, "Documents", "ScreenTimeGuardian", "sync")
        }).Concat(globalRoots.SelectMany(root => new[]
        {
            Path.Combine(root, ContainerName, "ScreenTimeGuardian", "sync"),
            Path.Combine(root, ContainerName, "Documents", "ScreenTimeGuardian", "sync")
        })).Concat(globalRoots.SelectMany(AppLibraryCandidates))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();

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

    private static IEnumerable<string> AppLibraryCandidates(string driveRoot)
    {
        IEnumerable<string> children;
        try { children = Directory.EnumerateDirectories(driveRoot, "*", SearchOption.TopDirectoryOnly).ToList(); }
        catch { yield break; }

        foreach (var child in children)
        {
            var normalized = new string(Path.GetFileName(child).Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());
            if (!normalized.Contains("screentimeguardian") &&
                !normalized.Contains("timbertrail") &&
                !normalized.Contains("icloudcomtimbertrailscreentimeguardian")) continue;
            yield return Path.Combine(child, "sync");
            yield return Path.Combine(child, "ScreenTimeGuardian", "sync");
            yield return Path.Combine(child, "Documents", "ScreenTimeGuardian", "sync");
        }
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
        var result = new List<string>();
        foreach (var hive in new[] { RegistryHive.CurrentUser, RegistryHive.LocalMachine })
        {
            foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
            {
                try
                {
                    using var baseKey = RegistryKey.OpenBaseKey(hive, view);
                    using var manager = baseKey.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager");
                    if (manager is null) continue;
                    foreach (var name in manager.GetSubKeyNames())
                    {
                        using var provider = manager.OpenSubKey(name);
                        if (provider is null || !IsICloudProvider(name, provider)) continue;
                        foreach (var valueName in new[] { "Path", "RootPath" })
                            if (provider.GetValue(valueName) is string path) result.Add(Environment.ExpandEnvironmentVariables(path));
                        using var roots = provider.OpenSubKey("UserSyncRoots");
                        if (roots is null) continue;
                        foreach (var valueName in roots.GetValueNames())
                            if (roots.GetValue(valueName) is string path) result.Add(Environment.ExpandEnvironmentVariables(path));
                    }
                }
                catch { }
            }
        }
        return result;
    }

    private static bool IsICloudProvider(string keyName, RegistryKey provider)
    {
        var identity = string.Join(" ", new[]
        {
            keyName,
            provider.GetValue("DisplayNameResource") as string,
            provider.GetValue("IconResource") as string,
            provider.GetValue("ProviderName") as string
        }.Where(value => !string.IsNullOrWhiteSpace(value)));
        return identity.Contains("icloud", StringComparison.OrdinalIgnoreCase) ||
               identity.Contains("apple", StringComparison.OrdinalIgnoreCase);
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
    private bool appRootReady;

    private OneDriveClient(OneDriveCredential credential) => this.credential = credential;
    public static bool IsSignedIn => Load() is not null;
    public static string AccountLabel => Load()?.AccountLabel ?? "Not signed in";

    public static async Task<OneDriveClient> SignInAsync(System.Windows.Window? owner, CancellationToken token = default)
    {
        _ = owner;
        var verifier = Base64Url(RandomNumberGenerator.GetBytes(48));
        var challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        var state = Base64Url(RandomNumberGenerator.GetBytes(24));
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var redirect = $"http://localhost:{port}/";
        var url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?" + Query(new()
        {
            ["client_id"] = CloudConfiguration.MicrosoftClientID, ["redirect_uri"] = redirect, ["response_type"] = "code",
            ["response_mode"] = "query", ["scope"] = Scope, ["code_challenge"] = challenge,
            ["code_challenge_method"] = "S256", ["state"] = state, ["prompt"] = "select_account"
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
            if (!valid) throw new InvalidOperationException(values.GetValueOrDefault("error_description") ?? values.GetValueOrDefault("error") ?? "Microsoft sign-in response was invalid");

            using var http = new HttpClient();
            var response = await http.PostAsync("https://login.microsoftonline.com/common/oauth2/v2.0/token", Form(new()
            {
                ["client_id"] = CloudConfiguration.MicrosoftClientID, ["code"] = values["code"],
                ["code_verifier"] = verifier, ["grant_type"] = "authorization_code",
                ["redirect_uri"] = redirect, ["scope"] = Scope
            }), token);
            var data = await response.Content.ReadAsByteArrayAsync(token);
            Ensure(response, data, "Microsoft token request failed");
            var tokenResponse = JsonSerializer.Deserialize<TokenResponse>(data, JsonOptions.Default) ?? throw new InvalidOperationException("Microsoft returned an invalid token");
            if (string.IsNullOrWhiteSpace(tokenResponse.RefreshToken)) throw new InvalidOperationException("Microsoft did not return an offline refresh token");
            var temporary = new OneDriveCredential(tokenResponse.AccessToken, tokenResponse.RefreshToken, DateTimeOffset.UtcNow.AddSeconds(tokenResponse.ExpiresIn), "Microsoft account");
            var client = new OneDriveClient(temporary);
            var profile = await client.GetProfileAsync(token);
            client.credential = temporary with { AccountLabel = profile }; client.Save();
            return client;
        }
        finally { listener.Stop(); }
    }

    public static OneDriveClient FromStore() => new(Load() ?? throw new InvalidOperationException("Sign in to OneDrive in Settings first"));
    public static void SignOut() => CredentialStore.Delete(CloudConfiguration.OneDriveCredential);

    public async Task<IReadOnlyList<RemoteFile>> ListAsync(CancellationToken token)
    {
        await EnsureAppRootAsync(token);
        var data = await GraphAsync(HttpMethod.Get, "/v1.0/me/drive/special/approot/children?$select=id,name,lastModifiedDateTime", null, token);
        return (JsonSerializer.Deserialize<OneDriveFileList>(data, JsonOptions.Default)?.Value ?? []).Select(value => new RemoteFile(value.ID, value.Name, value.LastModifiedDateTime)).ToList();
    }

    public async Task UploadAsync(string name, byte[] data, string? existingID, CancellationToken token)
    {
        await EnsureAppRootAsync(token);
        _ = await GraphAsync(HttpMethod.Put, $"/v1.0/me/drive/special/approot:/{Uri.EscapeDataString(name)}:/content", new ByteArrayContent(data), token);
    }

    public Task<byte[]> DownloadAsync(string id, CancellationToken token) => GraphAsync(HttpMethod.Get, $"/v1.0/me/drive/items/{Uri.EscapeDataString(id)}/content", null, token);

    public async Task<IReadOnlyList<RemoteFile>> ListFolderAsync(string folder, CancellationToken token)
    {
        var folderID = await EnsureFolderAsync(folder, token);
        var data = await GraphAsync(HttpMethod.Get, $"/v1.0/me/drive/items/{Uri.EscapeDataString(folderID)}/children?$select=id,name", null, token);
        return (JsonSerializer.Deserialize<OneDriveFileList>(data, JsonOptions.Default)?.Value ?? []).Select(value => new RemoteFile(value.ID, value.Name)).ToList();
    }

    public async Task UploadFolderAsync(string folder, string name, byte[] data, string? existingID, CancellationToken token)
    {
        var folderID = await EnsureFolderAsync(folder, token);
        _ = await GraphAsync(HttpMethod.Put, $"/v1.0/me/drive/items/{Uri.EscapeDataString(folderID)}:/{Uri.EscapeDataString(name)}:/content", new ByteArrayContent(data), token);
    }

    public async Task DeleteAsync(string id, CancellationToken token) => _ = await GraphAsync(HttpMethod.Delete, $"/v1.0/me/drive/items/{Uri.EscapeDataString(id)}", null, token);

    private async Task<string> EnsureFolderAsync(string name, CancellationToken token)
    {
        var files = await ListAsync(token); var found = files.FirstOrDefault(value => value.Name == name); if (found is not null) return found.ID;
        var rootData = await GraphAsync(HttpMethod.Get, "/v1.0/me/drive/special/approot?$select=id,name", null, token);
        var rootID = JsonSerializer.Deserialize<OneDriveFile>(rootData, JsonOptions.Default)?.ID ?? throw new InvalidDataException("Microsoft Graph did not return the app-root folder ID");
        var content = new StringContent(JsonSerializer.Serialize(new { name, folder = new { }, @microsoft_graph_conflictBehavior = "fail" }).Replace("microsoft_graph_conflictBehavior", "@microsoft.graph.conflictBehavior"), Encoding.UTF8, "application/json");
        var data = await GraphAsync(HttpMethod.Post, $"/v1.0/me/drive/items/{Uri.EscapeDataString(rootID)}/children", content, token);
        return JsonSerializer.Deserialize<OneDriveFile>(data, JsonOptions.Default)?.ID ?? throw new InvalidDataException("Microsoft Graph did not return the history folder ID");
    }

    private async Task<string> GetProfileAsync(CancellationToken token)
    {
        var data = await GraphAsync(HttpMethod.Get, "/v1.0/me?$select=displayName,mail,userPrincipalName", null, token);
        var profile = JsonSerializer.Deserialize<MicrosoftProfile>(data, JsonOptions.Default);
        return profile?.Mail ?? profile?.UserPrincipalName ?? profile?.DisplayName ?? "Microsoft account";
    }

    private async Task EnsureAppRootAsync(CancellationToken token)
    {
        if (appRootReady) return;
        var delays = new[] { 1, 2, 4, 8 };
        for (var attempt = 0; attempt <= delays.Length; attempt++)
        {
            try
            {
                _ = await GraphAsync(HttpMethod.Get, "/v1.0/me/drive/special/approot?$select=id,name,specialFolder", null, token);
                appRootReady = true;
                return;
            }
            catch (InvalidOperationException error) when (IsPendingProvisioning(error))
            {
                if (attempt == 0)
                {
                    try { _ = await GraphAsync(HttpMethod.Get, "/v1.0/me/drive?$select=id,driveType", null, token); }
                    catch (InvalidOperationException probeError) when (IsPendingProvisioning(probeError)) { }
                }
                if (attempt == delays.Length)
                    throw new InvalidOperationException("OneDrive is still preparing this account. Open OneDrive once with the same Microsoft account, wait for its Files page to load, then return to STG and sync again.");
                await Task.Delay(TimeSpan.FromSeconds(delays[attempt]), token);
            }
        }
    }

    private static bool IsPendingProvisioning(Exception error)
    {
        var message = error.Message;
        return message.Contains("pending provisioning", StringComparison.OrdinalIgnoreCase) ||
               message.Contains("serviceNotAvailable", StringComparison.OrdinalIgnoreCase);
    }

    private async Task<byte[]> GraphAsync(HttpMethod method, string path, HttpContent? content, CancellationToken token)
    {
        await RefreshAsync(token);
        using var request = new HttpRequestMessage(method, "https://graph.microsoft.com" + path) { Content = content };
        request.Headers.Authorization = new("Bearer", credential.AccessToken);
        if (content is not null) content.Headers.ContentType = new("application/json");
        var response = await http.SendAsync(request, token);
        var data = await response.Content.ReadAsByteArrayAsync(token);
        Ensure(response, data, $"Microsoft Graph {method.Method} {path} failed");
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
    private static string Base64Url(byte[] data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static string Query(Dictionary<string, string> values) => string.Join("&", values.Select(value => $"{Uri.EscapeDataString(value.Key)}={Uri.EscapeDataString(value.Value)}"));
    private static Dictionary<string, string> ParseQuery(string query) => query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries).Select(value => value.Split('=', 2)).ToDictionary(value => Uri.UnescapeDataString(value[0]), value => Uri.UnescapeDataString(value.ElementAtOrDefault(1)?.Replace('+', ' ') ?? ""));
    private static void Ensure(HttpResponseMessage response, byte[] data, string fallback)
    {
        if (response.IsSuccessStatusCode) return;
        var detail = ApiError(data);
        throw new InvalidOperationException(detail is null ? $"{fallback} ({(int)response.StatusCode})" : $"{fallback} ({(int)response.StatusCode}): {detail}");
    }
    private static string? ApiError(byte[] data) { try { var root = JsonDocument.Parse(data).RootElement; if (root.TryGetProperty("error_description", out var description)) return description.GetString(); if (root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object && error.TryGetProperty("message", out var message)) return message.GetString(); } catch { } return null; }

    private sealed record TokenResponse([property: JsonPropertyName("access_token")] string AccessToken, [property: JsonPropertyName("refresh_token")] string? RefreshToken, [property: JsonPropertyName("expires_in")] int ExpiresIn);
    private sealed record OneDriveFile([property: JsonPropertyName("id")] string ID, [property: JsonPropertyName("name")] string Name, [property: JsonPropertyName("lastModifiedDateTime")] DateTimeOffset? LastModifiedDateTime);
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
            var tokenItems = new Dictionary<string, string>
            {
                ["client_id"] = CloudConfiguration.GoogleClientID, ["code"] = values["code"],
                ["code_verifier"] = verifier, ["grant_type"] = "authorization_code", ["redirect_uri"] = redirect
            };
            if (!string.IsNullOrWhiteSpace(CloudConfiguration.GoogleClientSecret)) tokenItems["client_secret"] = CloudConfiguration.GoogleClientSecret;
            var response = await http.PostAsync("https://oauth2.googleapis.com/token", new FormUrlEncodedContent(tokenItems), token);
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
        var url = "https://www.googleapis.com/drive/v3/files?" + Query(new() { ["spaces"] = "appDataFolder", ["fields"] = "files(id,name,modifiedTime)", ["pageSize"] = "1000", ["q"] = "trashed = false" });
        var data = await AuthorizedAsync(HttpMethod.Get, url, null, token);
        return (JsonSerializer.Deserialize<GoogleFileList>(data, JsonOptions.Default)?.Files ?? []).Select(value => new RemoteFile(value.ID, value.Name, value.ModifiedTime)).ToList();
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

    public async Task<IReadOnlyList<RemoteFile>> ListFolderAsync(string folder, CancellationToken token)
    {
        var folderID = await EnsureFolderAsync(folder, token); var query = $"'{folderID}' in parents and trashed = false";
        var url = "https://www.googleapis.com/drive/v3/files?" + Query(new() { ["spaces"] = "appDataFolder", ["fields"] = "files(id,name)", ["pageSize"] = "1000", ["q"] = query });
        var data = await AuthorizedAsync(HttpMethod.Get, url, null, token);
        return (JsonSerializer.Deserialize<GoogleFileList>(data, JsonOptions.Default)?.Files ?? []).Select(value => new RemoteFile(value.ID, value.Name)).ToList();
    }

    public async Task UploadFolderAsync(string folder, string name, byte[] data, string? existingID, CancellationToken token)
    {
        if (existingID is not null) { var replacement = new ByteArrayContent(data); replacement.Headers.ContentType = new("application/octet-stream"); _ = await AuthorizedAsync(HttpMethod.Patch, $"https://www.googleapis.com/upload/drive/v3/files/{Uri.EscapeDataString(existingID)}?uploadType=media", replacement, token); return; }
        var parent = await EnsureFolderAsync(folder, token); var boundary = "stg-" + Guid.NewGuid().ToString("N"); var multipart = new MultipartContent("related", boundary);
        multipart.Add(new StringContent(JsonSerializer.Serialize(new { name, parents = new[] { parent } }), Encoding.UTF8, "application/json")); var payload = new ByteArrayContent(data); payload.Headers.ContentType = new("application/octet-stream"); multipart.Add(payload);
        _ = await AuthorizedAsync(HttpMethod.Post, "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart", multipart, token);
    }

    public async Task DeleteAsync(string id, CancellationToken token) => _ = await AuthorizedAsync(HttpMethod.Delete, $"https://www.googleapis.com/drive/v3/files/{Uri.EscapeDataString(id)}", null, token);

    private async Task<string> EnsureFolderAsync(string name, CancellationToken token)
    {
        var escaped = name.Replace("'", "\\'"); var q = $"name = '{escaped}' and mimeType = 'application/vnd.google-apps.folder' and 'appDataFolder' in parents and trashed = false";
        var url = "https://www.googleapis.com/drive/v3/files?" + Query(new() { ["spaces"] = "appDataFolder", ["fields"] = "files(id,name)", ["q"] = q });
        var data = await AuthorizedAsync(HttpMethod.Get, url, null, token); var existing = JsonSerializer.Deserialize<GoogleFileList>(data, JsonOptions.Default)?.Files?.FirstOrDefault(); if (existing is not null) return existing.ID;
        var metadata = new StringContent(JsonSerializer.Serialize(new { name, mimeType = "application/vnd.google-apps.folder", parents = new[] { "appDataFolder" } }), Encoding.UTF8, "application/json");
        data = await AuthorizedAsync(HttpMethod.Post, "https://www.googleapis.com/drive/v3/files?fields=id,name", metadata, token);
        return JsonSerializer.Deserialize<GoogleFile>(data, JsonOptions.Default)?.ID ?? throw new InvalidDataException("Google Drive did not return the history folder ID");
    }

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
        var tokenItems = new Dictionary<string, string>
        {
            ["client_id"] = CloudConfiguration.GoogleClientID,
            ["refresh_token"] = credential.RefreshToken, ["grant_type"] = "refresh_token"
        };
        if (!string.IsNullOrWhiteSpace(CloudConfiguration.GoogleClientSecret)) tokenItems["client_secret"] = CloudConfiguration.GoogleClientSecret;
        var response = await http.PostAsync("https://oauth2.googleapis.com/token", new FormUrlEncodedContent(tokenItems), token);
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
    private sealed record GoogleFile([property: JsonPropertyName("id")] string ID, [property: JsonPropertyName("name")] string Name, [property: JsonPropertyName("modifiedTime")] DateTimeOffset? ModifiedTime);
    private sealed record GoogleFileList([property: JsonPropertyName("files")] List<GoogleFile> Files);
    private sealed record GoogleProfile(string? Name, string? Email);
}
