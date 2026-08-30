import DeviceActivity
import Foundation

/// A unique identity for one complete DeviceActivity registration.
///
/// Putting the generation in both the activity and event names lets the
/// extension reject a callback queued by an older registration before that
/// callback can sync, alter the bitmap, or post a notification.
enum STGMonitorRegistration {
    static let generationDefaultsKey = "monitoring_generation"
    static let activityDefaultsKey = "monitoring_activity_name"
    static let startedAtDefaultsKey = "monitoring_start_timestamp"
    static let scopeDefaultsKey = "monitoring_scope"
    static let appDomainSelectionScope = "app_domain_selection"

    private static let activityPrefix = "stg.daily."
    private static let eventPrefix = "stg.threshold."

    static func makeGeneration(at date: Date = Date()) -> String {
        let milliseconds = Int64(date.timeIntervalSince1970 * 1_000)
        return "\(milliseconds)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    static func activity(generation: String) -> DeviceActivityName {
        DeviceActivityName("\(activityPrefix)\(generation)")
    }

    static func event(generation: String, thresholdMinutes: Int) -> DeviceActivityEvent.Name {
        DeviceActivityEvent.Name("\(eventPrefix)\(generation).\(thresholdMinutes)")
    }

    static func generation(from activity: DeviceActivityName) -> String? {
        guard activity.rawValue.hasPrefix(activityPrefix) else { return nil }
        let value = String(activity.rawValue.dropFirst(activityPrefix.count))
        return value.isEmpty ? nil : value
    }

    static func eventDetails(from event: DeviceActivityEvent.Name) -> (generation: String, thresholdMinutes: Int)? {
        guard event.rawValue.hasPrefix(eventPrefix) else { return nil }
        let value = String(event.rawValue.dropFirst(eventPrefix.count))
        guard let separator = value.lastIndex(of: "."),
              separator != value.startIndex,
              let threshold = Int(value[value.index(after: separator)...]) else { return nil }
        return (String(value[..<separator]), threshold)
    }

    static var activeGeneration: String? {
        SharedEnvironment.defaults.string(forKey: generationDefaultsKey)
    }

    static var activeActivityName: String? {
        SharedEnvironment.defaults.string(forKey: activityDefaultsKey)
    }

    static var startedAt: Date? {
        let timestamp = SharedEnvironment.defaults.double(forKey: startedAtDefaultsKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    static var activeScope: String? {
        SharedEnvironment.defaults.string(forKey: scopeDefaultsKey)
    }

    static func activate(generation: String, activity: DeviceActivityName, startedAt: Date, scope: String) {
        SharedEnvironment.defaults.set(generation, forKey: generationDefaultsKey)
        SharedEnvironment.defaults.set(activity.rawValue, forKey: activityDefaultsKey)
        SharedEnvironment.defaults.set(startedAt.timeIntervalSince1970, forKey: startedAtDefaultsKey)
        SharedEnvironment.defaults.set(scope, forKey: scopeDefaultsKey)
        // The app and monitor extension are separate processes. Flush this
        // small identity record before DeviceActivity can deliver a callback.
        SharedEnvironment.defaults.synchronize()
    }

    static func deactivate(ifGenerationMatches generation: String) {
        guard activeGeneration == generation else { return }
        SharedEnvironment.defaults.removeObject(forKey: generationDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: activityDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: startedAtDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: scopeDefaultsKey)
        SharedEnvironment.defaults.synchronize()
    }
}
