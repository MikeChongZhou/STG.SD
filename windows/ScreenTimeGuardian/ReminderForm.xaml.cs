using System.Media;
using System.Windows.Threading;

namespace ScreenTimeGuardian;

internal partial class ReminderForm : System.Windows.Window
{
    private readonly bool meetingMode;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private int seconds;
    public ReminderForm(string kind, int used, AppSettings settings, bool meetingMode)
    {
        InitializeComponent(); L.Apply(this); WindowLayout.FitToWorkingArea(this, 0.82, 0.82); this.meetingMode = meetingMode;
        TitleLabel.Text = L.T(kind == "eye" ? "Eye Break" : kind == "posture" ? "Posture Break" : "Daily Limit Reached");
        MessageLabel.Text = kind == "eye" ? L.T("Look 20 feet away for 20 seconds.") : kind == "posture" ? L.T("Stand or walk for 4 minutes and rest your eyes.") : string.Format(L.T("You've used your screen for {0}. Take a 5-minute walk."), DashboardForm.Duration(used));
        seconds = meetingMode ? 0 : (kind == "eye" ? settings.EyeCountdown : kind == "posture" ? settings.PostureCountdown : settings.DailyCountdown) * 60;
        timer.Tick += (_, _) => { if (seconds > 0) seconds--; UpdateCountdown(); if (seconds <= 0) timer.Stop(); }; UpdateCountdown(); if (seconds > 0) timer.Start(); if (!meetingMode) SystemSounds.Exclamation.Play(); Closed += (_, _) => timer.Stop();
    }
    private void UpdateCountdown() { CloseButton.IsEnabled = seconds <= 0; CountdownLabel.Text = meetingMode ? L.T("Meeting mode: this reminder can be closed immediately.") : seconds > 0 ? string.Format(L.T("Close available in {0}s"), seconds) : L.T("You can close this reminder now."); }
    private void Close_Click(object sender, System.Windows.RoutedEventArgs e) => Close();
}
