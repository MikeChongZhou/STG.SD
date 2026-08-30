using System.Text;

namespace ScreenTimeGuardian;

internal sealed class DiagnosticLog
{
    private readonly string path;
    private readonly object gate = new();

    public DiagnosticLog(string dataFolder)
    {
        var folder = Path.Combine(dataFolder, "Diagnostics");
        Directory.CreateDirectory(folder);
        path = Path.Combine(folder, "stg-test.log");
    }

    public void Record(string category, string message)
    {
        lock (gate)
        {
            try
            {
                if (File.Exists(path) && new FileInfo(path).Length > 2_000_000)
                    File.Move(path, path + ".previous", true);
                File.AppendAllText(path, $"{DateTimeOffset.UtcNow:yyyy-MM-ddTHH:mm:ssZ} [{category}] {message}{Environment.NewLine}", Encoding.UTF8);
            }
            catch { }
        }
    }

    public string ExportCopy()
    {
        Record("diagnostics", "test log export requested");
        var target = Path.Combine(Path.GetTempPath(), $"STG-test-log-{DateTime.Now:yyyyMMdd-HHmmss}.log");
        lock (gate) File.Copy(path, target, true);
        return target;
    }
}
