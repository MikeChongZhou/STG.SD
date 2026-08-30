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
/// A callback below the already reconstructed local-day total is ignored before
/// any write. Otherwise the current minute and previous 19 minutes are marked,
/// then a gap greater than three minutes is filled backwards using zero
/// positions from the current local day.
public func applyIOSScreenTimeThreshold(
    repository: BitmapRepository,
    deviceID: String,
    threshold: Int,
    now: Date,
    timeZoneID: String
) throws -> IOSScreenTimeThresholdResult {
    let measuredBeforeMarking = try repository.localDayMinutes(
        deviceID: deviceID,
        instant: now,
        timeZoneID: timeZoneID
    )
    if threshold <= measuredBeforeMarking {
        return IOSScreenTimeThresholdResult(
            changedUTCDateKeys: [],
            newlyMarkedMinutes: 0,
            measuredLocalDayMinutes: measuredBeforeMarking,
            skippedReminder: true
        )
    }

    var changedDates: Set<String> = []
    var newlyMarked = 0

    for offset in 0..<20 {
        let instant = now.addingTimeInterval(TimeInterval(-offset * 60))
        if try repository.mark(deviceID: deviceID, instant: instant, updatedAt: now) {
            newlyMarked += 1
            changedDates.insert(STGTime.utcDateKey(for: instant))
        }
    }

    var measured = try repository.localDayMinutes(deviceID: deviceID, instant: now, timeZoneID: timeZoneID)
    var gap = threshold - measured
    if gap > 3 {
        let localDayStart = STGTime.localDayInterval(containing: now, timeZoneID: timeZoneID).start
        var cursor = now.addingTimeInterval(-20 * 60)
        while gap > 0 && cursor >= localDayStart {
            if try repository.mark(deviceID: deviceID, instant: cursor, updatedAt: now) {
                newlyMarked += 1
                measured += 1
                gap -= 1
                changedDates.insert(STGTime.utcDateKey(for: cursor))
            }
            cursor = cursor.addingTimeInterval(-60)
        }
    }

    for key in changedDates { _ = try repository.rebuildAllDevices(utcDate: key) }
    measured = try repository.localDayMinutes(deviceID: deviceID, instant: now, timeZoneID: timeZoneID)
    return IOSScreenTimeThresholdResult(
        changedUTCDateKeys: changedDates,
        newlyMarkedMinutes: newlyMarked,
        measuredLocalDayMinutes: measured,
        skippedReminder: false
    )
}
