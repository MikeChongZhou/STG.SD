import XCTest
import SQLite3
@testable import STGCore

final class STGCoreTests: XCTestCase {
    func testPeriodAveragesUseActualDeviceMinutesAndExcludeToday() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"), importsBundledOpenRouterSeed: false, installsBundledDatabaseTemplate: false)
        for (date, minutes) in [("2026-10-01", 120), ("2026-10-02", 60), ("2026-10-03", 800)] {
            var bitmap = MinuteBitmap()
            for minute in 0..<minutes { bitmap[minute] = true }
            try repository.upsert(deviceID: "iphone", utcDate: date, bitmap: bitmap)
        }
        let now = ISO8601DateFormatter().date(from: "2026-10-03T20:00:00Z")!
        _ = try repository.refreshStatistics(localDeviceID: "iphone", localDeviceName: "iPhone", localDeviceKind: .ios, dailyLimitMinutes: 600, timeZoneID: "UTC", now: now)
        let rows = try repository.periodUsage(kind: "month", from: "2026-10-01", through: "2026-10-31")
        let phone = try XCTUnwrap(rows.first { $0.deviceID == "iphone" })
        XCTAssertEqual(phone.averageDailyMinutes, 90)
        XCTAssertEqual(phone.includedDays, 2)
        XCTAssertEqual(phone.excludedDays, 0)
        let aggregate = try XCTUnwrap(rows.first { $0.deviceID == "alldevices" })
        XCTAssertEqual(aggregate.includedDays, 0)
        XCTAssertEqual(aggregate.excludedDays, 2)
        XCTAssertNil(try repository.statisticsSummary(reference: now, timeZoneID: "UTC").thisMonthAverageMinutes)
    }

    func testLegacyPeriodCacheRecomputedFromRetainedDailyRecords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("stg.sqlite")
        let repository = try BitmapRepository(url: url, importsBundledOpenRouterSeed: false, installsBundledDatabaseTemplate: false)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let fixture = """
        INSERT INTO device VALUES('iphone','iPhone','ios',0);
        INSERT INTO daily_statistics VALUES('iphone','2026-09-01',120,600,0,0,1),('iphone','2026-09-02',0,600,0,0,1),('iphone','2026-09-03',360,600,0,0,1);
        INSERT INTO weekly_statistics VALUES('iphone',2026,36,'2026-08-31','2026-09-06',0,0,3,0,1);
        INSERT INTO monthly_statistics VALUES('iphone',2026,9,'2026-09-01','2026-09-30',0,0,3,0,1);
        INSERT INTO yearly_statistics VALUES('iphone',2026,'2026-01-01','2026-12-31',0,0,3,0,1);
        """
        XCTAssertEqual(sqlite3_exec(db, fixture, nil, nil, nil), SQLITE_OK)
        let now = ISO8601DateFormatter().date(from: "2026-10-03T20:00:00Z")!
        _ = try repository.refreshStatistics(localDeviceID: "iphone", localDeviceName: "iPhone", localDeviceKind: .ios, dailyLimitMinutes: 600, timeZoneID: "UTC", now: now)
        for kind in ["week", "month"] {
            let rows = try repository.periodUsage(kind: kind, from: "2026-09-01", through: "2026-09-03")
            let phone = try XCTUnwrap(rows.first { $0.deviceID == "iphone" })
            XCTAssertEqual(phone.averageDailyMinutes, 160)
            XCTAssertEqual(phone.includedDays, 3)
            XCTAssertEqual(phone.excludedDays, 0)
        }
        XCTAssertEqual(try repository.statisticsSummary(reference: now, timeZoneID: "UTC", deviceID: "iphone").thisYearAverageMinutes, 160)
    }

    func testMobileNotificationOptionsAndLegacySettings() throws {
        var settings = STGSettings(deviceID: "test", deviceName: "Phone", deviceKind: .ios)
        let legacy = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(STGSettings.self, from: legacy)
        XCTAssertTrue(decoded.eyeNotificationsEnabled)
        XCTAssertTrue(decoded.postureNotificationsEnabled)
        XCTAssertTrue(decoded.dailyNotificationsEnabled)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        document["breakNotifications"] = false
        let migrated = try JSONDecoder().decode(STGSettings.self, from: JSONSerialization.data(withJSONObject: document))
        XCTAssertFalse(migrated.eyeNotificationsEnabled)
        XCTAssertFalse(migrated.postureNotificationsEnabled)
        var updated = migrated
        updated.eyeNotificationsEnabled = true
        let saved = try JSONDecoder().decode(STGSettings.self, from: JSONEncoder().encode(updated))
        XCTAssertTrue(saved.eyeNotificationsEnabled)
        XCTAssertFalse(saved.postureNotificationsEnabled)
        for eye in [false, true] {
            for posture in [false, true] {
                for daily in [false, true] {
                    settings.eyeNotificationsEnabled = eye
                    settings.postureNotificationsEnabled = posture
                    settings.dailyNotificationsEnabled = daily
                    let restored = try JSONDecoder().decode(STGSettings.self, from: JSONEncoder().encode(settings))
                    XCTAssertEqual(restored.eyeNotificationsEnabled, eye)
                    XCTAssertEqual(restored.postureNotificationsEnabled, posture)
                    XCTAssertEqual(restored.dailyNotificationsEnabled, daily)
                    for kind in [ReminderKind.eye, .posture] {
                        let enabled = kind == .eye ? eye : posture
                        XCTAssertEqual(restored.mobileReminderKind(dailyMinutes: 20, breakKind: kind), enabled ? kind : nil)
                        XCTAssertEqual(restored.mobileReminderKind(dailyMinutes: 601, breakKind: kind), daily ? .dailyLimit : (enabled ? kind : nil))
                    }
                }
            }
        }
    }

    func testDesktopNotificationOptionsKeepAlternatingWhenDisabled() {
        let engine = ReminderEngine()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for eye in [false, true] {
            for posture in [false, true] {
                for daily in [false, true] {
                    for overLimit in [false, true] {
                        var settings = STGSettings(deviceID: "test", deviceName: "Mac", deviceKind: .macos)
                        settings.eyeNotificationsEnabled = eye
                        settings.postureNotificationsEnabled = posture
                        settings.dailyNotificationsEnabled = daily
                        var state = ReminderState(lastReminder: .posture)
                        var kinds: [ReminderKind] = []
                        for minute in 1...80 {
                            let result = engine.evaluate(active: true, now: start.addingTimeInterval(Double(minute * 60)), localMinuteIsSet: true, allDeviceDailyMinutes: overLimit ? 601 : 80, settings: settings, state: &state)
                            if let result { kinds.append(result.kind) }
                        }
                        let expected: [ReminderKind] = daily && overLimit ? [.dailyLimit, .dailyLimit, .dailyLimit, .dailyLimit] : [eye ? .eye : nil, posture ? .posture : nil, eye ? .eye : nil, posture ? .posture : nil].compactMap { $0 }
                        XCTAssertEqual(kinds, expected)
                    }
                }
            }
        }
    }

    func testBitmapVector() throws {
        var bitmap = MinuteBitmap()
        [0, 1, 7, 8, 719, 1439].forEach { bitmap[$0] = true }
        XCTAssertEqual(bitmap.count, 6)
        XCTAssertEqual(bitmap.data[0], 0x83)
        XCTAssertEqual(bitmap.data[1], 0x01)
        XCTAssertEqual(bitmap.data[179], 0x80)
        XCTAssertEqual(try MinuteBitmap(data: bitmap.data), bitmap)
    }

    func testUTCMapping() {
        let instant = ISO8601DateFormatter().date(from: "2026-04-25T23:59:59Z")!
        XCTAssertEqual(STGTime.utcDateKey(for: instant), "2026-04-25")
        XCTAssertEqual(STGTime.utcMinute(for: instant), 1439)
    }

    func testOneDriveAuthorizationRequestUsesPKCEAndAppCallback() async throws {
        let client = OneDriveClient(clientID: "test-client")
        let request = try await client.authorizationRequest(callbackScheme: "msauth.com.timbertrail.screentimeguardian.ios")
        let components = try XCTUnwrap(URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.host, "login.microsoftonline.com")
        XCTAssertEqual(values["client_id"], "test-client")
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertFalse(values["code_challenge", default: ""].isEmpty)
        XCTAssertEqual(values["state"], request.state)
        XCTAssertEqual(request.redirectURI, "msauth.com.timbertrail.screentimeguardian.ios://auth")
        XCTAssertTrue(values["scope", default: ""].contains("Files.ReadWrite.AppFolder"))
    }

    func testOneDriveAuthorizationRejectsMismatchedStateBeforeTokenExchange() async throws {
        let client = OneDriveClient(clientID: "test-client")
        let request = try await client.authorizationRequest(callbackScheme: "msauth.com.timbertrail.screentimeguardian.ios")
        let callback = try XCTUnwrap(URL(string: "msauth.com.timbertrail.screentimeguardian.ios://auth?code=test-code&state=wrong-state"))

        do {
            _ = try await client.credential(callbackURL: callback, request: request)
            XCTFail("A mismatched OAuth state must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("state did not match"))
        }
    }

    func testDSTLocalDayLength() {
        var components = DateComponents(); components.year = 2026; components.month = 3; components.day = 8; components.hour = 12
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        let day = STGTime.localDayInterval(containing: calendar.date(from: components)!, timeZoneID: "America/Detroit")
        XCTAssertEqual(day.duration, 23 * 3_600)
    }

    func testLocalBitmapUsesWallClockPositions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let formatter = ISO8601DateFormatter()
        let start = formatter.date(from: "2026-08-22T20:51:00Z")! // 16:51 America/Detroit
        for offset in 0...45 { _ = try repository.mark(deviceID: "local", instant: start.addingTimeInterval(Double(offset * 60))) }
        let bitmap = try repository.localClockDayBitmap(deviceID: "local", instant: start, timeZoneID: "America/Detroit")
        XCTAssertEqual(bitmap.count, 1_440)
        XCTAssertTrue(bitmap[16 * 60 + 51])
        XCTAssertTrue(bitmap[17 * 60 + 36])
        XCTAssertFalse(bitmap[18 * 60])
    }

    func testDSTReportStillHas1440ClockPositions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let instant = ISO8601DateFormatter().date(from: "2026-03-08T16:00:00Z")!
        XCTAssertEqual(try repository.localDayBitmap(deviceID: "local", instant: instant, timeZoneID: "America/Detroit").count, 1_380)
        XCTAssertEqual(try repository.localClockDayBitmap(deviceID: "local", instant: instant, timeZoneID: "America/Detroit").count, 1_440)
    }

    func testRepositoryPersistsAndAggregates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let instant = ISO8601DateFormatter().date(from: "2026-04-25T23:59:59Z")!
        XCTAssertTrue(try repository.mark(deviceID: "a", instant: instant))
        XCTAssertFalse(try repository.mark(deviceID: "a", instant: instant))
        XCTAssertTrue(try repository.mark(deviceID: "b", instant: instant.addingTimeInterval(-60)))
        let aggregate = try repository.rebuildAllDevices(utcDate: "2026-04-25")
        XCTAssertEqual(aggregate.count, 2)
    }

    func testRepositoryPersistsDeviceNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let older = ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z")!
        let newer = ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z")!
        try repository.upsertDevice(DeviceRecord(deviceID: "remote", name: "Old name", kind: .ios, updatedAt: older))
        try repository.upsertDevice(DeviceRecord(deviceID: "remote", name: "Mike's iPhone", kind: .ios, updatedAt: newer))
        try repository.upsertDevice(DeviceRecord(deviceID: "remote", name: "Stale name", kind: .ios, updatedAt: older))
        XCTAssertEqual(try repository.deviceRecords(), [DeviceRecord(deviceID: "remote", name: "Mike's iPhone", kind: .ios, updatedAt: newer)])
    }

    func testIncrementalDownloadCursorIsPerDeviceAndNeverMovesBackward() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))

        XCTAssertNil(try repository.incrementalDownloadCursor(remoteDeviceID: "iphone"))
        try repository.saveIncrementalDownloadCursor(remoteDeviceID: "iphone", latestUTCDate: "2026-08-24")
        try repository.saveIncrementalDownloadCursor(remoteDeviceID: "iphone", latestUTCDate: "2026-08-22")
        try repository.saveIncrementalDownloadCursor(remoteDeviceID: "mac", latestUTCDate: "2026-08-20")
        XCTAssertEqual(try repository.incrementalDownloadCursor(remoteDeviceID: "iphone"), "2026-08-24")

        try repository.saveIncrementalDownloadCursor(remoteDeviceID: "iphone", latestUTCDate: "2026-08-25")
        XCTAssertEqual(try repository.incrementalDownloadCursors(), ["iphone": "2026-08-25", "mac": "2026-08-20"])
    }

    func testIncrementalUploadCursorIsInclusiveAndPerProvider() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let now = ISO8601DateFormatter().date(from: "2026-08-25T12:00:00Z")!

        XCTAssertEqual(try STGTime.incrementalUploadUTCDateKeys(cursor: nil, now: now, initialDays: 3), ["2026-08-23", "2026-08-24", "2026-08-25"])
        try repository.saveIncrementalUploadCursor(syncTarget: "oneDrive", latestUTCDate: "2026-08-24")
        try repository.saveIncrementalUploadCursor(syncTarget: "oneDrive", latestUTCDate: "2026-08-22")
        try repository.saveIncrementalUploadCursor(syncTarget: "googleDrive", latestUTCDate: "2026-08-20")
        XCTAssertEqual(try repository.incrementalUploadCursor(syncTarget: "oneDrive"), "2026-08-24")
        XCTAssertEqual(try repository.incrementalUploadCursor(syncTarget: "googleDrive"), "2026-08-20")
        XCTAssertEqual(try STGTime.incrementalUploadUTCDateKeys(cursor: repository.incrementalUploadCursor(syncTarget: "oneDrive"), now: now), ["2026-08-24", "2026-08-25"])
        XCTAssertEqual(try STGTime.incrementalUploadUTCDateKeys(cursor: "2026-08-25", now: now), ["2026-08-25"])
    }

    func testMultiDayReportContainsEachDeviceAndDeduplicatedAggregate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let formatter = ISO8601DateFormatter()
        let first = formatter.date(from: "2026-08-24T12:00:00Z")!
        let second = formatter.date(from: "2026-08-25T12:00:00Z")!
        try repository.upsertDevice(DeviceRecord(deviceID: "remote", name: "Mike's iPhone", kind: .ios))
        XCTAssertTrue(try repository.mark(deviceID: "local", instant: first))
        XCTAssertTrue(try repository.mark(deviceID: "remote", instant: first)) // same minute: aggregate remains one minute
        XCTAssertTrue(try repository.mark(deviceID: "local", instant: second))
        XCTAssertTrue(try repository.mark(deviceID: "remote", instant: second.addingTimeInterval(60)))

        let points = try repository.multiDayReport(localDeviceID: "local", localDeviceName: "Mike's Mac", localDeviceKind: .macos, start: first, end: second, timeZoneID: "UTC", includeSyncedDevices: true)
        XCTAssertEqual(Set(points.map(\.dateLabel)), ["2026-08-24", "2026-08-25"])
        XCTAssertEqual(points.filter { $0.dateLabel == "2026-08-24" && $0.isAggregate }.first?.minutes, 1)
        XCTAssertEqual(points.filter { $0.dateLabel == "2026-08-25" && $0.isAggregate }.first?.minutes, 2)
        XCTAssertEqual(points.filter { $0.deviceID == "remote" }.map(\.displayName), ["Mike's iPhone", "Mike's iPhone"])
    }

    func testIOSScreenTimeThresholdStep323() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let now = ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")!

        let result = try applyIOSScreenTimeThreshold(repository: repository, deviceID: "ios", now: now, timeZoneID: "UTC")
        XCTAssertEqual(result.measuredLocalDayMinutes, 20)
        XCTAssertEqual(result.newlyMarkedMinutes, 20)
        XCTAssertFalse(result.skippedReminder)
        XCTAssertEqual(try repository.localDayMinutes(deviceID: "alldevices", instant: now, timeZoneID: "UTC"), 20)
    }

    func testIOSScreenTimeThresholdRespectsCallbackElapsedMinuteBudget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let now = ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")!

        let result = try applyIOSScreenTimeThreshold(
            repository: repository,
            deviceID: "ios",
            now: now,
            timeZoneID: "UTC",
            maximumNewMinutes: 5
        )
        XCTAssertEqual(result.measuredLocalDayMinutes, 5)
        XCTAssertEqual(result.newlyMarkedMinutes, 5)
        XCTAssertFalse(result.skippedReminder)
    }

    func testIOSScreenTimeThresholdRejectsSameMinuteCallback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let now = ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")!

        let result = try applyIOSScreenTimeThreshold(
            repository: repository,
            deviceID: "ios",
            now: now,
            timeZoneID: "UTC",
            maximumNewMinutes: 0
        )
        XCTAssertTrue(result.skippedReminder)
        XCTAssertEqual(result.measuredLocalDayMinutes, 0)
        XCTAssertEqual(result.newlyMarkedMinutes, 0)
        XCTAssertTrue(result.changedUTCDateKeys.isEmpty)
    }

    func testIOSScreenTimeThresholdUsesDefaultTwentyMinuteBudget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let now = ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")!
        let result = try applyIOSScreenTimeThreshold(repository: repository, deviceID: "ios", now: now, timeZoneID: "UTC")
        XCTAssertEqual(result.measuredLocalDayMinutes, 20)
        XCTAssertFalse(result.skippedReminder)
    }

    func testIOSScreenTimeThresholdWindowCrossesUTCMidnight() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let now = ISO8601DateFormatter().date(from: "2026-08-22T00:05:00Z")!
        let result = try applyIOSScreenTimeThreshold(repository: repository, deviceID: "ios", now: now, timeZoneID: "UTC")
        XCTAssertEqual(result.changedUTCDateKeys, ["2026-08-21", "2026-08-22"])
        XCTAssertEqual(result.measuredLocalDayMinutes, 6)
        XCTAssertFalse(result.skippedReminder)
    }

    func testIOSScreenTimeThresholdDoesNotCompareRegistrationTotalWithDailyBitmap() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let now = ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")!
        for offset in 0..<61 {
            XCTAssertTrue(try repository.mark(deviceID: "ios", instant: now.addingTimeInterval(TimeInterval(-(offset + 60) * 60))))
        }

        let result = try applyIOSScreenTimeThreshold(repository: repository, deviceID: "ios", now: now, timeZoneID: "UTC")
        XCTAssertFalse(result.skippedReminder)
        XCTAssertEqual(result.newlyMarkedMinutes, 20)
        XCTAssertEqual(result.measuredLocalDayMinutes, 81)
        XCTAssertEqual(result.changedUTCDateKeys, ["2026-08-22"])
        XCTAssertEqual(try repository.localDayMinutes(deviceID: "ios", instant: now, timeZoneID: "UTC"), 81)
    }

    func testRepositoryCanResetEstimateAndImportedDevices() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let instant = ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")!
        XCTAssertTrue(try repository.mark(deviceID: "local", instant: instant))
        XCTAssertTrue(try repository.mark(deviceID: "remote", instant: instant))
        XCTAssertEqual(try repository.clearLocalDay(deviceID: "local", instant: instant, timeZoneID: "UTC"), 1)
        XCTAssertEqual(try repository.localDayMinutes(deviceID: "local", instant: instant, timeZoneID: "UTC"), 0)
        XCTAssertEqual(try repository.deleteOtherDeviceData(localDeviceID: "local"), 1)
        XCTAssertFalse(try repository.deviceIDs().contains("remote"))
    }

    func testOpenRouterPublicActivityAggregation() throws {
        let payload = #"{"data":{"analytics":[{"date":"2026-08-09 00:00:00","total_prompt_tokens":"999","total_completion_tokens":1},{"date":"2026-08-10 00:00:00","total_prompt_tokens":"30","total_completion_tokens":2},{"date":"2026-08-16 00:00:00","total_prompt_tokens":20,"total_completion_tokens":3},{"date":"2026-08-17 00:00:00","total_prompt_tokens":999,"total_completion_tokens":1}],"cachedAt":1}}"#.data(using: .utf8)!
        let totals = try OpenRouterTrackingService.total(payload, start: "2026-08-10", end: "2026-08-16")
        XCTAssertEqual(totals.prompt, 50)
        XCTAssertEqual(totals.completion, 5)
        XCTAssertEqual(totals.total, 55)
    }

    func testOpenRouterCompletedUTCWeekWindow() throws {
        let now = ISO8601DateFormatter().date(from: "2026-08-22T16:00:00Z")!
        let window = try OpenRouterTrackingService.dateWindow(period: .week, now: now)
        XCTAssertEqual(window.start, "2026-08-10")
        XCTAssertEqual(window.end, "2026-08-16")
    }

    func testWeeklyArchiveKeepsTheTwoMostRecentCompletedWeeks() {
        XCTAssertEqual(CloudFolderSync.weekEnd(from: "device_week_2026-08-17_2026-08-23.json"), "2026-08-23")
        XCTAssertEqual(CloudFolderSync.weekEnd(from: "device_week_2026-08-17.json"), "2026-08-23")
        XCTAssertEqual(CloudFolderSync.weekArchiveCutoff(previousWeekStart: "2026-08-24"), "2026-08-17")
    }

    func testWeeklyMaintenanceBackfillsMissingWeeksBeforeDeletingDailyFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = folder.appendingPathComponent("cloud", isDirectory: true)
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"), importsBundledOpenRouterSeed: false, installsBundledDatabaseTemplate: false)
        let dates = ["2026-08-25", "2026-09-01", "2026-09-08"]
        for date in dates {
            let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "\(date)T12:00:00Z"))
            XCTAssertTrue(try repository.mark(deviceID: "local", instant: instant))
        }
        let seeded = try await CloudFolderSync(repository: repository, deviceID: "local").quickUpload(folder: cloud, utcDates: Set(dates))
        XCTAssertEqual(seeded, 3)

        let result = try await CloudFolderSync(repository: repository, deviceID: "local").weeklyMaintenance(
            folder: cloud, currentWeekStart: "2026-09-14", previousWeekStart: "2026-09-07", previousWeekEnd: "2026-09-13"
        )

        XCTAssertEqual(result.uploaded, 3)
        XCTAssertEqual(result.deletedDaily, 3)
        XCTAssertEqual(result.movedWeekly, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("history/local_week_2026-08-24_2026-08-30.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("sync/local_week_2026-08-31_2026-09-06.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("sync/local_week_2026-09-07_2026-09-13.json").path))
        for date in dates { XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("sync/local_bitmap_\(date).json").path)) }
    }

    func testOpenRouterPreviousUTCMonthWindow() throws {
        let now = ISO8601DateFormatter().date(from: "2026-08-22T16:00:00Z")!
        let window = try OpenRouterTrackingService.dateWindow(period: .month, now: now)
        XCTAssertEqual(window.start, "2026-07-01")
        XCTAssertEqual(window.end, "2026-07-31")
    }

    func testTrackingSortAndCSV() {
        let rows = [
            OpenRouterRankingRow(rank: 1, modelPermaslug: "model/a", promptTokens: 10, completionTokens: 5, totalTokens: 15, promptPricePerToken: 0.1, completionPricePerToken: 0.2),
            OpenRouterRankingRow(rank: 2, modelPermaslug: "model,b", promptTokens: 20, completionTokens: 1, totalTokens: 21, promptPricePerToken: nil, completionPricePerToken: nil),
            OpenRouterRankingRow(rank: 3, modelPermaslug: "model/c", promptTokens: 20, completionTokens: 9, totalTokens: 29, promptPricePerToken: 0.05, completionPricePerToken: 0.3)
        ]
        XCTAssertEqual(sortedOpenRouterRows(rows, by: .promptTokens, direction: .descending).map(\.rank), [2, 3, 1])
        XCTAssertEqual(sortedOpenRouterRows(rows, by: .promptTokens, direction: .ascending).map(\.rank), [1, 2, 3])
        XCTAssertEqual(sortedOpenRouterRows(rows, by: .promptPrice, direction: .descending).map(\.rank), [1, 3, 2])
        XCTAssertEqual(sortedOpenRouterRows(rows, by: .promptPrice, direction: .ascending).map(\.rank), [3, 1, 2])
        XCTAssertEqual(formattedWholeDollarUSD(1_234_567.89), "$1,234,568")
        let csv = openRouterTrackingCSV(rows: rows, period: "week", startDate: "2026-08-10", endDate: "2026-08-16")
        XCTAssertTrue(csv.contains("\"model,b\""))
        XCTAssertTrue(csv.contains("input_tokens"))
    }

    func testDesktopReminderAlternatesOnlyAtTwentyMinuteBoundaries() {
        let engine = ReminderEngine()
        var settings = STGSettings(deviceID: "mac", deviceName: "Mac", deviceKind: .macos)
        settings.dailyPlanMinutes = 600
        let start = ISO8601DateFormatter().date(from: "2026-08-23T12:00:00Z")!
        var state = ReminderState(
            continuousMinutes: 19,
            lastEyeAt: start.addingTimeInterval(-17 * 60),
            lastPostureAt: start.addingTimeInterval(-37 * 60)
        )

        let eye = engine.evaluate(active: true, now: start, localMinuteIsSet: true, allDeviceDailyMinutes: 100, settings: settings, state: &state)
        XCTAssertEqual(eye?.kind, .eye)
        XCTAssertEqual(state.lastReminder, .eye)
        XCTAssertEqual(state.continuousMinutes, 0)

        for minute in 1..<20 {
            let decision = engine.evaluate(active: true, now: start.addingTimeInterval(TimeInterval(minute * 60)), localMinuteIsSet: true, allDeviceDailyMinutes: 100 + minute, settings: settings, state: &state)
            XCTAssertNil(decision, "No second reminder is allowed before another complete 20-minute block")
        }
        let posture = engine.evaluate(active: true, now: start.addingTimeInterval(20 * 60), localMinuteIsSet: true, allDeviceDailyMinutes: 120, settings: settings, state: &state)
        XCTAssertEqual(posture?.kind, .posture)
        XCTAssertEqual(state.lastReminder, .posture)
        XCTAssertEqual(state.continuousMinutes, 0)
    }

    func testDesktopDailyLimitReminderUsesAlternatingSlotAndStrictlyExceedsPlan() {
        let engine = ReminderEngine()
        var settings = STGSettings(deviceID: "mac", deviceName: "Mac", deviceKind: .macos)
        settings.dailyPlanMinutes = 600
        let now = ISO8601DateFormatter().date(from: "2026-08-23T12:00:00Z")!

        var atPlan = ReminderState(continuousMinutes: 19)
        XCTAssertEqual(engine.evaluate(active: true, now: now, localMinuteIsSet: true, allDeviceDailyMinutes: 600, settings: settings, state: &atPlan)?.kind, .eye)

        var overPlan = ReminderState(continuousMinutes: 19)
        XCTAssertEqual(engine.evaluate(active: true, now: now, localMinuteIsSet: true, allDeviceDailyMinutes: 601, settings: settings, state: &overPlan)?.kind, .dailyLimit)
        XCTAssertEqual(overPlan.lastReminder, .eye)
        overPlan.continuousMinutes = 19
        XCTAssertEqual(engine.evaluate(active: true, now: now.addingTimeInterval(20 * 60), localMinuteIsSet: true, allDeviceDailyMinutes: 620, settings: settings, state: &overPlan)?.kind, .dailyLimit)
        XCTAssertEqual(overPlan.lastReminder, .posture)
    }

    func testRepositoryPersistsDesktopReminderState() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let eye = ISO8601DateFormatter().date(from: "2026-08-23T12:00:00Z")!
        let posture = eye.addingTimeInterval(20 * 60)
        let state = ReminderState(lastEyeAt: eye, lastPostureAt: posture, lastReminder: .posture)

        try repository.saveReminderState(deviceID: "mac", state: state, updatedAt: posture)
        XCTAssertEqual(try repository.reminderState(deviceID: "mac"), state)
        XCTAssertEqual(try repository.reminderState(deviceID: "other"), ReminderState())
    }

    func testQuickSyncStatePersistsPendingDatesAndCompletionTimes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let queuedAt = ISO8601DateFormatter().date(from: "2026-08-25T01:00:00Z")!
        let completedAt = queuedAt.addingTimeInterval(60)

        try repository.queueQuickUpload(deviceID: "ios", utcDateKeys: ["2026-08-24", "2026-08-25"], at: queuedAt)
        XCTAssertEqual(try repository.quickSyncState(deviceID: "ios").pendingUTCDateKeys, ["2026-08-24", "2026-08-25"])

        try repository.completeQuickBidirectional(deviceID: "ios", at: completedAt)
        try repository.completeQuickUpload(deviceID: "ios", utcDateKeys: ["2026-08-25"], at: completedAt)
        let state = try repository.quickSyncState(deviceID: "ios")
        XCTAssertEqual(state.lastBidirectionalAt, completedAt)
        XCTAssertEqual(state.lastUploadAt, completedAt)
        XCTAssertEqual(state.pendingUTCDateKeys, ["2026-08-24"])
    }

    func testCloudFolderQuickBidirectionalUsesOnlyRequestedUTCDates() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = folder.appendingPathComponent("cloud", isDirectory: true)
        let localRepository = try BitmapRepository(url: folder.appendingPathComponent("local.sqlite"))
        let remoteRepository = try BitmapRepository(url: folder.appendingPathComponent("remote.sqlite"))
        let current = ISO8601DateFormatter().date(from: "2026-08-25T12:34:00Z")!
        let previous = ISO8601DateFormatter().date(from: "2026-08-24T12:34:00Z")!
        XCTAssertTrue(try localRepository.mark(deviceID: "local", instant: current))
        XCTAssertTrue(try remoteRepository.mark(deviceID: "remote", instant: current))
        XCTAssertTrue(try remoteRepository.mark(deviceID: "remote", instant: previous))
        _ = try await CloudFolderSync(repository: remoteRepository, deviceID: "remote").quickUpload(folder: cloud, utcDates: ["2026-08-24", "2026-08-25"])

        let result = try await CloudFolderSync(repository: localRepository, deviceID: "local").quickBidirectional(
            folder: cloud,
            downloadUTCDateKeys: ["2026-08-25"],
            uploadUTCDateKeys: ["2026-08-25"]
        )

        XCTAssertEqual(result.uploaded, 1)
        XCTAssertEqual(result.downloaded, 1)
        XCTAssertEqual(result.discoveredDeviceIDs, ["remote"])
        XCTAssertTrue(try localRepository.bitmap(deviceID: "remote", utcDate: "2026-08-25")[754])
        XCTAssertEqual(try localRepository.bitmap(deviceID: "remote", utcDate: "2026-08-24").count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("sync/local_bitmap_2026-08-25.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("sync/local_bitmap_2026-08-24.json").path))
    }

    func testCloudFolderQuickBidirectionalMergesSameDeviceBeforeUpload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = folder.appendingPathComponent("cloud", isDirectory: true)
        let cloudSource = try BitmapRepository(url: folder.appendingPathComponent("cloud-source.sqlite"))
        let localRepository = try BitmapRepository(url: folder.appendingPathComponent("local.sqlite"))
        let cloudMinute = ISO8601DateFormatter().date(from: "2026-08-25T12:34:00Z")!
        let localMinute = cloudMinute.addingTimeInterval(120)
        XCTAssertTrue(try cloudSource.mark(deviceID: "same-device", instant: cloudMinute))
        let seeded = try await CloudFolderSync(repository: cloudSource, deviceID: "same-device").quickUpload(folder: cloud, utcDates: ["2026-08-25"])
        XCTAssertEqual(seeded, 1)
        XCTAssertTrue(try localRepository.mark(deviceID: "same-device", instant: localMinute))

        let result = try await CloudFolderSync(repository: localRepository, deviceID: "same-device").quickBidirectional(
            folder: cloud,
            downloadUTCDateKeys: ["2026-08-25"],
            uploadUTCDateKeys: ["2026-08-25"]
        )

        XCTAssertEqual(result.downloaded, 1)
        XCTAssertEqual(result.uploaded, 1)
        XCTAssertTrue(result.discoveredDeviceIDs.isEmpty)
        let merged = try localRepository.bitmap(deviceID: "same-device", utcDate: "2026-08-25")
        XCTAssertTrue(merged[754])
        XCTAssertTrue(merged[756])
        XCTAssertEqual(merged.count, 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cloudDocument = try decoder.decode(
            BitmapDocument.self,
            from: Data(contentsOf: cloud.appendingPathComponent("sync/same-device_bitmap_2026-08-25.json"))
        )
        XCTAssertEqual(try cloudDocument.bitmap().count, 2)
    }

    func testStoredDocumentRequiresARealRowAndPreservesUpdatedAt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let updatedAt = ISO8601DateFormatter().date(from: "2026-08-25T12:34:00Z")!

        XCTAssertNil(try repository.documentIfPresent(deviceID: "local", utcDate: "2026-08-25"))
        try repository.upsert(deviceID: "local", utcDate: "2026-08-25", bitmap: MinuteBitmap(), updatedAt: updatedAt)
        let document = try XCTUnwrap(repository.documentIfPresent(deviceID: "local", utcDate: "2026-08-25"))
        XCTAssertEqual(try document.bitmap().count, 0)
        XCTAssertEqual(document.updatedAt, updatedAt)
    }

    func testInitialCloudFolderSyncSkipsMissingLocalDates() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = folder.appendingPathComponent("cloud", isDirectory: true)
        let repository = try BitmapRepository(url: folder.appendingPathComponent("local.sqlite"))
        let now = ISO8601DateFormatter().date(from: "2026-08-25T12:34:00Z")!

        let result = try await CloudFolderSync(repository: repository, deviceID: "local").incrementalSync(folder: cloud, now: now, days: 3)

        XCTAssertEqual(result.uploaded, 0)
        XCTAssertNil(try repository.incrementalUploadCursor(syncTarget: "cloudFolder"))
        let sync = cloud.appendingPathComponent("sync", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: sync, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("_bitmap_") }.count, 0)
    }

    func testInitialCloudFolderSyncRestoresSameDeviceBeforeUpload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = folder.appendingPathComponent("cloud", isDirectory: true)
        let oldRepository = try BitmapRepository(url: folder.appendingPathComponent("old.sqlite"))
        let freshRepository = try BitmapRepository(url: folder.appendingPathComponent("fresh.sqlite"))
        let now = ISO8601DateFormatter().date(from: "2026-08-25T12:34:00Z")!
        let freshNow = now.addingTimeInterval(120)
        XCTAssertTrue(try oldRepository.mark(deviceID: "same-device", instant: now))
        let seeded = try await CloudFolderSync(repository: oldRepository, deviceID: "same-device").quickUpload(folder: cloud, utcDates: ["2026-08-25"])
        XCTAssertEqual(seeded, 1)
        XCTAssertTrue(try freshRepository.mark(deviceID: "same-device", instant: freshNow))

        let result = try await CloudFolderSync(repository: freshRepository, deviceID: "same-device").incrementalSync(folder: cloud, now: freshNow, days: 3)

        XCTAssertEqual(result.downloaded, 1)
        XCTAssertEqual(result.uploaded, 1)
        XCTAssertTrue(try freshRepository.bitmap(deviceID: "same-device", utcDate: "2026-08-25")[754])
        XCTAssertTrue(try freshRepository.bitmap(deviceID: "same-device", utcDate: "2026-08-25")[756])
        let restored = try XCTUnwrap(freshRepository.documentIfPresent(deviceID: "same-device", utcDate: "2026-08-25"))
        XCTAssertEqual(restored.updatedAt, freshNow)
        XCTAssertEqual(try restored.bitmap().count, 2)
    }

    func testOpenRouterWeeklyCursorAndModelFilter() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"), importsBundledOpenRouterSeed: false, installsBundledDatabaseTemplate: false)
        try repository.upsertOpenRouterWeeks([
            OpenRouterWeeklyRankingRow(weekStart: "2026-01-05", weekEnd: "2026-01-11", rank: 1, modelPermaslug: "model/a", promptTokens: 100, completionTokens: 20, totalTokens: 120, promptPricePerToken: 0.1, completionPricePerToken: 0.2),
            OpenRouterWeeklyRankingRow(weekStart: "2026-01-05", weekEnd: "2026-01-11", rank: 2, modelPermaslug: "model/b", promptTokens: 80, completionTokens: 10, totalTokens: 90, promptPricePerToken: nil, completionPricePerToken: nil)
        ])
        XCTAssertEqual(try repository.latestOpenRouterWeekEnd(), "2026-01-11")
        let rows = try repository.openRouterWeeks(models: ["model/b"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.modelPermaslug, "model/b")
    }

    func testOpenRouterLatestWeekTopModelsFollowSelectedMetric() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"), importsBundledOpenRouterSeed: false, installsBundledDatabaseTemplate: false)
        try repository.upsertOpenRouterWeeks([
            OpenRouterWeeklyRankingRow(weekStart: "2026-01-05", weekEnd: "2026-01-11", rank: 1, modelPermaslug: "old/leader", promptTokens: 9_000, completionTokens: 1_000, totalTokens: 10_000, promptPricePerToken: 0.1, completionPricePerToken: 0.1),
            OpenRouterWeeklyRankingRow(weekStart: "2026-01-12", weekEnd: "2026-01-18", rank: 1, modelPermaslug: "new/token-leader", promptTokens: 900, completionTokens: 100, totalTokens: 1_000, promptPricePerToken: 0.01, completionPricePerToken: 0.01),
            OpenRouterWeeklyRankingRow(weekStart: "2026-01-12", weekEnd: "2026-01-18", rank: 2, modelPermaslug: "new/revenue-leader", promptTokens: 100, completionTokens: 100, totalTokens: 200, promptPricePerToken: 10, completionPricePerToken: 10)
        ])
        XCTAssertEqual(try repository.latestOpenRouterTopModels(metric: .totalTokens, limit: 1), ["new/token-leader"])
        XCTAssertEqual(try repository.latestOpenRouterTopModels(metric: .revenue, limit: 1), ["new/revenue-leader"])
    }

    func testBundledOpenRouterSeedImportsCompletedHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        XCTAssertEqual(try repository.latestOpenRouterWeekEnd(), "2026-08-23")
        let models = try repository.latestOpenRouterTopModels(limit: 10)
        XCTAssertEqual(models.count, 10)
        let rows = try repository.openRouterWeeks(models: models)
        XCTAssertGreaterThan(rows.count, 10)
        XCTAssertTrue(rows.allSatisfy { $0.totalTokens > 0 })
        XCTAssertTrue(rows.allSatisfy { !$0.hasTokenBreakdown })
        XCTAssertTrue(rows.allSatisfy { $0.asOf != nil })
        XCTAssertTrue(rows.allSatisfy { $0.updatedAt.timeIntervalSince1970 > 0 })
        let incompleteRows = try repository.openRouterWeeks(models: ["google/gemini-2.0-flash-001"])
        XCTAssertTrue(incompleteRows.contains { !$0.isComplete && !$0.missingDates.isEmpty })
    }

    func testBundledOpenRouterSeedCanBeDeferredAndIsIdempotent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"), importsBundledOpenRouterSeed: false, installsBundledDatabaseTemplate: false)
        XCTAssertNil(try repository.latestOpenRouterWeekEnd())
        XCTAssertTrue(try repository.importBundledOpenRouterSeedIfNeeded())
        XCTAssertEqual(try repository.latestOpenRouterWeekEnd(), "2026-08-23")
        XCTAssertFalse(try repository.importBundledOpenRouterSeedIfNeeded())
    }

    func testWeeklyActionRunsOnlyInsideARequiredWeek() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let monday = ISO8601DateFormatter().date(from: "2026-08-24T12:00:00Z")!
        // A fresh seed has total tokens but no prompt/completion breakdown, so
        // the first weekly action must backfill the latest four weeks.
        XCTAssertTrue(try repository.weeklyActionDue(now: monday))
        try repository.completeOpenRouterDetailWeek(through: "2026-08-23")
        try repository.completeWeeklyAction(at: monday)
        XCTAssertEqual(try repository.latestOpenRouterDetailWeekEnd(), "2026-08-23")
        XCTAssertFalse(try repository.weeklyActionDue(now: monday))
        XCTAssertTrue(try repository.weeklyActionDue(now: monday.addingTimeInterval(7 * 86_400)))
        let nextMonday = monday.addingTimeInterval(7 * 86_400)
        try repository.upsertOpenRouterWeeks([OpenRouterWeeklyRankingRow(weekStart: "2026-08-17", weekEnd: "2026-08-23", rank: 1, modelPermaslug: "model/a", promptTokens: 1, completionTokens: 1, totalTokens: 2, promptPricePerToken: nil, completionPricePerToken: nil)])
        try repository.completeOpenRouterDetailWeek(through: "2026-08-30")
        try repository.completeWeeklyAction(at: nextMonday)
        XCTAssertFalse(try repository.weeklyActionDue(now: nextMonday))
    }
}
