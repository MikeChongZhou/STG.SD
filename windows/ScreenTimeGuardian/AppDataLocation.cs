using Windows.Storage;

namespace ScreenTimeGuardian;

/// <summary>Uses package-owned LocalState when STG runs as an MSIX package.</summary>
internal static class AppDataLocation
{
    private const string AppFolderName = "ScreenTimeGuardian";
    private const string PreservedFolderName = "PreservedData";

    public static string LegacyFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), AppFolderName);
    public static string PreservedFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppFolderName, PreservedFolderName);

    public static string Prepare()
    {
        var folder = CurrentFolder();
        Directory.CreateDirectory(folder);
        if (!PathsEqual(folder, LegacyFolder) && Directory.Exists(LegacyFolder) && !ContainsUserData(folder))
        {
            CopyDirectory(LegacyFolder, folder);
            Directory.Delete(LegacyFolder, true);
        }
        if (Directory.Exists(PreservedFolder) && !ContainsUserData(folder))
        {
            CopyDirectory(PreservedFolder, folder);
            Directory.Delete(PreservedFolder, true);
        }
        return folder;
    }

    public static void PreserveForReinstall()
    {
        var source = CurrentFolder();
        if (Directory.Exists(PreservedFolder)) Directory.Delete(PreservedFolder, true);
        if (Directory.Exists(source) && ContainsUserData(source)) CopyDirectory(source, PreservedFolder);
    }

    public static void DeleteAllUserData()
    {
        DeleteDirectory(CurrentFolder());
        if (!PathsEqual(CurrentFolder(), LegacyFolder)) DeleteDirectory(LegacyFolder);
        DeleteDirectory(PreservedFolder);
    }

    private static string CurrentFolder()
    {
        try { return ApplicationData.Current.LocalFolder.Path; }
        catch { return LegacyFolder; }
    }

    private static bool ContainsUserData(string folder) => File.Exists(Path.Combine(folder, "stg.sqlite")) || File.Exists(Path.Combine(folder, "settings.json"));
    private static void DeleteDirectory(string path) { if (Directory.Exists(path)) Directory.Delete(path, true); }
    private static bool PathsEqual(string left, string right) => string.Equals(Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar), Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase);

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var directory in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories)) Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(source, directory)));
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(destination, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target, true);
        }
    }
}
