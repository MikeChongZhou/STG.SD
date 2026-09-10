import Foundation

enum OpenRouterSeed {
    static let applicationID: Int32 = 0x535447

    static func databaseURL() throws -> URL {
        let bundles = [Bundle.main, Bundle(for: BundleToken.self)] + Bundle.allFrameworks
        var resourceURL = bundles.lazy.compactMap({ $0.url(forResource: "stg", withExtension: "sqlite") }).first
        #if SWIFT_PACKAGE
        if resourceURL == nil {
            resourceURL = Bundle.module.url(forResource: "stg", withExtension: "sqlite")
        }
        #endif
        guard let resourceURL else {
            throw STGError.invalidDocument("Bundled STG database template is missing")
        }
        return resourceURL
    }
}

private final class BundleToken: NSObject {}
