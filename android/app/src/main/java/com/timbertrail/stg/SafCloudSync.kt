package com.timbertrail.stg

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import org.json.JSONObject
import java.time.Instant

class SafCloudSync(private val context: Context, private val database: BitmapDatabase, private val settings: AppSettings) {
    data class Result(val uploaded: Int, val downloaded: Int, val devices: Set<String>, val downloadCursors: Map<String, String>, val uploadCursor: String?)
    fun incremental(): Result {
        val root = DocumentFile.fromTreeUri(context, Uri.parse(settings.cloudTreeUri ?: error("No private-cloud folder"))) ?: error("Cloud folder unavailable")
        val sync = root.findFile("sync") ?: root.createDirectory("sync") ?: error("Cannot create sync folder")
        val files = sync.listFiles(); val devices = files.mapNotNull { parseDevice(it.name ?: "") }.toSet(); var uploaded = 0; var downloaded = 0; val cursors = linkedMapOf<String, String>()
        database.upsertDevice(AndroidDeviceRecord(settings.deviceID, settings.deviceName, "android", settings.updatedAt))
        files.filter { it.name?.endsWith("_setting.json") == true }.forEach { file ->
            val remoteID = parseDevice(file.name ?: return@forEach) ?: return@forEach; if (remoteID == settings.deviceID) return@forEach
            runCatching { val json = read(file); if (json.getString("device_id") != remoteID) return@runCatching; database.upsertDevice(AndroidDeviceRecord(remoteID, json.optString("device_name", "Other device"), json.optString("device_kind", "android"), runCatching { Instant.parse(json.getString("updated_at")).toEpochMilli() }.getOrDefault(System.currentTimeMillis()))) }
        }
        val uploadTarget = "saf:${settings.cloudTreeUri}"
        var uploadCursor: String? = null
        TimeModel.incrementalUploadUtcDates(database.incrementalUploadCursor(uploadTarget)).forEach { key ->
            write(sync, "${settings.deviceID}_bitmap_$key.json", bitmapJson(settings.deviceID, key, database.bitmap(settings.deviceID, key)).toString())
            database.saveIncrementalUploadCursor(uploadTarget, key); uploadCursor = key; uploaded++
        }
        write(sync, "${settings.deviceID}_setting.json", settings.toJson().toString(2))
        devices.filter { it != settings.deviceID && it != "alldevices" }.forEach { remoteID ->
            val cursor = database.incrementalDownloadCursor(remoteID)
            val candidates = files.mapNotNull { file -> val name = file.name ?: return@mapNotNull null; val date = parseBitmapDate(name) ?: return@mapNotNull null; if (parseDevice(name) == remoteID && (cursor == null || date >= cursor)) file to date else null }.sortedBy { it.second }
            for ((file, expectedDate) in candidates) {
                val success = runCatching { val json = read(file); if (json.getString("device_id") != remoteID || json.getString("utc_date") != expectedDate) error("Remote bitmap identity mismatch"); val updated = runCatching { Instant.parse(json.getString("updated_at")).toEpochMilli() }.getOrDefault(System.currentTimeMillis()); database.upsertIfNewer(remoteID, expectedDate, MinuteBitmap.fromBase64(json.getString("bitmap_base64")), updated); database.rebuildAll(expectedDate); database.saveIncrementalDownloadCursor(remoteID, expectedDate); cursors[remoteID] = expectedDate; downloaded++ }.isSuccess
                if (!success) break
            }
        }
        return Result(uploaded, downloaded, devices, cursors, uploadCursor)
    }
    private fun bitmapJson(id: String, date: String, bitmap: MinuteBitmap) = JSONObject().apply { put("device_id", id); put("utc_date", date); put("bitmap_base64", bitmap.base64()); put("updated_at", Instant.now().toString()); put("reserved", JSONObject()) }
    private fun write(folder: DocumentFile, name: String, text: String) { val file = folder.findFile(name) ?: folder.createFile("application/json", name) ?: error("Cannot create $name"); context.contentResolver.openOutputStream(file.uri, "wt")!!.bufferedWriter().use { it.write(text) } }
    private fun read(file: DocumentFile) = JSONObject(context.contentResolver.openInputStream(file.uri)!!.bufferedReader().use { it.readText() })
    private fun parseDevice(name: String): String? = when { "_bitmap_" in name -> name.substringBefore("_bitmap_"); name.endsWith("_setting.json") -> name.removeSuffix("_setting.json"); else -> null }
    private fun parseBitmapDate(name: String): String? { if ("_bitmap_" !in name || !name.endsWith(".json")) return null; val date = name.substringAfter("_bitmap_").removeSuffix(".json"); return runCatching { java.time.LocalDate.parse(date); date }.getOrNull() }
}
