using System.Diagnostics;
using Microsoft.Win32;
using Windows.ApplicationModel;

namespace ScreenTimeGuardian;

internal static class UninstallCleanup
{
    public static void DeletePersonalData()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
        key?.DeleteValue("ScreenTimeGuardian", false);
        CredentialStore.Delete(CloudConfiguration.OneDriveCredential);
        CredentialStore.Delete(CloudConfiguration.GoogleDriveCredential);
        AppDataLocation.DeleteAllUserData();
    }

    public static void PrepareForSystemUninstall(bool keepPersonalData)
    {
        Thread.Sleep(TimeSpan.FromSeconds(4));
        if (keepPersonalData) AppDataLocation.PreserveForReinstall(); else DeletePersonalData();
        var target = "ms-settings:appsfeatures-app";
        try { target += "?" + Uri.EscapeDataString(Package.Current.Id.FamilyName); } catch { }
        Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
    }
}
