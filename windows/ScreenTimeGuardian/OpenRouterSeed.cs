using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ScreenTimeGuardian;

internal sealed record OpenRouterSeedDocument(
    [property: JsonPropertyName("schema")] int Schema,
    [property: JsonPropertyName("as_of")] string AsOf,
    [property: JsonPropertyName("start_date")] string StartDate,
    [property: JsonPropertyName("end_date")] string EndDate,
    [property: JsonPropertyName("missing_dates")] IReadOnlyList<string> MissingDates,
    [property: JsonPropertyName("token_breakdown_available")] bool TokenBreakdownAvailable,
    [property: JsonPropertyName("rows")] IReadOnlyList<OpenRouterSeedRow> Rows);

internal sealed record OpenRouterSeedRow(
    [property: JsonPropertyName("s")] string WindowStart,
    [property: JsonPropertyName("e")] string WindowEnd,
    [property: JsonPropertyName("r")] int Rank,
    [property: JsonPropertyName("m")] string Model,
    [property: JsonPropertyName("t")] long TotalTokens);

internal static class OpenRouterSeed
{
    public const string Marker = "openrouter_seed_v1";

    public static OpenRouterSeedDocument Load()
    {
        var assembly = Assembly.GetExecutingAssembly();
        var resource = assembly.GetManifestResourceNames().SingleOrDefault(
            value => value.EndsWith("openrouter-weekly-seed-v1.json", StringComparison.Ordinal));
        if (resource is null) throw new InvalidDataException("Bundled OpenRouter history seed is missing");
        using var stream = assembly.GetManifestResourceStream(resource)
            ?? throw new InvalidDataException("Bundled OpenRouter history seed cannot be opened");
        var document = JsonSerializer.Deserialize<OpenRouterSeedDocument>(stream)
            ?? throw new InvalidDataException("Bundled OpenRouter history seed is invalid");
        if (document.Schema != 1 || document.Rows.Count == 0)
            throw new InvalidDataException("Bundled OpenRouter history seed is invalid");
        return document;
    }
}
