using Microsoft.Win32;

namespace ScreenTimeGuardian;

internal static class UninstallCleanup
{
    public static void Run()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
        key?.DeleteValue("ScreenTimeGuardian", false);
        CredentialStore.Delete(CloudConfiguration.OneDriveCredential);
        CredentialStore.Delete(CloudConfiguration.GoogleDriveCredential);
    }
}
