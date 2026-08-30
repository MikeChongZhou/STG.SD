import Foundation

public enum TrackingSortField: String, CaseIterable, Sendable {
    case rank, model, promptTokens, completionTokens, totalTokens
    case promptPrice, completionPrice, revenue
}

public enum TrackingSortDirection: Sendable { case descending, ascending }

public func sortedOpenRouterRows(
    _ rows: [OpenRouterRankingRow],
    by field: TrackingSortField,
    direction: TrackingSortDirection
) -> [OpenRouterRankingRow] {
    rows.sorted { left, right in
        let leftMissing = isMissing(left, field: field)
        let rightMissing = isMissing(right, field: field)
        if leftMissing != rightMissing { return !leftMissing }

        let comparison: ComparisonResult
        switch field {
        case .rank: comparison = compare(left.rank, right.rank)
        case .model:
            comparison = left.modelPermaslug.compare(
                right.modelPermaslug,
                options: [.caseInsensitive, .numeric],
                locale: Locale(identifier: "en_US_POSIX")
            )
        case .promptTokens: comparison = compare(left.promptTokens, right.promptTokens)
        case .completionTokens: comparison = compare(left.completionTokens, right.completionTokens)
        case .totalTokens: comparison = compare(left.totalTokens, right.totalTokens)
        case .promptPrice: comparison = compareOptional(left.promptPricePerToken, right.promptPricePerToken)
        case .completionPrice: comparison = compareOptional(left.completionPricePerToken, right.completionPricePerToken)
        case .revenue: comparison = compareOptional(left.revenueUSD, right.revenueUSD)
        }
        if comparison != .orderedSame {
            return direction == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }

        // A deterministic, direction-independent tie breaker makes the
        // comparator a strict total order even when multiple numeric values
        // are equal or model names differ only by case.
        if left.rank != right.rank { return left.rank < right.rank }
        return left.modelPermaslug < right.modelPermaslug
    }
}

public func formattedWholeDollarUSD(_ value: Double?) -> String {
    guard let value else { return "N/A" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 0
    formatter.roundingMode = .halfUp
    return "$\(formatter.string(from: NSNumber(value: value)) ?? String(Int64(value.rounded())))"
}

public func openRouterTrackingCSV(
    rows: [OpenRouterRankingRow],
    period: String,
    startDate: String,
    endDate: String
) -> String {
    var lines = ["period,start_date_utc,end_date_utc,rank,model,input_tokens,output_tokens,total_tokens,input_price_usd_per_token,output_price_usd_per_token,estimated_revenue_usd"]
    lines += rows.map { row in
        let inputPrice = row.promptPricePerToken.map { String($0) } ?? ""
        let outputPrice = row.completionPricePerToken.map { String($0) } ?? ""
        let revenue = row.revenueUSD.map { String($0) } ?? ""
        let fields: [String] = [
            period, startDate, endDate, String(row.rank), row.modelPermaslug,
            String(row.promptTokens), String(row.completionTokens), String(row.totalTokens),
            inputPrice, outputPrice, revenue
        ]
        return fields.map(csvField).joined(separator: ",")
    }
    return lines.joined(separator: "\n") + "\n"
}

private func compare<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult {
    left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
}

private func compareOptional(_ left: Double?, _ right: Double?) -> ComparisonResult {
    switch (left, right) {
    case let (.some(a), .some(b)): return compare(a, b)
    case (.some, .none): return .orderedAscending
    case (.none, .some): return .orderedDescending
    case (.none, .none): return .orderedSame
    }
}

private func isMissing(_ row: OpenRouterRankingRow, field: TrackingSortField) -> Bool {
    switch field {
    case .promptPrice: row.promptPricePerToken == nil
    case .completionPrice: row.completionPricePerToken == nil
    case .revenue: row.revenueUSD == nil
    default: false
    }
}

private func csvField(_ value: String) -> String {
    guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}
