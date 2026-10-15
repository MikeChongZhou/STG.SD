using System.ComponentModel;
using System.Diagnostics;

namespace ScreenTimeGuardian;

internal partial class OneDriveAuthorizationForm : System.Windows.Window
{
    private readonly string verificationUri;
    private bool programmaticClose;
    public event EventHandler? CancelRequested;
    public OneDriveAuthorizationForm(string userCode, string verificationUri) { InitializeComponent(); L.Apply(this); WindowLayout.FitToWorkingArea(this, 0.82, 0.82); CodeLabel.Text = userCode; this.verificationUri = verificationUri; StatusLabel.Text = "Opening Microsoft sign-in with the code already filled in…"; Closing += OnClosing; Loaded += async (_, _) => await CopyCodeSafelyAsync(); }
    private void OnClosing(object? sender, CancelEventArgs e) { if (!programmaticClose) CancelRequested?.Invoke(this, EventArgs.Empty); }
    private async void Copy_Click(object sender, System.Windows.RoutedEventArgs e) => await CopyCodeSafelyAsync();
    private void Browser_Click(object sender, System.Windows.RoutedEventArgs e) => Process.Start(new ProcessStartInfo(verificationUri) { UseShellExecute = true });
    private void Cancel_Click(object sender, System.Windows.RoutedEventArgs e) => Close();
    public void SetStatus(string value) => Dispatcher.InvokeAsync(() => StatusLabel.Text = value);
    public void CloseAfterSuccess() => Dispatcher.InvokeAsync(() => { programmaticClose = true; Close(); });
    public void CloseAfterFailure() => Dispatcher.InvokeAsync(() => { programmaticClose = true; Close(); });
    private async Task CopyCodeSafelyAsync()
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try { System.Windows.Clipboard.SetText(CodeLabel.Text); StatusLabel.Text = "Code copied. The browser link also fills it automatically."; return; }
            catch (System.Runtime.InteropServices.ExternalException) when (attempt < 2) { await Task.Delay(120); }
            catch (Exception) { break; }
        }
        StatusLabel.Text = "The browser link fills the code automatically. Clipboard copy is unavailable right now.";
    }
}
