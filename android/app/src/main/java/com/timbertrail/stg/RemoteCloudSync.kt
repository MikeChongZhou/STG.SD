package com.timbertrail.stg

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.ByteArrayInputStream
import java.time.Instant
import java.time.LocalDate
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import java.util.zip.InflaterInputStream
import java.util.zip.DeflaterOutputStream
import java.util.zip.Inflater
import java.util.zip.Deflater

internal class RemoteCloudSync(private val database: BitmapDatabase, private val settings: AppSettings, private val drive: PrivateCloudDrive) {
    data class Result(val uploaded: Int, val downloaded: Int, val devices: Set<String>, val downloadCursors: Map<String, String>, val uploadCursor: String?, val warnings: List<String>)
    data class MaintenanceResult(val uploaded: Int, val deletedDaily: Int = 0, val movedWeekly: Int = 0, val deletedBitmaps: Int = 0, val deletedWeekly: Int = 0)
    data class AlignmentResult(val downloaded: Int, val uploaded: Int)
    private data class AlignmentArchive(val file: RemoteFile, val folder: String, val json: JSONObject, val rawDeflate: Boolean)

    fun alignAllData(progress: (String) -> Unit = {}): AlignmentResult {
        val root = drive.list(); val history = drive.listFolder("history")
        val daily = root.filter { parseDevice(it.name) != "alldevices" && parseBitmapDate(it.name) != null }
        val archives = (root.map { it to "sync" } + history.map { it to "history" }).filter { (file, folder) ->
            file.name.contains("_week_") && file.name.endsWith(".json") ||
                folder == "history" && !file.name.startsWith("openrouter_") && file.name.contains("_year_") && (file.name.endsWith(".json.gz") || file.name.endsWith(".json.zlib"))
        }
        val devices = database.deviceIDs().toMutableSet().apply { add(settings.deviceID) }
        val originalDaily = linkedMapOf<String, String>()
        val originalArchives = mutableListOf<AlignmentArchive>()
        val touched = mutableSetOf<String>()
        var downloaded = 0; var uploaded = 0
        daily.forEachIndexed { index, file ->
            progress("Downloading daily data ${index + 1}/${daily.size}…")
            val json = JSONObject(drive.download(file.id).decodeToString())
            val id = json.getString("device_id"); val date = json.getString("utc_date")
            require(file.name == "${id}_bitmap_$date.json") { "Daily bitmap identity mismatch: ${file.name}" }
            database.mergeBitmap(id, date, MinuteBitmap.fromBase64(json.getString("bitmap_base64")), Instant.parse(json.getString("updated_at")).epochSecond)
            originalDaily[file.name] = json.getString("bitmap_base64"); devices += id; touched += date; downloaded++
        }
        archives.forEachIndexed { index, (file, folder) ->
            progress("Downloading history ${index + 1}/${archives.size}…")
            val (decoded, rawDeflate) = unpackArchive(drive.download(file.id), file.name)
            val json = JSONObject(decoded.decodeToString())
            val kind = json.getString("kind")
            require(kind in setOf("week", "weekly_bitmap", "year", "yearly_bitmap")) { "Unsupported bitmap archive: ${file.name}" }
            val id = json.optString("device_id").ifEmpty { json.getString("deviceID") }
            require(file.name.startsWith("${id}_${if (kind == "year" || kind == "yearly_bitmap") "year" else "week"}_")) { "Archive identity mismatch: ${file.name}" }
            val rows = json.getJSONArray("rows")
            for (i in 0 until rows.length()) {
                val row = rows.getJSONObject(i); require(row.getString("device_id") == id)
                val date = row.getString("utc_date")
                database.mergeBitmap(id, date, MinuteBitmap.fromBase64(row.getString("bitmap_base64")), Instant.parse(row.getString("updated_at")).epochSecond)
                touched += date
            }
            originalArchives += AlignmentArchive(file, folder, json, rawDeflate); devices += id; downloaded++
        }
        touched.forEach(database::rebuildAll)
        daily.forEach { file ->
            val id = parseDevice(file.name)!!; val date = parseBitmapDate(file.name)!!
            val stored = database.storedBitmap(id, date) ?: return@forEach
            if (stored.bitmap.base64() != originalDaily[file.name]) {
                drive.upload(file.name, bitmapJson(id, date, stored).toString().encodeToByteArray(), file.id); uploaded++
            }
        }
        originalArchives.forEach { (file, folder, original, rawDeflate) ->
            val id = original.optString("device_id").ifEmpty { original.getString("deviceID") }
            val start = LocalDate.parse(original.optString("period_start").ifEmpty { original.getString("periodStart") })
            val end = LocalDate.parse(original.optString("period_end").ifEmpty { original.getString("periodEnd") })
            val rows = database.bitmapArchive(id, start, end)
            val oldRows = original.getJSONArray("rows").let { values -> (0 until values.length()).associate { i -> values.getJSONObject(i).let { it.getString("utc_date") to it.getString("bitmap_base64") } } }
            if (rows.size == oldRows.size && rows.all { oldRows[it.utcDate] == it.bitmapBase64 }) return@forEach
            val kind = if (original.getString("kind") in setOf("year", "yearly_bitmap")) "yearly_bitmap" else "weekly_bitmap"
            val data = packArchive(archiveJson(id, kind, start, end, rows), file.name, rawDeflate)
            if (folder == "history") drive.uploadFolder("history", file.name, data, file.id) else drive.upload(file.name, data, file.id)
            uploaded++
        }
        val currentWeek = LocalDate.now(java.time.ZoneOffset.UTC).let { it.minusDays((it.dayOfWeek.value - 1).toLong()) }
        val oldCutoff = currentWeek.minusWeeks(1)
        val existingDaily = daily.map { it.name }.toSet(); val newWeeks = mutableSetOf<String>()
        devices.filter { it != "alldevices" }.forEach { id -> database.bitmapDates(id).forEach { date ->
            val name = "${id}_bitmap_$date.json"
            if (name in existingDaily || originalArchives.any { (_, _, json, _) ->
                val archiveID = json.optString("device_id").ifEmpty { json.getString("deviceID") }
                val start = json.optString("period_start").ifEmpty { json.getString("periodStart") }
                val end = json.optString("period_end").ifEmpty { json.getString("periodEnd") }
                archiveID == id && date.toString() >= start && date.toString() <= end
            }) return@forEach
            val existingDailyInWeek = daily.any { file -> parseDevice(file.name) == id && parseBitmapDate(file.name)?.let { LocalDate.parse(it).minusDays((LocalDate.parse(it).dayOfWeek.value - 1).toLong()) } == date.minusDays((date.dayOfWeek.value - 1).toLong()) }
            if (date >= oldCutoff || existingDailyInWeek) {
                val stored = database.storedBitmap(id, date.toString()) ?: return@forEach
                drive.upload(name, bitmapJson(id, date.toString(), stored).toString().encodeToByteArray()); uploaded++
            } else {
                val start = date.minusDays((date.dayOfWeek.value - 1).toLong()); val end = start.plusDays(6)
                val weekName = "${id}_week_${start}_${end}.json"
                if (newWeeks.add(weekName)) {
                    drive.uploadFolder("history", weekName, archiveJson(id, "weekly_bitmap", start, end, database.bitmapArchive(id, start, end))); uploaded++
                }
            }
        } }
        database.refreshStatistics(settings)
        return AlignmentResult(downloaded, uploaded)
    }

    private fun archiveJson(id: String, kind: String, start: LocalDate, end: LocalDate, rows: List<AndroidBitmapArchiveRow>) = JSONObject()
        .put("kind", kind).put("device_id", id).put("period_start", start.toString()).put("period_end", end.toString())
        .put("created_at", Instant.now().toString()).put("rows", JSONArray().apply {
            rows.forEach { put(JSONObject().put("device_id", it.deviceID).put("utc_date", it.utcDate).put("bitmap_base64", it.bitmapBase64).put("updated_at", Instant.ofEpochSecond(it.updatedAt).toString())) }
        }).toString().encodeToByteArray()
    private fun unpackArchive(data: ByteArray, name: String): Pair<ByteArray, Boolean> = when {
        name.endsWith(".gz") -> GZIPInputStream(ByteArrayInputStream(data)).use { it.readBytes() } to false
        name.endsWith(".zlib") -> {
            try { InflaterInputStream(ByteArrayInputStream(data)).use { it.readBytes() } to false }
            catch (_: java.util.zip.ZipException) {
                InflaterInputStream(ByteArrayInputStream(data), Inflater(true)).use { it.readBytes() } to true
            }
        }
        else -> data to false
    }
    private fun packArchive(data: ByteArray, name: String, rawDeflate: Boolean): ByteArray = when {
        name.endsWith(".gz") -> ByteArrayOutputStream().also { output -> GZIPOutputStream(output).use { it.write(data) } }.toByteArray()
        name.endsWith(".zlib") -> ByteArrayOutputStream().also { output -> DeflaterOutputStream(output, Deflater(Deflater.DEFAULT_COMPRESSION, rawDeflate)).use { it.write(data) } }.toByteArray()
        else -> data
    }

    fun incremental(progress: (String) -> Unit = {}): Result {
        progress("Preparing cloud folders…")
        progress("Scanning remote devices…")
        var files = drive.list()
        var byName = files.associateBy { it.name }
        val devices = files.mapNotNull { parseDevice(it.name) }.toSet()
        val knownDevices = database.devices()
        var uploaded = 0; var downloaded = 0
        val warnings = mutableListOf<String>()
        val cursors = linkedMapOf<String, String>()
        database.upsertDevice(AndroidDeviceRecord(settings.deviceID, settings.deviceName, "android", settings.updatedAt))
        val uploadTarget = settings.cloudProvider
        val existingUploadCursor = database.incrementalUploadCursor(uploadTarget)
        val lastSync = database.lastIncrementalSync(settings.deviceID)

        files.filter { it.name.endsWith("_setting.json") }.forEach { file ->
            runCatching {
                val remoteID = parseDevice(file.name) ?: return@runCatching
                if (remoteID == settings.deviceID) return@runCatching
                if (file.modifiedAt != null && knownDevices[remoteID]?.updatedAt?.let { file.modifiedAt <= it } == true) return@runCatching
                progress("Updating device information…")
                val json = JSONObject(drive.download(file.id).decodeToString())
                if (json.getString("device_id") != remoteID) return@runCatching
                val contentTime = runCatching { Instant.parse(json.getString("updated_at")).epochSecond }.getOrDefault(Instant.now().epochSecond)
                database.upsertDevice(AndroidDeviceRecord(remoteID, json.optString("device_name", "Other device"), json.optString("device_kind", "android"), file.modifiedAt ?: contentTime))
            }.onFailure { warnings += "settings_import_failed; provider=${settings.cloudProvider}; file=${file.name}; ${it.diagnosticSummary()}" }
        }

        val initialCloudRestore = existingUploadCursor == null
        val downloadIDs = devices.filter { it != "alldevices" && (it != settings.deviceID || initialCloudRestore) }
        val candidatesByDevice = downloadIDs.associateWith { remoteID ->
            val restoringThisDevice = remoteID == settings.deviceID
            val cursor = if (remoteID == settings.deviceID) null else database.incrementalDownloadCursor(remoteID)
            files.mapNotNull { file ->
                val date = parseBitmapDate(file.name) ?: return@mapNotNull null
                val missing = initialCloudRestore && (restoringThisDevice || database.storedBitmap(remoteID, date) == null)
                if (parseDevice(file.name) == remoteID && (missing || (!restoringThisDevice && (cursor == null || date >= cursor) && (lastSync == null || file.modifiedAt == null || file.modifiedAt > lastSync)))) file to date else null
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

        val today = LocalDate.now(java.time.ZoneOffset.UTC)
        val currentWeekStart = today.minusDays((today.dayOfWeek.value - 1).toLong())
        val reconciledWeeks = mutableSetOf<LocalDate>()
        val restoredArchives = mutableListOf<String>()
        if (initialCloudRestore) {
            uploaded += reconcileInitialWeeklyArchives(files, drive.listFolder("history"), currentWeekStart, reconciledWeeks, restoredArchives)
            files = drive.list(); byName = files.associateBy { it.name }
        }

        val archiveCutoff = currentWeekStart.minusWeeks(1)
        val uploadKeys = (if (initialCloudRestore) database.bitmapDates(settings.deviceID).map { it.toString() }.filter { date -> LocalDate.parse(date) >= archiveCutoff && !reconciledWeeks.contains(LocalDate.parse(date).minusDays((LocalDate.parse(date).dayOfWeek.value - 1).toLong())) } else TimeModel.incrementalUploadUtcDates(existingUploadCursor)).filter { database.storedBitmap(settings.deviceID, it) != null }
        if (uploadKeys.isEmpty()) progress("Uploading local changes — nothing new…")
        uploadKeys.forEachIndexed { index, key ->
            val stored = database.storedBitmap(settings.deviceID, key) ?: return@forEachIndexed
            progress("Uploading local changes — ${index + 1} of ${uploadKeys.size}…")
            val name = "${settings.deviceID}_bitmap_$key.json"
            drive.upload(name, bitmapJson(settings.deviceID, key, stored).toString().encodeToByteArray(), byName[name]?.id)
            if (!initialCloudRestore) database.saveIncrementalUploadCursor(uploadTarget, key)
            uploaded++
        }
        val uploadCursor = uploadKeys.lastOrNull() ?: if (initialCloudRestore && (uploaded > 0 || downloaded > 0 || restoredArchives.isNotEmpty())) today.toString() else null
        val settingsName = "${settings.deviceID}_setting.json"
        progress("Uploading device settings…")
        drive.upload(settingsName, settings.toJson().toString(2).encodeToByteArray(), byName[settingsName]?.id)
        if (initialCloudRestore && warnings.isEmpty() && uploadCursor != null) database.saveIncrementalUploadCursor(uploadTarget, uploadCursor)
        return Result(uploaded, downloaded, devices, cursors, if (initialCloudRestore && warnings.isNotEmpty()) null else uploadCursor, warnings)
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
            val archiveName = "${settings.deviceID}_week_${weekStart}_${weekEnd}.json"
            val rootFile = remote.firstOrNull { it.name == archiveName }
            val historyFile = history.firstOrNull { it.name == archiveName }
            listOfNotNull(rootFile, historyFile).forEach { existing -> importWeeklyArchive(drive.download(existing.id), settings.deviceID) }
            val rows = database.bitmapArchive(settings.deviceID, weekStart, weekEnd)
            val archive = JSONObject().put("kind", "weekly_bitmap").put("device_id", settings.deviceID).put("period_start", weekStart.toString()).put("period_end", weekEnd.toString()).put("created_at", Instant.now().toString()).put("rows", JSONArray().apply {
                rows.forEach { put(JSONObject().put("device_id", it.deviceID).put("utc_date", it.utcDate).put("bitmap_base64", it.bitmapBase64).put("updated_at", Instant.ofEpochSecond(it.updatedAt).toString())) }
            })
            if (rootFile == null && historyFile != null) drive.uploadFolder("history", archiveName, archive.toString().encodeToByteArray(), historyFile.id)
            else drive.upload(archiveName, archive.toString().encodeToByteArray(), rootFile?.id)
            uploaded++
            dailyFiles.filter { it.third == weekStart }.forEach { drive.delete(it.first.id); deleted++ }
            database.recordArchive("bitmap-week-${settings.deviceID}-$weekStart", "weekly_bitmap", weekStart, weekEnd, if (rootFile == null && historyFile != null) "history/$archiveName" else archiveName)
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
    private fun importWeeklyArchive(data: ByteArray, expectedDeviceID: String? = null): String {
        val archive = JSONObject(data.decodeToString())
        val id = archive.optString("device_id").ifEmpty { archive.optString("deviceID") }
        require(id.isNotBlank() && (expectedDeviceID == null || id == expectedDeviceID) && archive.optString("kind") in setOf("weekly_bitmap", "week")) { "Weekly archive identity mismatch" }
        archive.getJSONArray("rows").let { rows -> for (index in 0 until rows.length()) {
            val row = rows.getJSONObject(index); require(row.getString("device_id") == id)
            val date = row.getString("utc_date"); val updated = Instant.parse(row.getString("updated_at")).epochSecond
            database.mergeBitmap(id, date, MinuteBitmap.fromBase64(row.getString("bitmap_base64")), updated); database.rebuildAll(date)
        } }
        return id
    }
    private fun reconcileInitialWeeklyArchives(root: List<RemoteFile>, history: List<RemoteFile>, currentWeekStart: LocalDate, reconciledWeeks: MutableSet<LocalDate>, restoredArchives: MutableList<String>): Int {
        val archives = (root + history).filter { it.name.contains("_week_") && it.name.endsWith(".json") }
        archives.forEach { archive -> val id = importWeeklyArchive(drive.download(archive.id)); require(archive.name.startsWith("${id}_week_")); restoredArchives += archive.name; if (id == settings.deviceID) runCatching { LocalDate.parse(archive.name.substringAfter("_week_").substringBefore('_')) }.getOrNull()?.let(reconciledWeeks::add) }
        var uploaded = 0
        val localWeeks = database.bitmapDates(settings.deviceID).filter { it.isBefore(currentWeekStart) }.map { it.minusDays((it.dayOfWeek.value - 1).toLong()) }.distinct().sorted()
        localWeeks.filter { it in reconciledWeeks || it < currentWeekStart.minusWeeks(1) }.forEach { start ->
            val end = start.plusDays(6); val name = "${settings.deviceID}_week_${start}_${end}.json"
            val rows = database.bitmapArchive(settings.deviceID, start, end)
            if (rows.isEmpty()) return@forEach
            val json = weeklyArchiveJson(start, end, rows)
            val rootFile = root.firstOrNull { it.name == name }; val historyFile = history.firstOrNull { it.name == name }
            if (historyFile != null) drive.uploadFolder("history", name, json, historyFile.id)
            else if (rootFile != null) drive.upload(name, json, rootFile.id)
            else if (start.isBefore(currentWeekStart.minusWeeks(1))) drive.uploadFolder("history", name, json, null)
            else drive.upload(name, json, null)
            database.recordArchive("bitmap-week-${settings.deviceID}-$start", "weekly_bitmap", start, end, if (historyFile != null || (rootFile == null && start.isBefore(currentWeekStart.minusWeeks(1)))) "history/$name" else name)
            reconciledWeeks += start
            uploaded++
        }
        return uploaded
    }
    private fun weeklyArchiveJson(start: LocalDate, end: LocalDate, rows: List<AndroidBitmapArchiveRow>) = JSONObject().put("kind", "weekly_bitmap").put("device_id", settings.deviceID).put("period_start", start.toString()).put("period_end", end.toString()).put("created_at", Instant.now().toString()).put("rows", JSONArray().apply {
        rows.forEach { put(JSONObject().put("device_id", it.deviceID).put("utc_date", it.utcDate).put("bitmap_base64", it.bitmapBase64).put("updated_at", Instant.ofEpochSecond(it.updatedAt).toString())) }
    }).toString().encodeToByteArray()
    private fun parseDevice(name: String): String? = when { "_bitmap_" in name -> name.substringBefore("_bitmap_"); name.endsWith("_setting.json") -> name.removeSuffix("_setting.json"); else -> null }
    private fun parseBitmapDate(name: String): String? { if ("_bitmap_" !in name || !name.endsWith(".json")) return null; val date = name.substringAfter("_bitmap_").removeSuffix(".json"); return runCatching { LocalDate.parse(date); date }.getOrNull() }
    private fun parseWeekEnd(name: String): LocalDate? { if ("_week_" !in name || !name.endsWith(".json")) return null; val parts = name.substringAfter("_week_").removeSuffix(".json").split('_'); val date = runCatching { LocalDate.parse(if (parts.size == 2) parts[1] else parts.single()) }.getOrNull() ?: return null; return if (parts.size == 1) date.plusDays(6) else date }
}
