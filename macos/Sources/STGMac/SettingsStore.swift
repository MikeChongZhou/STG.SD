import Foundation
import IOKit
import Security
import STGCore

final class SettingsStore {
    private let url: URL

    init(applicationSupport: URL) {
        url = applicationSupport.appendingPathComponent("settings.json")
    }

    func load() -> STGSettings {
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder.stg.decode(STGSettings.self, from: data) { return value }
        return STGSettings(deviceID: Self.platformUUID(), deviceName: Host.current().localizedName ?? "Mac", deviceKind: .macos)
    }

    func save(_ settings: STGSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.stg.encode(settings).write(to: url, options: .atomic)
    }

    private static func platformUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        if service != 0,
           let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
           !value.isEmpty { return value.lowercased() }
        return keychainUUID()
    }

    private static func keychainUUID() -> String {
        let service = "com.timbertrail.stg.device-id"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let value = String(data: data, encoding: .utf8) { return value }
        let value = UUID().uuidString.lowercased()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecValueData as String: Data(value.utf8)]
        SecItemAdd(add as CFDictionary, nil)
        return value
    }
}

extension JSONEncoder {
    static var stg: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]; value.dateEncodingStrategy = .iso8601; return value }
}

extension JSONDecoder {
    static var stg: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}

