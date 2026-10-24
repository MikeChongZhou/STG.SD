using System.Windows.Controls;

namespace ScreenTimeGuardian;

internal partial class SettingsForm : System.Windows.Window
{
    private readonly TrayAppContext app;
    private bool closeApproved;
    private (bool eye, bool posture, bool daily)? preQuiet;
    private string draftMode;
    public SettingsForm(TrayAppContext app)
    {
        InitializeComponent(); L.Apply(this); WindowLayout.FitToWorkingArea(this, 0.86, 0.84); this.app = app;
        PlanHourBox.ItemsSource = Enumerable.Range(0, 25); PlanMinuteBox.ItemsSource = new[] { 0, 15, 30, 45 };
        var countdowns = Enumerable.Range(0, 31).ToArray(); EyeCountdownBox.ItemsSource = countdowns; PostureCountdownBox.ItemsSource = countdowns; DailyCountdownBox.ItemsSource = countdowns;
        PlanHourBox.SelectedItem = app.Settings.DailyPlanMinutes / 60; PlanMinuteBox.SelectedItem = app.Settings.DailyPlanMinutes % 60;
        StartupBox.IsChecked = app.Settings.LaunchAtLogin;
        draftMode = app.Settings.NotificationMode;
        ReminderModeBox.ItemsSource = new[] { L.T("Quiet"), L.T("Light"), L.T("Alert") };
        ReminderModeBox.SelectedIndex = draftMode == "quiet" ? 0 : draftMode == "light" ? 1 : 2;
        EyeCountdownBox.SelectedItem = app.Settings.EyeCountdown; PostureCountdownBox.SelectedItem = app.Settings.PostureCountdown; DailyCountdownBox.SelectedItem = app.Settings.DailyCountdown;
        PlanHourBox.SelectionChanged += Draft_Changed; PlanMinuteBox.SelectionChanged += Draft_Changed;
        EyeCountdownBox.SelectionChanged += Draft_Changed; PostureCountdownBox.SelectionChanged += Draft_Changed; DailyCountdownBox.SelectionChanged += Draft_Changed;
        StartupBox.Checked += Draft_Changed; StartupBox.Unchecked += Draft_Changed;
        EyeNotificationsBox.IsChecked = app.Settings.EyeNotificationsEnabled;
        PostureNotificationsBox.IsChecked = app.Settings.PostureNotificationsEnabled;
        DailyNotificationsBox.IsChecked = app.Settings.DailyNotificationsEnabled;
        DailyCheckInBox.IsChecked = app.Settings.AutoDailyCheckInEnabled;
        SetQuietControls(draftMode == "quiet");
        ReminderModeBox.SelectionChanged += ReminderMode_Changed;
        foreach (var box in new[] { EyeNotificationsBox, PostureNotificationsBox, DailyNotificationsBox }) { box.Checked += Draft_Changed; box.Unchecked += Draft_Changed; }
        DailyCheckInBox.Checked += Draft_Changed; DailyCheckInBox.Unchecked += Draft_Changed;
        UpdateCloud(); app.StateChanged += OnStateChanged; Closing += SettingsForm_Closing; Closed += (_, _) => app.StateChanged -= OnStateChanged;
    }
    private void Draft_Changed(object sender, System.Windows.RoutedEventArgs e) => SaveButton.IsEnabled = HasUnsavedChanges();
    private void ReminderMode_Changed(object sender, SelectionChangedEventArgs e)
    {
        var mode = ReminderModeBox.SelectedIndex == 0 ? "quiet" : ReminderModeBox.SelectedIndex == 1 ? "light" : "alert";
        if (mode == "quiet" && draftMode != "quiet")
            preQuiet = (EyeNotificationsBox.IsChecked == true, PostureNotificationsBox.IsChecked == true, DailyNotificationsBox.IsChecked == true);
        else if (mode != "quiet" && draftMode == "quiet")
        {
            var restored = preQuiet ?? (app.Settings.QuietEyeNotifications ?? true, app.Settings.QuietPostureNotifications ?? true, app.Settings.QuietDailyNotifications ?? true);
            EyeNotificationsBox.IsChecked = restored.Item1; PostureNotificationsBox.IsChecked = restored.Item2; DailyNotificationsBox.IsChecked = restored.Item3;
        }
        draftMode = mode;
        SetQuietControls(mode == "quiet");
        SaveButton.IsEnabled = HasUnsavedChanges();
    }
    private void SetQuietControls(bool quiet)
    {
        if (quiet) EyeNotificationsBox.IsChecked = PostureNotificationsBox.IsChecked = DailyNotificationsBox.IsChecked = false;
        EyeNotificationsBox.IsEnabled = PostureNotificationsBox.IsEnabled = DailyNotificationsBox.IsEnabled = !quiet;
    }
    private void OnStateChanged(object? sender, EventArgs e) => Dispatcher.InvokeAsync(UpdateCloud);
    private void ConfigureCloud_Click(object sender, System.Windows.RoutedEventArgs e) { new CloudSetupForm(app) { Owner = this }.ShowDialog(); UpdateCloud(); }
    private async void AlignData_Click(object sender, System.Windows.RoutedEventArgs e)
    {
        AlignDataButton.IsEnabled = false;
        try { await app.AlignAllDataAsync(); }
        finally { UpdateCloud(); }
    }
    private void UpdateCloud()
    {
        var provider = app.Settings.SyncProvider; var signed = app.ProviderSignedIn(provider); ProviderLabel.Text = provider switch { SyncProvider.ICloudDrive => "Apple iCloud Drive", SyncProvider.OneDrive => "Microsoft OneDrive", SyncProvider.GoogleDrive => "Google Drive", _ => L.T("Off") }; AccountLabel.Text = provider == SyncProvider.None ? L.T("Single-device mode") : signed ? L.F("Connected through {0}", app.ProviderAccountLabel(provider)) : L.T("Not signed in"); CloudStatusLabel.Text = app.SyncStatus; AlignDataButton.IsEnabled = signed;
    }
    private void ExportLog_Click(object sender, System.Windows.RoutedEventArgs e) => app.ExportTestLog(this);
    private void ExportData_Click(object sender, System.Windows.RoutedEventArgs e) => app.ExportData(this);
    private void TestDailyCheckIn_Click(object sender, System.Windows.RoutedEventArgs e) => app.ShowDailyCheckIn(submit: false);
    private void Close_Click(object sender, System.Windows.RoutedEventArgs e) => Close();
    private void Save_Click(object sender, System.Windows.RoutedEventArgs e)
    {
        if (!ApplySettings()) return;
        SaveButton.IsEnabled = false;
    }
    private bool ApplySettings()
    {
        var hours = PlanHourBox.SelectedItem as int? ?? 10; var minutes = PlanMinuteBox.SelectedItem as int? ?? 0; var plan = hours * 60 + minutes;
        if (plan is < 20 or > 1440) { System.Windows.MessageBox.Show(this, "The daily limit must be between 0h 20m and 24h 0m.", "Invalid Daily Limit", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Warning); return false; }
        if (draftMode == "quiet" && app.Settings.NotificationMode != "quiet" && preQuiet is { } saved)
        {
            app.Settings.EyeNotificationsEnabled = saved.eye; app.Settings.PostureNotificationsEnabled = saved.posture; app.Settings.DailyNotificationsEnabled = saved.daily;
        }
        app.Settings.SetNotificationMode(draftMode);
        if (draftMode != "quiet")
        {
            app.Settings.EyeNotificationsEnabled = EyeNotificationsBox.IsChecked == true;
            app.Settings.PostureNotificationsEnabled = PostureNotificationsBox.IsChecked == true;
            app.Settings.DailyNotificationsEnabled = DailyNotificationsBox.IsChecked == true;
        }
        app.Settings.AutoDailyCheckInEnabled = DailyCheckInBox.IsChecked == true;
        app.Settings.DailyPlanMinutes = plan; app.Settings.LaunchAtLogin = StartupBox.IsChecked == true;
        app.Settings.EyeCountdown = EyeCountdownBox.SelectedItem as int? ?? 1; app.Settings.PostureCountdown = PostureCountdownBox.SelectedItem as int? ?? 2; app.Settings.DailyCountdown = DailyCountdownBox.SelectedItem as int? ?? 3; app.SaveSettings(); return true;
    }
    private bool HasUnsavedChanges()
    {
        var hours = PlanHourBox.SelectedItem as int? ?? 10; var minutes = PlanMinuteBox.SelectedItem as int? ?? 0;
        return hours * 60 + minutes != app.Settings.DailyPlanMinutes
            || draftMode != app.Settings.NotificationMode
            || (EyeNotificationsBox.IsChecked == true) != app.Settings.EyeNotificationsEnabled
            || (PostureNotificationsBox.IsChecked == true) != app.Settings.PostureNotificationsEnabled
            || (DailyNotificationsBox.IsChecked == true) != app.Settings.DailyNotificationsEnabled
            || (DailyCheckInBox.IsChecked == true) != app.Settings.AutoDailyCheckInEnabled
            || StartupBox.IsChecked == true != app.Settings.LaunchAtLogin
            || (EyeCountdownBox.SelectedItem as int? ?? 1) != app.Settings.EyeCountdown
            || (PostureCountdownBox.SelectedItem as int? ?? 2) != app.Settings.PostureCountdown
            || (DailyCountdownBox.SelectedItem as int? ?? 3) != app.Settings.DailyCountdown;
    }
    private void SettingsForm_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (closeApproved || !HasUnsavedChanges()) return;
        var result = System.Windows.MessageBox.Show(this, "Save your changes before closing?\n\nChoose Yes to save, No to discard them, or Cancel to keep editing.", "Unsaved Settings", System.Windows.MessageBoxButton.YesNoCancel, System.Windows.MessageBoxImage.Question);
        if (result == System.Windows.MessageBoxResult.Yes)
        {
            if (ApplySettings()) closeApproved = true; else e.Cancel = true;
        }
        else if (result == System.Windows.MessageBoxResult.No) closeApproved = true;
        else e.Cancel = true;
    }
}
