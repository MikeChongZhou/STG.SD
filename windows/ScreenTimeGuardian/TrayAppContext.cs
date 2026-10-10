using Microsoft.Win32;
using System.Drawing;
using System.IO.Compression;
using System.Text.Json;
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
    private bool sessionAvailable = true;
    private bool powerAvailable = true;
    private bool syncInProgress;
    private bool quickUploadInProgress;
    private bool exitInProgress;
    private readonly List<string> syncWarnings = [];
    private CancellationTokenSource? activeSyncCancellation;
    private bool disposed;
    private int continuous;
    private DateTimeOffset lastEye = DateTimeOffset.MinValue, lastPosture = DateTimeOffset.MinValue;
    private string? lastReminder;
    private DateOnly reminderLocalDate;

    public AppSettings Settings { get; private set; }
    public int LocalMinutes { get; private set; }
    public int AllMinutes { get; private set; }
    public string SyncStatus { get; private set; } = "Sync off";
    public UsageStatisticsSummary StatisticsSummary { get; private set; } = new(null, null, null, null, null, false);
    public string CurrentReportTimeZone => TimeZoneInfo.Local.Id;
    public event EventHandler? StateChanged;

    public TrayAppContext()
    {
        dataFolder = AppDataLocation.Prepare();
        settingsStore = new(dataFolder); log = new(dataFolder); Settings = settingsStore.Load(); Settings.ReportTimeZone = CurrentReportTimeZone;
        repository = new(Path.Combine(dataFolder, "stg.sqlite"));
        repository.UpsertDevice(new(Settings.DeviceID, Settings.DeviceName, Settings.DeviceKind, Settings.UpdatedAt));
        var reminderState = repository.LoadReminderState(Settings.DeviceID);
        lastEye = reminderState.LastEyeAt; lastPosture = reminderState.LastPostureAt; lastReminder = reminderState.LastReminder;
        reminderLocalDate = DateOnly.FromDateTime(DateTime.Now);
        var lastReminderDate = DateOnly.FromDateTime((lastEye > lastPosture ? lastEye : lastPosture).LocalDateTime);
        if (lastReminderDate != reminderLocalDate)
        {
            lastReminder = "posture";
            repository.SaveReminderState(Settings.DeviceID, new(lastEye, lastPosture, lastReminder), DateTimeOffset.Now);
            log.Record("reminder", $"daily reminder slot reset; previous_date={lastReminderDate:yyyy-MM-dd}; local_date={reminderLocalDate:yyyy-MM-dd}; next_slot=posture");
        }

        var menu = new WinForms.ContextMenuStrip { Font = new Font("Segoe UI", 10) };
        Add(menu, L.T("Screen Time Guardian"), ShowMain); Add(menu, L.T("Report"), ShowReport); Add(menu, L.T("Tracking"), ShowTracking);
        menu.Items.Add(new WinForms.ToolStripSeparator()); Add(menu, L.T("Sync Now"), () => _ = SyncAsync()); Add(menu, L.T("Settings"), ShowSettings); Add(menu, L.T("About"), ShowAbout);
        menu.Items.Add(new WinForms.ToolStripSeparator()); Add(menu, "Remove app…", BeginUninstall); Add(menu, "Quit", Exit);
        var applicationIcon = Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? "") ?? SystemIcons.Shield;
        tray = new WinForms.NotifyIcon { Text = "Screen Time Guardian", Icon = applicationIcon, Visible = true, ContextMenuStrip = menu };
        tray.MouseDoubleClick += (_, eventArgs) => { if (eventArgs.Button == WinForms.MouseButtons.Left) { log.Record("lifecycle", "tray icon double-click; opening main window"); ShowMain(); } };
        timer = new() { Interval = 60_000, Enabled = true }; timer.Tick += (_, _) => Tick();
        SystemEvents.SessionSwitch += OnSessionSwitch; SystemEvents.PowerModeChanged += OnPowerModeChanged;
        RefreshSyncStatus(); RefreshTotals();
        log.Record("lifecycle", $"launch; repository=ready; provider={Settings.SyncProvider}; device={ShortDeviceID}; ui=wpf");
        log.Record("reminder", $"state restored; last={lastReminder ?? "none"}; last_eye={lastEye:O}; last_posture={lastPosture:O}");
        Tick(); if (Settings.SyncProvider != SyncProvider.None) _ = SyncAsync();
        if (!Settings.OnboardingComplete) System.Windows.Application.Current.Dispatcher.BeginInvoke(ShowOnboarding);
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
    public void ShowAbout() { var window = new AboutForm { Owner = VisibleDashboard }; window.ShowDialog(); }
    private void ShowOnboarding() { if (!Settings.OnboardingComplete) new OnboardingForm(this).ShowDialog(); }
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
        if (exitInProgress) { log.Record("sync", "sync skipped; application_exit_in_progress=true"); return; }
        if (syncInProgress) { log.Record("sync", "sync request coalesced; another sync is running"); return; }
        if (Settings.SyncProvider == SyncProvider.None) { SyncStatus = "Sync off — choose iCloud Drive, OneDrive, or Google Drive in Settings"; log.Record("sync", "sync skipped; provider=None"); Changed(); return; }
        if (!ProviderSignedIn(Settings.SyncProvider)) { SyncStatus = $"{ProviderName(Settings.SyncProvider)} account sign-in required"; log.Record("sync", $"sync blocked; provider={Settings.SyncProvider}; account_not_signed_in"); Changed(); return; }
        syncInProgress = true; syncWarnings.Clear(); SyncStatus = $"Connecting to {ProviderName(Settings.SyncProvider)}…"; log.Record("sync", $"sync begin; provider={Settings.SyncProvider}; local_device={ShortDeviceID}"); Changed();
        using var cancellation = new CancellationTokenSource(); activeSyncCancellation = cancellation;
        try
        {
            IPrivateCloudDrive drive = Settings.SyncProvider switch { SyncProvider.ICloudDrive => ICloudDriveClient.Connect(), SyncProvider.OneDrive => OneDriveClient.FromStore(), _ => GoogleDriveClient.FromStore() };
            var result = await new PrivateCloudSync(repository, Settings, drive).IncrementalAsync(cancellation.Token, ReportSyncProgress);
            repository.CompleteIncrementalSync(Settings.DeviceID);
            var discovered = string.Join(',', result.Devices.Select(value => value[..Math.Min(8, value.Length)]).Order());
            var completionStatus = $"Synced · {result.Uploaded} activity files uploaded, {result.Downloaded} downloaded";
            SyncStatus = completionStatus;
            var cursors = string.Join(',', result.DownloadCursors.OrderBy(value => value.Key).Select(value => $"{value.Key[..Math.Min(8, value.Key.Length)]}={value.Value}"));
            log.Record("sync", $"sync complete; provider={Settings.SyncProvider}; uploaded={result.Uploaded}; downloaded={result.Downloaded}; upload_cursor={result.UploadCursor ?? "none"}; discovered=[{discovered}]; download_cursors=[{cursors}]"); RefreshTotals();
            foreach (var warning in result.Warnings) log.Record("sync-warning", warning);
            await RunWeeklyActionIfDueAsync(cancellation.Token);
            SyncStatus = syncWarnings.Count == 0 ? completionStatus : completionStatus + " · " + string.Join(" · ", syncWarnings);
        }
        catch (OperationCanceledException) when (exitInProgress) { log.Record("sync", "active incremental sync cancelled; reason=application_quit"); }
        catch (Exception error) { SyncStatus = $"Sync failed: {error.Message}"; log.Record("sync", $"sync failed; provider={Settings.SyncProvider}; {DiagnosticLog.Describe(error)}"); }
        finally { if (ReferenceEquals(activeSyncCancellation, cancellation)) activeSyncCancellation = null; syncInProgress = false; if (!disposed) Changed(); }
    }

    private void ReportSyncProgress(string message)
    {
        SyncStatus = message;
        log.Record("sync-progress", $"provider={Settings.SyncProvider}; message={message}");
        Changed();
    }

    private async Task QuickUploadAsync(string trigger, CancellationToken cancellationToken = default)
    {
        if (disposed || quickUploadInProgress) return;
        if (syncInProgress) { log.Record("sync", $"quick upload covered by running incremental sync; trigger={trigger}"); return; }
        if (Settings.SyncProvider == SyncProvider.None || !ProviderSignedIn(Settings.SyncProvider)) { log.Record("sync", $"quick upload skipped; trigger={trigger}; provider={Settings.SyncProvider}; configured=false"); return; }
        quickUploadInProgress = true;
        try
        {
            IPrivateCloudDrive drive = Settings.SyncProvider switch { SyncProvider.ICloudDrive => ICloudDriveClient.Connect(), SyncProvider.OneDrive => OneDriveClient.FromStore(), _ => GoogleDriveClient.FromStore() };
            log.Record("sync", $"quick upload begin; trigger={trigger}; provider={Settings.SyncProvider}");
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); timeout.CancelAfter(TimeSpan.FromSeconds(8));
            var count = await new PrivateCloudSync(repository, Settings, drive).QuickUploadAsync(timeout.Token);
            log.Record("sync", $"quick upload complete; trigger={trigger}; provider={Settings.SyncProvider}; files={count}");
        }
        catch (OperationCanceledException) { log.Record("sync", $"quick upload cancelled; trigger={trigger}; provider={Settings.SyncProvider}; cancellation_requested=true"); }
        catch (Exception error) { log.Record("sync", $"quick upload failed; trigger={trigger}; provider={Settings.SyncProvider}; {DiagnosticLog.Describe(error)}"); }
        finally { quickUploadInProgress = false; }
    }

    public void SaveSettings()
    {
        Settings.DeviceName = Environment.MachineName;
        Settings.ReportTimeZone = CurrentReportTimeZone;
        settingsStore.Save(Settings); repository.UpsertDevice(new(Settings.DeviceID, Settings.DeviceName, Settings.DeviceKind, Settings.UpdatedAt)); ConfigureStartup(); RefreshSyncStatus(); RefreshTotals();
        log.Record("settings", $"saved; plan={Settings.DailyPlanMinutes}m; timezone={Settings.ReportTimeZone}; provider={Settings.SyncProvider}; meeting={Settings.MeetingMode}"); Changed();
    }

    public void ExportTestLog(System.Windows.Window? owner)
    {
        try
        {
            var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "Log files (*.log)|*.log", FileName = $"STG-test-log-{DateTime.Now:yyyyMMdd-HHmmss}.log" };
            if (dialog.ShowDialog(owner) != true) return;
            File.Copy(log.ExportCopy(), dialog.FileName, true); log.Clear(); SyncStatus = $"Test log exported to {dialog.FileName}"; Changed();
        }
        catch (Exception error) { System.Windows.MessageBox.Show(owner, error.Message, "Could not export test log", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Error); }
    }

    public void ExportData(System.Windows.Window? owner)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "STG data package (*.zip)|*.zip", FileName = $"STG-data-{DateTime.Now:yyyyMMdd-HHmmss}.zip" };
        if (dialog.ShowDialog(owner) != true) return;
        var temporary = Path.Combine(Path.GetTempPath(), $"stg-export-{Guid.NewGuid():N}"); Directory.CreateDirectory(temporary);
        try
        {
            repository.ExportDatabaseSnapshot(Path.Combine(temporary, "stg.sqlite"));
            File.WriteAllText(Path.Combine(temporary, "global-settings.json"), JsonSerializer.Serialize(Settings, JsonOptions.Default));
            if (File.Exists(dialog.FileName)) File.Delete(dialog.FileName); ZipFile.CreateFromDirectory(temporary, dialog.FileName, CompressionLevel.Optimal, false);
            log.Record("diagnostics", $"database and global data exported; destination={Path.GetFileName(dialog.FileName)}");
        }
        catch (Exception error) { System.Windows.MessageBox.Show(owner, error.Message, "Could not export data", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Error); }
        finally { try { Directory.Delete(temporary, true); } catch { } }
    }

    private void Tick()
    {
        var now = DateTimeOffset.Now; var previous = now.AddMinutes(-1);
        var today = DateOnly.FromDateTime(now.LocalDateTime);
        if (today != reminderLocalDate)
        {
            var previousDate = reminderLocalDate; reminderLocalDate = today; lastReminder = "posture";
            repository.SaveReminderState(Settings.DeviceID, new(lastEye, lastPosture, lastReminder), now);
            log.Record("reminder", $"daily reminder slot reset; previous_date={previousDate:yyyy-MM-dd}; local_date={today:yyyy-MM-dd}; next_slot=posture");
        }
        var previousSet = repository.Bitmap(Settings.DeviceID, TimeModel.UtcDate(previous))[TimeModel.UtcMinute(previous)];
        if (!screenAvailable) { continuous = 0; return; }
        var newlyMarked = repository.Mark(Settings.DeviceID, now); repository.RebuildAll(TimeModel.UtcDate(now)); continuous = previousSet ? continuous + 1 : 1; RefreshTotals();
        log.Record("record", $"active minute sample; utc_date={TimeModel.UtcDate(now)}; utc_minute={TimeModel.UtcMinute(now)}; newly_marked={newlyMarked}; continuous={continuous}m; local={LocalMinutes}m; all={AllMinutes}m");
        if (continuous < 20) { Changed(); return; }
        continuous = 0; var priorReminder = lastReminder ?? "none"; var followsEyeReminder = lastReminder == "eye"; string? kind = null;
        if (followsEyeReminder)
        {
            if (Settings.DailyNotificationsEnabled && AllMinutes > Settings.DailyPlanMinutes) { lastEye = now; lastPosture = now; lastReminder = "posture"; kind = "daily"; }
            else if (Settings.PostureNotificationsEnabled && (now - lastPosture).TotalMinutes >= 37) { lastEye = now; lastPosture = now; lastReminder = "posture"; kind = "posture"; }
            else if (!Settings.PostureNotificationsEnabled) lastReminder = "posture";
        }
        else
        {
            if (Settings.DailyNotificationsEnabled && AllMinutes > Settings.DailyPlanMinutes) { lastEye = now; lastPosture = now; lastReminder = "eye"; kind = "daily"; }
            else if (Settings.EyeNotificationsEnabled && (now - lastEye).TotalMinutes >= 17) { lastEye = now; lastReminder = "eye"; kind = "eye"; }
            else if (!Settings.EyeNotificationsEnabled) lastReminder = "eye";
        }
        if (kind is null && lastReminder != priorReminder) repository.SaveReminderState(Settings.DeviceID, new(lastEye, lastPosture, lastReminder), now);
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
        var zone = CurrentReportTimeZone;
        LocalMinutes = repository.LocalDayMinutes(Settings.DeviceID, DateTimeOffset.Now, zone);
        foreach (var date in TimeModel.LocalDayMinutes(DateTimeOffset.Now, zone).Select(TimeModel.UtcDate).Distinct()) repository.RebuildAll(date);
        AllMinutes = repository.LocalDayMinutes("alldevices", DateTimeOffset.Now, zone);
        repository.UpdateRuntimeState(Settings.DeviceID, continuous, LocalMinutes, AllMinutes, TimeModel.LocalDate(DateTimeOffset.Now, zone));
    }

    public IReadOnlyList<DeviceDayReport> TodayReport() => ReportForDate(TimeModel.LocalDate(DateTimeOffset.Now, CurrentReportTimeZone));

    public IReadOnlyList<DeviceDayReport> ReportForDate(DateOnly date)
    {
        var zone = CurrentReportTimeZone; var instant = TimeModel.LocalDateInstant(date, zone);
        log.Record("report", $"refresh begin; date={date:yyyy-MM-dd}; timezone={zone}; sync_enabled={Settings.SyncProvider != SyncProvider.None}; local_device={ShortDeviceID}");
        repository.UpsertDevice(new(Settings.DeviceID, Settings.DeviceName, Settings.DeviceKind, Settings.UpdatedAt));
        var refreshed = repository.RefreshStatistics(Settings);
        StatisticsSummary = repository.StatisticsSummary(DateTimeOffset.Now, zone);
        log.Record("statistics", $"incremental refresh complete; start={refreshed.Start:yyyy-MM-dd}; end={refreshed.End:yyyy-MM-dd}; last_statistics_at={DateTimeOffset.UtcNow:O}");
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
        var refreshed = repository.RefreshStatistics(Settings);
        StatisticsSummary = repository.StatisticsSummary(DateTimeOffset.Now, CurrentReportTimeZone);
        var result = repository.DailyStatistics(start, end).Select(value => new DailyUsagePoint(value.Date, value.DeviceID, value.DisplayName, value.Minutes, value.IsAggregate, value.Estimated)).ToList();
        log.Record("statistics", $"incremental refresh complete; start={refreshed.Start:yyyy-MM-dd}; end={refreshed.End:yyyy-MM-dd}; trigger=multi_day");
        log.Record("report", $"multi-day complete; start={start:yyyy-MM-dd}; end={end:yyyy-MM-dd}; points={result.Count}; series={result.Select(value => value.DeviceID).Distinct().Count()}");
        return result;
    }

    public IReadOnlyList<PeriodUsagePoint> PeriodReport(string kind, DateOnly start, DateOnly end)
    {
        var refreshed = repository.RefreshStatistics(Settings);
        StatisticsSummary = repository.StatisticsSummary(DateTimeOffset.Now, CurrentReportTimeZone);
        var result = repository.PeriodUsage(kind, start, end);
        log.Record("report", $"period report complete; kind={kind}; start={start:yyyy-MM-dd}; end={end:yyyy-MM-dd}; points={result.Count}; statistics_refresh={refreshed.Start:yyyy-MM-dd}..{refreshed.End:yyyy-MM-dd}");
        return result;
    }

    public bool IsEstimatedReport(string deviceID = "alldevices") => repository.ReportIncludesEstimatedIos(deviceID);

    public IReadOnlyList<WeeklyRankingRow> OpenRouterWeeks(IEnumerable<string> models) => repository.OpenRouterWeeks(models);
    public IReadOnlyList<string> LatestOpenRouterTopModels(WeeklyMetric metric) => repository.LatestOpenRouterTopModels(metric);
    public string LatestTrackingTopTwo { get { var names = repository.LatestOpenRouterTopModels(WeeklyMetric.TotalTokens, 2); return names.Count == 0 ? "Weekly data will appear after sync." : string.Join(Environment.NewLine, names.Select((name, index) => $"{index + 1}. {name}")); } }
    public void TrackingLog(string message) => log.Record("tracking", message);

    private async Task RunWeeklyActionIfDueAsync(CancellationToken cancellationToken = default)
    {
        var now = DateTimeOffset.UtcNow;
        var cloudDue = repository.WeeklyCloudActionDue(now);
        var today = DateOnly.FromDateTime(now.UtcDateTime); var daysSinceMonday = ((int)today.DayOfWeek + 6) % 7; var previousSunday = today.AddDays(-daysSinceMonday - 1);
        var totalCursor = repository.LatestOpenRouterWeekEnd(); var start = DateOnly.TryParse(totalCursor, out var latestDate) ? latestDate.AddDays(1) : new DateOnly(2025, 1, 1);
        var trackingDue = start <= previousSunday;
        if (!cloudDue && !trackingDue) return;
        log.Record("sync", $"weekly action begin; cloud_due={cloudDue}; tracking_due={trackingDue}; openrouter_start={start:yyyy-MM-dd}; openrouter_end={previousSunday:yyyy-MM-dd}; latest_week_cursor={totalCursor ?? "none"}");
        IPrivateCloudDrive? drive = null;
        if (cloudDue)
        {
            ReportSyncProgress("Updating weekly archive…");
            try
            {
                drive = Settings.SyncProvider switch { SyncProvider.ICloudDrive => ICloudDriveClient.Connect(), SyncProvider.OneDrive => OneDriveClient.FromStore(), _ => GoogleDriveClient.FromStore() };
                var monday = previousSunday.AddDays(-6); var maintenance = await new PrivateCloudSync(repository, Settings, drive).WeeklyMaintenanceAsync(monday.AddDays(7), monday, previousSunday, cancellationToken);
                repository.CompleteWeeklyAction(DateTimeOffset.UtcNow); repository.CompleteWeeklyActionState(Settings.DeviceID);
                log.Record("sync", $"weekly cloud maintenance complete; bitmap_uploaded={maintenance.Uploaded}; daily_deleted={maintenance.DeletedDaily}; weekly_moved={maintenance.MovedWeekly}; history_ready=true; completed_at={DateTimeOffset.UtcNow:O}");
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception error) { syncWarnings.Add("Weekly archive failed"); log.Record("sync", $"weekly cloud maintenance failed; completion_not_recorded=true; {DiagnosticLog.Describe(error)}"); }
        }
        if (trackingDue)
        {
            ReportSyncProgress("Updating tracking data…");
            try
            {
                var rows = await new OpenRouterClient().WeeklyHistoryAsync(start, previousSunday, cancellationToken);
                if (rows.Count == 0) throw new InvalidDataException("OpenRouter returned no weekly model-activity rows; detail cursor was not advanced");
                repository.UpsertOpenRouterWeeks(rows); repository.CompleteOpenRouterDetailWeek(previousSunday.ToString("yyyy-MM-dd"));
                log.Record("sync", $"weekly tracking complete; openrouter_rows={rows.Count}; weeks={rows.Select(value => value.WindowStart).Distinct().Count()}; completion_recorded=true");
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception error) { syncWarnings.Add("Tracking update failed"); log.Record("sync", $"weekly tracking failed; completion_not_recorded=true; start={start:yyyy-MM-dd}; end={previousSunday:yyyy-MM-dd}; {DiagnosticLog.Describe(error)}"); }
        }
        if (drive is not null) await RunYearlyActionIfDueAsync(drive, cancellationToken);
    }

    private async Task RunYearlyActionIfDueAsync(IPrivateCloudDrive drive, CancellationToken cancellationToken)
    {
        if (!repository.YearlyActionDue(Settings.DeviceID)) return;
        var year = DateTimeOffset.UtcNow.Year - 1; var cleanupYear = year - 1;
        try
        {
            var start = new DateOnly(year, 1, 1); var end = new DateOnly(year, 12, 31);
            var rows = await new OpenRouterClient().WeeklyHistoryAsync(start, end, cancellationToken); if (rows.Count > 0) repository.UpsertOpenRouterWeeks(rows);
            var result = await new PrivateCloudSync(repository, Settings, drive).YearlyMaintenanceAsync(year, cleanupYear, cancellationToken);
            repository.CompleteYearlyAction(Settings.DeviceID);
            log.Record("sync", $"yearly action complete; year={year}; uploaded={result.Uploaded}; deleted_bitmaps={result.DeletedBitmaps}; deleted_weekly={result.DeletedWeekly}");
        }
        catch (Exception error) { log.Record("sync", $"yearly action failed; year={year}; stage=archive; {DiagnosticLog.Describe(error)}"); }
    }

    private void RefreshSyncStatus() => SyncStatus = Settings.SyncProvider switch { SyncProvider.None => "Sync off — choose a provider in Settings", SyncProvider.ICloudDrive when !ProviderSignedIn(Settings.SyncProvider) => "iCloud for Windows setup required", _ when !ProviderSignedIn(Settings.SyncProvider) => $"{ProviderName(Settings.SyncProvider)} account sign-in required", SyncProvider.ICloudDrive => "iCloud Drive connected through iCloud for Windows", _ => $"{ProviderName(Settings.SyncProvider)} connected as {ProviderAccountLabel(Settings.SyncProvider)}" };
    private void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason is SessionSwitchReason.SessionLock)
        {
            log.Record("sync", "incremental sync requested; trigger=session_lock"); _ = SyncAsync(); sessionAvailable = false;
        }
        else if (e.Reason is SessionSwitchReason.SessionLogoff or SessionSwitchReason.ConsoleDisconnect) { _ = QuickUploadAsync($"session:{e.Reason}"); sessionAvailable = false; }
        else if (e.Reason is SessionSwitchReason.SessionUnlock or SessionSwitchReason.SessionLogon or SessionSwitchReason.ConsoleConnect) sessionAvailable = true;
        UpdateMonitoringAvailability($"session:{e.Reason}");
    }

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend) { _ = QuickUploadAsync("power_suspend"); powerAvailable = false; }
        else if (e.Mode == PowerModes.Resume) powerAvailable = true;
        UpdateMonitoringAvailability($"power:{e.Mode}");
    }

    private void UpdateMonitoringAvailability(string trigger)
    {
        var available = sessionAvailable && powerAvailable;
        if (available == screenAvailable) { log.Record("lifecycle", $"availability unchanged; trigger={trigger}; screen_available={screenAvailable}; minute_timer_running={timer.Enabled}"); return; }
        screenAvailable = available;
        if (!available)
        {
            timer.Stop(); continuous = 0;
            log.Record("lifecycle", $"screen unavailable; trigger={trigger}; minute_timer_paused=true");
            return;
        }
        timer.Start();
        log.Record("lifecycle", $"screen available; trigger={trigger}; minute_timer_resumed=true; immediate_tick=true; immediate_sync=true");
        Tick(); _ = SyncAsync();
    }
    private void ConfigureStartup() { using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true); if (Settings.LaunchAtLogin) key?.SetValue("ScreenTimeGuardian", $"\"{Environment.ProcessPath}\""); else key?.DeleteValue("ScreenTimeGuardian", false); }
    internal static string ProviderName(SyncProvider provider) => provider switch { SyncProvider.ICloudDrive => "iCloud Drive", SyncProvider.OneDrive => "OneDrive", SyncProvider.GoogleDrive => "Google Drive", _ => "Off" };
    private string ShortDeviceID => Settings.DeviceID[..Math.Min(8, Settings.DeviceID.Length)];
    private static void Add(WinForms.ContextMenuStrip menu, string text, Action action) { var item = menu.Items.Add(text); item.Click += (_, _) => action(); }
    private void Changed() => System.Windows.Application.Current.Dispatcher.InvokeAsync(() => StateChanged?.Invoke(this, EventArgs.Empty));
    private void Exit() { if (exitInProgress) return; exitInProgress = true; _ = ExitAsync(); }
    public void BeginUninstall()
    {
        var result = WinForms.MessageBox.Show("Do you want to keep your personal settings and screen-time data for the next installation?\n\nYes keeps a local restore copy. No permanently deletes settings, data, saved cloud sign-ins, and the restore copy.\n\nAfter your choice, Windows Settings will open so you can remove the app.", "Remove Screen Time Guardian", WinForms.MessageBoxButtons.YesNoCancel, WinForms.MessageBoxIcon.Question);
        if (result == WinForms.DialogResult.Cancel) return;
        var mode = result == WinForms.DialogResult.Yes ? "keep" : "delete";
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Environment.ProcessPath!, $"--prepare-uninstall {mode}") { UseShellExecute = true });
        Exit();
    }
    private async Task ExitAsync()
    {
        log.Record("lifecycle", $"quit requested; active_sync={syncInProgress}; quick_upload={quickUploadInProgress}; hard_timeout=3s");
        timer.Stop(); SystemEvents.SessionSwitch -= OnSessionSwitch; SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        activeSyncCancellation?.Cancel();
        using var quitCancellation = new CancellationTokenSource();
        var work = FinishExitUploadAsync(quitCancellation.Token);
        var completed = await Task.WhenAny(work, Task.Delay(TimeSpan.FromSeconds(3)));
        if (completed == work) { await work; log.Record("lifecycle", "quit preparation complete; hard_timeout=false"); }
        else { quitCancellation.Cancel(); log.Record("lifecycle", "quit upload hard timeout reached; limit=3s; continuing_termination=true"); }
        DisposeCore(disposeRepository: !syncInProgress && !quickUploadInProgress);
        System.Windows.Application.Current.Shutdown();
    }

    private async Task FinishExitUploadAsync(CancellationToken token)
    {
        for (var attempt = 0; syncInProgress && attempt < 10; attempt++) await Task.Delay(50, token);
        if (syncInProgress) { log.Record("sync", "quit upload skipped; active incremental sync did not stop within 500ms"); return; }
        log.Record("sync", "quick upload requested; trigger=application_quit");
        await QuickUploadAsync("application_quit", token);
    }

    public void Dispose() => DisposeCore(disposeRepository: true);
    private void DisposeCore(bool disposeRepository)
    {
        if (disposed) return; disposed = true; log.Record("lifecycle", $"shutdown resources; repository_disposed={disposeRepository}"); tray.Visible = false; tray.Dispose(); timer.Stop(); timer.Dispose(); SystemEvents.SessionSwitch -= OnSessionSwitch; SystemEvents.PowerModeChanged -= OnPowerModeChanged; if (disposeRepository) repository.Dispose();
    }
}
