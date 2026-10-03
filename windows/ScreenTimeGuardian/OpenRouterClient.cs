using System.Globalization;
using System.Net.Http.Headers;
using System.Net.Http;
using System.Text.Json;

namespace ScreenTimeGuardian;

internal enum TrackingPeriod
{
    Week,
    Month,
    Custom
}

internal sealed record RankingRow(
    int Rank,
    string Model,
    long PromptTokens,
    long CompletionTokens,
    long TotalTokens,
    double? PromptPricePerToken,
    double? CompletionPricePerToken)
{
    public double? PromptPricePerMillion => PromptPricePerToken * 1_000_000d;
    public double? CompletionPricePerMillion => CompletionPricePerToken * 1_000_000d;
    public double? RevenueUSD =>
        PromptPricePerToken is not null && CompletionPricePerToken is not null
            ? PromptTokens * PromptPricePerToken.Value +
              CompletionTokens * CompletionPricePerToken.Value
            : null;
}

internal sealed record RankingSnapshot(
    IReadOnlyList<RankingRow> Rows,
    DateOnly StartDate,
    DateOnly EndDate,
    DateTimeOffset AsOf,
    string Citation);

internal sealed record WeeklyRankingRow(
    DateOnly WindowStart,
    DateOnly WindowEnd,
    int Rank,
    string Model,
    long PromptTokens,
    long CompletionTokens,
    long TotalTokens,
    double? PromptPricePerToken,
    double? CompletionPricePerToken,
    DateTimeOffset? AsOf = null,
    IReadOnlyList<string>? MissingDates = null,
    bool IsComplete = true)
{
    public bool HasTokenBreakdown => PromptTokens >= 0 && CompletionTokens >= 0;
    public double? RevenueUSD =>
        HasTokenBreakdown && PromptPricePerToken is not null && CompletionPricePerToken is not null
            ? PromptTokens * PromptPricePerToken.Value + CompletionTokens * CompletionPricePerToken.Value
            : null;
}

internal sealed class OpenRouterClient
{
    private const string RankingsUrl =
        "https://openrouter.ai/api/frontend/v1/rankings/models";
    private const string ActivityUrl =
        "https://openrouter.ai/api/frontend/v1/stats/model-activity";
    private const string EffectivePricingUrl =
        "https://openrouter.ai/api/frontend/v1/stats/effective-pricing";

    private readonly HttpClient http;

    public OpenRouterClient(HttpClient? httpClient = null)
    {
        http = httpClient ?? new HttpClient();
        http.Timeout = TimeSpan.FromSeconds(45);
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Screen-Time-Guardian/1.1.9");
        http.DefaultRequestHeaders.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/json"));
        http.DefaultRequestHeaders.Referrer = new Uri("https://openrouter.ai/rankings");
    }

    public async Task<RankingSnapshot> Top20Async(
        TrackingPeriod period,
        CancellationToken cancellationToken)
    {
        var (startDate, endDate) = DateWindow(period, DateOnly.FromDateTime(DateTime.UtcNow));
        return await Top20Async(startDate, endDate, cancellationToken);
    }

    public async Task<RankingSnapshot> Top20Async(
        DateOnly startDate,
        DateOnly endDate,
        CancellationToken cancellationToken)
    {
        var yesterday = DateOnly.FromDateTime(DateTime.UtcNow).AddDays(-1);
        if (startDate > endDate) throw new ArgumentException("Start date must not be after end date");
        if (endDate > yesterday) throw new ArgumentException("The range may include only completed UTC days");

        var weekCandidatesTask = FetchCandidatesAsync("week", cancellationToken);
        var monthCandidatesTask = FetchCandidatesAsync("month", cancellationToken);
        await Task.WhenAll(weekCandidatesTask, monthCandidatesTask);

        var candidates = weekCandidatesTask.Result
            .Concat(monthCandidatesTask.Result)
            .GroupBy(candidate => (candidate.Permaslug, candidate.Variant))
            .Select(group => group.OrderByDescending(candidate => candidate.TotalTokens).First())
            .OrderByDescending(candidate => candidate.TotalTokens)
            .ThenBy(candidate => candidate.Permaslug, StringComparer.Ordinal)
            .Take(120)
            .ToList();

        using var gate = new SemaphoreSlim(8);
        var activityTasks = candidates.Select(async candidate =>
        {
            await gate.WaitAsync(cancellationToken);
            try
            {
                try
                {
                    return await FetchActivityAsync(
                        candidate,
                        startDate,
                        endDate,
                        cancellationToken);
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch
                {
                    return new VariantUsage(candidate.Permaslug, candidate.VariantPermaslug, 0, 0);
                }
            }
            finally
            {
                gate.Release();
            }
        }).ToArray();

        var usage = await Task.WhenAll(activityTasks);
        Dictionary<string, Price> prices;
        try
        {
            var rankedModels = usage.GroupBy(value => value.Model, StringComparer.Ordinal)
                .Select(group => new { Model = group.Key, Total = group.Sum(value => value.PromptTokens + value.CompletionTokens) })
                .OrderByDescending(value => value.Total).Take(20).Select(value => value.Model).ToHashSet(StringComparer.Ordinal);
            prices = await FetchPricesAsync(candidates.Where(value => rankedModels.Contains(value.Permaslug)), cancellationToken);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            prices = new Dictionary<string, Price>(StringComparer.OrdinalIgnoreCase);
        }

        var rows = usage
            .GroupBy(item => item.Model, StringComparer.Ordinal)
            .Select(group => Weighted(group.Key, group, prices))
            .Where(item => item.TotalTokens > 0)
            .OrderByDescending(item => item.TotalTokens)
            .ThenBy(item => item.Model, StringComparer.Ordinal)
            .Take(20)
            .Select((item, index) =>
            {
                return new RankingRow(
                    index + 1,
                    item.Model,
                    item.PromptTokens,
                    item.CompletionTokens,
                    item.TotalTokens,
                    item.PromptPrice,
                    item.CompletionPrice);
            })
            .ToList();

        return new RankingSnapshot(
            rows,
            startDate,
            endDate,
            DateTimeOffset.UtcNow,
            "OpenRouter public rankings and model activity APIs");
    }

    /// Downloads each candidate's daily public activity once, then folds the
    /// inclusive range into ISO Monday-Sunday buckets. The first bucket may be
    /// partial when history begins on 2025-01-01.
    public async Task<IReadOnlyList<WeeklyRankingRow>> WeeklyHistoryAsync(
        DateOnly startDate,
        DateOnly endDate,
        CancellationToken cancellationToken)
    {
        if (startDate > endDate) return [];
        var weekCandidatesTask = FetchCandidatesAsync("week", cancellationToken);
        var monthCandidatesTask = FetchCandidatesAsync("month", cancellationToken);
        await Task.WhenAll(weekCandidatesTask, monthCandidatesTask);
        var candidates = weekCandidatesTask.Result.Concat(monthCandidatesTask.Result)
            .GroupBy(value => (value.Permaslug, value.Variant))
            .Select(group => group.OrderByDescending(value => value.TotalTokens).First())
            .OrderByDescending(value => value.TotalTokens).Take(120).ToList();

        using var gate = new SemaphoreSlim(8);
        var tasks = candidates.Select(async candidate =>
        {
            await gate.WaitAsync(cancellationToken);
            try { return (Days: await FetchDailyActivityAsync(candidate, startDate, endDate, cancellationToken), Error: (Exception?)null, Model: candidate.Permaslug); }
            catch (OperationCanceledException) { throw; }
            catch (Exception error) { return (Days: (IReadOnlyList<DailyUsage>)Array.Empty<DailyUsage>(), Error: error, Model: candidate.Permaslug); }
            finally { gate.Release(); }
        }).ToArray();
        var attempts = await Task.WhenAll(tasks);
        var days = attempts.SelectMany(value => value.Days).ToList();
        var failures = attempts.Where(value => value.Error is not null).ToList();
        if (days.Count == 0 && failures.Count > 0)
            throw new InvalidOperationException($"OpenRouter weekly activity failed for all {failures.Count} candidates; samples=[{string.Join(" | ", failures.Take(3).Select(value => $"model={value.Model}; {DiagnosticLog.Describe(value.Error!)}"))}]");
        Dictionary<string, Price> prices;
        try { prices = await FetchPricesAsync(candidates, cancellationToken); }
        catch (OperationCanceledException) { throw; }
        catch { prices = new(StringComparer.OrdinalIgnoreCase); }

        var grouped = days.GroupBy(value =>
        {
            var monday = value.Date.AddDays(-(((int)value.Date.DayOfWeek + 6) % 7));
            return (Start: monday < startDate ? startDate : monday, End: monday.AddDays(6) > endDate ? endDate : monday.AddDays(6));
        });
        var result = new List<WeeklyRankingRow>();
        foreach (var week in grouped.OrderBy(value => value.Key.Start))
        {
            var totals = week.GroupBy(value => value.Model, StringComparer.Ordinal)
                .Select(group => Weighted(group.Key, group.Select(value => new VariantUsage(value.Model, value.VariantPermaslug, value.PromptTokens, value.CompletionTokens)), prices))
                .Where(value => value.TotalTokens > 0)
                .OrderByDescending(value => value.TotalTokens).ThenBy(value => value.Model, StringComparer.Ordinal).ToList();
            for (var index = 0; index < totals.Count; index++)
            {
                var value = totals[index];
                result.Add(new WeeklyRankingRow(week.Key.Start, week.Key.End, index + 1, value.Model, value.PromptTokens, value.CompletionTokens, value.TotalTokens, value.PromptPrice, value.CompletionPrice, new DateTimeOffset(week.Key.End.ToDateTime(TimeOnly.MinValue), TimeSpan.Zero)));
            }
        }
        return result;
    }

    private async Task<IReadOnlyList<Candidate>> FetchCandidatesAsync(
        string view,
        CancellationToken cancellationToken)
    {
        using var response = await http.GetAsync(
            $"{RankingsUrl}?view={Uri.EscapeDataString(view)}",
            cancellationToken);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);

        var array = FindArray(document.RootElement, "data", "models");
        if (array is null)
        {
            return [];
        }

        var result = new List<Candidate>();
        foreach (var item in array.Value.EnumerateArray())
        {
            var permaslug = StringValue(item, "model_permaslug");
            if (string.IsNullOrWhiteSpace(permaslug))
            {
                continue;
            }

            var variant = StringValue(item, "variant") ?? string.Empty;
            var prompt = IntegerValue(item, "total_prompt_tokens");
            var completion = IntegerValue(item, "total_completion_tokens");
            var variantPermaslug = StringValue(item, "variant_permaslug") ?? permaslug;
            result.Add(new Candidate(permaslug, variant, variantPermaslug, prompt + completion));
        }

        return result;
    }

    private async Task<VariantUsage> FetchActivityAsync(
        Candidate candidate,
        DateOnly startDate,
        DateOnly endDate,
        CancellationToken cancellationToken)
    {
        var query =
            $"{ActivityUrl}?permaslug={Uri.EscapeDataString(candidate.Permaslug)}" +
            $"&variant={Uri.EscapeDataString(candidate.Variant)}";
        using var response = await http.GetAsync(query, cancellationToken);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);

        var analytics = FindArray(document.RootElement, "data", "analytics");
        long prompt = 0;
        long completion = 0;
        if (analytics is not null)
        {
            foreach (var item in analytics.Value.EnumerateArray())
            {
                var dateText = StringValue(item, "date");
                if (dateText?.Length >= 10)
                {
                    dateText = dateText[..10];
                }
                if (!DateOnly.TryParse(
                        dateText,
                        CultureInfo.InvariantCulture,
                        DateTimeStyles.None,
                        out var date) ||
                    date < startDate ||
                    date > endDate)
                {
                    continue;
                }

                prompt += IntegerValue(item, "total_prompt_tokens");
                completion += IntegerValue(item, "total_completion_tokens");
            }
        }

        return new VariantUsage(candidate.Permaslug, candidate.VariantPermaslug, prompt, completion);
    }

    private async Task<IReadOnlyList<DailyUsage>> FetchDailyActivityAsync(
        Candidate candidate,
        DateOnly startDate,
        DateOnly endDate,
        CancellationToken cancellationToken)
    {
        var query = $"{ActivityUrl}?permaslug={Uri.EscapeDataString(candidate.Permaslug)}&variant={Uri.EscapeDataString(candidate.Variant)}";
        using var response = await http.GetAsync(query, cancellationToken);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
        var analytics = FindArray(document.RootElement, "data", "analytics");
        if (analytics is null) return [];
        var result = new List<DailyUsage>();
        foreach (var item in analytics.Value.EnumerateArray())
        {
            var text = StringValue(item, "date"); if (text?.Length >= 10) text = text[..10];
            if (!DateOnly.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) || date < startDate || date > endDate) continue;
            result.Add(new DailyUsage(candidate.Permaslug, candidate.VariantPermaslug, date, IntegerValue(item, "total_prompt_tokens"), IntegerValue(item, "total_completion_tokens")));
        }
        return result;
    }

    private async Task<Dictionary<string, Price>> FetchPricesAsync(
        IEnumerable<Candidate> candidates,
        CancellationToken cancellationToken)
    {
        var result = new Dictionary<string, Price>(StringComparer.OrdinalIgnoreCase);
        using var gate = new SemaphoreSlim(8);
        var tasks = candidates.Select(value => value.VariantPermaslug).Distinct(StringComparer.OrdinalIgnoreCase).Select(async slug =>
        {
            await gate.WaitAsync(cancellationToken);
            try
            {
                var url = $"{EffectivePricingUrl}?permaslug={Uri.EscapeDataString(slug)}&shape=v7";
                using var response = await http.GetAsync(url, cancellationToken);
                response.EnsureSuccessStatusCode();
                await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
                using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
                if (!document.RootElement.TryGetProperty("data", out var data)) return;
                var input = DoubleValue(data, "weightedInputPrice");
                var output = DoubleValue(data, "weightedOutputPrice");
                if ((input ?? 0) <= 0 && (output ?? 0) <= 0) return;
                lock (result) result[slug] = new Price(input / 1_000_000d, output / 1_000_000d);
            }
            catch (OperationCanceledException) { throw; }
            catch { }
            finally { gate.Release(); }
        }).ToArray();
        await Task.WhenAll(tasks);

        return result;
    }

    private static (DateOnly Start, DateOnly End) DateWindow(
        TrackingPeriod period,
        DateOnly todayUtc)
    {
        if (period == TrackingPeriod.Week)
        {
            var daysSinceMonday = ((int)todayUtc.DayOfWeek + 6) % 7;
            var thisMonday = todayUtc.AddDays(-daysSinceMonday);
            return (thisMonday.AddDays(-7), thisMonday.AddDays(-1));
        }

        var firstOfThisMonth = new DateOnly(todayUtc.Year, todayUtc.Month, 1);
        var lastOfPreviousMonth = firstOfThisMonth.AddDays(-1);
        return (
            new DateOnly(lastOfPreviousMonth.Year, lastOfPreviousMonth.Month, 1),
            lastOfPreviousMonth);
    }

    private static JsonElement? FindArray(
        JsonElement root,
        string containerName,
        string arrayName)
    {
        if (root.TryGetProperty(containerName, out var container))
        {
            if (container.ValueKind == JsonValueKind.Array)
            {
                return container;
            }

            if (container.ValueKind == JsonValueKind.Object &&
                container.TryGetProperty(arrayName, out var nested) &&
                nested.ValueKind == JsonValueKind.Array)
            {
                return nested;
            }
        }

        if (root.TryGetProperty(arrayName, out var direct) &&
            direct.ValueKind == JsonValueKind.Array)
        {
            return direct;
        }

        return null;
    }

    private static string? StringValue(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value))
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number => value.GetRawText(),
            _ => null
        };
    }

    private static long IntegerValue(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value))
        {
            return 0;
        }

        if (value.ValueKind == JsonValueKind.Number)
        {
            if (value.TryGetInt64(out var integer))
            {
                return integer;
            }

            if (value.TryGetDouble(out var number))
            {
                return checked((long)Math.Round(number));
            }
        }

        if (value.ValueKind == JsonValueKind.String &&
            double.TryParse(
                value.GetString(),
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out var parsed))
        {
            return checked((long)Math.Round(parsed));
        }

        return 0;
    }

    private static double? DoubleValue(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value))
        {
            return null;
        }

        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number))
        {
            return number;
        }

        if (value.ValueKind == JsonValueKind.String &&
            double.TryParse(
                value.GetString(),
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out var parsed))
        {
            return parsed;
        }

        return null;
    }

    private static WeightedUsage Weighted(string model, IEnumerable<VariantUsage> values, IReadOnlyDictionary<string, Price> prices)
    {
        long prompt = 0, completion = 0, pricedPrompt = 0, pricedCompletion = 0;
        double promptCost = 0, completionCost = 0;
        foreach (var value in values)
        {
            prompt += value.PromptTokens; completion += value.CompletionTokens;
            if (prices.TryGetValue(value.VariantPermaslug, out var price))
            {
                if (price.Prompt is not null) { promptCost += value.PromptTokens * price.Prompt.Value; pricedPrompt += value.PromptTokens; }
                if (price.Completion is not null) { completionCost += value.CompletionTokens * price.Completion.Value; pricedCompletion += value.CompletionTokens; }
            }
        }
        return new WeightedUsage(model, prompt, completion,
            prompt > 0 && pricedPrompt == prompt ? promptCost / prompt : null,
            completion > 0 && pricedCompletion == completion ? completionCost / completion : null);
    }

    private sealed record Candidate(string Permaslug, string Variant, string VariantPermaslug, long TotalTokens);
    private sealed record VariantUsage(string Model, string VariantPermaslug, long PromptTokens, long CompletionTokens);
    private sealed record WeightedUsage(string Model, long PromptTokens, long CompletionTokens, double? PromptPrice, double? CompletionPrice)
    {
        public long TotalTokens => PromptTokens + CompletionTokens;
    }

    private sealed record DailyUsage(string Model, string VariantPermaslug, DateOnly Date, long PromptTokens, long CompletionTokens);

    private sealed record Price(double? Prompt, double? Completion);
}
