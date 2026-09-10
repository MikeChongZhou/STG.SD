import DeviceActivity
import Foundation
import STGCore

/// A unique identity for one complete DeviceActivity registration.
///
/// Putting the generation in both the activity and event names lets the
/// extension reject a callback queued by an older registration before that
/// callback can sync, alter the bitmap, or post a notification.
enum STGMonitorRegistration {
    static let generationDefaultsKey = "monitoring_generation"
    static let generationCounterDefaultsKey = "monitoring_generation_counter"
    static let activityDefaultsKey = "monitoring_activity_name"
    static let startedAtDefaultsKey = "monitoring_start_timestamp"
    static let scopeDefaultsKey = "monitoring_scope"
    static let policyVersionDefaultsKey = "monitoring_policy_version"
    static let callbackGenerationDefaultsKey = "monitoring_last_callback_generation"
    static let callbackReceivedAtDefaultsKey = "monitoring_last_callback_received_at"
    static let processedEventGenerationDefaultsKey = "monitoring_processed_event_generation"
    static let processedEventLocalDateDefaultsKey = "monitoring_processed_event_local_date"
    static let processedEventNamesDefaultsKey = "monitoring_processed_event_names"
    static let appDomainSelectionScope = "app_domain_selection"
    static let currentPolicyVersion = 2

    private static let activityPrefix = "stg.daily."
    private static let eventPrefix = "stg.threshold."
    private static let callbackStateLock = NSLock()

    struct CallbackAdmission {
        let duplicate: Bool
        let localDate: String
        let previousReceivedAt: Date?
        let elapsedWholeMinutes: Int
        let markingLimitMinutes: Int
        let baseline: String
    }

    /// Allocates a short, monotonically increasing registration identity.
    /// Consumed values are intentionally not reused after a failed start, so a
    /// delayed callback can never be mistaken for a later retry.
    static func makeGeneration() -> String {
        callbackStateLock.lock()
        defer { callbackStateLock.unlock() }

        let defaults = SharedEnvironment.defaults
        let storedCounter = (defaults.object(forKey: generationCounterDefaultsKey) as? NSNumber)?.int64Value ?? 0
        let numericActiveGeneration = activeGeneration.flatMap(Int64.init) ?? 0
        let next = max(storedCounter, numericActiveGeneration) + 1
        defaults.set(next, forKey: generationCounterDefaultsKey)
        defaults.synchronize()
        return String(next)
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

    static var activePolicyVersion: Int {
        SharedEnvironment.defaults.integer(forKey: policyVersionDefaultsKey)
    }

    static func activate(generation: String, activity: DeviceActivityName, startedAt: Date, scope: String) {
        SharedEnvironment.defaults.set(generation, forKey: generationDefaultsKey)
        SharedEnvironment.defaults.set(activity.rawValue, forKey: activityDefaultsKey)
        SharedEnvironment.defaults.set(startedAt.timeIntervalSince1970, forKey: startedAtDefaultsKey)
        SharedEnvironment.defaults.set(scope, forKey: scopeDefaultsKey)
        SharedEnvironment.defaults.set(currentPolicyVersion, forKey: policyVersionDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: callbackGenerationDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: callbackReceivedAtDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: processedEventGenerationDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: processedEventLocalDateDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: processedEventNamesDefaultsKey)
        // The app and monitor extension are separate processes. Flush this
        // small identity record before DeviceActivity can deliver a callback.
        SharedEnvironment.defaults.synchronize()
    }

    /// Atomically claims one event for its local day and records the arrival
    /// time in the App Group. This survives extension process recreation and
    /// prevents the same generation/event from being processed twice in one
    /// local day. A duplicate does not advance the valid-callback clock.
    static func admitCallback(
        generation: String,
        eventName: String,
        receivedAt: Date,
        timeZoneID: String
    ) -> CallbackAdmission {
        callbackStateLock.lock()
        defer { callbackStateLock.unlock() }

        let defaults = SharedEnvironment.defaults
        let day = STGTime.localDayInterval(containing: receivedAt, timeZoneID: timeZoneID)
        let localDate = localDateKey(for: receivedAt, timeZoneID: timeZoneID)
        let processedGeneration = defaults.string(forKey: processedEventGenerationDefaultsKey)
        let processedLocalDate = defaults.string(forKey: processedEventLocalDateDefaultsKey)
        var processedEvents = processedGeneration == generation && processedLocalDate == localDate
            ? Set(defaults.stringArray(forKey: processedEventNamesDefaultsKey) ?? [])
            : []

        if processedEvents.contains(eventName) {
            return CallbackAdmission(
                duplicate: true,
                localDate: localDate,
                previousReceivedAt: nil,
                elapsedWholeMinutes: 0,
                markingLimitMinutes: 0,
                baseline: "duplicate_event"
            )
        }
        processedEvents.insert(eventName)

        let storedGeneration = defaults.string(forKey: callbackGenerationDefaultsKey)
        let storedTimestamp = defaults.double(forKey: callbackReceivedAtDefaultsKey)
        let storedDate = storedTimestamp > 0 ? Date(timeIntervalSince1970: storedTimestamp) : nil
        let previous = storedGeneration == generation
            && storedDate.map { day.contains($0) && $0 <= receivedAt } == true
            ? storedDate
            : nil
        let registrationDate = activeGeneration == generation ? startedAt : nil
        let registrationBaseline = registrationDate.map { min(receivedAt, max(day.start, $0)) } ?? day.start
        let baselineDate = previous ?? registrationBaseline
        let elapsed = max(0, Int(receivedAt.timeIntervalSince(baselineDate) / 60.0))

        defaults.set(generation, forKey: processedEventGenerationDefaultsKey)
        defaults.set(localDate, forKey: processedEventLocalDateDefaultsKey)
        defaults.set(processedEvents.sorted(), forKey: processedEventNamesDefaultsKey)
        defaults.set(generation, forKey: callbackGenerationDefaultsKey)
        defaults.set(receivedAt.timeIntervalSince1970, forKey: callbackReceivedAtDefaultsKey)
        defaults.synchronize()

        return CallbackAdmission(
            duplicate: false,
            localDate: localDate,
            previousReceivedAt: previous,
            elapsedWholeMinutes: elapsed,
            markingLimitMinutes: min(20, elapsed),
            baseline: previous == nil
                ? (registrationBaseline > day.start ? "monitoring_registration" : "local_day_start")
                : "previous_callback"
        )
    }

    private static func localDateKey(for date: Date, timeZoneID: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func deactivate(ifGenerationMatches generation: String) {
        guard activeGeneration == generation else { return }
        SharedEnvironment.defaults.removeObject(forKey: generationDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: activityDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: startedAtDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: scopeDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: policyVersionDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: callbackGenerationDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: callbackReceivedAtDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: processedEventGenerationDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: processedEventLocalDateDefaultsKey)
        SharedEnvironment.defaults.removeObject(forKey: processedEventNamesDefaultsKey)
        SharedEnvironment.defaults.synchronize()
    }
}
