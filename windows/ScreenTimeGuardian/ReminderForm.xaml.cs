using System.Media;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace ScreenTimeGuardian;

internal partial class ReminderForm : System.Windows.Window
{
    private readonly bool lightMode;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private int seconds;
    public ReminderForm(string kind, int used, AppSettings settings, bool lightMode)
    {
        InitializeComponent(); L.Apply(this); this.lightMode = lightMode;
        TitleLabel.Text = L.T(kind == "eye" ? "Eye Break" : kind == "posture" ? "Posture Break" : "Daily Limit Reached");
        MessageLabel.Text = kind == "eye" ? L.T("Look 20 feet away for 20 seconds.") : kind == "posture" ? L.T("Stand or walk for 4 minutes and rest your eyes.") : string.Format(L.T("You've used your screen for {0}. Take a 5-minute walk."), DashboardForm.Duration(used));
        seconds = lightMode ? 10 : (kind == "eye" ? settings.EyeCountdown : kind == "posture" ? settings.PostureCountdown : settings.DailyCountdown) * 60;
        if (lightMode)
        {
            Width = 620; Height = 88; MinWidth = 0; MinHeight = 0; ShowInTaskbar = false; ShowActivated = false; WindowStyle = WindowStyle.None;
            WindowStartupLocation = WindowStartupLocation.Manual;
            var area = SystemParameters.WorkArea; Left = area.Left + (area.Width - Width) / 2; Top = area.Top + 8;
            var row = new Grid { Margin = new Thickness(16), VerticalAlignment = VerticalAlignment.Center };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock { Text = TitleLabel.Text, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
            var message = new TextBlock { Text = MessageLabel.Text, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center }; Grid.SetColumn(message, 1); row.Children.Add(message);
            var dismiss = new System.Windows.Controls.Button { Content = L.T("Close"), Margin = new Thickness(10, 0, 0, 0) }; dismiss.Click += (_, _) => Close(); Grid.SetColumn(dismiss, 2); row.Children.Add(dismiss);
            Content = row;
        }
        else WindowLayout.FitToWorkingArea(this, 0.82, 0.82);
        timer.Tick += (_, _) => { if (seconds > 0) seconds--; if (lightMode && seconds <= 0) { Close(); return; } UpdateCountdown(); if (seconds <= 0) timer.Stop(); };
        UpdateCountdown(); if (seconds > 0) timer.Start(); if (!lightMode) SystemSounds.Exclamation.Play(); Closed += (_, _) => timer.Stop();
    }
    private void UpdateCountdown() { CloseButton.IsEnabled = lightMode || seconds <= 0; CountdownLabel.Text = lightMode ? "" : seconds > 0 ? string.Format(L.T("Close available in {0}s"), seconds) : L.T("You can close this reminder now."); }
    private void Close_Click(object sender, System.Windows.RoutedEventArgs e) => Close();
}
