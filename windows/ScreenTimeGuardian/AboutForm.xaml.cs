namespace ScreenTimeGuardian;
internal partial class AboutForm : System.Windows.Window
{
    private readonly TrayAppContext app;
    public AboutForm(TrayAppContext app) { InitializeComponent(); WindowLayout.FitToWorkingArea(this, 0.84, 0.86); this.app = app; }
    private void Export_Click(object sender, System.Windows.RoutedEventArgs e) => app.ExportTestLog(this);
    private void Close_Click(object sender, System.Windows.RoutedEventArgs e) => Close();
}
