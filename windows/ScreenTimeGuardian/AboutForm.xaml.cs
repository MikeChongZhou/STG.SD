namespace ScreenTimeGuardian;
internal partial class AboutForm : System.Windows.Window
{
    public AboutForm() { InitializeComponent(); L.Apply(this); WindowLayout.FitToWorkingArea(this, 0.84, 0.86); }
    private void Close_Click(object sender, System.Windows.RoutedEventArgs e) => Close();
    private void OpenSourceLicenses_RequestNavigate(object sender, System.Windows.Navigation.RequestNavigateEventArgs e)
    {
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
        e.Handled = true;
    }
}
