import Foundation
import Security
import STGCore
import UIKit

enum SharedEnvironment {
    static let appGroup = "group.com.timbertrail.screentimeguardian"
    static let iCloudContainer = "iCloud.com.timbertrail.screentimeguardian"
    static let keychainAccessGroup: String = {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "STGKeychainAccessGroup") as? String,
           !configured.isEmpty,
           !configured.contains("$("),
           !configured.hasPrefix("group.") {
            return configured
        }
        return "DA6DVPSL36.group.com.timbertrail.screentimeguardian"
    }()
    static let oneDriveCredentialService = "com.timbertrail.screentimeguardian.ios.onedrive"
    static let googleDriveCredentialService = "com.timbertrail.screentimeguardian.ios.googledrive"
    private static let canonicalDeviceIDKey = "canonical_device_id"
    private static let groupDefaults = UserDefaults(suiteName: appGroup)
    static let defaults = groupDefaults ?? .standard

    private enum EnvironmentError: LocalizedError {
        case appGroupUnavailable
        case canonicalDeviceIDMissing
        case settingsMissing
        case settingsInvalid(String)

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "The App Group container is unavailable"
            case .canonicalDeviceIDMissing:
                return "The shared canonical device ID has not been initialized by the main app"
            case .settingsMissing:
                return "The shared settings file is missing"
            case let .settingsInvalid(message):
                return "The shared settings file could not be decoded: \(message)"
            }
        }
    }

    private static var appGroupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var container: URL {
        if let group = appGroupContainer { return group }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenTimeGuardian-iOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    static var databaseURL: URL { container.appendingPathComponent("stg.sqlite") }
    private static var settingsURL: URL { container.appendingPathComponent("settings.json") }

    static let diagnosticLog = DiagnosticLog(directory: container.appendingPathComponent("Diagnostics", isDirectory: true))

    static func repository() throws -> BitmapRepository {
        guard appGroupContainer != nil else { throw EnvironmentError.appGroupUnavailable }
        return try BitmapRepository(url: databaseURL)
    }

    /// The main app owns creation of the local identity. It persists the
    /// canonical ID and complete settings before a monitor extension can run.
    static func loadAppSettings() -> STGSettings {
        var decodedSettings: STGSettings?
        var settingsSource = "missing"

        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                decodedSettings = try decoder.decode(STGSettings.self, from: Data(contentsOf: settingsURL))
                settingsSource = "file"
            } catch {
                settingsSource = "decode_failed"
                diagnosticLog.record("settings decode failed; process=app; error=\(error.localizedDescription)", category: "environment")
            }
        }

        let canonicalID: String
        if let sharedID = validDeviceID(groupDefaults?.string(forKey: canonicalDeviceIDKey)) {
            canonicalID = sharedID
            settingsSource += "+shared_id"
        } else if let fileID = validDeviceID(decodedSettings?.deviceID) {
            canonicalID = fileID
            groupDefaults?.set(fileID, forKey: canonicalDeviceIDKey)
            settingsSource += "+seeded_shared_id"
        } else {
            canonicalID = legacyAppDeviceID()
            groupDefaults?.set(canonicalID, forKey: canonicalDeviceIDKey)
            settingsSource += "+legacy_keychain_bootstrap"
        }

        var settings = decodedSettings ?? STGSettings(deviceID: canonicalID, deviceName: UIDevice.current.name, deviceKind: .ios)
        if settings.deviceID != canonicalID {
            diagnosticLog.record("device identity normalized; process=app; settings_device=\(settings.deviceID.prefix(8)); canonical_device=\(canonicalID.prefix(8))", category: "environment")
            settings.deviceID = canonicalID
        }

        do {
            try saveSettings(settings)
        } catch {
            diagnosticLog.record("settings bootstrap save failed; process=app; error=\(error.localizedDescription)", category: "environment")
        }
        recordEnvironment(process: "app", settingsSource: settingsSource, deviceID: canonicalID)
        return settings
    }

    /// Extensions may consume the shared identity, but must never invent one.
    static func loadMonitorSettings() throws -> STGSettings {
        guard appGroupContainer != nil, let groupDefaults else { throw EnvironmentError.appGroupUnavailable }
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { throw EnvironmentError.settingsMissing }

        let settings: STGSettings
        do {
            settings = try decoder.decode(STGSettings.self, from: Data(contentsOf: settingsURL))
        } catch {
            throw EnvironmentError.settingsInvalid(error.localizedDescription)
        }

        let canonicalID: String
        var source: String
        if let sharedID = validDeviceID(groupDefaults.string(forKey: canonicalDeviceIDKey)) {
            canonicalID = sharedID
            source = "file+shared_id"
        } else if let fileID = validDeviceID(settings.deviceID) {
            // This supports an update whose extension runs before the updated
            // main app. The ID still comes from the shared file, never from the
            // extension's private Keychain domain.
            canonicalID = fileID
            groupDefaults.set(fileID, forKey: canonicalDeviceIDKey)
            source = "file+seeded_shared_id"
        } else {
            throw EnvironmentError.canonicalDeviceIDMissing
        }

        var normalized = settings
        if settings.deviceID != canonicalID {
            normalized.deviceID = canonicalID
            source += "+normalized"
            diagnosticLog.record("device identity normalized; process=monitor; settings_device=\(settings.deviceID.prefix(8)); canonical_device=\(canonicalID.prefix(8))", category: "environment")
        }
        recordEnvironment(process: "monitor", settingsSource: source, deviceID: canonicalID)
        return normalized
    }

    static func saveSettings(_ settings: STGSettings) throws {
        guard appGroupContainer != nil, let groupDefaults else { throw EnvironmentError.appGroupUnavailable }
        var normalized = settings
        if let canonicalID = validDeviceID(groupDefaults.string(forKey: canonicalDeviceIDKey)) {
            normalized.deviceID = canonicalID
        } else {
            guard let deviceID = validDeviceID(settings.deviceID) else { throw EnvironmentError.canonicalDeviceIDMissing }
            groupDefaults.set(deviceID, forKey: canonicalDeviceIDKey)
            normalized.deviceID = deviceID
        }
        try encoder.encode(normalized).write(to: settingsURL, options: .atomic)
    }

    /// Moves credentials created by an older build from the main app's private
    /// Keychain domain into the access group shared with the monitor extension.
    /// The legacy item is retained until sign-out so an interrupted update can
    /// still fall back to the previous build.
    static func migrateCloudCredentialsToSharedKeychain() {
        do {
            if OneDriveCredentialStore.load(service: oneDriveCredentialService, accessGroup: keychainAccessGroup) == nil,
               let legacy = OneDriveCredentialStore.load(service: oneDriveCredentialService) {
                try OneDriveCredentialStore.save(legacy, service: oneDriveCredentialService, accessGroup: keychainAccessGroup)
                diagnosticLog.record("OneDrive credential migrated to monitor access group", category: "sync")
            }
            if GoogleDriveCredentialStore.load(service: googleDriveCredentialService, accessGroup: keychainAccessGroup) == nil,
               let legacy = GoogleDriveCredentialStore.load(service: googleDriveCredentialService) {
                try GoogleDriveCredentialStore.save(legacy, service: googleDriveCredentialService, accessGroup: keychainAccessGroup)
                diagnosticLog.record("Google Drive credential migrated to monitor access group", category: "sync")
            }
        } catch {
            diagnosticLog.record("credential access-group migration failed: \(error.localizedDescription)", category: "sync")
        }
    }

    static func cloudFolder() -> URL? {
        guard let root = FileManager.default.url(forUbiquityContainerIdentifier: iCloudContainer) else { return nil }
        let folder = root.appendingPathComponent("Documents/ScreenTimeGuardian", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func recordEnvironment(process: String, settingsSource: String, deviceID: String?) {
        let groupAvailable = appGroupContainer != nil
        diagnosticLog.record(
            "process=\(process); app_group_available=\(groupAvailable); container=\(container.path); database=\(databaseURL.path); settings_source=\(settingsSource); device=\(deviceID.map { String($0.prefix(8)) } ?? "none")",
            category: "environment"
        )
    }

    private static func validDeviceID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Reads the main app's pre-fix Keychain identity so an update keeps the
    /// established local ID. The monitor extension never calls this method.
    private static func legacyAppDeviceID() -> String {
        let service = "com.timbertrail.screentimeguardian.device-id"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let value = String(data: data, encoding: .utf8) { return value }
        let value = UUID().uuidString.lowercased()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecValueData as String: Data(value.utf8)]
        SecItemAdd(add as CFDictionary, nil)
        return value
    }

    static var encoder: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value }
    static var decoder: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
