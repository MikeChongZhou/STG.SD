using Microsoft.Web.WebView2.Core;
using System.Text.Json;

namespace ScreenTimeGuardian;

internal partial class DailyCheckInWindow : System.Windows.Window
{
    private const string Url = "https://www.1point3acres.com/next/daily-checkin";
    private readonly string text; private readonly bool submit; private readonly Action<string> log; private bool injected;
    public DailyCheckInWindow(string text, bool submit, Action<string> log) { InitializeComponent(); this.text = text; this.submit = submit; this.log = log; Loaded += OnLoaded; }
    private async void OnLoaded(object sender, System.Windows.RoutedEventArgs e)
    {
        try
        {
            var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ScreenTimeGuardian", "checkin-browser");
            await Browser.EnsureCoreWebView2Async(await CoreWebView2Environment.CreateAsync(null, folder));
            Browser.CoreWebView2.NavigationCompleted += NavigationCompleted;
            Browser.CoreWebView2.Navigate(Url); log($"browser_opened; submit={submit}");
        }
        catch (Exception error) { log($"browser_initialization_failed; {DiagnosticLog.Describe(error)}"); }
    }
    private async void NavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (!e.IsSuccess) { log($"navigation_failed; error={e.WebErrorStatus}"); return; }
        if (injected || !submit) { log($"page_loaded; automatic_submit={submit}; url={Browser.Source}"); return; }
        injected = true;
        var payload = JsonSerializer.Serialize(text);
        var script = """
        (() => {
          const note = __STG_TEXT__;
          const buttons = [...document.querySelectorAll('button')];
          const mood = buttons.find(x => x.innerText.includes('开心'));
          const entry = document.querySelector('textarea');
          const submit = buttons.find(x => x.innerText.includes('提交签到'));
          if (!entry || !submit) return 'form_not_found';
          if (mood) mood.click();
          entry.focus(); entry.value = note;
          entry.dispatchEvent(new Event('input', { bubbles: true })); entry.dispatchEvent(new Event('change', { bubbles: true }));
          submit.click(); return 'submitted';
        })()
        """.Replace("__STG_TEXT__", payload, StringComparison.Ordinal);
        try { var result = await Browser.CoreWebView2.ExecuteScriptAsync(script); log($"automatic_action; result={result}; text_length={text.Length}"); }
        catch (Exception error) { log($"automatic_action_failed; {DiagnosticLog.Describe(error)}"); }
    }
}
