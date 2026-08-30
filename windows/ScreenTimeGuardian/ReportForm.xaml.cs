using System.Globalization;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using WpfButton = System.Windows.Controls.Button;
using WpfClipboard = System.Windows.Clipboard;
using WpfColor = System.Windows.Media.Color;
using WpfPen = System.Windows.Media.Pen;
using WpfPoint = System.Windows.Point;

namespace ScreenTimeGuardian;

internal sealed record DeviceDayReport(string DeviceID, string DisplayName, bool[] Minutes, int UsedMinutes, bool IsAggregate);
internal sealed record DailyUsagePoint(DateOnly Date, string DeviceID, string DisplayName, int Minutes, bool IsAggregate);

internal partial class ReportForm : Window
{
    private readonly TrayAppContext app;
    private IReadOnlyList<DeviceDayReport> reports = [];
    private IReadOnlyList<DailyUsagePoint> rangePoints = [];

    public ReportForm(TrayAppContext app)
    {
        InitializeComponent(); WindowLayout.FitToWorkingArea(this, 0.9, 0.86); this.app = app;
        var today = TimeModel.LocalDate(DateTimeOffset.Now, app.Settings.ReportTimeZone);
        DailyDatePicker.SelectedDate = today.ToDateTime(TimeOnly.MinValue);
        EndDatePicker.SelectedDate = today.ToDateTime(TimeOnly.MinValue);
        StartDatePicker.SelectedDate = today.AddDays(-6).ToDateTime(TimeOnly.MinValue);
        RefreshDailyReport(); RefreshRangeReport();
    }

    private void RefreshDailyReport()
    {
        var selected = DailyDatePicker.SelectedDate ?? DateTime.Today;
        var date = DateOnly.FromDateTime(selected);
        reports = app.ReportForDate(date);
        var aggregate = reports.FirstOrDefault(value => value.IsAggregate);
        var local = reports.FirstOrDefault(value => value.DeviceID.Equals(app.Settings.DeviceID, StringComparison.OrdinalIgnoreCase));
        AllValue.Text = DashboardForm.Duration(aggregate?.UsedMinutes ?? 0); LocalValue.Text = DashboardForm.Duration(local?.UsedMinutes ?? 0); PlanValue.Text = DashboardForm.Duration(app.Settings.DailyPlanMinutes);
        StatusLabel.Text = $"{date:yyyy-MM-dd} · {app.SyncStatus}";
        ReportCards.Children.Clear(); foreach (var report in reports) ReportCards.Children.Add(Card(report));
    }

    private void RefreshRangeReport()
    {
        var start = DateOnly.FromDateTime(StartDatePicker.SelectedDate ?? DateTime.Today.AddDays(-6));
        var end = DateOnly.FromDateTime(EndDatePicker.SelectedDate ?? DateTime.Today);
        rangePoints = app.MultiDayReport(start, end); UsageChart.Points = rangePoints;
        var series = rangePoints.Select(value => value.DeviceID).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        RangeStatusLabel.Text = $"{(start <= end ? start : end):yyyy-MM-dd} – {(start <= end ? end : start):yyyy-MM-dd} · {series} lines · one point per local report day · {app.SyncStatus}";
    }

    private static Border Card(DeviceDayReport report)
    {
        var root = new Grid(); root.RowDefinitions.Add(new() { Height = GridLength.Auto }); root.RowDefinitions.Add(new() { Height = new GridLength(112) });
        root.Children.Add(new TextBlock { Text = $"{report.DisplayName}, {DashboardForm.Duration(report.UsedMinutes)}.  Active intervals: {UsageIntervals(report.Minutes)}", FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 5) });
        var bitmap = new MinuteBitmapControl(report.Minutes) { MinWidth = 320, Height = 112 }; Grid.SetRow(bitmap, 1); root.Children.Add(bitmap);
        return new Border { Style = (Style)System.Windows.Application.Current.Resources["Card"], Padding = new Thickness(12, 9, 12, 9), Child = root, Margin = new Thickness(0, 0, 0, 9) };
    }

    private async void Sync_Click(object sender, RoutedEventArgs e) { if (sender is WpfButton button) button.IsEnabled = false; try { await app.SyncAsync(); RefreshCurrent(); } finally { if (sender is WpfButton value) value.IsEnabled = true; } }
    private void Refresh_Click(object sender, RoutedEventArgs e) => RefreshCurrent();
    private void DailyDate_Changed(object sender, SelectionChangedEventArgs e) { if (IsLoaded) RefreshDailyReport(); }
    private void Today_Click(object sender, RoutedEventArgs e) { var today = TimeModel.LocalDate(DateTimeOffset.Now, app.Settings.ReportTimeZone); DailyDatePicker.SelectedDate = today.ToDateTime(TimeOnly.MinValue); RefreshDailyReport(); }
    private void Range_Click(object sender, RoutedEventArgs e) => RefreshRangeReport();
    private void ReportTabs_SelectionChanged(object sender, SelectionChangedEventArgs e) { if (IsLoaded && e.Source == ReportTabs) RefreshCurrent(); }
    private void RefreshCurrent() { if (ReportTabs.SelectedIndex == 0) RefreshDailyReport(); else RefreshRangeReport(); }
    private void Copy_Click(object sender, RoutedEventArgs e) => WpfClipboard.SetText(ReportTabs.SelectedIndex == 0 ? CopyDailyText() : RangeCsv());
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
    private void Export_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "CSV files (*.csv)|*.csv", FileName = ReportTabs.SelectedIndex == 0 ? "stg-daily-report.csv" : "stg-multi-day-report.csv" }; if (dialog.ShowDialog(this) != true) return;
        File.WriteAllText(dialog.FileName, ReportTabs.SelectedIndex == 0 ? DailyCsv() : RangeCsv(), new UTF8Encoding(true));
        if (ReportTabs.SelectedIndex == 0) StatusLabel.Text = $"Exported to {dialog.FileName}"; else RangeStatusLabel.Text = $"Exported to {dialog.FileName}";
    }

    private string DailyCsv()
    {
        var date = DateOnly.FromDateTime(DailyDatePicker.SelectedDate ?? DateTime.Today);
        var builder = new StringBuilder("date,device_id,device_name,minutes,report_timezone,estimated,bitmap\r\n");
        foreach (var report in reports) { var bits = string.Concat(report.Minutes.Select(value => value ? '1' : '0')); builder.Append(date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)).Append(',').Append(Csv(report.DeviceID)).Append(',').Append(Csv(report.DisplayName)).Append(',').Append(report.UsedMinutes).Append(',').Append(Csv(app.Settings.ReportTimeZone)).Append(",true,").Append(bits).Append("\r\n"); }
        return builder.ToString();
    }

    private string RangeCsv()
    {
        var builder = new StringBuilder("date,device_id,device_name,minutes,report_timezone,estimated\r\n");
        foreach (var point in rangePoints.OrderBy(value => value.Date).ThenBy(value => value.DisplayName)) builder.Append(point.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)).Append(',').Append(Csv(point.DeviceID)).Append(',').Append(Csv(point.DisplayName)).Append(',').Append(point.Minutes).Append(',').Append(Csv(app.Settings.ReportTimeZone)).Append(",true\r\n");
        return builder.ToString();
    }

    private string CopyDailyText()
    {
        var date = DateOnly.FromDateTime(DailyDatePicker.SelectedDate ?? DateTime.Today); var aggregate = reports.FirstOrDefault(value => value.IsAggregate); var local = reports.FirstOrDefault(value => value.DeviceID.Equals(app.Settings.DeviceID, StringComparison.OrdinalIgnoreCase));
        var lines = new List<string> { $"STG {date:yyyy-MM-dd} · {app.Settings.ReportTimeZone}", $"All devices: {DashboardForm.Duration(aggregate?.UsedMinutes ?? 0)}", $"This PC: {DashboardForm.Duration(local?.UsedMinutes ?? 0)}", $"Plan: {DashboardForm.Duration(app.Settings.DailyPlanMinutes)}" }; lines.AddRange(reports.Select(value => $"{value.DisplayName}: {DashboardForm.Duration(value.UsedMinutes)} · {UsageIntervals(value.Minutes)}")); return string.Join(Environment.NewLine, lines);
    }

    private static string UsageIntervals(bool[] minutes) { var ranges = new List<string>(); for (var index = 0; index < minutes.Length;) { if (!minutes[index]) { index++; continue; } var start = index; while (index < minutes.Length && minutes[index]) index++; ranges.Add($"{ClockLabel(start)}–{ClockLabel(index)}"); } return ranges.Count == 0 ? "None" : string.Join(", ", ranges); }
    private static string ClockLabel(int minute) => minute >= 1440 ? "24:00" : $"{minute / 60:00}:{minute % 60:00}";
    private static string Csv(string value) => value.IndexOfAny([',', '"', '\r', '\n']) < 0 ? value : $"\"{value.Replace("\"", "\"\"")}\"";
}

internal sealed class UsageLineChartControl : FrameworkElement
{
    private IReadOnlyList<DailyUsagePoint> points = [];
    public IReadOnlyList<DailyUsagePoint> Points { get => points; set { points = value; InvalidateVisual(); } }
    private static readonly WpfColor[] Palette = [WpfColor.FromRgb(15, 118, 110), WpfColor.FromRgb(37, 99, 235), WpfColor.FromRgb(234, 88, 12), WpfColor.FromRgb(147, 51, 234), WpfColor.FromRgb(190, 24, 93), WpfColor.FromRgb(22, 163, 74), WpfColor.FromRgb(71, 85, 105)];

    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc); var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip; var face = new Typeface("Segoe UI");
        if (points.Count == 0) { DrawText(dc, "No report data for this range", 20, 20, 15, WpfColor.FromRgb(100, 116, 139), face, dpi); return; }
        var series = points.GroupBy(value => value.DeviceID, StringComparer.OrdinalIgnoreCase).OrderByDescending(value => value.First().IsAggregate).ThenBy(value => value.First().DisplayName).ToList();
        var dates = points.Select(value => value.Date).Distinct().Order().ToList(); var maxMinutes = Math.Max(60, points.Max(value => value.Minutes)); var yMax = ((maxMinutes + 59) / 60) * 60;
        var left = 66d; var top = 48d; var right = Math.Min(250d, Math.Max(170d, ActualWidth * .22)); var bottom = 58d; var plotWidth = Math.Max(240, ActualWidth - left - right); var plotHeight = Math.Max(180, ActualHeight - top - bottom);
        var grid = new WpfPen(new SolidColorBrush(WpfColor.FromRgb(220, 228, 236)), 1); var axis = new WpfPen(new SolidColorBrush(WpfColor.FromRgb(100, 116, 139)), 1);
        for (var tick = 0; tick <= 4; tick++) { var minutes = yMax * tick / 4; var y = top + plotHeight - plotHeight * tick / 4; dc.DrawLine(grid, new WpfPoint(left, y), new WpfPoint(left + plotWidth, y)); DrawText(dc, $"{minutes / 60}h {minutes % 60}m", 4, y - 8, 11, WpfColor.FromRgb(100, 116, 139), face, dpi); }
        dc.DrawLine(axis, new WpfPoint(left, top), new WpfPoint(left, top + plotHeight)); dc.DrawLine(axis, new WpfPoint(left, top + plotHeight), new WpfPoint(left + plotWidth, top + plotHeight));
        var labelEvery = Math.Max(1, (int)Math.Ceiling(dates.Count / 8d));
        for (var i = 0; i < dates.Count; i++) { if (i % labelEvery != 0 && i != dates.Count - 1) continue; var x = X(i); DrawText(dc, dates[i].ToString("MM-dd", CultureInfo.InvariantCulture), x - 17, top + plotHeight + 10, 10, WpfColor.FromRgb(100, 116, 139), face, dpi); }
        for (var seriesIndex = 0; seriesIndex < series.Count; seriesIndex++)
        {
            var group = series[seriesIndex]; var color = Palette[seriesIndex % Palette.Length]; var pen = new WpfPen(new SolidColorBrush(color), group.First().IsAggregate ? 3 : 2); var byDate = group.ToDictionary(value => value.Date); WpfPoint? previous = null;
            for (var index = 0; index < dates.Count; index++) { if (!byDate.TryGetValue(dates[index], out var point)) { previous = null; continue; } var current = new WpfPoint(X(index), top + plotHeight - point.Minutes * plotHeight / yMax); if (previous is not null) dc.DrawLine(pen, previous.Value, current); dc.DrawEllipse(new SolidColorBrush(color), null, current, group.First().IsAggregate ? 4 : 3, group.First().IsAggregate ? 4 : 3); previous = current; }
            var legendY = top + seriesIndex * 27; dc.DrawLine(pen, new WpfPoint(left + plotWidth + 20, legendY + 8), new WpfPoint(left + plotWidth + 48, legendY + 8)); DrawText(dc, group.First().DisplayName, left + plotWidth + 56, legendY, 12, WpfColor.FromRgb(24, 35, 48), face, dpi);
        }
        double X(int index) => left + (dates.Count == 1 ? plotWidth / 2 : index * plotWidth / (dates.Count - 1));
    }

    private static void DrawText(DrawingContext dc, string value, double x, double y, double size, WpfColor color, Typeface face, double dpi) => dc.DrawText(new FormattedText(value, CultureInfo.CurrentCulture, System.Windows.FlowDirection.LeftToRight, face, size, new SolidColorBrush(color), dpi), new WpfPoint(x, y));
}

internal sealed class MinuteBitmapControl(bool[] minutes) : FrameworkElement
{
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc); var left = 58d; var plotWidth = Math.Max(240, ActualWidth - left - 8); var rowHeight = ActualHeight / 4; var active = new SolidColorBrush(WpfColor.FromRgb(15, 136, 123)); var inactive = new SolidColorBrush(WpfColor.FromRgb(232, 238, 242)); var grid = new WpfPen(new SolidColorBrush(WpfColor.FromRgb(148, 163, 184)), 1); var typeface = new Typeface("Segoe UI");
        for (var row = 0; row < 4; row++)
        {
            var y = row * rowHeight; DrawText(dc, $"{row * 6:00}–{(row + 1) * 6:00}", 0, y + 7, typeface); dc.DrawRectangle(inactive, null, new Rect(left, y + 8, plotWidth, Math.Max(10, rowHeight - 14))); var cell = plotWidth / 360;
            for (var offset = 0; offset < 360; offset++) { var index = row * 360 + offset; if (index < minutes.Length && minutes[index]) dc.DrawRectangle(active, null, new Rect(left + offset * cell, y + 8, Math.Max(1, cell), Math.Max(10, rowHeight - 14))); }
            for (var hour = 0; hour <= 6; hour++) { var x = left + hour * plotWidth / 6; dc.DrawLine(grid, new WpfPoint(x, y + 5), new WpfPoint(x, y + rowHeight - 4)); if (hour < 6) DrawText(dc, $"{row * 6 + hour:00}", x + 3, y - 1, typeface); }
        }
    }
    private void DrawText(DrawingContext dc, string value, double x, double y, Typeface typeface) => dc.DrawText(new FormattedText(value, CultureInfo.CurrentCulture, System.Windows.FlowDirection.LeftToRight, typeface, 11, new SolidColorBrush(WpfColor.FromRgb(100, 116, 139)), VisualTreeHelper.GetDpi(this).PixelsPerDip), new WpfPoint(x, y));
}
