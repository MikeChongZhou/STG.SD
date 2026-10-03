import Foundation

public struct ReminderState: Equatable, Sendable {
    public var continuousMinutes = 0
    public var lastEyeAt = Date.distantPast
    public var lastPostureAt = Date.distantPast
    /// Daily-limit reminders still occupy the alternating eye/posture slot.
    /// Therefore this value only stores `.eye`, `.posture`, or `nil`.
    public var lastReminder: ReminderKind?

    public init(
        continuousMinutes: Int = 0,
        lastEyeAt: Date = .distantPast,
        lastPostureAt: Date = .distantPast,
        lastReminder: ReminderKind? = nil
    ) {
        self.continuousMinutes = continuousMinutes
        self.lastEyeAt = lastEyeAt
        self.lastPostureAt = lastPostureAt
        self.lastReminder = lastReminder
    }
}

public struct ReminderEngine: Sendable {
    public init() {}

    public func evaluate(
        active: Bool,
        now: Date,
        localMinuteIsSet: Bool,
        allDeviceDailyMinutes: Int,
        settings: STGSettings,
        state: inout ReminderState
    ) -> ReminderDecision? {
        guard active else { state.continuousMinutes = 0; return nil }
        state.continuousMinutes = localMinuteIsSet ? state.continuousMinutes + 1 : 1
        guard state.continuousMinutes >= 20 else { return nil }

        // Every evaluation consumes one 20-minute continuous-use block,
        // including a block suppressed by the 17/37-minute safety windows.
        state.continuousMinutes = 0
        let silent = settings.meetingMode
        let followsEyeReminder = state.lastReminder == .eye

        if followsEyeReminder {
            if settings.dailyNotificationsEnabled && allDeviceDailyMinutes > settings.dailyPlanMinutes {
                state.lastEyeAt = now; state.lastPostureAt = now
                state.lastReminder = .posture
                return .init(kind: .dailyLimit, usedMinutes: allDeviceDailyMinutes, closeCountdownMinutes: settings.dailyCloseCountdownMinutes, silent: silent)
            }
            guard settings.postureNotificationsEnabled else { state.lastReminder = .posture; return nil }
            if now.timeIntervalSince(state.lastPostureAt) >= 37 * 60 {
                state.lastEyeAt = now; state.lastPostureAt = now
                state.lastReminder = .posture
                return .init(kind: .posture, usedMinutes: allDeviceDailyMinutes, closeCountdownMinutes: settings.postureCloseCountdownMinutes, silent: silent)
            }
            return nil
        }

        if settings.dailyNotificationsEnabled && allDeviceDailyMinutes > settings.dailyPlanMinutes {
            state.lastEyeAt = now; state.lastPostureAt = now
            state.lastReminder = .eye
            return .init(kind: .dailyLimit, usedMinutes: allDeviceDailyMinutes, closeCountdownMinutes: settings.dailyCloseCountdownMinutes, silent: silent)
        }
        guard settings.eyeNotificationsEnabled else { state.lastReminder = .eye; return nil }
        if now.timeIntervalSince(state.lastEyeAt) >= 17 * 60 {
            state.lastEyeAt = now
            state.lastReminder = .eye
            return .init(kind: .eye, usedMinutes: allDeviceDailyMinutes, closeCountdownMinutes: settings.eyeCloseCountdownMinutes, silent: silent)
        }
        return nil
    }
}
