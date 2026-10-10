using Microsoft.Win32;

namespace ScreenTimeGuardian;

internal static class UninstallCleanup
{
    public static void DeletePersonalData()
    {
        RemoveStartupRegistration();
        CredentialStore.Delete(CloudConfiguration.OneDriveCredential);
        CredentialStore.Delete(CloudConfiguration.GoogleDriveCredential);
        var dataFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ScreenTimeGuardian");
        if (Directory.Exists(dataFolder)) Directory.Delete(dataFolder, true);
    }

    public static void RemoveStartupRegistration()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
        key?.DeleteValue("ScreenTimeGuardian", false);
    }
}
