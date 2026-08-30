using Microsoft.Win32;
using System.Drawing;
using WinForms = System.Windows.Forms;

namespace ScreenTimeGuardian;

internal sealed class TrayAppContext : IDisposable
{
    private readonly string dataFolder;
    private readonly SettingsStore settingsStore;
    private readonly BitmapRepository repository;
    private readonly DiagnosticLog log;
    private readonly WinForms.NotifyIcon tray;
    private readonly WinForms.Timer timer;
    private DashboardForm? dashboard;
    private bool screenAvailable = true;
    private bool syncInProgress;
    private bool disposed;
    private int continuous;
    private DateTimeOffset lastEye = DateTimeOffset.MinValue, lastPosture = DateTimeOffset.MinValue;
    private string? lastReminder;

    public AppSettings Settings { get; private set; }
    public int LocalMinutes { get; private set; }
    public int AllMinutes { get; private set; }
    public string SyncStatus { get; private set; } = "Sync off";
    public event EventHandler? StateChanged;

    public TrayAppContext()
    {
        dataFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ScreenTimeGuardian");
        settingsStore = new(dataFolder); log = new(dataFolder); Settings = settingsStore.Load();
        repository = new(Path.Combine(dataFolder, "stg.sqlite"));
        repository.UpsertDevice(new(Settings.DeviceID, Settings.DeviceName, Settings.DeviceKind, Settings.UpdatedAt));
        var reminderState = repository.LoadReminderState(Settings.DeviceID);
        lastEye = reminderState.LastEyeAt; lastPosture = reminderState.LastPostureAt; lastReminder = reminderState.LastReminder;

        var menu = new WinForms.ContextMenuStrip { Font = new Font("Segoe UI", 10) };
        Add(menu, "Open Screen Time Guardian", ShowMain); Add(menu, "Today's report", ShowReport); Add(menu, "OpenRouter tracking", ShowTracking);
        menu.Items.Add(new WinForms.ToolStripSeparator()); Add(menu, "Sync now", () => _ = SyncAsync()); Add(menu, "Settings", ShowSettings); Add(menu, "Export test log", () => ExportTestLog(dashboard)); Add(menu, "About", ShowAbout);
        menu.Items.Add(new WinForms.ToolStripSeparator()); Add(menu, "Quit", Exit);
        var applicationIcon = Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? "") ?? SystemIcons.Shield;
        tray = new WinForms.NotifyIcon { Text = "Screen Time Guardian", Icon = applicationIcon, Visible = true, ContextMenuStrip = menu };
        tray.DoubleClick += (_, _) => ShowMain();
        SystemEvents.SessionSwitch += OnSessionSwitch; SystemEvents.PowerModeChanged += OnPowerModeChanged;
        timer = new() { Interval = 60_000, Enabled = true }; timer.Tick += (_, _) => Tick();
        RefreshSyncStatus(); RefreshTotals();
        log.Record("lifecycle", $"launch; repository=ready; provider={Settings.SyncProvider}; device={ShortDeviceID}; ui=wpf");
        log.Record("reminder", $"state restored; last={lastReminder ?? "none"}; last_eye={lastEye:O}; last_posture={lastPosture:O}");
        Tick(); if (Settings.SyncProvider != SyncProvider.None) _ = SyncAsync();
    }

    public string ProviderAccountLabel(SyncProvider provider) => provider switch { SyncProvider.ICloudDrive => ICloudDriveClient.AccountLabel, SyncProvider.OneDrive => OneDriveClient.AccountLabel, SyncProvider.GoogleDrive => GoogleDriveClient.AccountLabel, _ => "Single-device mode" };
    public bool ProviderSignedIn(SyncProvider provider) => provider switch { SyncProvider.ICloudDrive => ICloudDriveClient.IsAvailable, SyncProvider.OneDrive => OneDriveClient.IsSignedIn, SyncProvider.GoogleDrive => GoogleDriveClient.IsSignedIn, _ => false };
    public MeetingDetectionResult CheckMeetingNow()
    {
        var result = MeetingDetector.Check();
        log.Record("meeting", $"detection check; automatic={result.IsMeeting}; reason={(result.IsMeeting ? string.Join("; ", result.Reasons) : "no microphone or camera activity")}"); return result;
    }

    public void ShowMain() { dashboard ??= new(this); if (!dashboard.IsVisible) dashboard.Show(); if (dashboard.WindowState == System.Windows.WindowState.Minimized) dashboard.WindowState = System.Windows.WindowState.Normal; dashboard.Activate(); }
    public void ShowReport() { var window = new ReportForm(this) { Owner = VisibleDashboard }; window.Show(); }
    public void ShowSettings() { var window = new SettingsForm(this) { Owner = VisibleDashboard }; window.ShowDialog(); }
    public void ShowTracking() { var window = new TrackingForm(this) { Owner = VisibleDashboard }; window.Show(); }
    public void ShowAbout() { var window = new AboutForm(this) { Owner = VisibleDashboard }; window.ShowDialog(); }
    private DashboardForm? VisibleDashboard => dashboard?.IsVisible == true ? dashboard : null;

    public async Task SignInAsync(SyncProvider provider, System.Windows.Window? owner)
    {
        if (provider == SyncProvider.None) return;
        Settings.SyncProvider = provider; SaveSettings();
        SyncStatus = provider switch { SyncProvider.ICloudDrive => "Checking iCloud for Windows…", SyncProvider.OneDrive => "Opening Microsoft sign-in…", _ => "Opening Google sign-in…" };
        log.Record("sync", $"sign-in begin; provider={provider}"); Changed();
        try
        {
            if (provider == SyncProvider.ICloudDrive)
            {
                log.Record("sync", $"iCloud discovery; {ICloudDriveClient.DiscoverySummary()}");
                _ = ICloudDriveClient.Connect();
            }
            else if (provider == SyncProvider.OneDrive) await OneDriveClient.SignInAsync(owner);
            else await GoogleDriveClient.SignInAsync();
            SyncStatus = $"{ProviderName(provider)} connected as {ProviderAccountLabel(provider)}";
            log.Record("sync", $"sign-in complete; provider={provider}; account=authorized"); Changed(); _ = SyncAsync();
        }
        catch (OperationCanceledException) { SyncStatus = $"{ProviderName(provider)} sign-in cancelled"; log.Record("sync", $"sign-in cancelled; provider={provider}"); }
        catch (Exception error) { SyncStatus = $"Sign-in failed: {error.Message}"; log.Record("sync", $"sign-in failed; provider={provider}; error={error.Message}"); }
        Changed();
    }

    public void SignOut(SyncProvider provider)
    {
        if (provider == SyncProvider.OneDrive) OneDriveClient.SignOut();
        if (provider == SyncProvider.GoogleDrive) GoogleDriveClient.SignOut();
        log.Record("sync", $"signed out; provider={provider}"); RefreshSyncStatus(); Changed();
    }

    public async Task SyncAsync()
    {
        if (syncInProgress) { log.Record("sync", "sync request coalesced; another sync is running"); return; }
        if (Settings.SyncProvider == SyncProvider.None) { SyncStatus = "Sync off — choose iCloud Drive, OneDrive, or Google Drive in Settings"; log.Record("sync", "sync skipped; provider=None"); Changed(); return; }
        if (!ProviderSignedIn(Settings.SyncProvider)) { SyncStatus = $"{ProviderName(Settings.SyncProvider)} account sign-in required"; log.Record("sync", $"sync blocked; provider={Settings.SyncProvider}; account_not_signed_in"); Changed(); return; }
        syncInProgress = true; SyncStatus = $"Syncing {ProviderName(Settings.SyncProvider)}…"; log.Record("sync", $"sync begin; provider={Settings.SyncProvider}; local_device={ShortDeviceID}"); Changed();
        try
        {
            IPrivateCloudDrive drive = Settings.SyncProvider switch { SyncProvider.ICloudDrive => ICloudDriveClient.Connect(), SyncProvider.OneDrive => OneDriveClient.FromStore(), _ => GoogleDriveClient.FromStore() };
            var result = await new PrivateCloudSync(repository, Settings, drive).IncrementalAsync();
            var discovered = string.Join(',', result.Devices.Select(value => value[..Math.Min(8, value.Length)]).Order());
            SyncStatus = $"Synced · {result.Uploaded} uploaded, {result.Downloaded} downloaded";
            var cursors = string.Join(',', result.DownloadCursors.OrderBy(value => value.Key).Select(value => $"{value.Key[..Math.Min(8, value.Key.Length)]}={value.Value}"));
            log.Record("sync", $"sync complete; provider={Settings.SyncProvider}; uploaded={result.Uploaded}; downloaded={result.Downloaded}; upload_cursor={result.UploadCursor ?? "none"}; discovered=[{discovered}]; download_cursors=[{cursors}]"); RefreshTotals();
            await RunWeeklyActionIfDueAsync();
        }
        catch (Exception error) { SyncStatus = $"Sync failed: {error.Message}"; log.Record("sync", $"sync failed; provider={Settings.SyncProvider}; error={error.Message}"); }
        finally { syncInProgress = false; Changed(); }
    }

    public void SaveSettings()
    {
        Settings.DeviceName = Environment.MachineName;
        settingsStore.Save(Settings); repository.UpsertDevice(new(Settings.DeviceID, Settings.DeviceName, Settings.DeviceKind, Settings.UpdatedAt)); ConfigureStartup(); RefreshSyncStatus(); RefreshTotals();
        log.Record("settings", $"saved; plan={Settings.DailyPlanMinutes}m; timezone={Settings.ReportTimeZone}; provider={Settings.SyncProvider}; meeting={Settings.MeetingMode}"); Changed();
    }

    public void ExportTestLog(System.Windows.Window? owner)
    {
        try
        {
            var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "Log files (*.log)|*.log", FileName = $"STG-test-log-{DateTime.Now:yyyyMMdd-HHmmss}.log" };
            if (dialog.ShowDialog(owner) != true) return;
            File.Copy(log.ExportCopy(), dialog.FileName, true); SyncStatus = $"Test log exported to {dialog.FileName}"; Changed();
        }
        catch (Exception error) { System.Windows.MessageBox.Show(owner, error.Message, "Could not export test log", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Error); }
    }

    private void Tick()
    {
        var now = DateTimeOffset.Now; var previous = now.AddMinutes(-1);
        var previousSet = repository.Bitmap(Settings.DeviceID, TimeModel.UtcDate(previous))[TimeModel.UtcMinute(previous)];
        if (!screenAvailable) { continuous = 0; return; }
        var newlyMarked = repository.Mark(Settings.DeviceID, now); repository.RebuildAll(TimeModel.UtcDate(now)); continuous = previousSet ? continuous + 1 : 1; RefreshTotals();
        log.Record("record", $"active minute sample; utc_date={TimeModel.UtcDate(now)}; utc_minute={TimeModel.UtcMinute(now)}; newly_marked={newlyMarked}; continuous={continuous}m; local={LocalMinutes}m; all={AllMinutes}m");
        if (continuous < 20) { Changed(); return; }
        continuous = 0; var priorReminder = lastReminder ?? "none"; var followsEyeReminder = lastReminder == "eye"; string? kind = null;
        if (followsEyeReminder)
        {
            if (AllMinutes > Settings.DailyPlanMinutes) { lastEye = now; lastPosture = now; lastReminder = "posture"; kind = "daily"; }
            else if ((now - lastPosture).TotalMinutes >= 37) { lastEye = now; lastPosture = now; lastReminder = "posture"; kind = "posture"; }
        }
        else
        {
            if (AllMinutes > Settings.DailyPlanMinutes) { lastEye = now; lastPosture = now; lastReminder = "eye"; kind = "daily"; }
            else if ((now - lastEye).TotalMinutes >= 17) { lastEye = now; lastReminder = "eye"; kind = "eye"; }
        }
        if (kind is not null)
        {
            repository.SaveReminderState(Settings.DeviceID, new(lastEye, lastPosture, lastReminder), now);
            var automaticMeeting = CheckMeetingNow(); var meetingMode = Settings.MeetingMode || automaticMeeting.IsMeeting;
            var meetingReason = Settings.MeetingMode ? "manual setting" : automaticMeeting.IsMeeting ? string.Join("; ", automaticMeeting.Reasons) : "no microphone or camera activity";
            log.Record("meeting", $"check at reminder; manual={Settings.MeetingMode}; automatic={automaticMeeting.IsMeeting}; effective={meetingMode}; reason={meetingReason}");
            log.Record("reminder", $"reminder; kind={kind}; previous_slot={priorReminder}; next_slot={lastReminder}; all_used={AllMinutes}m; local_used={LocalMinutes}m; silent={meetingMode}");
            new ReminderForm(kind, AllMinutes, Settings, meetingMode).Show();
            log.Record("sync", $"incremental sync requested; trigger=reminder; kind={kind}");
            _ = SyncAsync();
        }
        else log.Record("reminder", $"20m block complete; no reminder due; previous_slot={priorReminder}; all_used={AllMinutes}m");
        Changed();
    }

    private void RefreshTotals()
    {
        LocalMinutes = repository.LocalDayMinutes(Settings.DeviceID, DateTimeOffset.Now, Settings.ReportTimeZone);
        foreach (var date in TimeModel.LocalDayMinutes(DateTimeOffset.Now, Settings.ReportTimeZone).Select(TimeModel.UtcDate).Distinct()) repository.RebuildAll(date);
        AllMinutes = repository.LocalDayMinutes("alldevices", DateTimeOffset.Now, Settings.ReportTimeZone);
    }

    public IReadOnlyList<DeviceDayReport> TodayReport() => ReportForDate(TimeModel.LocalDate(DateTimeOffset.Now, Settings.ReportTimeZone));

    public IReadOnlyList<DeviceDayReport> ReportForDate(DateOnly date)
    {
        var zone = Settings.ReportTimeZone; var instant = TimeModel.LocalDateInstant(date, zone);
        log.Record("report", $"refresh begin; date={date:yyyy-MM-dd}; timezone={zone}; sync_enabled={Settings.SyncProvider != SyncProvider.None}; local_device={ShortDeviceID}");
        repository.UpsertDevice(new(Settings.DeviceID, Settings.DeviceName, Settings.DeviceKind, Settings.UpdatedAt));
        foreach (var utcDate in TimeModel.LocalDayMinutes(instant, zone).Select(TimeModel.UtcDate).Distinct()) repository.RebuildAll(utcDate);
        var names = repository.Devices();
        var result = new List<DeviceDayReport> { new("alldevices", "All devices", repository.LocalClockDayBitmap("alldevices", instant, zone), repository.LocalDayMinutes("alldevices", instant, zone), true) };
        foreach (var id in repository.DeviceIDs())
        {
            var name = id.Equals(Settings.DeviceID, StringComparison.OrdinalIgnoreCase) ? Settings.DeviceName : names.GetValueOrDefault(id)?.Name ?? "Other device";
            result.Add(new(id, name, repository.LocalClockDayBitmap(id, instant, zone), repository.LocalDayMinutes(id, instant, zone), false));
        }
        log.Record("report", $"refresh complete; {string.Join(',', result.Select(value => $"{value.DeviceID[..Math.Min(8, value.DeviceID.Length)]}={value.UsedMinutes}m"))}"); return result;
    }

    public IReadOnlyList<DailyUsagePoint> MultiDayReport(DateOnly start, DateOnly end)
    {
        if (end < start) (start, end) = (end, start);
        var result = new List<DailyUsagePoint>();
        for (var date = start; date <= end; date = date.AddDays(1))
            result.AddRange(ReportForDate(date).Select(value => new DailyUsagePoint(date, value.DeviceID, value.DisplayName, value.UsedMinutes, value.IsAggregate)));
        log.Record("report", $"multi-day complete; start={start:yyyy-MM-dd}; end={end:yyyy-MM-dd}; points={result.Count}; series={result.Select(value => value.DeviceID).Distinct().Count()}");
        return result;
    }

    public IReadOnlyList<WeeklyRankingRow> OpenRouterWeeks(IEnumerable<string> models) => repository.OpenRouterWeeks(models);
    public IReadOnlyList<string> LatestOpenRouterTopModels() => repository.LatestOpenRouterTopModels();
    public void TrackingLog(string message) => log.Record("tracking", message);

    private async Task RunWeeklyActionIfDueAsync(CancellationToken cancellationToken = default)
    {
        if (!repository.WeeklyActionDue(DateTimeOffset.UtcNow)) return;
        try
        {
            var today = DateOnly.FromDateTime(DateTime.UtcNow); var daysSinceMonday = ((int)today.DayOfWeek + 6) % 7; var previousSunday = today.AddDays(-daysSinceMonday - 1);
            var totalCursor = repository.LatestOpenRouterWeekEnd(); var start = DateOnly.TryParse(totalCursor, out var latestDate) ? latestDate.AddDays(1) : new DateOnly(2025, 1, 1);
            log.Record("sync", $"weekly action begin; openrouter_start={start:yyyy-MM-dd}; openrouter_end={previousSunday:yyyy-MM-dd}; latest_week_cursor={totalCursor ?? "none"}");
            IReadOnlyList<WeeklyRankingRow> rows = start > previousSunday ? [] : await new OpenRouterClient().WeeklyHistoryAsync(start, previousSunday, cancellationToken);
            if (start <= previousSunday && rows.Count == 0) throw new InvalidDataException("OpenRouter returned no weekly model-activity rows; detail cursor was not advanced");
            repository.UpsertOpenRouterWeeks(rows); repository.CompleteOpenRouterDetailWeek(previousSunday.ToString("yyyy-MM-dd")); repository.CompleteWeeklyAction(DateTimeOffset.UtcNow);
            log.Record("sync", $"weekly action complete; openrouter_rows={rows.Count}; weeks={rows.Select(value => value.WindowStart).Distinct().Count()}; completed_at={DateTimeOffset.UtcNow:O}");
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error) { log.Record("sync", $"weekly action failed; completion_not_recorded=true; error={error.Message}"); }
    }

    private void RefreshSyncStatus() => SyncStatus = Settings.SyncProvider switch { SyncProvider.None => "Sync off — choose a provider in Settings", SyncProvider.ICloudDrive when !ProviderSignedIn(Settings.SyncProvider) => "iCloud for Windows setup required", _ when !ProviderSignedIn(Settings.SyncProvider) => $"{ProviderName(Settings.SyncProvider)} account sign-in required", SyncProvider.ICloudDrive => "iCloud Drive connected through iCloud for Windows", _ => $"{ProviderName(Settings.SyncProvider)} connected as {ProviderAccountLabel(Settings.SyncProvider)}" };
    private void OnSessionSwitch(object sender, SessionSwitchEventArgs e) { screenAvailable = e.Reason is not (SessionSwitchReason.SessionLock or SessionSwitchReason.SessionLogoff or SessionSwitchReason.ConsoleDisconnect); log.Record("lifecycle", $"session switch; reason={e.Reason}; screen_available={screenAvailable}"); if (screenAvailable) _ = SyncAsync(); }
    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e) { screenAvailable = e.Mode != PowerModes.Suspend; log.Record("lifecycle", $"power mode={e.Mode}; screen_available={screenAvailable}"); if (e.Mode == PowerModes.Resume) _ = SyncAsync(); }
    private void ConfigureStartup() { using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true); if (Settings.LaunchAtLogin) key?.SetValue("ScreenTimeGuardian", $"\"{Environment.ProcessPath}\""); else key?.DeleteValue("ScreenTimeGuardian", false); }
    internal static string ProviderName(SyncProvider provider) => provider switch { SyncProvider.ICloudDrive => "iCloud Drive", SyncProvider.OneDrive => "OneDrive", SyncProvider.GoogleDrive => "Google Drive", _ => "Off" };
    private string ShortDeviceID => Settings.DeviceID[..Math.Min(8, Settings.DeviceID.Length)];
    private static void Add(WinForms.ContextMenuStrip menu, string text, Action action) { var item = menu.Items.Add(text); item.Click += (_, _) => action(); }
    private void Changed() => System.Windows.Application.Current.Dispatcher.InvokeAsync(() => StateChanged?.Invoke(this, EventArgs.Empty));
    private void Exit() { Dispose(); System.Windows.Application.Current.Shutdown(); }
    public void Dispose() { if (disposed) return; disposed = true; log.Record("lifecycle", "quit requested"); tray.Visible = false; tray.Dispose(); timer.Stop(); timer.Dispose(); SystemEvents.SessionSwitch -= OnSessionSwitch; SystemEvents.PowerModeChanged -= OnPowerModeChanged; repository.Dispose(); }
}
