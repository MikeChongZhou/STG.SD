import Foundation

public struct OpenRouterRankingRow: Identifiable, Equatable, Sendable {
    public var id: String { modelPermaslug }
    public var rank: Int
    public var modelPermaslug: String
    public var promptTokens: Int64
    public var completionTokens: Int64
    public var totalTokens: Int64
    public var promptPricePerToken: Double?
    public var completionPricePerToken: Double?
    public var hasTokenBreakdown: Bool { promptTokens >= 0 && completionTokens >= 0 }
    public var revenueUSD: Double? {
        guard hasTokenBreakdown, let promptPricePerToken, let completionPricePerToken else { return nil }
        return Double(promptTokens) * promptPricePerToken + Double(completionTokens) * completionPricePerToken
    }
}

public struct OpenRouterTokenTotals: Equatable, Sendable {
    public var prompt: Int64 = 0
    public var completion: Int64 = 0
    public var total: Int64 { prompt + completion }
}

private struct WeightedTokenTotals: Sendable {
    var prompt: Int64 = 0
    var completion: Int64 = 0
    var promptCost: Double = 0
    var completionCost: Double = 0
    var pricedPrompt: Int64 = 0
    var pricedCompletion: Int64 = 0
    var total: Int64 { prompt + completion }
    var promptPrice: Double? { prompt > 0 && pricedPrompt == prompt ? promptCost / Double(prompt) : nil }
    var completionPrice: Double? { completion > 0 && pricedCompletion == completion ? completionCost / Double(completion) : nil }

    mutating func add(prompt: Int64, completion: Int64, price: ModelPrice?) {
        self.prompt += prompt; self.completion += completion
        if let value = price?.prompt { promptCost += Double(prompt) * value; pricedPrompt += prompt }
        if let value = price?.completion { completionCost += Double(completion) * value; pricedCompletion += completion }
    }
}

public struct OpenRouterRankingSnapshot: Equatable, Sendable {
    public var rows: [OpenRouterRankingRow]
    public var asOf: String
    public var startDate: String
    public var endDate: String
    public var citation: String { "Source: OpenRouter public rankings (openrouter.ai/rankings), through \(asOf)." }
}

public struct OpenRouterWeeklyRankingRow: Identifiable, Equatable, Sendable {
    public var id: String { "\(weekStart)|\(modelPermaslug)" }
    public var weekStart: String
    public var weekEnd: String
    public var rank: Int
    public var modelPermaslug: String
    public var promptTokens: Int64
    public var completionTokens: Int64
    public var totalTokens: Int64
    public var promptPricePerToken: Double?
    public var completionPricePerToken: Double?
    public var hasTokenBreakdown: Bool { promptTokens >= 0 && completionTokens >= 0 }
    public var revenueUSD: Double? {
        guard hasTokenBreakdown, let promptPricePerToken, let completionPricePerToken else { return nil }
        return Double(promptTokens) * promptPricePerToken + Double(completionTokens) * completionPricePerToken
    }
}

public enum TrackingPeriod: Sendable { case week, month }

/// Reads the same public aggregate data used by OpenRouter's rankings page. No
/// account or API key is involved. Daily activity is used so a weekly report is
/// a completed ISO week (Monday through Sunday), not a rolling seven-day total.
public actor OpenRouterTrackingService {
    public static let shared = OpenRouterTrackingService()
    private let session: URLSession
    private var cache: [String: OpenRouterRankingSnapshot] = [:]

    public init(session: URLSession = .shared) { self.session = session }

    public func top20(period: TrackingPeriod, now: Date = .now) async throws -> OpenRouterRankingSnapshot {
        let window = try Self.dateWindow(period: period, now: now)
        return try await top20(startDate: window.start, endDate: window.end)
    }

    /// Returns the public Top 20 for an inclusive UTC calendar-date range.
    public func top20(startDate: String, endDate: String) async throws -> OpenRouterRankingSnapshot {
        guard let start = Self.parseDate(startDate), let end = Self.parseDate(endDate), start <= end else {
            throw STGError.invalidDocument("Choose a valid date range whose start is not after its end")
        }
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = STGTime.utc
        let today = calendar.startOfDay(for: .now)
        guard end < today else {
            throw STGError.invalidDocument("Custom reports can include completed UTC days only")
        }
        return try await loadTop20(startDate: Self.dateString(start), endDate: Self.dateString(end))
    }

    /// Builds completed UTC Monday–Sunday model-week rows. The first interval
    /// may be the partial 2025-01-01…2025-01-05 bootstrap week.
    public func weeklyHistory(startDate: String, endDate: String) async throws -> [OpenRouterWeeklyRankingRow] {
        guard let start = Self.parseDate(startDate), let end = Self.parseDate(endDate), start <= end else {
            throw STGError.invalidDocument("Choose a valid weekly-history range")
        }
        let candidates = try await candidateModels()
        let prices = await Self.fetchEffectivePrices(candidates: candidates, session: session)
        var dailyByModel: [String: [DailyUsage]] = [:]
        for batchStart in stride(from: 0, to: candidates.count, by: 8) {
            let batch = Array(candidates[batchStart..<min(batchStart + 8, candidates.count)])
            await withTaskGroup(of: (String, [DailyUsage])?.self) { group in
                for candidate in batch {
                    group.addTask { [session] in
                        do { return (candidate.model, try await Self.dailyUsage(candidate, price: prices[candidate.variantPermaslug], session: session)) }
                        catch { return nil }
                    }
                }
                for await result in group {
                    guard let (model, days) = result else { continue }
                    dailyByModel[model, default: []].append(contentsOf: days)
                }
            }
        }
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = STGTime.utc
        var buckets: [String: [String: WeightedTokenTotals]] = [:]
        for (model, days) in dailyByModel {
            for day in days where day.date >= start && day.date <= end {
                let weekStart = max(start, calendar.dateInterval(of: .weekOfYear, for: day.date)?.start ?? day.date)
                let key = Self.dateString(weekStart)
                buckets[key, default: [:]][model, default: .init()].add(prompt: day.prompt, completion: day.completion, price: day.price)
            }
        }
        return buckets.keys.sorted().flatMap { weekKey -> [OpenRouterWeeklyRankingRow] in
            guard let weekStart = Self.parseDate(weekKey) else { return [] }
            let nominalEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
            let weekEnd = min(end, nominalEnd)
            return buckets[weekKey, default: [:]].filter { $0.value.total > 0 }
                .sorted { $0.value.total == $1.value.total ? $0.key < $1.key : $0.value.total > $1.value.total }
                .enumerated().map { index, element in
                    return OpenRouterWeeklyRankingRow(weekStart: weekKey, weekEnd: Self.dateString(weekEnd), rank: index + 1,
                        modelPermaslug: element.key, promptTokens: element.value.prompt,
                        completionTokens: element.value.completion, totalTokens: element.value.total,
                        promptPricePerToken: element.value.promptPrice, completionPricePerToken: element.value.completionPrice)
                }
        }
    }

    private func loadTop20(startDate: String, endDate: String) async throws -> OpenRouterRankingSnapshot {
        let window = (start: startDate, end: endDate)
        let cacheKey = "\(window.start)|\(window.end)"
        if let cached = cache[cacheKey] { return cached }
        let candidates = try await candidateModels()
        guard !candidates.isEmpty else { throw STGError.invalidDocument("OpenRouter returned no public ranking data") }

        var totals: [String: WeightedTokenTotals] = [:]
        var totalsByVariant: [String: OpenRouterTokenTotals] = [:]
        for batchStart in stride(from: 0, to: candidates.count, by: 8) {
            let batch = Array(candidates[batchStart..<min(batchStart + 8, candidates.count)])
            await withTaskGroup(of: (Candidate, OpenRouterTokenTotals)?.self) { group in
                for candidate in batch {
                    group.addTask { [session] in
                        do {
                            let data = try await Self.fetchActivity(candidate, session: session)
                            return (candidate, try Self.total(data, start: window.start, end: window.end))
                        } catch { return nil }
                    }
                }
                for await result in group {
                    if let (candidate, value) = result {
                        totalsByVariant[candidate.id] = value
                        totals[candidate.model, default: .init()].add(prompt: value.prompt, completion: value.completion, price: nil)
                    }
                }
            }
        }

        let rankedModels = Set(totals.sorted { $0.value.total > $1.value.total }.prefix(20).map(\.key))
        let pricedCandidates = candidates.filter { rankedModels.contains($0.model) }
        let prices = await Self.fetchEffectivePrices(candidates: pricedCandidates, session: session)
        var pricedTotals: [String: WeightedTokenTotals] = [:]
        for candidate in candidates where rankedModels.contains(candidate.model) {
            guard let usage = totalsByVariant[ candidate.id ] else { continue }
            pricedTotals[candidate.model, default: .init()].add(prompt: usage.prompt, completion: usage.completion, price: prices[candidate.variantPermaslug])
        }

        let rows = pricedTotals.filter { $0.value.total > 0 }
            .sorted { $0.value.total == $1.value.total ? $0.key < $1.key : $0.value.total > $1.value.total }
            .prefix(20).enumerated().map {
                return OpenRouterRankingRow(rank: $0.offset + 1, modelPermaslug: $0.element.key,
                    promptTokens: $0.element.value.prompt, completionTokens: $0.element.value.completion,
                    totalTokens: $0.element.value.total, promptPricePerToken: $0.element.value.promptPrice, completionPricePerToken: $0.element.value.completionPrice)
            }
        guard !rows.isEmpty else { throw STGError.invalidDocument("OpenRouter has no daily public data for \(window.start) – \(window.end)") }
        let snapshot = OpenRouterRankingSnapshot(rows: rows, asOf: window.end, startDate: window.start, endDate: window.end)
        cache[cacheKey] = snapshot
        return snapshot
    }

    public static func dateWindow(period: TrackingPeriod, now: Date) throws -> (start: String, end: String) {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = STGTime.utc
        let today = calendar.startOfDay(for: now)
        let start: Date
        let end: Date
        switch period {
        case .week:
            guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: today),
                  let previousMonday = calendar.date(byAdding: .day, value: -7, to: currentWeek.start),
                  let previousSunday = calendar.date(byAdding: .day, value: -1, to: currentWeek.start) else {
                throw STGError.invalidDocument("Unable to calculate the previous calendar week")
            }
            start = previousMonday
            end = previousSunday
        case .month:
            guard let currentMonth = calendar.dateInterval(of: .month, for: today),
                  let priorMonthDay = calendar.date(byAdding: .day, value: -1, to: currentMonth.start),
                  let priorMonth = calendar.dateInterval(of: .month, for: priorMonthDay) else {
                throw STGError.invalidDocument("Unable to calculate the previous calendar month")
            }
            start = priorMonth.start
            end = priorMonthDay
        }
        return (dateString(start), dateString(end))
    }

    public static func total(_ data: Data, start: String, end: String) throws -> OpenRouterTokenTotals {
        let response = try JSONDecoder().decode(ActivityResponse.self, from: data)
        return response.data.analytics.filter {
            let date = String($0.date.prefix(10)); return date >= start && date <= end
        }.reduce(into: OpenRouterTokenTotals()) {
            $0.prompt += $1.totalPromptTokens.value
            $0.completion += $1.totalCompletionTokens.value
        }
    }

    private static func dailyUsage(_ candidate: Candidate, price: ModelPrice?, session: URLSession) async throws -> [DailyUsage] {
        let data = try await fetchActivity(candidate, session: session)
        let response = try JSONDecoder().decode(ActivityResponse.self, from: data)
        return response.data.analytics.compactMap { day in
            guard let date = parseDate(String(day.date.prefix(10))) else { return nil }
            return DailyUsage(date: date, prompt: day.totalPromptTokens.value, completion: day.totalCompletionTokens.value, price: price)
        }
    }

    private func candidateModels() async throws -> [Candidate] {
        async let week = Self.fetchCandidates(view: "week", session: session)
        async let month = Self.fetchCandidates(view: "month", session: session)
        let (weekRows, monthRows) = try await (week, month)
        var seen: Set<String> = []
        return (weekRows + monthRows).sorted { $0.total > $1.total }
            .filter { seen.insert($0.id).inserted }.prefix(120).map { $0 }
    }

    private static func fetchCandidates(view: String, session: URLSession) async throws -> [Candidate] {
        var components = URLComponents(string: "https://openrouter.ai/api/frontend/v1/rankings/models")!
        components.queryItems = [URLQueryItem(name: "view", value: view)]
        var request = publicRequest(components.url!); request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(PublicRankingsResponse.self, from: data).data.map {
            Candidate(model: $0.modelPermaslug, variant: $0.variant, variantPermaslug: $0.variantPermaslug, total: $0.totalPromptTokens.value + $0.totalCompletionTokens.value)
        }
    }

    private static func fetchActivity(_ candidate: Candidate, session: URLSession) async throws -> Data {
        var components = URLComponents(string: "https://openrouter.ai/api/frontend/v1/stats/model-activity")!
        components.queryItems = [URLQueryItem(name: "permaslug", value: candidate.model), URLQueryItem(name: "variant", value: candidate.variant)]
        var request = publicRequest(components.url!); request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    private static func fetchEffectivePrices(candidates: [Candidate], session: URLSession) async -> [String: ModelPrice] {
        var result: [String: ModelPrice] = [:]
        let slugs = Array(Set(candidates.map(\.variantPermaslug)))
        for batchStart in stride(from: 0, to: slugs.count, by: 8) {
            let batch = Array(slugs[batchStart..<min(batchStart + 8, slugs.count)])
            await withTaskGroup(of: (String, ModelPrice)?.self) { group in
                for slug in batch {
                    group.addTask {
                        var components = URLComponents(string: "https://openrouter.ai/api/frontend/v1/stats/effective-pricing")!
                        components.queryItems = [URLQueryItem(name: "permaslug", value: slug), URLQueryItem(name: "shape", value: "v7")]
                        do {
                            var request = publicRequest(components.url!); request.timeoutInterval = 30
                            let (data, response) = try await session.data(for: request); try validate(response)
                            let body = try JSONDecoder().decode(EffectivePricingResponse.self, from: data).data
                            guard body.weightedInputPrice > 0 || body.weightedOutputPrice > 0 else { return nil }
                            return (slug, ModelPrice(prompt: body.weightedInputPrice / 1_000_000, completion: body.weightedOutputPrice / 1_000_000))
                        } catch { return nil }
                    }
                }
                for await item in group { if let (slug, price) = item { result[slug] = price } }
            }
        }
        return result
    }

    private static func publicRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("https://openrouter.ai/rankings", forHTTPHeaderField: "Referer")
        request.setValue("Screen-Time-Guardian/1.1.6", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw STGError.invalidDocument("OpenRouter public rankings request failed")
        }
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = STGTime.utc; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = STGTime.utc; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

private struct Candidate: Sendable {
    var model: String
    var variant: String
    var variantPermaslug: String
    var total: Int64
    var id: String { "\(model)|\(variant)" }
}

private struct DailyUsage: Sendable {
    var date: Date
    var prompt: Int64
    var completion: Int64
    var price: ModelPrice?
}

private struct PublicRankingsResponse: Decodable {
    var data: [Row]
    struct Row: Decodable {
        var modelPermaslug: String
        var variant: String
        var variantPermaslug: String
        var totalPromptTokens: FlexibleInteger
        var totalCompletionTokens: FlexibleInteger
        enum CodingKeys: String, CodingKey {
            case modelPermaslug = "model_permaslug", variant, variantPermaslug = "variant_permaslug"
            case totalPromptTokens = "total_prompt_tokens", totalCompletionTokens = "total_completion_tokens"
        }
    }
}

private struct ActivityResponse: Decodable {
    var data: Body
    struct Body: Decodable { var analytics: [Day] }
    struct Day: Decodable {
        var date: String
        var totalPromptTokens: FlexibleInteger
        var totalCompletionTokens: FlexibleInteger
        enum CodingKeys: String, CodingKey {
            case date
            case totalPromptTokens = "total_prompt_tokens", totalCompletionTokens = "total_completion_tokens"
        }
    }
}

private struct ModelPrice: Sendable { var prompt: Double; var completion: Double }

private struct EffectivePricingResponse: Decodable {
    var data: Body
    struct Body: Decodable {
        var weightedInputPrice: Double
        var weightedOutputPrice: Double
    }
}

private struct FlexibleInteger: Decodable {
    var value: Int64
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int64.self) { value = integer }
        else if let double = try? container.decode(Double.self) { value = Int64(double) }
        else if let string = try? container.decode(String.self), let integer = Int64(string) { value = integer }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an integer") }
    }
}
