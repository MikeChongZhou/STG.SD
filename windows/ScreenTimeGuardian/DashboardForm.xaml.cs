using System.ComponentModel;

namespace ScreenTimeGuardian;

internal partial class DashboardForm : System.Windows.Window
{
    private readonly TrayAppContext app;
    public DashboardForm(TrayAppContext app)
    {
        InitializeComponent(); WindowLayout.FitToWorkingArea(this, 0.9, 0.9); this.app = app; DateLabel.Text = DateTime.Now.ToString("dddd, MMMM d");
        app.StateChanged += OnStateChanged; Closing += OnClosing; RefreshView();
    }
    private void OnStateChanged(object? sender, EventArgs e) => Dispatcher.InvokeAsync(RefreshView);
    private void RefreshView()
    {
        AllValue.Text = Duration(app.AllMinutes); LocalValue.Text = Duration(app.LocalMinutes); PlanValue.Text = Duration(app.Settings.DailyPlanMinutes);
        SyncStatusLabel.Text = app.SyncStatus; PlanProgress.Maximum = Math.Max(1, app.Settings.DailyPlanMinutes); PlanProgress.Value = Math.Min(PlanProgress.Maximum, app.AllMinutes);
        ProgressLabel.Text = $"{app.AllMinutes * 100 / Math.Max(1, app.Settings.DailyPlanMinutes)}% of plan";
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
