using System.Windows.Controls;

namespace ScreenTimeGuardian;

internal partial class SettingsForm : System.Windows.Window
{
    private readonly TrayAppContext app;
    public SettingsForm(TrayAppContext app)
    {
        InitializeComponent(); WindowLayout.FitToWorkingArea(this, 0.86, 0.84); this.app = app;
        PlanHourBox.ItemsSource = Enumerable.Range(0, 25); PlanMinuteBox.ItemsSource = Enumerable.Range(0, 60);
        var countdowns = Enumerable.Range(0, 31).ToArray(); EyeCountdownBox.ItemsSource = countdowns; PostureCountdownBox.ItemsSource = countdowns; DailyCountdownBox.ItemsSource = countdowns;
        PlanHourBox.SelectedItem = app.Settings.DailyPlanMinutes / 60; PlanMinuteBox.SelectedItem = app.Settings.DailyPlanMinutes % 60;
        TimeZoneBox.Text = app.Settings.ReportTimeZone; StartupBox.IsChecked = app.Settings.LaunchAtLogin; MeetingModeBox.IsChecked = app.Settings.MeetingMode;
        EyeCountdownBox.SelectedItem = app.Settings.EyeCountdown; PostureCountdownBox.SelectedItem = app.Settings.PostureCountdown; DailyCountdownBox.SelectedItem = app.Settings.DailyCountdown;
        UpdateCloud(); app.StateChanged += OnStateChanged; Closed += (_, _) => app.StateChanged -= OnStateChanged;
    }
    private void OnStateChanged(object? sender, EventArgs e) => Dispatcher.InvokeAsync(UpdateCloud);
    private void ConfigureCloud_Click(object sender, System.Windows.RoutedEventArgs e) { new CloudSetupForm(app) { Owner = this }.ShowDialog(); UpdateCloud(); }
    private void UpdateCloud()
    {
        var provider = app.Settings.SyncProvider; var signed = app.ProviderSignedIn(provider); ProviderLabel.Text = provider switch { SyncProvider.ICloudDrive => "Apple iCloud Drive", SyncProvider.OneDrive => "Microsoft OneDrive", SyncProvider.GoogleDrive => "Google Drive", _ => "Off" }; AccountLabel.Text = provider == SyncProvider.None ? "Single-device mode" : signed ? $"Connected through {app.ProviderAccountLabel(provider)}" : "Not signed in"; CloudStatusLabel.Text = app.SyncStatus;
    }
    private void DetectMeeting_Click(object sender, System.Windows.RoutedEventArgs e) { var result = app.CheckMeetingNow(); MeetingStatusLabel.Text = result.IsMeeting ? $"Meeting detected: {string.Join("; ", result.Reasons)}" : "No microphone or camera activity detected."; }
    private void ExportLog_Click(object sender, System.Windows.RoutedEventArgs e) => app.ExportTestLog(this);
    private void Cancel_Click(object sender, System.Windows.RoutedEventArgs e) => Close();
    private void Save_Click(object sender, System.Windows.RoutedEventArgs e)
    {
        var hours = PlanHourBox.SelectedItem as int? ?? 10; var minutes = PlanMinuteBox.SelectedItem as int? ?? 0; var plan = hours * 60 + minutes;
        if (plan is < 20 or > 1440) { System.Windows.MessageBox.Show(this, "Daily plan must be between 0h 20m and 24h 0m.", "Invalid daily plan", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Warning); return; }
        app.Settings.DailyPlanMinutes = plan; app.Settings.ReportTimeZone = TimeZoneBox.Text.Trim(); app.Settings.LaunchAtLogin = StartupBox.IsChecked == true; app.Settings.MeetingMode = MeetingModeBox.IsChecked == true;
        app.Settings.EyeCountdown = EyeCountdownBox.SelectedItem as int? ?? 1; app.Settings.PostureCountdown = PostureCountdownBox.SelectedItem as int? ?? 2; app.Settings.DailyCountdown = DailyCountdownBox.SelectedItem as int? ?? 3; app.SaveSettings(); Close();
    }
}
