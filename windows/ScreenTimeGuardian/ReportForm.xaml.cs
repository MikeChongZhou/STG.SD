using System.Globalization;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using WpfButton = System.Windows.Controls.Button;
using WpfColor = System.Windows.Media.Color;
using WpfPen = System.Windows.Media.Pen;
using WpfPoint = System.Windows.Point;

namespace ScreenTimeGuardian;

internal sealed record DeviceDayReport(string DeviceID, string DisplayName, bool[] Minutes, int UsedMinutes, bool IsAggregate);
internal sealed record DailyUsagePoint(DateOnly Date, string DeviceID, string DisplayName, int Minutes, bool IsAggregate, bool Estimated = false);
internal readonly record struct MinuteBitmapSegment(int Start, int End) { public int Count => End - Start; }

internal partial class ReportForm : Window
{
    private readonly TrayAppContext app;
    private IReadOnlyList<DeviceDayReport> reports = [];
    private IReadOnlyList<DailyUsagePoint> rangePoints = [];
    private DateOnly dailyDate;
    private DateOnly rangeStart;
    private DateOnly rangeEnd;

    public ReportForm(TrayAppContext app)
    {
        InitializeComponent(); L.Apply(this); WindowLayout.FitToWorkingArea(this, 0.96, 0.9); this.app = app;
        var today = TimeModel.LocalDate(DateTimeOffset.Now, app.CurrentReportTimeZone);
        dailyDate = today; rangeEnd = today; rangeStart = today.AddDays(-6);
        SetCalendar(DailyCalendar, dailyDate); SetCalendar(StartCalendar, rangeStart); SetCalendar(EndCalendar, rangeEnd);
        UpdateDateButtons();
        RefreshDailyReport(); RefreshRangeReport();
    }

    private void RefreshDailyReport()
    {
        var date = dailyDate;
        reports = app.ReportForDate(date);
        var aggregate = reports.FirstOrDefault(value => value.IsAggregate);
        var local = reports.FirstOrDefault(value => value.DeviceID.Equals(app.Settings.DeviceID, StringComparison.OrdinalIgnoreCase));
        AllValue.Text = DashboardForm.Duration(aggregate?.UsedMinutes ?? 0); LocalValue.Text = DashboardForm.Duration(local?.UsedMinutes ?? 0); PlanValue.Text = DashboardForm.Duration(app.Settings.DailyPlanMinutes);
        StatusLabel.Text = $"{date:yyyy-MM-dd} · {app.SyncStatus}";
        UpdateStatisticsSummary();
        var alignedSegments = MinuteBitmapControl.VisibleSegments(CombinedMinutes(reports));
        ReportCards.Children.Clear(); foreach (var report in reports) ReportCards.Children.Add(Card(report, alignedSegments));
    }

    private void RefreshRangeReport()
    {
        var start = rangeStart;
        var end = rangeEnd;
        rangePoints = app.MultiDayReport(start, end); UsageChart.Points = rangePoints;
        var series = rangePoints.Select(value => value.DeviceID).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        var average = rangePoints.Where(value => value.IsAggregate).Select(value => value.Minutes).DefaultIfEmpty().Average();
        RangeStatusLabel.Text = $"{(start <= end ? start : end):yyyy-MM-dd} – {(start <= end ? end : start):yyyy-MM-dd} · {series} lines · interval average {DashboardForm.Duration((int)Math.Round(average))}{EstimatedSuffix(rangePoints.Any(value => value.Estimated))} · {app.SyncStatus}";
        UpdateStatisticsSummary();
    }

    private void RefreshYearWeeks()
    {
        var year = DateTime.Now.Year; var start = new DateOnly(year, 1, 1); var end = new DateOnly(year, 12, 31);
        var points = app.PeriodReport("week", start, end);
        YearChart.Points = points.Select(value => new DailyUsagePoint(value.PeriodStart, value.DeviceID, value.DisplayName, (int)Math.Round(value.AverageDailyMinutes), value.DeviceID == "alldevices", value.Estimated)).ToList();
        YearStatusLabel.Text = $"{year} · weekly average daily use · {points.Select(value => value.DeviceID).Distinct().Count()} lines{EstimatedSuffix(points.Any(value => value.Estimated))}";
        UpdateStatisticsSummary();
    }

    private void RefreshYearsMonths()
    {
        var end = new DateOnly(DateTime.Now.Year, DateTime.Now.Month, 1).AddMonths(1).AddDays(-1); var start = end.AddYears(-2).AddDays(1);
        var points = app.PeriodReport("month", start, end);
        MonthChart.Points = points.Select(value => new DailyUsagePoint(value.PeriodStart, value.DeviceID, value.DisplayName, (int)Math.Round(value.AverageDailyMinutes), value.DeviceID == "alldevices", value.Estimated)).ToList();
        MonthStatusLabel.Text = $"{start:yyyy-MM} – {end:yyyy-MM} · monthly average daily use · {points.Select(value => value.DeviceID).Distinct().Count()} lines{EstimatedSuffix(points.Any(value => value.Estimated))}";
        UpdateStatisticsSummary();
    }

    private void UpdateStatisticsSummary()
    {
        var value = app.StatisticsSummary;
        StatisticsSummaryLabel.Text = $"This week {Average(value.ThisWeekAverageMinutes)}   Last week {Average(value.LastWeekAverageMinutes)}   This month {Average(value.ThisMonthAverageMinutes)}   Last month {Average(value.LastMonthAverageMinutes)}   This year {Average(value.ThisYearAverageMinutes)}{EstimatedSuffix(value.ContainsEstimatedIosData)}";
    }

    private static string Average(double? minutes) => minutes is null ? "—" : DashboardForm.Duration((int)Math.Round(minutes.Value));
    private static string EstimatedSuffix(bool estimated) => estimated ? " · Includes estimated iOS data" : "";

    private static bool[] CombinedMinutes(IReadOnlyList<DeviceDayReport> values)
    {
        var count = values.Select(value => value.Minutes.Length).DefaultIfEmpty().Max();
        var combined = new bool[count];
        foreach (var value in values) for (var index = 0; index < Math.Min(count, value.Minutes.Length); index++) combined[index] |= value.Minutes[index];
        return combined;
    }

    private static Border Card(DeviceDayReport report, IReadOnlyList<MinuteBitmapSegment> alignedSegments)
    {
        var bitmapHeight = report.UsedMinutes > 0 ? MinuteBitmapControl.PreferredHeight(alignedSegments) : 0;
        var root = new Grid(); root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var heading = new TextBlock { FontSize = 14, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 5) };
        heading.Inlines.Add(new Run($"{report.DisplayName}, {DashboardForm.Duration(report.UsedMinutes)}.  ") { FontWeight = FontWeights.SemiBold });
        heading.Inlines.Add(new Run($"Active intervals: {UsageIntervals(report.Minutes)}") { FontWeight = FontWeights.Normal });
        root.Children.Add(heading);
        if (report.UsedMinutes > 0)
        {
            root.RowDefinitions.Add(new() { Height = new GridLength(bitmapHeight) });
            var bitmap = new MinuteBitmapControl(report.Minutes, alignedSegments) { MinWidth = 900, Height = bitmapHeight, HorizontalAlignment = System.Windows.HorizontalAlignment.Stretch }; Grid.SetRow(bitmap, 1); root.Children.Add(bitmap);
        }
        return new Border { Style = (Style)System.Windows.Application.Current.Resources["Card"], Padding = new Thickness(12, 9, 12, 9), Child = root, Margin = new Thickness(0, 0, 0, 9), HorizontalAlignment = System.Windows.HorizontalAlignment.Stretch };
    }

    private async void Sync_Click(object sender, RoutedEventArgs e) { if (sender is WpfButton button) button.IsEnabled = false; try { await app.SyncAsync(); RefreshCurrent(); } finally { if (sender is WpfButton value) value.IsEnabled = true; } }
    private void Refresh_Click(object sender, RoutedEventArgs e) => RefreshCurrent();
    private void DailyDate_Click(object sender, RoutedEventArgs e) => DailyDatePopup.IsOpen = true;
    private void StartDate_Click(object sender, RoutedEventArgs e) => StartDatePopup.IsOpen = true;
    private void EndDate_Click(object sender, RoutedEventArgs e) => EndDatePopup.IsOpen = true;
    private void DailyCalendar_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (DailyCalendar.SelectedDate is not DateTime value) return;
        dailyDate = DateOnly.FromDateTime(value); UpdateDateButtons(); DailyDatePopup.IsOpen = false; if (IsLoaded) RefreshDailyReport();
    }
    private void StartCalendar_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (StartCalendar.SelectedDate is not DateTime value) return;
        rangeStart = DateOnly.FromDateTime(value); UpdateDateButtons(); StartDatePopup.IsOpen = false; if (IsLoaded) RefreshRangeReport();
    }
    private void EndCalendar_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (EndCalendar.SelectedDate is not DateTime value) return;
        rangeEnd = DateOnly.FromDateTime(value); UpdateDateButtons(); EndDatePopup.IsOpen = false; if (IsLoaded) RefreshRangeReport();
    }
    private void ReportTabs_SelectionChanged(object sender, SelectionChangedEventArgs e) { if (IsLoaded && e.Source == ReportTabs) RefreshCurrent(); }
    private void RefreshCurrent() { if (ReportTabs.SelectedIndex == 0) RefreshDailyReport(); else if (ReportTabs.SelectedIndex == 1) RefreshRangeReport(); else if (ReportTabs.SelectedIndex == 2) RefreshYearWeeks(); else RefreshYearsMonths(); }
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
    private void Export_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "CSV files (*.csv)|*.csv", FileName = ReportTabs.SelectedIndex == 0 ? "stg-daily-report.csv" : "stg-statistics-report.csv" }; if (dialog.ShowDialog(this) != true) return;
        File.WriteAllText(dialog.FileName, ReportTabs.SelectedIndex == 0 ? DailyCsv() : RangeCsv(), new UTF8Encoding(true));
        if (ReportTabs.SelectedIndex == 0) StatusLabel.Text = $"Exported to {dialog.FileName}"; else if (ReportTabs.SelectedIndex == 1) RangeStatusLabel.Text = $"Exported to {dialog.FileName}";
    }

    private string DailyCsv()
    {
        var date = dailyDate;
        var builder = new StringBuilder("date,device_id,device_name,minutes,report_timezone,estimated,bitmap\r\n");
        foreach (var report in reports) { var bits = string.Concat(report.Minutes.Select(value => value ? '1' : '0')); builder.Append(date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)).Append(',').Append(Csv(report.DeviceID)).Append(',').Append(Csv(report.DisplayName)).Append(',').Append(report.UsedMinutes).Append(',').Append(Csv(app.CurrentReportTimeZone)).Append(',').Append(app.IsEstimatedReport(report.DeviceID) ? "true" : "false").Append(',').Append(bits).Append("\r\n"); }
        return builder.ToString();
    }

    private string RangeCsv()
    {
        var builder = new StringBuilder("date,device_id,device_name,minutes,report_timezone,estimated\r\n");
        foreach (var point in rangePoints.OrderBy(value => value.Date).ThenBy(value => value.DisplayName)) builder.Append(point.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)).Append(',').Append(Csv(point.DeviceID)).Append(',').Append(Csv(point.DisplayName)).Append(',').Append(point.Minutes).Append(',').Append(Csv(app.CurrentReportTimeZone)).Append(',').Append(point.Estimated ? "true" : "false").Append("\r\n");
        return builder.ToString();
    }

    private void UpdateDateButtons()
    {
        DailyDateButton.Content = dailyDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        StartDateButton.Content = rangeStart.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        EndDateButton.Content = rangeEnd.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    }

    private static void SetCalendar(System.Windows.Controls.Calendar calendar, DateOnly date)
    {
        var value = date.ToDateTime(TimeOnly.MinValue); calendar.DisplayDate = value; calendar.SelectedDate = value;
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

internal sealed class MinuteBitmapControl(bool[] minutes, IReadOnlyList<MinuteBitmapSegment> segments) : FrameworkElement
{
    private const int SegmentMinutes = 360;

    internal static double PreferredHeight(IReadOnlyList<MinuteBitmapSegment> source)
    {
        var segmentCount = source.Count;
        return segmentCount == 0 ? 20 : segmentCount * 32;
    }

    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip; var typeface = new Typeface("Segoe UI");
        if (segments.Count == 0) { DrawText(dc, "No Activity", 2, 7, 12, WpfColor.FromRgb(100, 116, 139), typeface, dpi); return; }
        var plotWidth = Math.Max(240, ActualWidth - 8); var rowHeight = ActualHeight / segments.Count;
        var active = new SolidColorBrush(WpfColor.FromRgb(15, 136, 123)); var inactive = new SolidColorBrush(WpfColor.FromArgb(56, 100, 116, 139));
        var baselinePen = new WpfPen(new SolidColorBrush(WpfColor.FromArgb(34, 100, 116, 139)), .5);
        for (var row = 0; row < segments.Count; row++)
        {
            var segment = segments[row]; var y = row * rowHeight; var canvasTop = y + 13; var canvasHeight = Math.Max(14, rowHeight - 14); var baselineY = canvasTop + canvasHeight * .58; var minuteWidth = plotWidth / segment.Count;
            dc.DrawLine(baselinePen, new WpfPoint(0, baselineY), new WpfPoint(plotWidth, baselineY));
            for (var boundary = segment.Start; boundary <= segment.End; boundary += 60)
            {
                var progress = (boundary - segment.Start) / (double)segment.Count; var x = Math.Clamp(progress * plotWidth, 0, Math.Max(0, plotWidth - 20));
                DrawText(dc, $"{boundary / 60:00}", x, y, 11, WpfColor.FromRgb(100, 116, 139), typeface, dpi);
            }
            for (var offset = 0; offset <= segment.Count; offset += 5)
            {
                var absolute = segment.Start + offset; var x = offset * minuteWidth; var hour = absolute % 60 == 0; var halfHour = absolute % 30 == 0;
                var length = hour ? canvasHeight : halfHour ? canvasHeight * .58 : canvasHeight * .32;
                var color = WpfColor.FromArgb(hour ? (byte)107 : halfHour ? (byte)71 : (byte)43, 100, 116, 139);
                dc.DrawLine(new WpfPen(new SolidColorBrush(color), hour ? .8 : .5), new WpfPoint(x, baselineY - length / 2), new WpfPoint(x, baselineY + length / 2));
            }
            int? runStart = null;
            for (var offset = 0; offset <= segment.Count; offset++)
            {
                var index = segment.Start + offset; var isActive = offset < segment.Count && index < minutes.Length && minutes[index];
                if (isActive && runStart is null) runStart = offset;
                if (!isActive && runStart is int start)
                {
                    var end = offset - 1;
                    if (end > start) dc.DrawLine(new WpfPen(active, 2.2) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, new WpfPoint((start + .5) * minuteWidth, baselineY), new WpfPoint((end + .5) * minuteWidth, baselineY));
                    runStart = null;
                }
            }
            for (var offset = 0; offset < segment.Count; offset++)
            {
                var index = segment.Start + offset; var isActive = index < minutes.Length && minutes[index]; var radius = isActive ? 1.25 : .62;
                dc.DrawEllipse(isActive ? active : inactive, null, new WpfPoint((offset + .5) * minuteWidth, baselineY), radius, radius);
            }
        }
    }

    internal static IReadOnlyList<MinuteBitmapSegment> VisibleSegments(bool[] source)
    {
        var result = new List<MinuteBitmapSegment>(); var count = Math.Min(source.Length, 1440); var cursor = 0;
        while (cursor < count)
        {
            var first = -1; for (var index = cursor; index < count; index++) if (source[index]) { first = index; break; }
            if (first < 0) break;
            var start = first / 60 * 60; var end = Math.Min(start + SegmentMinutes, 1440); result.Add(new(start, end)); cursor = end;
        }
        return result;
    }

    private static void DrawText(DrawingContext dc, string value, double x, double y, double size, WpfColor color, Typeface typeface, double dpi) => dc.DrawText(new FormattedText(value, CultureInfo.CurrentCulture, System.Windows.FlowDirection.LeftToRight, typeface, size, new SolidColorBrush(color), dpi), new WpfPoint(x, y));
}
