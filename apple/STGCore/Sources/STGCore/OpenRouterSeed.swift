import Foundation

struct OpenRouterSeedDocument: Decodable {
    let schema: Int
    let asOf: String
    let startDate: String
    let endDate: String
    let missingDates: [String]
    let tokenBreakdownAvailable: Bool
    let rows: [OpenRouterSeedRow]

    enum CodingKeys: String, CodingKey {
        case schema
        case asOf = "as_of"
        case startDate = "start_date"
        case endDate = "end_date"
        case missingDates = "missing_dates"
        case tokenBreakdownAvailable = "token_breakdown_available"
        case rows
    }
}

struct OpenRouterSeedRow: Decodable {
    let weekStart: String
    let weekEnd: String
    let rank: Int
    let model: String
    let totalTokens: Int64

    enum CodingKeys: String, CodingKey {
        case weekStart = "s", weekEnd = "e", rank = "r", model = "m", totalTokens = "t"
    }
}

enum OpenRouterSeed {
    static let marker = "openrouter_seed_v1"

    static func load() throws -> OpenRouterSeedDocument {
        let bundles = [Bundle.main, Bundle(for: BundleToken.self)] + Bundle.allFrameworks
        var resourceURL = bundles.lazy.compactMap({
            $0.url(forResource: "openrouter-weekly-seed-v1", withExtension: "json")
        }).first
        #if SWIFT_PACKAGE
        // Access Bundle.module only after the standard app/framework locations.
        // A manually packaged macOS app carries the JSON in Contents/Resources.
        if resourceURL == nil {
            resourceURL = Bundle.module.url(forResource: "openrouter-weekly-seed-v1", withExtension: "json")
        }
        #endif
        guard let url = resourceURL else {
            throw STGError.invalidDocument("Bundled OpenRouter history seed is missing")
        }
        let document = try JSONDecoder().decode(OpenRouterSeedDocument.self, from: Data(contentsOf: url))
        guard document.schema == 1, !document.rows.isEmpty else {
            throw STGError.invalidDocument("Bundled OpenRouter history seed is invalid")
        }
        return document
    }
}

private final class BundleToken: NSObject {}
