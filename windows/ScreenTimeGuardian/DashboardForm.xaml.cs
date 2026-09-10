using System.ComponentModel;

namespace ScreenTimeGuardian;

internal partial class DashboardForm : System.Windows.Window
{
    private readonly TrayAppContext app;
    public DashboardForm(TrayAppContext app)
    {
        InitializeComponent(); L.Apply(this); WindowLayout.FitToWorkingArea(this, 0.82, 0.82); this.app = app;
        app.StateChanged += OnStateChanged; Closing += OnClosing; RefreshView();
    }
    private void OnStateChanged(object? sender, EventArgs e) => Dispatcher.InvokeAsync(RefreshView);
    private void RefreshView()
    {
        AllValue.Text = Duration(app.AllMinutes); LocalValue.Text = Duration(app.LocalMinutes); PlanValue.Text = Duration(app.Settings.DailyPlanMinutes);
        MeetingModeLabel.Text = L.T(app.Settings.MeetingMode ? "Meeting Mode: " : "Meeting auto-detect: ");
        MeetingModeValue.Text = L.T("On"); SyncStatusLabel.Text = app.SyncStatus; TrackingSummary.Text = app.LatestTrackingTopTwo;
    }
    private void OnClosing(object? sender, CancelEventArgs e) { e.Cancel = true; Hide(); }
    private void Report_Click(object sender, System.Windows.RoutedEventArgs e) => app.ShowReport();
    private void Tracking_Click(object sender, System.Windows.RoutedEventArgs e) => app.ShowTracking();
    private void Settings_Click(object sender, System.Windows.RoutedEventArgs e) => app.ShowSettings();
    private void About_Click(object sender, System.Windows.RoutedEventArgs e) => app.ShowAbout();
    private async void Sync_Click(object sender, System.Windows.RoutedEventArgs e) { if (sender is System.Windows.Controls.Button button) button.IsEnabled = false; try { await app.SyncAsync(); } finally { if (sender is System.Windows.Controls.Button value) value.IsEnabled = true; } }
    private void CloseWindow_Click(object sender, System.Windows.RoutedEventArgs e) => Hide();
    internal static string Duration(int minutes) => $"{minutes / 60}h {minutes % 60}m";
}
