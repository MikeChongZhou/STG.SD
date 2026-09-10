import Foundation

public struct IOSScreenTimeThresholdResult: Equatable, Sendable {
    public var changedUTCDateKeys: Set<String>
    public var newlyMarkedMinutes: Int
    public var measuredLocalDayMinutes: Int
    public var skippedReminder: Bool

    public init(changedUTCDateKeys: Set<String>, newlyMarkedMinutes: Int, measuredLocalDayMinutes: Int, skippedReminder: Bool) {
        self.changedUTCDateKeys = changedUTCDateKeys
        self.newlyMarkedMinutes = newlyMarkedMinutes
        self.measuredLocalDayMinutes = measuredLocalDayMinutes
        self.skippedReminder = skippedReminder
    }
}

/// Implements design step 3.2.3 for DeviceActivity threshold callbacks.
/// No more than `maximumNewMinutes` points are added. The caller derives that
/// limit from the elapsed time since the preceding accepted system callback,
/// capped at 20. DeviceActivity thresholds belong to the current monitoring
/// registration while the bitmap belongs to the local day, so this function
/// deliberately neither compares nor reconciles those two totals.
public func applyIOSScreenTimeThreshold(
    repository: BitmapRepository,
    deviceID: String,
    now: Date,
    timeZoneID: String,
    maximumNewMinutes: Int = 20
) throws -> IOSScreenTimeThresholdResult {
    let measuredBeforeMarking = try repository.localDayMinutes(
        deviceID: deviceID,
        instant: now,
        timeZoneID: timeZoneID
    )
    let additionBudget = max(0, min(20, maximumNewMinutes))
    if additionBudget == 0 {
        return IOSScreenTimeThresholdResult(
            changedUTCDateKeys: [],
            newlyMarkedMinutes: 0,
            measuredLocalDayMinutes: measuredBeforeMarking,
            skippedReminder: true
        )
    }

    var changedDates: Set<String> = []
    var newlyMarked = 0

    for offset in 0..<additionBudget {
        let instant = now.addingTimeInterval(TimeInterval(-offset * 60))
        if try repository.mark(deviceID: deviceID, instant: instant, updatedAt: now) {
            newlyMarked += 1
            changedDates.insert(STGTime.utcDateKey(for: instant))
        }
    }

    for key in changedDates { _ = try repository.rebuildAllDevices(utcDate: key) }
    let measured = try repository.localDayMinutes(deviceID: deviceID, instant: now, timeZoneID: timeZoneID)
    return IOSScreenTimeThresholdResult(
        changedUTCDateKeys: changedDates,
        newlyMarkedMinutes: newlyMarked,
        measuredLocalDayMinutes: measured,
        skippedReminder: false
    )
}
