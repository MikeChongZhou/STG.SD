import DeviceActivity
import FamilyControls
import Foundation
import STGCore

@MainActor
final class DeviceActivityController: ObservableObject {
    @Published var selection: FamilyActivitySelection
    @Published var authorization: AuthorizationStatus = .notDetermined
    @Published var status = "Screen Time monitoring isn’t set up."
    private lazy var center = DeviceActivityCenter()
    private static let selectionDefaultsKey = "familySelection"

    init() {
        let started = ProcessInfo.processInfo.systemUptime
        if let data = SharedEnvironment.defaults.data(forKey: Self.selectionDefaultsKey),
           let saved = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            var normalized = FamilyActivitySelection(includeEntireCategory: false)
            normalized.applicationTokens = saved.applicationTokens
            normalized.categoryTokens = saved.categoryTokens
            normalized.webDomainTokens = saved.webDomainTokens
            selection = normalized
        } else {
            selection = FamilyActivitySelection(includeEntireCategory: false)
        }

        let activeScope = STGMonitorRegistration.activeScope
        let activePolicyVersion = STGMonitorRegistration.activePolicyVersion
        if STGMonitorRegistration.activeGeneration != nil {
            status = activeScope == STGMonitorRegistration.appDomainSelectionScope
                && activePolicyVersion == STGMonitorRegistration.currentPolicyVersion
                ? "Monitoring is active."
                : "Updating monitoring…"
        }
        SharedEnvironment.diagnosticLog.record(
            "monitor state on controller initialization; elapsed=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1_000))ms; authorization=deferred; activity_center=deferred; active_generation=\(STGMonitorRegistration.activeGeneration ?? "none"); active_activity=\(STGMonitorRegistration.activeActivityName ?? "none"); monitoring_scope=\(activeScope ?? "legacy_or_none"); policy_version=\(activePolicyVersion); required_policy_version=\(STGMonitorRegistration.currentPolicyVersion); restored_selection_apps=\(selection.applicationTokens.count); restored_selection_categories=\(selection.categoryTokens.count); restored_selection_domains=\(selection.webDomainTokens.count); registered_activities=deferred",
            category: "screen-time"
        )
        if STGMonitorRegistration.activeGeneration != nil,
           activeScope != STGMonitorRegistration.appDomainSelectionScope
                || activePolicyVersion != STGMonitorRegistration.currentPolicyVersion,
           selection.categoryTokens.isEmpty,
           !selection.applicationTokens.isEmpty || !selection.webDomainTokens.isEmpty {
            Task { @MainActor [weak self] in
                SharedEnvironment.diagnosticLog.record("automatic monitoring policy migration begin; previous_scope=\(activeScope ?? "none"); previous_policy_version=\(activePolicyVersion); target_scope=app_domain_selection; target_policy_version=\(STGMonitorRegistration.currentPolicyVersion)", category: "screen-time")
                self?.startMonitoring()
            }
        }
    }

    func refreshAuthorizationStatus() {
        let started = ProcessInfo.processInfo.systemUptime
        authorization = AuthorizationCenter.shared.authorizationStatus
        SharedEnvironment.diagnosticLog.record(
            "FamilyControls authorization status refreshed; status=\(String(describing: authorization)); duration=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1_000))ms",
            category: "screen-time"
        )
    }

    func requestAuthorization() async {
        do { try await AuthorizationCenter.shared.requestAuthorization(for: .individual); authorization = AuthorizationCenter.shared.authorizationStatus; status = "Screen Time access is authorized."; SharedEnvironment.diagnosticLog.record("FamilyControls authorization=\(String(describing: authorization))", category: "screen-time") }
        catch { status = "Couldn’t authorize Screen Time. Try again."; SharedEnvironment.diagnosticLog.record("FamilyControls authorization failed; error=\(error.localizedDescription)", category: "screen-time") }
    }

    @discardableResult func startMonitoring() -> Bool {
        let applicationCount = selection.applicationTokens.count
        let categoryCount = selection.categoryTokens.count
        let domainCount = selection.webDomainTokens.count
        guard categoryCount == 0 else {
            status = "Categories aren’t supported. Deselect all categories and choose individual apps."
            SharedEnvironment.diagnosticLog.record(
                "monitor registration blocked; reason=category_selection_not_allowed; applications=\(applicationCount); categories=\(categoryCount); domains=\(domainCount)",
                category: "screen-time"
            )
            return false
        }
        guard applicationCount + domainCount > 0 else {
            status = "Choose at least one app or website."
            SharedEnvironment.diagnosticLog.record(
                "monitor registration blocked; reason=empty_app_domain_selection; applications=0; categories=0; domains=0; all_activity_not_registered=true",
                category: "screen-time"
            )
            return false
        }

        guard let selectionData = try? JSONEncoder().encode(selection) else {
            status = "Couldn’t save your selection."
            SharedEnvironment.diagnosticLog.record("monitor registration blocked; reason=selection_encode_failed", category: "screen-time")
            return false
        }

        let activitiesBeforeStop = center.activities.map(\.rawValue).sorted()
        let activeGeneration = STGMonitorRegistration.activeGeneration
        let activeActivityName = STGMonitorRegistration.activeActivityName
        let previousScope = STGMonitorRegistration.activeScope
        let previousPolicyVersion = STGMonitorRegistration.activePolicyVersion
        let previousSelectionData = SharedEnvironment.defaults.data(forKey: Self.selectionDefaultsKey)
        let savedSelection = previousSelectionData.flatMap { try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0) }
        let selectionMatches = savedSelection.map {
            $0.applicationTokens == selection.applicationTokens
                && $0.categoryTokens == selection.categoryTokens
                && $0.webDomainTokens == selection.webDomainTokens
        } ?? false
        let activeActivityIsRegistered = activeActivityName.map(activitiesBeforeStop.contains) == true

        if activeGeneration != nil,
           previousScope == STGMonitorRegistration.appDomainSelectionScope,
           previousPolicyVersion == STGMonitorRegistration.currentPolicyVersion,
           selectionMatches,
           activeActivityIsRegistered {
            status = "Monitoring is active."
            SharedEnvironment.diagnosticLog.record(
                "monitor registration skipped; reason=already_running_with_same_selection; generation=\(activeGeneration ?? "none"); activity=\(activeActivityName ?? "none"); applications=\(applicationCount); categories=0; domains=\(domainCount); registered_activities=[\(activitiesBeforeStop.joined(separator: ","))]",
                category: "screen-time"
            )
            return true
        }

        let registeredAt = Date()
        let generation = STGMonitorRegistration.makeGeneration()
        let activity = STGMonitorRegistration.activity(generation: generation)
        let scopeChanged = activeGeneration != nil
            && previousScope != STGMonitorRegistration.appDomainSelectionScope
        let policyChanged = activeGeneration != nil
            && previousPolicyVersion != STGMonitorRegistration.currentPolicyVersion
        let selectionChanged = previousSelectionData != nil ? !selectionMatches : activeGeneration != nil

        SharedEnvironment.diagnosticLog.record(
            "monitor registration requested; generation=\(generation); activity=\(activity.rawValue); registered_at=\(registeredAt.ISO8601Format()); monitoring_scope=app_domain_selection; previous_scope=\(previousScope ?? "none"); scope_changed=\(scopeChanged); previous_policy_version=\(previousPolicyVersion); policy_version=\(STGMonitorRegistration.currentPolicyVersion); policy_changed=\(policyChanged); selection_changed=\(selectionChanged); applications=\(applicationCount); categories=0; domains=\(domainCount); includes_all_activity=false; existing_activities=[\(activitiesBeforeStop.joined(separator: ","))]",
            category: "screen-time"
        )

        // Make the new generation visible before stopping/starting. If iOS
        // delivers a queued callback during this transition, the extension
        // rejects it as stale before doing any work.
        SharedEnvironment.defaults.set(selectionData, forKey: Self.selectionDefaultsKey)
        SharedEnvironment.defaults.synchronize()
        STGMonitorRegistration.activate(generation: generation, activity: activity, startedAt: registeredAt, scope: STGMonitorRegistration.appDomainSelectionScope)
        center.stopMonitoring()
        SharedEnvironment.diagnosticLog.record(
            "stop all monitoring completed; generation=\(generation); remaining_activities=[\(center.activities.map(\.rawValue).sorted().joined(separator: ","))]",
            category: "screen-time"
        )

        if scopeChanged || selectionChanged {
            do {
                let settings = try SharedEnvironment.loadMonitorSettings()
                let repository = try SharedEnvironment.repository()
                let interval = STGTime.localDayInterval(containing: registeredAt, timeZoneID: TimeZone.current.identifier)
                let changedDates = Set(STGTime.utcDateKeys(overlapping: interval))
                let removed = try repository.clearLocalDay(deviceID: settings.deviceID, instant: registeredAt, timeZoneID: TimeZone.current.identifier)
                try repository.queueQuickUpload(deviceID: settings.deviceID, utcDateKeys: changedDates, at: registeredAt)
                SharedEnvironment.diagnosticLog.record("monitoring selection change reset local estimate; generation=\(generation); device=\(settings.deviceID.prefix(8)); previous_scope=\(previousScope ?? "none"); removed_minutes=\(removed); queued_utc_dates=\(changedDates.sorted().joined(separator: ","))", category: "screen-time")
            } catch {
                STGMonitorRegistration.deactivate(ifGenerationMatches: generation)
                status = "Couldn’t update monitoring. Try again."
                SharedEnvironment.diagnosticLog.record("monitoring selection restoration failed; generation=\(generation); error=\(error.localizedDescription)", category: "screen-time")
                return false
            }
        }

        let schedule = DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0), intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true)

        let includesPastActivity = false
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for minutes in stride(from: 20, through: 1_440, by: 20) {
            let event: DeviceActivityEvent
            if #available(iOS 17.4, *) {
                event = DeviceActivityEvent(
                    applications: selection.applicationTokens,
                    categories: [],
                    webDomains: selection.webDomainTokens,
                    threshold: DateComponents(minute: minutes),
                    includesPastActivity: false
                )
            } else {
                event = DeviceActivityEvent(
                    applications: selection.applicationTokens,
                    categories: [],
                    webDomains: selection.webDomainTokens,
                    threshold: DateComponents(minute: minutes)
                )
            }
            events[STGMonitorRegistration.event(generation: generation, thresholdMinutes: minutes)] = event
        }

        let firstEvent = STGMonitorRegistration.event(generation: generation, thresholdMinutes: 20).rawValue
        let lastEvent = STGMonitorRegistration.event(generation: generation, thresholdMinutes: 1_440).rawValue
        SharedEnvironment.diagnosticLog.record(
            "monitor registration plan; generation=\(generation); policy_version=\(STGMonitorRegistration.currentPolicyVersion); activity=\(activity.rawValue); timezone=\(TimeZone.current.identifier); schedule_local=00:00-23:59; repeats=true; monitoring_scope=app_domain_selection; applications=\(applicationCount); categories=0; domains=\(domainCount); includes_all_activity=false; includes_past_activity=\(includesPastActivity); event_count=\(events.count); threshold_range=20...1440/20m; first_event=\(firstEvent); last_event=\(lastEvent)",
            category: "screen-time"
        )

        do {
            try center.startMonitoring(activity, during: schedule, events: events)
            status = "Monitoring is active."
            SharedEnvironment.diagnosticLog.record(
                "monitor registration succeeded; generation=\(generation); policy_version=\(STGMonitorRegistration.currentPolicyVersion); activity=\(activity.rawValue); monitoring_scope=app_domain_selection; applications=\(applicationCount); categories=0; domains=\(domainCount); includes_all_activity=false; event_count=\(events.count); includes_past_activity=\(includesPastActivity); registered_activities=[\(center.activities.map(\.rawValue).sorted().joined(separator: ","))]",
                category: "screen-time"
            )
            return true
        } catch {
            STGMonitorRegistration.deactivate(ifGenerationMatches: generation)
            status = "Couldn’t start monitoring. Try again."
            SharedEnvironment.diagnosticLog.record(
                "monitor registration failed; generation=\(generation); activity=\(activity.rawValue); error_type=\(String(reflecting: type(of: error))); error=\(error.localizedDescription); registered_activities=[\(center.activities.map(\.rawValue).sorted().joined(separator: ","))]",
                category: "screen-time"
            )
            return false
        }
    }
}
