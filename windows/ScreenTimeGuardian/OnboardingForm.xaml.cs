namespace ScreenTimeGuardian;

internal partial class OnboardingForm : System.Windows.Window
{
    private readonly TrayAppContext app;
    private int step;

    public OnboardingForm(TrayAppContext app)
    {
        InitializeComponent(); L.Apply(this); this.app = app; StartupBox.IsChecked = app.Settings.LaunchAtLogin;
        Closing += (_, e) => { if (!app.Settings.OnboardingComplete) e.Cancel = true; };
        Render();
    }

    private void Render()
    {
        var cloud = step == 0;
        StepLabel.Text = string.Format(L.T("Step {0} of {1}"), step + 1, 2);
        TitleLabel.Text = L.T(cloud ? "Connect your private cloud?" : "Start automatically when you sign in?");
        DetailLabel.Text = cloud
            ? L.T("Private-cloud sync combines screen-use records from your own devices. You can skip this and configure it later.")
            : L.T("Automatic startup keeps minute recording and reminders available after you sign in.");
        CloudButtons.Visibility = cloud ? System.Windows.Visibility.Visible : System.Windows.Visibility.Collapsed;
        StartupBox.Visibility = cloud ? System.Windows.Visibility.Collapsed : System.Windows.Visibility.Visible;
        BackButton.Visibility = cloud ? System.Windows.Visibility.Collapsed : System.Windows.Visibility.Visible;
        FinishButton.Visibility = cloud ? System.Windows.Visibility.Collapsed : System.Windows.Visibility.Visible;
    }

    private void ConfigureCloud_Click(object sender, System.Windows.RoutedEventArgs e) { new CloudSetupForm(app) { Owner = this }.ShowDialog(); step = 1; Render(); }
    private void SkipCloud_Click(object sender, System.Windows.RoutedEventArgs e) { step = 1; Render(); }
    private void Back_Click(object sender, System.Windows.RoutedEventArgs e) { step = 0; Render(); }
    private void Finish_Click(object sender, System.Windows.RoutedEventArgs e) { app.Settings.LaunchAtLogin = StartupBox.IsChecked == true; app.Settings.OnboardingComplete = true; app.SaveSettings(); Close(); }
}
