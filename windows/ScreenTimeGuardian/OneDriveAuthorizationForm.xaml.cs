using System.ComponentModel;
using System.Diagnostics;

namespace ScreenTimeGuardian;

internal partial class OneDriveAuthorizationForm : System.Windows.Window
{
    private readonly string verificationUri;
    private bool programmaticClose;
    public event EventHandler? CancelRequested;
    public OneDriveAuthorizationForm(string userCode, string verificationUri) { InitializeComponent(); L.Apply(this); WindowLayout.FitToWorkingArea(this, 0.82, 0.82); CodeLabel.Text = userCode; this.verificationUri = verificationUri; StatusLabel.Text = "Waiting for Microsoft to confirm the sign-in…"; Closing += OnClosing; }
    private void OnClosing(object? sender, CancelEventArgs e) { if (!programmaticClose) CancelRequested?.Invoke(this, EventArgs.Empty); }
    private void Copy_Click(object sender, System.Windows.RoutedEventArgs e) => System.Windows.Clipboard.SetText(CodeLabel.Text);
    private void Browser_Click(object sender, System.Windows.RoutedEventArgs e) => Process.Start(new ProcessStartInfo(verificationUri) { UseShellExecute = true });
    private void Cancel_Click(object sender, System.Windows.RoutedEventArgs e) => Close();
    public void SetStatus(string value) => Dispatcher.InvokeAsync(() => StatusLabel.Text = value);
    public void CloseAfterSuccess() => Dispatcher.InvokeAsync(() => { programmaticClose = true; Close(); });
    public void CloseAfterFailure() => Dispatcher.InvokeAsync(() => { programmaticClose = true; Close(); });
}
