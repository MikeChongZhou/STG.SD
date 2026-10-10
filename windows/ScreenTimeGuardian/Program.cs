namespace ScreenTimeGuardian;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Any(value => value.Equals("--uninstall-cleanup", StringComparison.OrdinalIgnoreCase))) { UninstallCleanup.DeletePersonalData(); return; }
        var preparation = Array.FindIndex(args, value => value.Equals("--prepare-uninstall", StringComparison.OrdinalIgnoreCase));
        if (preparation >= 0) { UninstallCleanup.PrepareForSystemUninstall(preparation + 1 < args.Length && args[preparation + 1].Equals("keep", StringComparison.OrdinalIgnoreCase)); return; }
        System.Windows.Forms.Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        System.Windows.Forms.Application.EnableVisualStyles();
        var application = new System.Windows.Application { ShutdownMode = System.Windows.ShutdownMode.OnExplicitShutdown };
        application.Resources.MergedDictionaries.Add(new System.Windows.ResourceDictionary { Source = new Uri("/ScreenTimeGuardian;component/WpfTheme.xaml", UriKind.RelativeOrAbsolute) });
        using var tray = new TrayAppContext();
        application.Run();
    }
}
