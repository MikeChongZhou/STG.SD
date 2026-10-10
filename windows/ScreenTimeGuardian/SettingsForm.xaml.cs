using System.Windows.Controls;

namespace ScreenTimeGuardian;

internal partial class SettingsForm : System.Windows.Window
{
    private readonly TrayAppContext app;
    private bool closeApproved;
    public SettingsForm(TrayAppContext app)
    {
        InitializeComponent(); L.Apply(this); WindowLayout.FitToWorkingArea(this, 0.86, 0.84); this.app = app;
        PlanHourBox.ItemsSource = Enumerable.Range(0, 25); PlanMinuteBox.ItemsSource = new[] { 0, 15, 30, 45 };
        var countdowns = Enumerable.Range(0, 31).ToArray(); EyeCountdownBox.ItemsSource = countdowns; PostureCountdownBox.ItemsSource = countdowns; DailyCountdownBox.ItemsSource = countdowns;
        PlanHourBox.SelectedItem = app.Settings.DailyPlanMinutes / 60; PlanMinuteBox.SelectedItem = app.Settings.DailyPlanMinutes % 60;
        StartupBox.IsChecked = app.Settings.LaunchAtLogin; MeetingModeBox.IsChecked = app.Settings.MeetingMode;
        EyeCountdownBox.SelectedItem = app.Settings.EyeCountdown; PostureCountdownBox.SelectedItem = app.Settings.PostureCountdown; DailyCountdownBox.SelectedItem = app.Settings.DailyCountdown;
        PlanHourBox.SelectionChanged += Draft_Changed; PlanMinuteBox.SelectionChanged += Draft_Changed;
        EyeCountdownBox.SelectionChanged += Draft_Changed; PostureCountdownBox.SelectionChanged += Draft_Changed; DailyCountdownBox.SelectionChanged += Draft_Changed;
        StartupBox.Checked += Draft_Changed; StartupBox.Unchecked += Draft_Changed; MeetingModeBox.Checked += Draft_Changed; MeetingModeBox.Unchecked += Draft_Changed;
        EyeNotificationsBox.IsChecked = app.Settings.EyeNotificationsEnabled;
        PostureNotificationsBox.IsChecked = app.Settings.PostureNotificationsEnabled;
        DailyNotificationsBox.IsChecked = app.Settings.DailyNotificationsEnabled;
        foreach (var box in new[] { EyeNotificationsBox, PostureNotificationsBox, DailyNotificationsBox }) { box.Checked += Draft_Changed; box.Unchecked += Draft_Changed; }
        UpdateCloud(); app.StateChanged += OnStateChanged; Closing += SettingsForm_Closing; Closed += (_, _) => app.StateChanged -= OnStateChanged;
    }
    private void Draft_Changed(object sender, System.Windows.RoutedEventArgs e) => SaveButton.IsEnabled = HasUnsavedChanges();
    private void OnStateChanged(object? sender, EventArgs e) => Dispatcher.InvokeAsync(UpdateCloud);
    private void ConfigureCloud_Click(object sender, System.Windows.RoutedEventArgs e) { new CloudSetupForm(app) { Owner = this }.ShowDialog(); UpdateCloud(); }
    private void UpdateCloud()
    {
        var provider = app.Settings.SyncProvider; var signed = app.ProviderSignedIn(provider); ProviderLabel.Text = provider switch { SyncProvider.ICloudDrive => "Apple iCloud Drive", SyncProvider.OneDrive => "Microsoft OneDrive", SyncProvider.GoogleDrive => "Google Drive", _ => L.T("Off") }; AccountLabel.Text = provider == SyncProvider.None ? L.T("Single-device mode") : signed ? L.F("Connected through {0}", app.ProviderAccountLabel(provider)) : L.T("Not signed in"); CloudStatusLabel.Text = app.SyncStatus;
    }
    private void ExportLog_Click(object sender, System.Windows.RoutedEventArgs e) => app.ExportTestLog(this);
    private void ExportData_Click(object sender, System.Windows.RoutedEventArgs e) => app.ExportData(this);
    private void Close_Click(object sender, System.Windows.RoutedEventArgs e) => Close();
    private void RemoveApp_Click(object sender, System.Windows.RoutedEventArgs e)
    {
        if (HasUnsavedChanges() && !ApplySettings()) return;
        closeApproved = true;
        Close();
        app.BeginUninstall();
    }
    private void Save_Click(object sender, System.Windows.RoutedEventArgs e)
    {
        if (!ApplySettings()) return;
        SaveButton.IsEnabled = false;
    }
    private bool ApplySettings()
    {
        var hours = PlanHourBox.SelectedItem as int? ?? 10; var minutes = PlanMinuteBox.SelectedItem as int? ?? 0; var plan = hours * 60 + minutes;
        if (plan is < 20 or > 1440) { System.Windows.MessageBox.Show(this, "The daily limit must be between 0h 20m and 24h 0m.", "Invalid Daily Limit", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Warning); return false; }
        app.Settings.EyeNotificationsEnabled = EyeNotificationsBox.IsChecked == true;
        app.Settings.PostureNotificationsEnabled = PostureNotificationsBox.IsChecked == true;
        app.Settings.DailyNotificationsEnabled = DailyNotificationsBox.IsChecked == true;
        app.Settings.DailyPlanMinutes = plan; app.Settings.LaunchAtLogin = StartupBox.IsChecked == true; app.Settings.MeetingMode = MeetingModeBox.IsChecked == true;
        app.Settings.EyeCountdown = EyeCountdownBox.SelectedItem as int? ?? 1; app.Settings.PostureCountdown = PostureCountdownBox.SelectedItem as int? ?? 2; app.Settings.DailyCountdown = DailyCountdownBox.SelectedItem as int? ?? 3; app.SaveSettings(); return true;
    }
    private bool HasUnsavedChanges()
    {
        var hours = PlanHourBox.SelectedItem as int? ?? 10; var minutes = PlanMinuteBox.SelectedItem as int? ?? 0;
        return hours * 60 + minutes != app.Settings.DailyPlanMinutes
            || (EyeNotificationsBox.IsChecked == true) != app.Settings.EyeNotificationsEnabled
            || (PostureNotificationsBox.IsChecked == true) != app.Settings.PostureNotificationsEnabled
            || (DailyNotificationsBox.IsChecked == true) != app.Settings.DailyNotificationsEnabled
            || StartupBox.IsChecked == true != app.Settings.LaunchAtLogin
            || MeetingModeBox.IsChecked == true != app.Settings.MeetingMode
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
