using System.Reflection;
namespace ScreenTimeGuardian;

internal static class OpenRouterTemplate
{
    public const int ApplicationId = 0x535447;

    public static void CopyDatabaseTo(string destination)
    {
        var directory = Path.GetDirectoryName(destination);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        var assembly = Assembly.GetExecutingAssembly();
        var resource = assembly.GetManifestResourceNames().SingleOrDefault(
            value => value.EndsWith("stg.sqlite", StringComparison.Ordinal));
        if (resource is null) throw new InvalidDataException("Bundled STG database template is missing");
        using var input = assembly.GetManifestResourceStream(resource)
            ?? throw new InvalidDataException("Bundled STG database template cannot be opened");
        using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        input.CopyTo(output);
    }
}
