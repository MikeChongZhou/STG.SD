import Foundation

public typealias SyncProgressHandler = @MainActor @Sendable (String) async -> Void

public enum DeviceKind: String, Codable, Sendable { case macos, windows, ios, android }

public enum SyncProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case iCloudDrive
    case oneDrive
    case googleDrive
}

public struct DeviceRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { deviceID }
    public var deviceID: String
    public var name: String
    public var kind: DeviceKind
    public var updatedAt: Date

    public init(deviceID: String, name: String, kind: DeviceKind, updatedAt: Date = .now) {
        self.deviceID = deviceID; self.name = name; self.kind = kind; self.updatedAt = updatedAt
    }
}

public struct DeviceDayBitmap: Equatable, Sendable, Identifiable {
    public var id: String { deviceID }
    public var deviceID: String
    public var displayName: String
    public var minutes: [Bool]
    public var isAggregate: Bool
    private var calculatedUsedMinutes: Int?
    public var usedMinutes: Int { calculatedUsedMinutes ?? minutes.lazy.filter { $0 }.count }

    public init(deviceID: String, displayName: String, minutes: [Bool], isAggregate: Bool = false, usedMinutes: Int? = nil) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.minutes = minutes
        self.isAggregate = isAggregate
        calculatedUsedMinutes = usedMinutes
    }
}

public struct DailyUsagePoint: Equatable, Sendable, Identifiable {
    public var id: String { "\(deviceID)|\(dateLabel)" }
    public var date: Date
    public var dateLabel: String
    public var deviceID: String
    public var displayName: String
    public var minutes: Int
    public var isAggregate: Bool
    public var estimated: Bool

    public init(date: Date, dateLabel: String, deviceID: String, displayName: String, minutes: Int, isAggregate: Bool = false, estimated: Bool = false) {
        self.date = date; self.dateLabel = dateLabel; self.deviceID = deviceID; self.displayName = displayName; self.minutes = minutes; self.isAggregate = isAggregate; self.estimated = estimated
    }
}

public struct UsageStatisticsSummary: Equatable, Sendable {
    public var thisWeekAverageMinutes: Double?
    public var lastWeekAverageMinutes: Double?
    public var thisMonthAverageMinutes: Double?
    public var lastMonthAverageMinutes: Double?
    public var thisYearAverageMinutes: Double?
    public var containsEstimatedIOSData: Bool

    public init(thisWeekAverageMinutes: Double? = nil, lastWeekAverageMinutes: Double? = nil,
                thisMonthAverageMinutes: Double? = nil, lastMonthAverageMinutes: Double? = nil,
                thisYearAverageMinutes: Double? = nil, containsEstimatedIOSData: Bool = false) {
        self.thisWeekAverageMinutes = thisWeekAverageMinutes
        self.lastWeekAverageMinutes = lastWeekAverageMinutes
        self.thisMonthAverageMinutes = thisMonthAverageMinutes
        self.lastMonthAverageMinutes = lastMonthAverageMinutes
        self.thisYearAverageMinutes = thisYearAverageMinutes
        self.containsEstimatedIOSData = containsEstimatedIOSData
    }
}

public struct PeriodUsagePoint: Equatable, Sendable, Identifiable {
    public var id: String { "\(periodKind)|\(periodLabel)|\(deviceID)" }
    public var periodKind: String
    public var periodLabel: String
    public var periodStart: String
    public var periodEnd: String
    public var deviceID: String
    public var displayName: String
    public var averageDailyMinutes: Double
    public var includedDays: Int
    public var excludedDays: Int
    public var estimated: Bool
}

public struct STGSettings: Codable, Equatable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var deviceKind: DeviceKind
    public var dailyPlanMinutes = 600
    public var reportTimeZone = TimeZone.current.identifier
    public var eyeCloseCountdownMinutes = 1
    public var postureCloseCountdownMinutes = 2
    public var dailyCloseCountdownMinutes = 3
    public var launchAtLogin = true
    public var meetingMode = false
    public var cloudFolderPath: String?
    /// Device-local sync selection. It is intentionally omitted from SettingDocument.
    public var syncProvider: SyncProvider?
    public var updatedAt = Date()

    public init(deviceID: String, deviceName: String, deviceKind: DeviceKind) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.deviceKind = deviceKind
    }
}

public struct BitmapDocument: Codable, Equatable, Sendable {
    public var deviceID: String
    public var utcDate: String
    public var bitmapBase64: String
    public var updatedAt: Date
    public var reserved: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", utcDate = "utc_date", bitmapBase64 = "bitmap_base64"
        case updatedAt = "updated_at", reserved
    }

    public init(deviceID: String, utcDate: String, bitmap: MinuteBitmap, updatedAt: Date = .now) {
        self.deviceID = deviceID; self.utcDate = utcDate
        bitmapBase64 = bitmap.data.base64EncodedString(); self.updatedAt = updatedAt
    }

    public func bitmap() throws -> MinuteBitmap {
        guard let decoded = Data(base64Encoded: bitmapBase64) else { throw STGError.invalidDocument("invalid base64") }
        return try MinuteBitmap(data: decoded)
    }
}

public struct BitmapArchiveDocument: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var kind: String
    public var deviceID: String
    public var periodStart: String
    public var periodEnd: String
    public var rows: [BitmapDocument]
    public var createdAt: Date
    public var reserved: [String: String] = [:]

    public init(kind: String, deviceID: String, periodStart: String, periodEnd: String, rows: [BitmapDocument], createdAt: Date = .now) {
        self.kind = kind; self.deviceID = deviceID; self.periodStart = periodStart; self.periodEnd = periodEnd; self.rows = rows; self.createdAt = createdAt
    }
}

public struct OpenRouterArchiveDocument: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var periodStart: String
    public var periodEnd: String
    public var rows: [OpenRouterWeeklyRankingRow]
    public var createdAt: Date
}

public struct QuickSyncResult: Equatable, Sendable {
    public var uploaded: Int
    public var downloaded: Int
    public var failed: Int
    public var discoveredDeviceIDs: Set<String>

    public init(uploaded: Int = 0, downloaded: Int = 0, failed: Int = 0, discoveredDeviceIDs: Set<String> = []) {
        self.uploaded = uploaded
        self.downloaded = downloaded
        self.failed = failed
        self.discoveredDeviceIDs = discoveredDeviceIDs
    }
}

public struct QuickSyncState: Equatable, Sendable {
    public var lastUploadAt: Date
    public var lastBidirectionalAt: Date
    public var pendingUTCDateKeys: Set<String>

    public init(lastUploadAt: Date = .distantPast, lastBidirectionalAt: Date = .distantPast, pendingUTCDateKeys: Set<String> = []) {
        self.lastUploadAt = lastUploadAt
        self.lastBidirectionalAt = lastBidirectionalAt
        self.pendingUTCDateKeys = pendingUTCDateKeys
    }
}

public struct SettingDocument: Codable, Equatable, Sendable {
    public var deviceID: String; public var deviceName: String; public var deviceKind: DeviceKind
    public var dailyPlanMinutes: Int; public var reportTimeZone: String
    public var eyeCloseCountdownMinutes: Int; public var postureCloseCountdownMinutes: Int; public var dailyCloseCountdownMinutes: Int
    public var launchAtLogin: Bool; public var meetingMode: Bool; public var updatedAt: Date; public var reserved: [String: String] = [:]
    enum CodingKeys: String, CodingKey { case deviceID = "device_id", deviceName = "device_name", deviceKind = "device_kind", dailyPlanMinutes = "daily_plan_minutes", reportTimeZone = "report_time_zone", eyeCloseCountdownMinutes = "eye_close_countdown_minutes", postureCloseCountdownMinutes = "posture_close_countdown_minutes", dailyCloseCountdownMinutes = "daily_close_countdown_minutes", launchAtLogin = "launch_at_login", meetingMode = "meeting_mode", updatedAt = "updated_at", reserved }
    public init(_ settings: STGSettings) { deviceID = settings.deviceID; deviceName = settings.deviceName; deviceKind = settings.deviceKind; dailyPlanMinutes = settings.dailyPlanMinutes; reportTimeZone = settings.reportTimeZone; eyeCloseCountdownMinutes = settings.eyeCloseCountdownMinutes; postureCloseCountdownMinutes = settings.postureCloseCountdownMinutes; dailyCloseCountdownMinutes = settings.dailyCloseCountdownMinutes; launchAtLogin = settings.launchAtLogin; meetingMode = settings.meetingMode; updatedAt = settings.updatedAt }

    public var deviceRecord: DeviceRecord {
        DeviceRecord(deviceID: deviceID, name: deviceName, kind: deviceKind, updatedAt: updatedAt)
    }
}

public enum ReminderKind: String, Codable, Sendable { case eye, posture, dailyLimit }

public struct ReminderDecision: Equatable, Sendable {
    public var kind: ReminderKind
    public var usedMinutes: Int
    public var closeCountdownMinutes: Int
    public var silent: Bool
}
