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

    public static Task<bool> OpenAsync(DailyCheckInContent content, bool submit, Action<string> log)
        => Task.Run(() => OpenAndSubmit(content, submit, log));

    private static bool OpenAndSubmit(DailyCheckInContent content, bool submit, Action<string> log)
    {
        try
        {
            var chrome = FindChrome();
            Process.Start(new ProcessStartInfo(chrome, $"--new-tab {Url}") { UseShellExecute = true });
            log($"chrome requested; submit={submit}; mood={content.Mood}; note_length={content.Note.Length}");

            var deadline = DateTime.UtcNow.AddSeconds(30);
            var submissionClicked = false;
            var lastPreparationResult = "document_not_ready";
            while (DateTime.UtcNow < deadline)
            {
                var page = FindCheckInPage();
                if (page is not null)
                {
                    if (submit && AlreadyCheckedIn(page)) { log("chrome automation complete; result=already_checked_in"); return true; }
                    if (!submissionClicked && TryPrepare(page, content, out var submitButton, out lastPreparationResult))
                    {
                        if (!submit) { log($"chrome automation complete; result=prepared_without_submitting; mood={content.Mood}; note_length={content.Note.Length}"); return false; }
                        if (submitButton is not null && submitButton.TryGetCurrentPattern(InvokePattern.Pattern, out var submitPattern))
                        {
                            ((InvokePattern)submitPattern).Invoke();
                            submissionClicked = true;
                            log("chrome submission clicked; waiting for confirmation");
                        }
                    }
                }
                Thread.Sleep(750);
            }
            log(submissionClicked ? "chrome automation incomplete; result=submission_not_confirmed" : $"chrome automation incomplete; result={lastPreparationResult}");
            return false;
        }
        catch (Exception error)
        {
            log($"chrome automation failed; {DiagnosticLog.Describe(error)}");
            return false;
        }
    }

    private static bool AlreadyCheckedIn(AutomationElement page)
    {
        var buttons = page.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button));
        return buttons.Cast<AutomationElement>().Any(button => button.Current.Name.Contains("今日已签到", StringComparison.Ordinal));
    }

    private static bool TryPrepare(AutomationElement page, DailyCheckInContent content, out AutomationElement? submit, out string result)
    {
        result = "form_not_ready_or_not_logged_in";
        var buttons = page.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button));
        AutomationElement? mood = null;
        submit = null;
        var moodLabel = content.Mood.Split(' ', StringSplitOptions.RemoveEmptyEntries).Last();
        foreach (AutomationElement button in buttons)
        {
            var name = button.Current.Name;
            if (name.Contains(content.Mood, StringComparison.Ordinal) || name.Contains(moodLabel, StringComparison.Ordinal)) mood = button;
            if (name.Contains("提交签到", StringComparison.Ordinal) || name.Contains("今日已签到", StringComparison.Ordinal)) submit = button;
        }
        if (mood is null || submit is null) return false;
        var entries = page.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit));
        var candidates = entries.Cast<AutomationElement>().Where(element => element.TryGetCurrentPattern(ValuePattern.Pattern, out _)).ToList();
        var named = candidates.Where(element => element.Current.AutomationId == "todaysay" || element.Current.Name.Contains("记录今天的点点滴滴", StringComparison.Ordinal) || element.Current.HelpText.Contains("记录今天的点点滴滴", StringComparison.Ordinal)).ToList();
        // Chrome may omit HTML name/placeholder from UI Automation. The multiline
        // field is then the only sizeable edit box between the mood row and submit.
        var moodBounds = mood.Current.BoundingRectangle;
        var submitBounds = submit.Current.BoundingRectangle;
        var spatial = candidates.Where(element =>
        {
            var bounds = element.Current.BoundingRectangle;
            return bounds.Height >= 40 && bounds.Top >= moodBounds.Top && bounds.Bottom <= submitBounds.Top + 8 &&
                   bounds.Right > submitBounds.Left && bounds.Left < submitBounds.Right;
        }).ToList();
        var matches = named.Count > 0 ? named : spatial;
        if (matches.Count != 1) { result = $"note_field_ambiguous; named={named.Count}; spatial={spatial.Count}"; return false; }
        var entry = matches[0];
        if (!mood.TryGetCurrentPattern(InvokePattern.Pattern, out var moodPattern)) return false;
        ((InvokePattern)moodPattern).Invoke();
        ((ValuePattern)entry.GetCurrentPattern(ValuePattern.Pattern)).SetValue(content.Note);
        if (((ValuePattern)entry.GetCurrentPattern(ValuePattern.Pattern)).Current.Value != content.Note) { result = "note_not_set"; return false; }
        if (!submit.Current.IsEnabled) { result = "submit_not_enabled"; return false; }
        result = "prepared";
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
                if (!window.Current.Name.Contains("每日签到", StringComparison.Ordinal) && !window.Current.Name.Contains("1Point3Acres", StringComparison.Ordinal)) continue;
                var documents = window.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Document));
                foreach (AutomationElement document in documents)
                {
                    var buttons = document.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button));
                    if (buttons.Cast<AutomationElement>().Any(button => button.Current.Name.Contains("提交签到", StringComparison.Ordinal) || button.Current.Name.Contains("今日已签到", StringComparison.Ordinal))) return document;
                }
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
