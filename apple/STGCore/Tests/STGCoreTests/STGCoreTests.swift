import XCTest
@testable import STGCore

final class STGCoreTests: XCTestCase {
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

        let result = try applyIOSScreenTimeThreshold(repository: repository, deviceID: "ios", threshold: 60, now: now, timeZoneID: "UTC")
        XCTAssertEqual(result.measuredLocalDayMinutes, 60)
        XCTAssertEqual(result.newlyMarkedMinutes, 60)
        XCTAssertFalse(result.skippedReminder)
        XCTAssertEqual(try repository.localDayMinutes(deviceID: "alldevices", instant: now, timeZoneID: "UTC"), 60)
    }

    func testIOSScreenTimeThresholdThreeMinuteToleranceContinuesReminder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let now = ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")!
        let result = try applyIOSScreenTimeThreshold(repository: repository, deviceID: "ios", threshold: 23, now: now, timeZoneID: "UTC")
        XCTAssertEqual(result.measuredLocalDayMinutes, 20)
        XCTAssertFalse(result.skippedReminder)
    }

    func testIOSScreenTimeThresholdWindowCrossesUTCMidnight() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let now = ISO8601DateFormatter().date(from: "2026-08-22T00:05:00Z")!
        let result = try applyIOSScreenTimeThreshold(repository: repository, deviceID: "ios", threshold: 6, now: now, timeZoneID: "UTC")
        XCTAssertEqual(result.changedUTCDateKeys, ["2026-08-21", "2026-08-22"])
        XCTAssertEqual(result.measuredLocalDayMinutes, 6)
        XCTAssertFalse(result.skippedReminder)
    }

    func testIOSScreenTimeThresholdBelowMeasuredExitsBeforeWriting() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"))
        let now = ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")!
        for offset in 0..<61 {
            XCTAssertTrue(try repository.mark(deviceID: "ios", instant: now.addingTimeInterval(TimeInterval(-(offset + 60) * 60))))
        }

        let result = try applyIOSScreenTimeThreshold(repository: repository, deviceID: "ios", threshold: 60, now: now, timeZoneID: "UTC")
        XCTAssertTrue(result.skippedReminder)
        XCTAssertEqual(result.newlyMarkedMinutes, 0)
        XCTAssertEqual(result.measuredLocalDayMinutes, 61)
        XCTAssertTrue(result.changedUTCDateKeys.isEmpty)
        XCTAssertEqual(try repository.localDayMinutes(deviceID: "ios", instant: now, timeZoneID: "UTC"), 61)
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

    func testOpenRouterWeeklyCursorAndModelFilter() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try BitmapRepository(url: folder.appendingPathComponent("stg.sqlite"), importsBundledOpenRouterSeed: false)
        try repository.upsertOpenRouterWeeks([
            OpenRouterWeeklyRankingRow(weekStart: "2026-01-05", weekEnd: "2026-01-11", rank: 1, modelPermaslug: "model/a", promptTokens: 100, completionTokens: 20, totalTokens: 120, promptPricePerToken: 0.1, completionPricePerToken: 0.2),
            OpenRouterWeeklyRankingRow(weekStart: "2026-01-05", weekEnd: "2026-01-11", rank: 2, modelPermaslug: "model/b", promptTokens: 80, completionTokens: 10, totalTokens: 90, promptPricePerToken: nil, completionPricePerToken: nil)
        ])
        XCTAssertEqual(try repository.latestOpenRouterWeekEnd(), "2026-01-11")
        let rows = try repository.openRouterWeeks(models: ["model/b"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.modelPermaslug, "model/b")
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
