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
        InitializeComponent(); WindowLayout.FitToWorkingArea(this, 0.82, 0.82); this.meetingMode = meetingMode;
        TitleLabel.Text = kind == "eye" ? "Time for an Eye Break" : kind == "posture" ? "Stand Up & Stretch" : "Daily Limit Reached";
        MessageLabel.Text = kind == "eye" ? "Look at something 20 feet away for 20 seconds." : kind == "posture" ? "Stand or walk around for 4 minutes and rest your eyes." : $"You've used your screen for {DashboardForm.Duration(used)}. Time to walk around for 5 minutes.";
        seconds = meetingMode ? 0 : (kind == "eye" ? settings.EyeCountdown : kind == "posture" ? settings.PostureCountdown : settings.DailyCountdown) * 60;
        timer.Tick += (_, _) => { if (seconds > 0) seconds--; UpdateCountdown(); if (seconds <= 0) timer.Stop(); }; UpdateCountdown(); if (seconds > 0) timer.Start(); if (!meetingMode) SystemSounds.Exclamation.Play(); Closed += (_, _) => timer.Stop();
    }
    private void UpdateCountdown() { CloseButton.IsEnabled = seconds <= 0; CountdownLabel.Text = meetingMode ? "Meeting mode: this reminder can be closed immediately." : seconds > 0 ? $"Close available in {seconds}s" : "You can close this reminder now."; }
    private void Close_Click(object sender, System.Windows.RoutedEventArgs e) => Close();
}
