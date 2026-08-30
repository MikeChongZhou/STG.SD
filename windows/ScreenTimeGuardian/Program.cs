namespace ScreenTimeGuardian;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        System.Windows.Forms.Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        System.Windows.Forms.Application.EnableVisualStyles();
        var application = new System.Windows.Application { ShutdownMode = System.Windows.ShutdownMode.OnExplicitShutdown };
        application.Resources.MergedDictionaries.Add(new System.Windows.ResourceDictionary { Source = new Uri("/ScreenTimeGuardian;component/WpfTheme.xaml", UriKind.RelativeOrAbsolute) });
        using var tray = new TrayAppContext();
        application.Run();
    }
}
