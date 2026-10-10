using System.ComponentModel;
using System.Globalization;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using WpfColor = System.Windows.Media.Color;
using WpfPen = System.Windows.Media.Pen;
using WpfPoint = System.Windows.Point;

namespace ScreenTimeGuardian;

internal enum WeeklyMetric { Rank, InputTokens, OutputTokens, TotalTokens, InputPrice, OutputPrice, Revenue }

internal partial class TrackingForm : Window
{
    private readonly TrayAppContext app;
    private readonly CancellationTokenSource cancellation = new();
    private bool isInitialized;
    private DateOnly startDate;
    private IReadOnlyList<RankingRow> rows = [];
    private IReadOnlyList<WeeklyRankingRow> weeklyRows = [];
    private RankingSnapshot? snapshot;

    public TrackingForm(TrayAppContext app)
    {
        // XAML can raise SelectionChanged while InitializeComponent is still
        // constructing the tab content. Store the app first and ignore those
        // premature events until every named control exists.
        this.app = app ?? throw new ArgumentNullException(nameof(app));
        InitializeComponent(); L.Apply(this); WindowLayout.FitToWorkingArea(this, 0.91, 0.87);
        startDate = DateOnly.FromDateTime(DateTime.UtcNow.Date.AddDays(-7));
        var initialDate = startDate.ToDateTime(TimeOnly.MinValue);
        StartCalendar.DisplayDate = initialDate;
        StartCalendar.SelectedDate = initialDate;
        UpdateStartDateButton();
        MetricBox.ItemsSource = new[] { "Rank", "Input tokens", "Output tokens", "Total tokens", "Input price / M", "Output price / M", "Revenue" }; MetricBox.SelectedIndex = 3;
        ExportButton.IsEnabled = false;
        isInitialized = true;
        Loaded += (_, _) => LoadWeeklyChart();
        Closed += (_, _) => cancellation.Cancel();
    }

    private void LoadWeeklyChart()
    {
        try
        {
            RefreshWeeklyChart();
        }
        catch (Exception error)
        {
            ShowTrackingError("Could not load saved weekly tracking data", error);
        }
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshTopAsync();
    private void StartDate_Click(object sender, RoutedEventArgs e) => StartDatePopup.IsOpen = true;
    private void StartCalendar_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (StartCalendar.SelectedDate is not DateTime value) return;
        startDate = DateOnly.FromDateTime(value);
        UpdateStartDateButton();
        StartDatePopup.IsOpen = false;
    }
    private void UpdateStartDateButton() => StartDateButton.Content = startDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    private async Task RefreshTopAsync()
    {
        var start = startDate; var end = DateOnly.FromDateTime(DateTime.UtcNow.Date.AddDays(-1));
        StatusLabel.Text = "Loading OpenRouter public ranking…"; ExportButton.IsEnabled = false; app.TrackingLog($"OpenRouter refresh begin; start={start:yyyy-MM-dd}; end={end:yyyy-MM-dd}");
        try
        {
            snapshot = await new OpenRouterClient().Top20Async(start, end, cancellation.Token); rows = snapshot.Rows; RankingGrid.ItemsSource = rows; RankingGrid.Items.Refresh();
            StatusLabel.Text = $"Source: OpenRouter public APIs · {snapshot.StartDate:yyyy-MM-dd} – {snapshot.EndDate:yyyy-MM-dd} UTC · effective weighted prices include cache/provider discounts · revenue is estimated · as of {snapshot.AsOf:yyyy-MM-dd HH:mm:ss} UTC"; ExportButton.IsEnabled = rows.Count > 0;
            app.TrackingLog($"OpenRouter refresh complete; window={snapshot.StartDate:yyyy-MM-dd}...{snapshot.EndDate:yyyy-MM-dd}; rows={rows.Count}"); RefreshWeeklyChart();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception error) { rows = []; RankingGrid.ItemsSource = null; StatusLabel.Text = $"Could not load public ranking: {error.Message}"; app.TrackingLog($"OpenRouter refresh failed: {error.Message}"); }
    }

    private void RefreshWeeklyChart()
    {
        if (!isInitialized || WeeklyChart is null || MetricBox is null || TrackingTabs is null || ExportButton is null || TokenUnitLabel is null) return;
        var metric = (WeeklyMetric)Math.Max(0, MetricBox.SelectedIndex); var models = app.LatestOpenRouterTopModels(metric).ToList(); weeklyRows = app.OpenRouterWeeks(models); WeeklyChart.Points = weeklyRows; WeeklyChart.Metric = metric; TokenUnitLabel.Visibility = metric is WeeklyMetric.InputTokens or WeeklyMetric.OutputTokens or WeeklyMetric.TotalTokens ? Visibility.Visible : Visibility.Collapsed; ExportButton.IsEnabled = TrackingTabs.SelectedIndex == 0 ? rows.Count > 0 : weeklyRows.Count > 0;
        if (TrackingTabs.SelectedIndex == 1) StatusLabel.Text = weeklyRows.Count == 0 ? $"No saved weekly data contains {MetricBox.SelectedItem}." : $"Showing all saved weeks for the latest completed week's {MetricBox.SelectedItem} Top {models.Count}.";
    }

    private void Metric_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!isInitialized || WeeklyChart is null || MetricBox is null) return;
        RefreshWeeklyChart();
    }

    private async void TrackingTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!isInitialized || TrackingTabs is null || e.Source != TrackingTabs) return;
        try
        {
            if (TrackingTabs.SelectedIndex == 0 && rows.Count == 0) await RefreshTopAsync();
            else RefreshWeeklyChart();
        }
        catch (Exception error)
        {
            ShowTrackingError("Could not change the tracking view", error);
        }
    }

    private void ShowTrackingError(string message, Exception error)
    {
        rows = [];
        weeklyRows = [];
        if (RankingGrid is not null) RankingGrid.ItemsSource = null;
        if (WeeklyChart is not null) WeeklyChart.Points = [];
        if (ExportButton is not null) ExportButton.IsEnabled = false;
        if (StatusLabel is not null) StatusLabel.Text = $"{message}: {error.Message}";
        app.TrackingLog($"{message}; type={error.GetType().FullName}; error={error.Message}");
    }

    private void Grid_Sorting(object sender, DataGridSortingEventArgs e)
    {
        e.Handled = true; var property = e.Column.SortMemberPath; if (string.IsNullOrWhiteSpace(property)) return;
        var direction = e.Column.SortDirection == ListSortDirection.Descending ? ListSortDirection.Ascending : ListSortDirection.Descending;
        foreach (var column in RankingGrid.Columns) column.SortDirection = null; e.Column.SortDirection = direction;
        RankingGrid.ItemsSource = rows.OrderBy(row => row, Comparer<RankingRow>.Create((left, right) => CompareRows(left, right, property, direction))).ToList();
    }

    private void Export_Click(object sender, RoutedEventArgs e)
    {
        if (TrackingTabs.SelectedIndex == 0) ExportTop(); else ExportWeekly();
    }

    private void ExportTop()
    {
        if (snapshot is null || rows.Count == 0) return; var ordered = RankingGrid.ItemsSource.Cast<RankingRow>().ToList();
        var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "CSV files (*.csv)|*.csv", FileName = $"stg-openrouter-{snapshot.StartDate:yyyyMMdd}-latest.csv" }; if (dialog.ShowDialog(this) != true) return;
        var builder = new StringBuilder("period,window_start_utc,window_end_utc,rank,model,input_tokens,output_tokens,total_tokens,input_price_usd_per_token,output_price_usd_per_token,estimated_revenue_usd,as_of_utc\r\n");
        foreach (var row in ordered) builder.Append("date_to_latest,").Append(snapshot.StartDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)).Append(',').Append(snapshot.EndDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)).Append(',').Append(row.Rank).Append(',').Append(Csv(row.Model)).Append(',').Append(row.PromptTokens).Append(',').Append(row.CompletionTokens).Append(',').Append(row.TotalTokens).Append(',').Append(Number(row.PromptPricePerToken)).Append(',').Append(Number(row.CompletionPricePerToken)).Append(',').Append(Number(row.RevenueUSD)).Append(',').Append(snapshot.AsOf.UtcDateTime.ToString("O", CultureInfo.InvariantCulture)).Append("\r\n");
        File.WriteAllText(dialog.FileName, builder.ToString(), new UTF8Encoding(true)); StatusLabel.Text = $"Exported {ordered.Count} rows to {dialog.FileName}";
    }

    private void ExportWeekly()
    {
        if (weeklyRows.Count == 0) return; var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "CSV files (*.csv)|*.csv", FileName = "stg-openrouter-weekly-trends.csv" }; if (dialog.ShowDialog(this) != true) return;
        var builder = new StringBuilder("window_start_utc,window_end_utc,rank,model,input_tokens,output_tokens,total_tokens,input_price_usd_per_token,output_price_usd_per_token,estimated_revenue_usd\r\n");
        foreach (var row in weeklyRows.OrderBy(value => value.WindowStart).ThenBy(value => value.Rank)) builder.Append(row.WindowStart.ToString("yyyy-MM-dd")).Append(',').Append(row.WindowEnd.ToString("yyyy-MM-dd")).Append(',').Append(row.Rank).Append(',').Append(Csv(row.Model)).Append(',').Append(Token(row.PromptTokens)).Append(',').Append(Token(row.CompletionTokens)).Append(',').Append(row.TotalTokens).Append(',').Append(Number(row.PromptPricePerToken)).Append(',').Append(Number(row.CompletionPricePerToken)).Append(',').Append(Number(row.RevenueUSD)).Append("\r\n");
        File.WriteAllText(dialog.FileName, builder.ToString(), new UTF8Encoding(true)); StatusLabel.Text = $"Exported {weeklyRows.Count} model-week rows to {dialog.FileName}";
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();
    private static int CompareRows(RankingRow left, RankingRow right, string property, ListSortDirection direction)
    {
        int comparison;
        if (property == nameof(RankingRow.PromptPricePerMillion)) comparison = CompareNullable(left.PromptPricePerMillion, right.PromptPricePerMillion, direction);
        else if (property == nameof(RankingRow.CompletionPricePerMillion)) comparison = CompareNullable(left.CompletionPricePerMillion, right.CompletionPricePerMillion, direction);
        else if (property == nameof(RankingRow.RevenueUSD)) comparison = CompareNullable(left.RevenueUSD, right.RevenueUSD, direction);
        else { comparison = property switch { nameof(RankingRow.Model) => string.Compare(left.Model, right.Model, StringComparison.OrdinalIgnoreCase), nameof(RankingRow.PromptTokens) => left.PromptTokens.CompareTo(right.PromptTokens), nameof(RankingRow.CompletionTokens) => left.CompletionTokens.CompareTo(right.CompletionTokens), nameof(RankingRow.TotalTokens) => left.TotalTokens.CompareTo(right.TotalTokens), _ => left.Rank.CompareTo(right.Rank) }; if (direction == ListSortDirection.Descending) comparison = -comparison; }
        return comparison != 0 ? comparison : left.Rank.CompareTo(right.Rank);
    }
    private static int CompareNullable(double? left, double? right, ListSortDirection direction) { if (left is null) return right is null ? 0 : 1; if (right is null) return -1; var comparison = left.Value.CompareTo(right.Value); return direction == ListSortDirection.Descending ? -comparison : comparison; }
    private static string Number(double? value) => value?.ToString("0.################", CultureInfo.InvariantCulture) ?? string.Empty;
    private static string Token(long value) => value >= 0 ? value.ToString(CultureInfo.InvariantCulture) : string.Empty;
    private static string Csv(string value) => value.IndexOfAny([',', '"', '\r', '\n']) < 0 ? value : $"\"{value.Replace("\"", "\"\"")}\"";
}

internal sealed class WeeklyTrackingChartControl : FrameworkElement
{
    private IReadOnlyList<WeeklyRankingRow> points = [];
    private WeeklyMetric metric = WeeklyMetric.TotalTokens;
    public IReadOnlyList<WeeklyRankingRow> Points { get => points; set { points = value; Width = Math.Max(920, points.Select(row => row.WindowStart).Distinct().Count() * 72 + 326); InvalidateVisual(); } }
    public WeeklyMetric Metric { get => metric; set { metric = value; InvalidateVisual(); } }
    private static readonly WpfColor[] Palette = [WpfColor.FromRgb(13,143,130),WpfColor.FromRgb(37,99,235),WpfColor.FromRgb(234,88,12),WpfColor.FromRgb(147,51,234),WpfColor.FromRgb(190,24,93),WpfColor.FromRgb(22,163,74),WpfColor.FromRgb(8,145,178),WpfColor.FromRgb(202,138,4),WpfColor.FromRgb(79,70,229),WpfColor.FromRgb(71,85,105)];
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc); var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip; var face = new Typeface("Segoe UI");
        if (points.Count == 0) { Draw(dc,"Weekly data will be created by the next due weekly action during incremental sync",20,20,14,WpfColor.FromRgb(100,116,139),face,dpi); return; }
        var weeks = points.Select(value => value.WindowStart).Distinct().Order().ToList(); var series = points.GroupBy(value => value.Model).OrderBy(value => value.Min(row => row.Rank)).Take(10).ToList();
        double? Value(WeeklyRankingRow row) => metric switch { WeeklyMetric.Rank => row.Rank, WeeklyMetric.InputTokens => row.HasTokenBreakdown ? row.PromptTokens : null, WeeklyMetric.OutputTokens => row.HasTokenBreakdown ? row.CompletionTokens : null, WeeklyMetric.TotalTokens => row.TotalTokens, WeeklyMetric.InputPrice => row.PromptPricePerToken * 1_000_000, WeeklyMetric.OutputPrice => row.CompletionPricePerToken * 1_000_000, WeeklyMetric.Revenue => row.RevenueUSD, _ => null };
        var available = points.Select(Value).OfType<double>().Where(double.IsFinite).ToList();
        if (available.Count == 0) { Draw(dc,"This metric is not published in the OpenRouter historical dataset",20,20,14,WpfColor.FromRgb(100,116,139),face,dpi); return; }
        var max = Math.Max(1, available.Max()); var left=76d; var top=24d; var right=250d; var bottom=50d; var plotWidth=Math.Max(500,ActualWidth-left-right); var plotHeight=Math.Max(260,ActualHeight-top-bottom); var grid=new WpfPen(new SolidColorBrush(WpfColor.FromRgb(220,228,236)),1);
        for(var tick=0;tick<=4;tick++){var value=max*tick/4;var y=top+plotHeight-plotHeight*tick/4;dc.DrawLine(grid,new WpfPoint(left,y),new WpfPoint(left+plotWidth,y));Draw(dc,Label(value),2,y-8,10,WpfColor.FromRgb(100,116,139),face,dpi);}
        for(var i=0;i<weeks.Count;i++){var x=X(i);var date=weeks[i].ToDateTime(TimeOnly.MinValue);var year=ISOWeek.GetYear(date);var week=ISOWeek.GetWeekOfYear(date);var priorYear=i>0?ISOWeek.GetYear(weeks[i-1].ToDateTime(TimeOnly.MinValue)):year;var full=i==0||i==weeks.Count-1||year!=priorYear;var label=full?$"{year:0000}-W{week:00}":$"W{week:00}";Draw(dc,label,x-(full?29:10),top+plotHeight+10,9,WpfColor.FromRgb(100,116,139),face,dpi);}
        for(var s=0;s<series.Count;s++){var group=series[s];var color=Palette[s%Palette.Length];var pen=new WpfPen(new SolidColorBrush(color),2);var byWeek=group.GroupBy(value=>value.WindowStart).ToDictionary(values=>values.Key,values=>values.OrderByDescending(value=>value.WindowEnd).ThenBy(value=>value.Rank).First());WpfPoint? previous=null;for(var i=0;i<weeks.Count;i++){if(!byWeek.TryGetValue(weeks[i],out var row)||Value(row) is not double value||!double.IsFinite(value)){previous=null;continue;}var current=new WpfPoint(X(i),top+plotHeight-value*plotHeight/max);if(previous is not null)dc.DrawLine(pen,previous.Value,current);dc.DrawEllipse(new SolidColorBrush(color),null,current,3,3);previous=current;}var ly=top+s*34;dc.DrawLine(pen,new WpfPoint(left+plotWidth+18,ly+8),new WpfPoint(left+plotWidth+44,ly+8));Draw(dc,group.Key,left+plotWidth+50,ly,10,WpfColor.FromRgb(24,35,48),face,dpi);}
        double X(int index)=>left+(weeks.Count==1?plotWidth/2:index*plotWidth/(weeks.Count-1));
        string Label(double value)=>metric is WeeklyMetric.InputPrice or WeeklyMetric.OutputPrice?value.ToString("$#,##0.####",CultureInfo.InvariantCulture):metric==WeeklyMetric.Revenue?value.ToString("$#,##0",CultureInfo.InvariantCulture):value>=1_000_000_000_000?$"{value/1_000_000_000_000:0.#}T":value>=1_000_000_000?$"{value/1_000_000_000:0.#} Billion":value>=1_000_000?$"{value/1_000_000:0.#} Million":value.ToString("#,##0",CultureInfo.InvariantCulture);
    }
    private static void Draw(DrawingContext dc,string value,double x,double y,double size,WpfColor color,Typeface face,double dpi)=>dc.DrawText(new FormattedText(value,CultureInfo.CurrentCulture,System.Windows.FlowDirection.LeftToRight,face,size,new SolidColorBrush(color),dpi),new WpfPoint(x,y));
}
