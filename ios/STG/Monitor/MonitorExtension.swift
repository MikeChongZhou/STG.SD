import DeviceActivity
import Foundation
import STGCore
import UserNotifications

/// Actor methods are reentrant across `await`, so merely putting cloud sync in
/// an actor does not serialize the complete callback pipeline. This gate stays
/// locked while one callback performs sync, validation, marking, and posting.
private actor ThresholdProcessingGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            locked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

final class MonitorExtension: DeviceActivityMonitor {
    private static let processingGate = ThresholdProcessingGate()

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        logIntervalCallback(kind: "interval_did_start", activity: activity)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        logIntervalCallback(kind: "interval_did_end", activity: activity)
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        let receivedAt = Date()
        let eventDetails = STGMonitorRegistration.eventDetails(from: event)
        let activityGeneration = STGMonitorRegistration.generation(from: activity)
        let activeGeneration = STGMonitorRegistration.activeGeneration
        let eventGeneration = eventDetails?.generation
        let generationMatches = activeGeneration != nil
            && activityGeneration == activeGeneration
            && eventGeneration == activeGeneration

        SharedEnvironment.diagnosticLog.record(
            "system threshold callback received; received_at=\(receivedAt.ISO8601Format()); activity=\(activity.rawValue); activity_generation=\(activityGeneration ?? "none"); event=\(event.rawValue); event_generation=\(eventGeneration ?? "none"); threshold=\(eventDetails.map { String($0.thresholdMinutes) } ?? "invalid"); active_generation=\(activeGeneration ?? "none"); active_activity=\(STGMonitorRegistration.activeActivityName ?? "none"); monitoring_scope=\(STGMonitorRegistration.activeScope ?? "none"); generation_match=\(generationMatches)",
            category: "monitor"
        )

        guard let eventDetails, let activityGeneration else {
            SharedEnvironment.diagnosticLog.record(
                "system threshold callback rejected; reason=malformed_or_legacy_name; activity=\(activity.rawValue); event=\(event.rawValue); no_sync=true; no_bitmap_change=true; no_notification=true",
                category: "monitor"
            )
            return
        }
        guard generationMatches else {
            SharedEnvironment.diagnosticLog.record(
                "system threshold callback rejected; reason=stale_generation; callback_generation=\(eventDetails.generation); activity_generation=\(activityGeneration); active_generation=\(activeGeneration ?? "none"); threshold=\(eventDetails.thresholdMinutes)m; no_sync=true; no_bitmap_change=true; no_notification=true",
                category: "monitor"
            )
            return
        }

        let callbackAdmission = STGMonitorRegistration.admitCallback(
            generation: eventDetails.generation,
            eventName: event.rawValue,
            receivedAt: receivedAt,
            timeZoneID: TimeZone.current.identifier
        )
        SharedEnvironment.diagnosticLog.record(
            "threshold callback admission; generation=\(eventDetails.generation); local_date=\(callbackAdmission.localDate); event=\(event.rawValue); threshold=\(eventDetails.thresholdMinutes)m; duplicate=\(callbackAdmission.duplicate); received_at=\(receivedAt.ISO8601Format()); previous_received_at=\(callbackAdmission.previousReceivedAt?.ISO8601Format() ?? "none"); baseline=\(callbackAdmission.baseline); elapsed_whole_minutes=\(callbackAdmission.elapsedWholeMinutes); marking_limit=\(callbackAdmission.markingLimitMinutes)m",
            category: "monitor"
        )
        guard !callbackAdmission.duplicate else {
            SharedEnvironment.diagnosticLog.record(
                "system threshold callback rejected; reason=duplicate_daily_event; generation=\(eventDetails.generation); local_date=\(callbackAdmission.localDate); event=\(event.rawValue); threshold=\(eventDetails.thresholdMinutes)m; no_sync=true; no_bitmap_change=true; no_notification=true",
                category: "monitor"
            )
            return
        }

        Task {
            await Self.processingGate.acquire()
            await process(
                generation: eventDetails.generation,
                threshold: eventDetails.thresholdMinutes,
                activityName: activity.rawValue,
                eventName: event.rawValue,
                receivedAt: receivedAt,
                markingLimitMinutes: callbackAdmission.markingLimitMinutes
            )
            await Self.processingGate.release()
        }
    }

    private func process(
        generation: String,
        threshold: Int,
        activityName: String,
        eventName: String,
        receivedAt now: Date,
        markingLimitMinutes: Int
    ) async {
        do {
            guard STGMonitorRegistration.activeGeneration == generation else {
                SharedEnvironment.diagnosticLog.record(
                    "threshold processing aborted; reason=generation_changed_before_processing; callback_generation=\(generation); active_generation=\(STGMonitorRegistration.activeGeneration ?? "none"); threshold=\(threshold)m",
                    category: "monitor"
                )
                return
            }

            let elapsedSinceRegistration = STGMonitorRegistration.startedAt.map { now.timeIntervalSince($0) }
            SharedEnvironment.diagnosticLog.record(
                "threshold processing begin; generation=\(generation); activity=\(activityName); event=\(eventName); threshold=\(threshold)m; elapsed_since_registration_seconds=\(elapsedSinceRegistration.map { String(format: "%.3f", $0) } ?? "unknown"); marking_limit=\(markingLimitMinutes)m",
                category: "monitor"
            )

            let settings = try SharedEnvironment.loadMonitorSettings()
            let repository = try SharedEnvironment.repository()
            SharedEnvironment.diagnosticLog.record("threshold context; generation=\(generation); device=\(settings.deviceID.prefix(8)); timezone=\(TimeZone.current.identifier); database=\(SharedEnvironment.databaseURL.path)", category: "monitor")

            // Design 3.1: every delivered threshold performs its own current-day
            // quick bidirectional sync. Calls are serialized for database and
            // credential safety, but no threshold events are merged or dropped.
            await ThresholdQuickSync.shared.bidirectional(settings: settings, repository: repository, threshold: threshold, now: now)

            guard STGMonitorRegistration.activeGeneration == generation else {
                SharedEnvironment.diagnosticLog.record(
                    "threshold processing aborted; reason=generation_changed_during_quick_sync; callback_generation=\(generation); active_generation=\(STGMonitorRegistration.activeGeneration ?? "none"); threshold=\(threshold)m; no_bitmap_change=true; no_notification=true",
                    category: "monitor"
                )
                return
            }

            guard markingLimitMinutes > 0 else {
                SharedEnvironment.diagnosticLog.record(
                    "threshold ignored before marking; generation=\(generation); event=\(threshold)m; reason=no_elapsed_minute_since_previous_callback; marking_limit=0m; bitmap_unchanged=true; notification_posted=false",
                    category: "monitor"
                )
                return
            }

            let measuredBefore = try repository.localDayMinutes(deviceID: settings.deviceID, instant: now, timeZoneID: TimeZone.current.identifier)
            let aggregateBefore = try repository.localDayMinutes(deviceID: "alldevices", instant: now, timeZoneID: TimeZone.current.identifier)
            SharedEnvironment.diagnosticLog.record(
                "threshold bitmap snapshot; generation=\(generation); threshold=\(threshold)m; local_device_measured_before=\(measuredBefore)m; stored_aggregate_before=\(aggregateBefore)m; threshold_not_compared_with_daily_bitmap=true",
                category: "monitor"
            )

            let result = try applyIOSScreenTimeThreshold(
                repository: repository,
                deviceID: settings.deviceID,
                now: now,
                timeZoneID: TimeZone.current.identifier,
                maximumNewMinutes: markingLimitMinutes
            )

            SharedEnvironment.diagnosticLog.record("threshold applied; generation=\(generation); device=\(settings.deviceID.prefix(8)); event=\(threshold)m; marking_limit=\(markingLimitMinutes)m; newly_marked=\(result.newlyMarkedMinutes)m; measured=\(result.measuredLocalDayMinutes)m; changed_utc_dates=\(result.changedUTCDateKeys.sorted().joined(separator: ","))", category: "monitor")
            await ThresholdQuickSync.shared.uploadChanged(settings: settings, repository: repository, threshold: threshold, utcDateKeys: result.changedUTCDateKeys)

            let all = try repository.localDayMinutes(deviceID: "alldevices", instant: now, timeZoneID: TimeZone.current.identifier)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            try repository.updateRuntimeState(
                deviceID: settings.deviceID,
                continuousMinutes: 0,
                localDailyMinutes: result.measuredLocalDayMinutes,
                aggregateDailyMinutes: all,
                localDate: formatter.string(from: now),
                at: now
            )
            let kind: ReminderKind = all >= settings.dailyPlanMinutes ? .dailyLimit : (threshold % 40 == 0 ? .posture : .eye)
            SharedEnvironment.diagnosticLog.record("threshold reminder prepared; generation=\(generation); device=\(settings.deviceID.prefix(8)); threshold=\(threshold)m; stored_aggregate=\(all)m; reminder=\(kind.rawValue); silent=\(settings.meetingMode)", category: "monitor")
            await post(generation: generation, threshold: threshold, kind: kind, minutes: all, silent: settings.meetingMode)
        } catch {
            SharedEnvironment.diagnosticLog.record("threshold processing failed; generation=\(generation); threshold=\(threshold)m; error_type=\(String(reflecting: type(of: error))); error=\(error.localizedDescription)", category: "monitor")
            return
        }
    }

    private func post(generation: String, threshold: Int, kind: ReminderKind, minutes: Int, silent: Bool) async {
        let content = UNMutableNotificationContent()
        switch kind {
        case .eye:
            content.title = NSLocalizedString("Eye Break", comment: "Eye-break notification title")
            content.body = NSLocalizedString("Look 20 feet away for 20 seconds.", comment: "Eye-break notification body")
        case .posture:
            content.title = NSLocalizedString("Posture Break", comment: "Posture notification title")
            content.body = NSLocalizedString("Stand or walk for 4 minutes and rest your eyes.", comment: "Posture notification body")
        case .dailyLimit:
            content.title = NSLocalizedString("Daily Limit Reached", comment: "Daily-limit notification title")
            content.body = String(format: NSLocalizedString("Screen use today: %lldh %lldm. Take a 5-minute break.", comment: "Daily-limit notification body"), minutes / 60, minutes % 60)
        }
        if !silent { content.sound = .default }
        let identifier = "stg-\(generation)-\(threshold)-\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            SharedEnvironment.diagnosticLog.record(
                "threshold notification enqueued; generation=\(generation); threshold=\(threshold)m; identifier=\(identifier); reminder=\(kind.rawValue); displayed_minutes=\(minutes)m; silent=\(silent)",
                category: "monitor"
            )
        } catch {
            SharedEnvironment.diagnosticLog.record(
                "threshold notification enqueue failed; generation=\(generation); threshold=\(threshold)m; identifier=\(identifier); error_type=\(String(reflecting: type(of: error))); error=\(error.localizedDescription)",
                category: "monitor"
            )
        }
    }

    private func logIntervalCallback(kind: String, activity: DeviceActivityName) {
        let activityGeneration = STGMonitorRegistration.generation(from: activity)
        let activeGeneration = STGMonitorRegistration.activeGeneration
        SharedEnvironment.diagnosticLog.record(
            "system \(kind); received_at=\(Date().ISO8601Format()); activity=\(activity.rawValue); activity_generation=\(activityGeneration ?? "none"); active_generation=\(activeGeneration ?? "none"); generation_match=\(activityGeneration != nil && activityGeneration == activeGeneration)",
            category: "monitor"
        )
    }
}
