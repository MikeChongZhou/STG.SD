using System.Diagnostics;
using System.Windows.Automation;

namespace ScreenTimeGuardian;

internal sealed record DailyCheckInContent(string Mood, string Note);

internal static class ChromeDailyCheckIn
{
    private const string Url = "https://www.1point3acres.com/next/daily-checkin";

    public static DailyCheckInContent ContentFor(DateOnly date)
    {
        var choices = new[]
        {
            new DailyCheckInContent("😀 开心", "今天保持好心情，也记得休息。"),
            new DailyCheckInContent("✊ 奋斗", "继续专注，也给自己留一点休息时间。"),
            new DailyCheckInContent("😶 无聊", "平静的一天，按时休息。"),
            new DailyCheckInContent("😴 慵懒", "今天有些疲惫，早点休息。")
        };
        return choices[(date.DayOfYear - 1) % choices.Length];
    }

    public static Task OpenAsync(DailyCheckInContent content, bool submit, Action<string> log)
        => Task.Run(() => OpenAndSubmit(content, submit, log));

    private static void OpenAndSubmit(DailyCheckInContent content, bool submit, Action<string> log)
    {
        try
        {
            var chrome = FindChrome();
            Process.Start(new ProcessStartInfo(chrome, $"--new-window {Url}") { UseShellExecute = true });
            log($"chrome requested; submit={submit}; mood={content.Mood}; note_length={content.Note.Length}");
            if (!submit) return;

            var deadline = DateTime.UtcNow.AddSeconds(30);
            while (DateTime.UtcNow < deadline)
            {
                var page = FindCheckInPage();
                if (page is not null && TrySubmit(page, content, out var result))
                {
                    log($"chrome automation complete; result={result}; mood={content.Mood}; note_length={content.Note.Length}");
                    return;
                }
                Thread.Sleep(750);
            }
            log("chrome automation incomplete; page left open for manual sign-in or submission");
        }
        catch (Exception error)
        {
            log($"chrome automation failed; {DiagnosticLog.Describe(error)}");
        }
    }

    private static bool TrySubmit(AutomationElement page, DailyCheckInContent content, out string result)
    {
        result = "form_not_ready";
        var buttons = page.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button));
        AutomationElement? mood = null;
        AutomationElement? submit = null;
        foreach (AutomationElement button in buttons)
        {
            var name = button.Current.Name;
            if (name.Contains(content.Mood, StringComparison.Ordinal) || name.Contains(content.Mood[2..], StringComparison.Ordinal)) mood = button;
            if (name.Contains("提交签到", StringComparison.Ordinal)) submit = button;
        }
        var entries = page.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit));
        var entry = entries.Cast<AutomationElement>().FirstOrDefault(element => element.TryGetCurrentPattern(ValuePattern.Pattern, out _));
        if (mood is null || submit is null || entry is null) return false;

        ((InvokePattern)mood.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
        ((ValuePattern)entry.GetCurrentPattern(ValuePattern.Pattern)).SetValue(content.Note);
        ((InvokePattern)submit.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
        result = "submitted";
        return true;
    }

    private static AutomationElement? FindCheckInPage()
    {
        var windows = AutomationElement.RootElement.FindAll(TreeScope.Children, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window));
        foreach (AutomationElement window in windows)
        {
            try
            {
                if (window.Current.ProcessId == 0 || !string.Equals(Process.GetProcessById(window.Current.ProcessId).ProcessName, "chrome", StringComparison.OrdinalIgnoreCase)) continue;
                if (window.Current.Name.Contains("每日签到", StringComparison.Ordinal) || window.Current.Name.Contains("1Point3Acres", StringComparison.Ordinal)) return window;
            }
            catch (ArgumentException) { }
        }
        return null;
    }

    private static string FindChrome()
    {
        var candidates = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Google", "Chrome", "Application", "chrome.exe")
        };
        return candidates.FirstOrDefault(File.Exists) ?? "chrome.exe";
    }
}
