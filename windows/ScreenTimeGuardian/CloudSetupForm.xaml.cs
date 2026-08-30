namespace ScreenTimeGuardian;

internal partial class CloudSetupForm : System.Windows.Window
{
    private readonly TrayAppContext app; private bool loading = true;
    public CloudSetupForm(TrayAppContext app) { InitializeComponent(); this.app = app; ProviderBox.ItemsSource = new[] { new Choice("Off — single device", SyncProvider.None), new Choice("Apple iCloud Drive", SyncProvider.ICloudDrive), new Choice("Microsoft OneDrive", SyncProvider.OneDrive), new Choice("Google Drive", SyncProvider.GoogleDrive) }; ProviderBox.SelectedIndex = app.Settings.SyncProvider switch { SyncProvider.ICloudDrive => 1, SyncProvider.OneDrive => 2, SyncProvider.GoogleDrive => 3, _ => 0 }; loading = false; UpdateRecommendation(); UpdateAccount(); }
    private SyncProvider Selected => ProviderBox.SelectedItem is Choice choice ? choice.Value : SyncProvider.None;
    private SyncProvider Recommended => ChinaBox.IsChecked == true ? SyncProvider.OneDrive : SyncProvider.GoogleDrive;
    private void Choice_Changed(object sender, System.Windows.RoutedEventArgs e) { UpdateRecommendation(); if (!loading) ProviderBox.SelectedIndex = Recommended == SyncProvider.OneDrive ? 2 : 3; }
    private void UpdateRecommendation() { RecommendationLabel.Text = Recommended == SyncProvider.OneDrive ? "Microsoft OneDrive" : "Google Drive"; }
    private void Provider_Changed(object sender, System.Windows.Controls.SelectionChangedEventArgs e) { if (!loading) UpdateAccount(); }
    private void UpdateAccount() { var signed = app.ProviderSignedIn(Selected); AccountLabel.Text = Selected == SyncProvider.None ? "No account — this PC only" : signed ? $"Connected through {app.ProviderAccountLabel(Selected)}" : Selected == SyncProvider.ICloudDrive ? "Open iCloud for Windows, sign in, and turn on iCloud Drive" : "Not signed in"; ConnectButton.Visibility = Selected == SyncProvider.None ? System.Windows.Visibility.Collapsed : System.Windows.Visibility.Visible; ConnectButton.Content = Selected == SyncProvider.ICloudDrive ? "Check iCloud Drive…" : signed ? "Reconnect account…" : "Connect account…"; SignOutButton.Visibility = signed && Selected != SyncProvider.ICloudDrive ? System.Windows.Visibility.Visible : System.Windows.Visibility.Collapsed; StatusLabel.Text = app.SyncStatus; }
    private async void Connect_Click(object sender, System.Windows.RoutedEventArgs e) { if (Selected == SyncProvider.None) return; app.Settings.SyncProvider = Selected; app.SaveSettings(); ConnectButton.IsEnabled = false; try { await app.SignInAsync(Selected, this); } finally { ConnectButton.IsEnabled = true; UpdateAccount(); } }
    private void SignOut_Click(object sender, System.Windows.RoutedEventArgs e) { app.SignOut(Selected); UpdateAccount(); }
    private void Save_Click(object sender, System.Windows.RoutedEventArgs e) { app.Settings.SyncProvider = Selected; app.SaveSettings(); Close(); }
    private void Cancel_Click(object sender, System.Windows.RoutedEventArgs e) => Close();
    private sealed record Choice(string Label, SyncProvider Value) { public override string ToString() => Label; }
}
