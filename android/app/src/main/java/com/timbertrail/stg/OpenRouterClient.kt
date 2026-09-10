package com.timbertrail.stg

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URLEncoder
import java.net.URL
import java.nio.charset.StandardCharsets
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.temporal.TemporalAdjusters
import java.util.concurrent.Executors

enum class TrackingPeriod { WEEK, MONTH }

data class RankingRow(
    val rank: Int,
    val model: String,
    val promptTokens: Long,
    val completionTokens: Long,
    val totalTokens: Long,
    val promptPrice: Double?,
    val completionPrice: Double?
) {
    val revenue: Double? get() = if (promptPrice == null || completionPrice == null) null else promptTokens * promptPrice + completionTokens * completionPrice
}

data class RankingSnapshot(val rows: List<RankingRow>, val asOf: String, val startDate: String, val endDate: String) {
    val citation: String get() = "Source: OpenRouter public rankings (openrouter.ai/rankings), through $asOf."
}
data class WeeklyRankingRow(val weekStart: LocalDate, val weekEnd: LocalDate, val rank: Int, val model: String, val promptTokens: Long, val completionTokens: Long, val totalTokens: Long, val promptPrice: Double?, val completionPrice: Double?, val revenue: Double?, val asOf: String? = null, val missingDates: List<String> = emptyList(), val isComplete: Boolean = true) { val hasTokenBreakdown: Boolean get() = promptTokens >= 0 && completionTokens >= 0 }

class OpenRouterClient {
    fun top20(period: TrackingPeriod): RankingSnapshot {
        val today = LocalDate.now(ZoneOffset.UTC)
        return when (period) {
            TrackingPeriod.WEEK -> {
                val currentMonday = today.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
                top20(currentMonday.minusWeeks(1), currentMonday.minusDays(1))
            }
            TrackingPeriod.MONTH -> {
                val end = today.withDayOfMonth(1).minusDays(1)
                top20(end.withDayOfMonth(1), end)
            }
        }
    }

    fun top20(start: LocalDate, end: LocalDate): RankingSnapshot {
        require(!start.isAfter(end)) { "Start date must not be after end date" }
        require(end.isBefore(LocalDate.now(ZoneOffset.UTC))) { "Only completed UTC days can be included" }
        val candidates = candidates()
        require(candidates.isNotEmpty()) { "OpenRouter returned no public ranking data" }
        val pool = Executors.newFixedThreadPool(8)
        val futures = candidates.take(120).map { candidate ->
            pool.submit<VariantUsage?> { runCatching { val value = activity(candidate, start, end); VariantUsage(candidate.model, candidate.variantPermaslug, value.prompt, value.completion) }.getOrNull() }
        }
        val usage = futures.mapNotNull { it.get() }
        pool.shutdown()
        val rankedModels = usage.groupBy { it.model }.entries.sortedByDescending { (_, values) -> values.sumOf { it.prompt + it.completion } }.take(20).map { it.key }.toSet()
        val prices = runCatching { prices(candidates.filter { it.model in rankedModels }) }.getOrDefault(emptyMap())
        val weighted = usage.groupBy { it.model }.map { (model, values) -> weighted(model, values, prices) }
        val rows = weighted.filter { it.total > 0 }
            .sortedWith(compareByDescending<WeightedUsage> { it.total }.thenBy { it.model })
            .take(20).mapIndexed { index, value ->
                RankingRow(index + 1, value.model, value.prompt, value.completion, value.total, value.promptPrice, value.completionPrice)
            }
        require(rows.isNotEmpty()) { "OpenRouter has no public daily data for $start – $end" }
        return RankingSnapshot(rows, end.toString(), start.toString(), end.toString())
    }

    fun weeklyHistory(start: LocalDate, end: LocalDate): List<WeeklyRankingRow> {
        if (start.isAfter(end)) return emptyList()
        val candidates = candidates().take(120); val prices = runCatching { prices(candidates) }.getOrDefault(emptyMap()); val days = mutableListOf<DailyUsage>()
        val pool = Executors.newFixedThreadPool(8)
        val futures = candidates.map { candidate -> pool.submit<Pair<Candidate, Map<LocalDate, Totals>>> { candidate to activityByDay(candidate, start, end) } }
        futures.forEach { future -> val (candidate, values) = future.get(); values.forEach { (date, value) -> days += DailyUsage(candidate.model, candidate.variantPermaslug, date, value.prompt, value.completion) } }; pool.shutdown()
        return days.groupBy { it.date.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY)) }.toSortedMap().flatMap { (weekStart, values) ->
            values.groupBy { it.model }.map { (model, variants) -> weighted(model, variants.map { VariantUsage(it.model, it.variantPermaslug, it.prompt, it.completion) }, prices) }
                .filter { it.total > 0 }.sortedWith(compareByDescending<WeightedUsage> { it.total }.thenBy { it.model }).take(20)
                .mapIndexed { index, value -> WeeklyRankingRow(weekStart, minOf(weekStart.plusDays(6), end), index + 1, value.model, value.prompt, value.completion, value.total, value.promptPrice, value.completionPrice, if (value.promptPrice == null || value.completionPrice == null) null else value.prompt * value.promptPrice + value.completion * value.completionPrice, minOf(weekStart.plusDays(6), end).toString()) }
        }
    }

    private fun candidates(): List<Candidate> {
        val merged = candidateView("week") + candidateView("month")
        val seen = mutableSetOf<String>()
        return merged.sortedByDescending { it.total }.filter { seen.add("${it.model}|${it.variant}") }
    }

    private fun candidateView(view: String): List<Candidate> {
        val data = get("https://openrouter.ai/api/frontend/v1/rankings/models?view=$view").getJSONArray("data")
        return (0 until data.length()).map { index ->
            val row = data.getJSONObject(index)
            Candidate(row.getString("model_permaslug"), row.optString("variant"), row.optString("variant_permaslug", row.getString("model_permaslug")), flexibleLong(row.opt("total_prompt_tokens")) + flexibleLong(row.opt("total_completion_tokens")))
        }
    }

    private fun activity(candidate: Candidate, start: LocalDate, end: LocalDate): Totals {
        return activityByDay(candidate, start, end).values.fold(Totals(0,0)) { old, value -> Totals(old.prompt + value.prompt, old.completion + value.completion) }
    }
    private fun activityByDay(candidate: Candidate, start: LocalDate, end: LocalDate): Map<LocalDate, Totals> {
        val model = URLEncoder.encode(candidate.model, StandardCharsets.UTF_8.toString())
        val variant = URLEncoder.encode(candidate.variant, StandardCharsets.UTF_8.toString())
        val analytics = get("https://openrouter.ai/api/frontend/v1/stats/model-activity?permaslug=$model&variant=$variant").getJSONObject("data").getJSONArray("analytics")
        val result = mutableMapOf<LocalDate, Totals>()
        for (index in 0 until analytics.length()) {
            val day = analytics.getJSONObject(index); val date = LocalDate.parse(day.getString("date").take(10))
            if (!date.isBefore(start) && !date.isAfter(end)) {
                result[date] = Totals(flexibleLong(day.opt("total_prompt_tokens")), flexibleLong(day.opt("total_completion_tokens")))
            }
        }
        return result
    }

    private fun prices(candidates: List<Candidate>): Map<String, Price> {
        val result = java.util.concurrent.ConcurrentHashMap<String, Price>()
        val pool = Executors.newFixedThreadPool(8)
        candidates.map { it.variantPermaslug }.distinct().map { slug -> pool.submit {
            runCatching {
                val encoded = URLEncoder.encode(slug, StandardCharsets.UTF_8.toString())
                val data = get("https://openrouter.ai/api/frontend/v1/stats/effective-pricing?permaslug=$encoded&shape=v7").getJSONObject("data")
                val input = data.optDouble("weightedInputPrice", 0.0)
                val output = data.optDouble("weightedOutputPrice", 0.0)
                if (input > 0 || output > 0) result[slug] = Price(input / 1_000_000.0, output / 1_000_000.0)
            }
        } }.forEach { it.get() }
        pool.shutdown()
        return result
    }

    private fun get(url: String): JSONObject {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.setRequestProperty("Referer", "https://openrouter.ai/rankings")
        connection.setRequestProperty("User-Agent", "Screen-Time-Guardian-Android/1.1.8")
        connection.setRequestProperty("Accept", "application/json")
        connection.connectTimeout = 15_000; connection.readTimeout = 30_000
        val code = connection.responseCode
        val text = (if (code in 200..299) connection.inputStream else connection.errorStream).bufferedReader().use { it.readText() }
        if (code !in 200..299) error("OpenRouter HTTP $code")
        return JSONObject(text)
    }

    private fun flexibleLong(value: Any?): Long = value?.toString()?.toDoubleOrNull()?.toLong() ?: 0L
    private fun weighted(model: String, values: List<VariantUsage>, prices: Map<String, Price>): WeightedUsage {
        var prompt = 0L; var completion = 0L; var pricedPrompt = 0L; var pricedCompletion = 0L; var promptCost = 0.0; var completionCost = 0.0
        values.forEach { value ->
            prompt += value.prompt; completion += value.completion
            prices[value.variantPermaslug]?.let { price -> promptCost += value.prompt * price.prompt; completionCost += value.completion * price.completion; pricedPrompt += value.prompt; pricedCompletion += value.completion }
        }
        return WeightedUsage(model, prompt, completion, if (prompt > 0 && pricedPrompt == prompt) promptCost / prompt else null, if (completion > 0 && pricedCompletion == completion) completionCost / completion else null)
    }
    private data class Candidate(val model: String, val variant: String, val variantPermaslug: String, val total: Long)
    private data class VariantUsage(val model: String, val variantPermaslug: String, val prompt: Long, val completion: Long)
    private data class WeightedUsage(val model: String, val prompt: Long, val completion: Long, val promptPrice: Double?, val completionPrice: Double?) { val total: Long get() = prompt + completion }
    private data class DailyUsage(val model: String, val variantPermaslug: String, val date: LocalDate, val prompt: Long, val completion: Long)
    private data class Totals(val prompt: Long, val completion: Long) { val total: Long get() = prompt + completion }
    private data class Price(val prompt: Double, val completion: Double)
}
