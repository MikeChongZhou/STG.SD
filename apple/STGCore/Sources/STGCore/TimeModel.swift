import Foundation

public enum STGTime {
    public static let utc = TimeZone(secondsFromGMT: 0)!

    public static func utcDateKey(for instant: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func utcMinute(for instant: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let parts = calendar.dateComponents([.hour, .minute], from: instant)
        return parts.hour! * 60 + parts.minute!
    }

    public static func utcDayStart(_ key: String) throws -> Date {
        let pieces = key.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { throw STGError.invalidUTCDate(key) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        guard let date = calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])) else {
            throw STGError.invalidUTCDate(key)
        }
        return date
    }

    public static func localDayInterval(containing instant: Date, timeZoneID: String) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return calendar.dateInterval(of: .day, for: instant)!
    }

    /// Returns the wall-clock minute (00:00 = 0, 23:59 = 1439) in the
    /// requested report timezone. This is deliberately different from elapsed
    /// minutes since local midnight on daylight-saving transition days.
    public static func localClockMinute(for instant: Date, timeZoneID: String) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: instant)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    public static func localClockLabel(minute: Int) -> String {
        let bounded = max(0, min(1_440, minute))
        if bounded == 1_440 { return "24:00" }
        return String(format: "%02d:%02d", bounded / 60, bounded % 60)
    }

    public static func utcDateKeys(overlapping interval: DateInterval) -> [String] {
        var keys: [String] = []
        var cursor = interval.start
        while cursor < interval.end {
            let key = utcDateKey(for: cursor)
            if keys.last != key { keys.append(key) }
            cursor = min(interval.end, (try? utcDayStart(key).addingTimeInterval(86_400)) ?? interval.end)
        }
        return keys
    }

    /// Dates uploaded by a full incremental sync. With no cursor this seeds a
    /// bounded history; afterwards the last successful date is intentionally
    /// included because its bitmap can continue changing throughout the day.
    public static func incrementalUploadUTCDateKeys(cursor: String?, now: Date, initialDays: Int = 14) throws -> [String] {
        let today = utcDateKey(for: now)
        guard let cursor else {
            return (0..<max(1, min(initialDays, 14)))
                .map { utcDateKey(for: now.addingTimeInterval(TimeInterval(-$0 * 86_400))) }
                .sorted()
        }
        let start = try utcDayStart(cursor)
        let end = try utcDayStart(today)
        guard start <= end else { return [today] }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        var result: [String] = []
        var day = start
        while day <= end {
            result.append(utcDateKey(for: day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}
