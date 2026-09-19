package com.timbertrail.stg

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.time.Instant
import java.time.LocalDate
import java.util.zip.GZIPOutputStream

internal class RemoteCloudSync(private val database: BitmapDatabase, private val settings: AppSettings, private val drive: PrivateCloudDrive) {
    data class Result(val uploaded: Int, val downloaded: Int, val devices: Set<String>, val downloadCursors: Map<String, String>, val uploadCursor: String?, val warnings: List<String>)
    data class MaintenanceResult(val uploaded: Int, val deletedDaily: Int = 0, val movedWeekly: Int = 0, val deletedBitmaps: Int = 0, val deletedWeekly: Int = 0)

    fun incremental(progress: (String) -> Unit = {}): Result {
        progress("Preparing cloud folders…")
        drive.listFolder("history")
        progress("Scanning remote devices…")
        var files = drive.list()
        var byName = files.associateBy { it.name }
        val devices = files.mapNotNull { parseDevice(it.name) }.toSet()
        var uploaded = 0; var downloaded = 0
        val warnings = mutableListOf<String>()
        val cursors = linkedMapOf<String, String>()
        database.upsertDevice(AndroidDeviceRecord(settings.deviceID, settings.deviceName, "android", settings.updatedAt))
        val uploadTarget = settings.cloudProvider
        val existingUploadCursor = database.incrementalUploadCursor(uploadTarget)

        files.filter { it.name.endsWith("_setting.json") }.forEach { file ->
            runCatching {
                val remoteID = parseDevice(file.name) ?: return@runCatching
                if (remoteID == settings.deviceID) return@runCatching
                val json = JSONObject(drive.download(file.id).decodeToString())
                if (json.getString("device_id") != remoteID) return@runCatching
                database.upsertDevice(AndroidDeviceRecord(remoteID, json.optString("device_name", "Other device"), json.optString("device_kind", "android"), runCatching { Instant.parse(json.getString("updated_at")).epochSecond }.getOrDefault(Instant.now().epochSecond)))
            }.onFailure { warnings += "settings_import_failed; provider=${settings.cloudProvider}; file=${file.name}; ${it.diagnosticSummary()}" }
        }

        val downloadIDs = devices.filter { it != "alldevices" && (it != settings.deviceID || existingUploadCursor == null) }
        val candidatesByDevice = downloadIDs.associateWith { remoteID ->
            val cursor = if (remoteID == settings.deviceID) null else database.incrementalDownloadCursor(remoteID)
            files.mapNotNull { file ->
                val date = parseBitmapDate(file.name) ?: return@mapNotNull null
                if (parseDevice(file.name) == remoteID && (cursor == null || date >= cursor)) file to date else null
            }.sortedBy { it.second }
        }
        val totalDownloads = candidatesByDevice.values.sumOf { it.size }
        if (totalDownloads == 0) progress("Downloading device data — nothing new…")
        downloadIDs.forEach { remoteID ->
            val restoringThisDevice = remoteID == settings.deviceID
            val candidates = candidatesByDevice[remoteID].orEmpty()
            for ((file, expectedDate) in candidates) {
                progress("Downloading device data — ${downloaded + 1} of $totalDownloads…")
                val attempt = runCatching {
                    val json = JSONObject(drive.download(file.id).decodeToString())
                    if (json.getString("device_id") != remoteID || json.getString("utc_date") != expectedDate) error("Remote bitmap identity mismatch")
                    val updated = runCatching { Instant.parse(json.getString("updated_at")).epochSecond }.getOrDefault(Instant.now().epochSecond)
                    val bitmap = MinuteBitmap.fromBase64(json.getString("bitmap_base64"))
                    if (restoringThisDevice) database.mergeBitmap(remoteID, expectedDate, bitmap, updated) else database.upsertIfNewer(remoteID, expectedDate, bitmap, updated)
                    database.rebuildAll(expectedDate)
                    if (!restoringThisDevice) { database.saveIncrementalDownloadCursor(remoteID, expectedDate); cursors[remoteID] = expectedDate }
                    downloaded++
                }
                if (attempt.isFailure) { warnings += "bitmap_import_failed; provider=${settings.cloudProvider}; device=${remoteID.take(8)}; utc_date=$expectedDate; file=${file.name}; cursor_not_advanced=true; ${attempt.exceptionOrNull()!!.diagnosticSummary()}"; break }
            }
        }

        val uploadKeys = TimeModel.incrementalUploadUtcDates(existingUploadCursor).filter { database.storedBitmap(settings.deviceID, it) != null }
        if (uploadKeys.isEmpty()) progress("Uploading local changes — nothing new…")
        uploadKeys.forEachIndexed { index, key ->
            val stored = database.storedBitmap(settings.deviceID, key) ?: return@forEachIndexed
            progress("Uploading local changes — ${index + 1} of ${uploadKeys.size}…")
            val name = "${settings.deviceID}_bitmap_$key.json"
            drive.upload(name, bitmapJson(settings.deviceID, key, stored).toString().encodeToByteArray(), byName[name]?.id)
            database.saveIncrementalUploadCursor(uploadTarget, key); uploaded++
        }
        val uploadCursor = uploadKeys.lastOrNull()
        val settingsName = "${settings.deviceID}_setting.json"
        progress("Uploading device settings…")
        drive.upload(settingsName, settings.toJson().toString(2).encodeToByteArray(), byName[settingsName]?.id)
        return Result(uploaded, downloaded, devices, cursors, uploadCursor, warnings)
    }

    fun quickUpload(): Int {
        val key = TimeModel.utcDate(Instant.now())
        val stored = database.storedBitmap(settings.deviceID, key) ?: run { database.completeQuickUpload(settings.deviceID); return 0 }
        val name = "${settings.deviceID}_bitmap_$key.json"
        val existing = drive.list().firstOrNull { it.name == name }
        drive.upload(name, bitmapJson(settings.deviceID, key, stored).toString().encodeToByteArray(), existing?.id)
        database.completeQuickUpload(settings.deviceID)
        return 1
    }

    fun weeklyMaintenance(currentWeekStart: LocalDate, previousWeekStart: LocalDate, previousWeekEnd: LocalDate): MaintenanceResult {
        var remote = drive.list(); val history = drive.listFolder("history")
        val dailyFiles = remote.mapNotNull { file ->
            val text = parseBitmapDate(file.name) ?: return@mapNotNull null
            val date = runCatching { LocalDate.parse(text) }.getOrNull() ?: return@mapNotNull null
            if (parseDevice(file.name) != settings.deviceID || !date.isBefore(currentWeekStart)) return@mapNotNull null
            Triple(file, date, date.minusDays((date.dayOfWeek.value - 1).toLong()))
        }
        val weekStarts = (dailyFiles.map { it.third } + previousWeekStart).distinct().sorted()
        var uploaded = 0; var deleted = 0
        weekStarts.forEach { weekStart ->
            val weekEnd = weekStart.plusDays(6)
            val rows = database.bitmapArchive(settings.deviceID, weekStart, weekEnd)
            val archiveName = "${settings.deviceID}_week_${weekStart}_${weekEnd}.json"
            val archive = JSONObject().put("kind", "weekly_bitmap").put("device_id", settings.deviceID).put("period_start", weekStart.toString()).put("period_end", weekEnd.toString()).put("created_at", Instant.now().toString()).put("rows", JSONArray().apply {
                rows.forEach { put(JSONObject().put("device_id", it.deviceID).put("utc_date", it.utcDate).put("bitmap_base64", it.bitmapBase64).put("updated_at", Instant.ofEpochSecond(it.updatedAt).toString())) }
            })
            drive.upload(archiveName, archive.toString().encodeToByteArray(), remote.firstOrNull { it.name == archiveName }?.id); uploaded++
            dailyFiles.filter { it.third == weekStart }.forEach { drive.delete(it.first.id); deleted++ }
            database.recordArchive("bitmap-week-${settings.deviceID}-$weekStart", "weekly_bitmap", weekStart, weekEnd, archiveName)
        }
        remote = drive.list(); val cutoff = previousWeekStart.minusWeeks(1); var moved = 0
        remote.filter { it.name.startsWith("${settings.deviceID}_week_") && parseWeekEnd(it.name)?.isBefore(cutoff) == true }.forEach { file ->
            drive.uploadFolder("history", file.name, drive.download(file.id), history.firstOrNull { it.name == file.name }?.id); drive.delete(file.id); moved++
        }
        return MaintenanceResult(uploaded, deletedDaily = deleted, movedWeekly = moved)
    }

    fun yearlyMaintenance(year: Int, trackingCleanupYear: Int): MaintenanceResult {
        val history = drive.listFolder("history")
        val start = LocalDate.of(year, 1, 1); val end = LocalDate.of(year, 12, 31)
        val bitmapRows = database.bitmapArchive(settings.deviceID, start, end)
        val bitmapJSON = JSONObject().put("kind", "yearly_bitmap").put("device_id", settings.deviceID).put("period_start", start.toString()).put("period_end", end.toString()).put("created_at", Instant.now().toString()).put("rows", JSONArray().apply {
            bitmapRows.forEach { put(JSONObject().put("device_id", it.deviceID).put("utc_date", it.utcDate).put("bitmap_base64", it.bitmapBase64).put("updated_at", Instant.ofEpochSecond(it.updatedAt).toString())) }
        })
        val bitmapName = "${settings.deviceID}_year_$year.json.gz"
        drive.uploadFolder("history", bitmapName, gzip(bitmapJSON.toString().encodeToByteArray()), history.firstOrNull { it.name == bitmapName }?.id)
        val tracking = database.openRouterArchive(year)
        val trackingJSON = JSONObject().put("kind", "openrouter_year").put("year", year).put("created_at", Instant.now().toString()).put("rows", JSONArray().apply {
            tracking.forEach { row -> put(JSONObject().put("week_start", row.weekStart.toString()).put("week_end", row.weekEnd.toString()).put("rank", row.rank).put("model", row.model).put("prompt_tokens", row.promptTokens).put("completion_tokens", row.completionTokens).put("total_tokens", row.totalTokens).put("prompt_price", row.promptPrice).put("completion_price", row.completionPrice).put("estimated_revenue", row.revenue).put("as_of", row.asOf).put("missing_dates", JSONArray(row.missingDates)).put("is_complete", row.isComplete)) }
        })
        val trackingName = "openrouter_year_$year.json.gz"
        drive.uploadFolder("history", trackingName, gzip(trackingJSON.toString().encodeToByteArray()), history.firstOrNull { it.name == trackingName }?.id)
        val deletedBitmaps = database.deleteBitmapRows(settings.deviceID, start, end)
        val deletedWeekly = database.deleteOpenRouterWeeks(trackingCleanupYear)
        database.recordArchive("bitmap-year-${settings.deviceID}-$year", "yearly_bitmap", start, end, "history/$bitmapName")
        database.recordArchive("openrouter-year-$year", "openrouter_year", start, end, "history/$trackingName")
        return MaintenanceResult(2, deletedBitmaps = deletedBitmaps, deletedWeekly = deletedWeekly)
    }

    private fun gzip(data: ByteArray): ByteArray { val output = ByteArrayOutputStream(); GZIPOutputStream(output).use { it.write(data) }; return output.toByteArray() }
    private fun bitmapJson(id: String, date: String, stored: AndroidStoredBitmap) = JSONObject().put("device_id", id).put("utc_date", date).put("bitmap_base64", stored.bitmap.base64()).put("updated_at", Instant.ofEpochSecond(stored.updatedAt).toString()).put("reserved", JSONObject())
    private fun parseDevice(name: String): String? = when { "_bitmap_" in name -> name.substringBefore("_bitmap_"); name.endsWith("_setting.json") -> name.removeSuffix("_setting.json"); else -> null }
    private fun parseBitmapDate(name: String): String? { if ("_bitmap_" !in name || !name.endsWith(".json")) return null; val date = name.substringAfter("_bitmap_").removeSuffix(".json"); return runCatching { LocalDate.parse(date); date }.getOrNull() }
    private fun parseWeekEnd(name: String): LocalDate? { if ("_week_" !in name || !name.endsWith(".json")) return null; val parts = name.substringAfter("_week_").removeSuffix(".json").split('_'); val date = runCatching { LocalDate.parse(if (parts.size == 2) parts[1] else parts.single()) }.getOrNull() ?: return null; return if (parts.size == 1) date.plusDays(6) else date }
}
