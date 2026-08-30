package com.timbertrail.stg

import android.content.*
import android.database.sqlite.*
import org.json.JSONObject
import java.time.Instant

data class AndroidDeviceRecord(val id: String, val name: String, val kind: String, val updatedAt: Long)

class BitmapDatabase(context: Context) : SQLiteOpenHelper(context, "stg.sqlite", null, 5) {
    private val appContext = context.applicationContext
    override fun onConfigure(db: SQLiteDatabase) { db.enableWriteAheadLogging(); db.execSQL("PRAGMA busy_timeout=3000") }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE bitmap(device_id TEXT NOT NULL,utc_date TEXT NOT NULL,bits BLOB NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(device_id,utc_date))")
        db.execSQL("CREATE TABLE device(device_id TEXT PRIMARY KEY,name TEXT NOT NULL,kind TEXT NOT NULL,updated_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE incremental_download_cursor(remote_device_id TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE incremental_upload_cursor(sync_target TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL)")
        createTrackingTables(db)
        importOpenRouterSeed(db)
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) db.execSQL("CREATE TABLE IF NOT EXISTS incremental_download_cursor(remote_device_id TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL)")
        if (oldVersion < 3) db.execSQL("CREATE TABLE IF NOT EXISTS incremental_upload_cursor(sync_target TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL)")
        if (oldVersion < 4) createTrackingTables(db)
        if (oldVersion < 5) {
            if (oldVersion >= 4) {
                db.execSQL("ALTER TABLE openrouter_weekly ADD COLUMN total_tokens INTEGER NOT NULL DEFAULT 0")
                db.execSQL("UPDATE openrouter_weekly SET total_tokens=prompt_tokens+completion_tokens")
            }
            importOpenRouterSeed(db)
        }
    }
    private fun createTrackingTables(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE IF NOT EXISTS openrouter_weekly(window_start TEXT NOT NULL,window_end TEXT NOT NULL,rank INTEGER NOT NULL,model TEXT NOT NULL,prompt_tokens INTEGER NOT NULL,completion_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL, prompt_price REAL,completion_price REAL,revenue REAL,updated_at INTEGER NOT NULL,PRIMARY KEY(window_start,model))")
        db.execSQL("CREATE TABLE IF NOT EXISTS maintenance_state(action TEXT PRIMARY KEY,completed_period TEXT NOT NULL,updated_at INTEGER NOT NULL)")
    }
    private fun importOpenRouterSeed(db: SQLiteDatabase) {
        val imported = db.rawQuery("SELECT 1 FROM maintenance_state WHERE action='openrouter_seed_v1' LIMIT 1", null).use { it.moveToFirst() }
        if (imported) return
        val document = appContext.assets.open("openrouter-weekly-seed-v1.json").bufferedReader().use { JSONObject(it.readText()) }
        require(document.getInt("schema") == 1) { "Bundled OpenRouter history seed is invalid" }
        val rows = document.getJSONArray("rows")
        val statement = db.compileStatement("INSERT OR IGNORE INTO openrouter_weekly(window_start,window_end,rank,model,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,updated_at) VALUES(?,?,?,?,-1,-1,?,NULL,NULL,NULL,?)")
        for (index in 0 until rows.length()) {
            val row = rows.getJSONObject(index); statement.clearBindings()
            statement.bindString(1, row.getString("s")); statement.bindString(2, row.getString("e")); statement.bindLong(3, row.getLong("r")); statement.bindString(4, row.getString("m")); statement.bindLong(5, row.getLong("t")); statement.bindLong(6, System.currentTimeMillis())
            statement.executeInsert()
        }
        db.execSQL("INSERT OR REPLACE INTO maintenance_state(action,completed_period,updated_at) VALUES('openrouter_seed_v1',?,?)", arrayOf(document.getString("as_of"), System.currentTimeMillis()))
    }
    @Synchronized fun bitmap(deviceID: String, utcDate: String): MinuteBitmap {
        readableDatabase.query("bitmap", arrayOf("bits"), "device_id=? AND utc_date=?", arrayOf(deviceID, utcDate), null, null, null).use { if (it.moveToFirst()) return MinuteBitmap(it.getBlob(0)) }
        return MinuteBitmap()
    }
    @Synchronized fun mark(deviceID: String, instant: Instant): Boolean {
        val date = TimeModel.utcDate(instant); val bitmap = bitmap(deviceID, date); val changed = bitmap.mark(TimeModel.utcMinute(instant)); if (changed) upsert(deviceID, date, bitmap, instant.toEpochMilli()); return changed
    }
    @Synchronized fun upsert(deviceID: String, date: String, bitmap: MinuteBitmap, updatedAt: Long = System.currentTimeMillis()) {
        val values = ContentValues().apply { put("device_id", deviceID); put("utc_date", date); put("bits", bitmap.data); put("updated_at", updatedAt) }
        writableDatabase.insertWithOnConflict("bitmap", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }
    @Synchronized fun upsertIfNewer(deviceID: String, date: String, bitmap: MinuteBitmap, updatedAt: Long) {
        val existing = readableDatabase.query("bitmap", arrayOf("updated_at"), "device_id=? AND utc_date=?", arrayOf(deviceID, date), null, null, null).use { if (it.moveToFirst()) it.getLong(0) else Long.MIN_VALUE }
        if (updatedAt >= existing) upsert(deviceID, date, bitmap, updatedAt)
    }
    @Synchronized fun upsertDevice(record: AndroidDeviceRecord) {
        val values = ContentValues().apply { put("device_id", record.id); put("name", record.name); put("kind", record.kind); put("updated_at", record.updatedAt) }
        writableDatabase.insertWithOnConflict("device", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }
    @Synchronized fun devices(): Map<String, AndroidDeviceRecord> {
        val result = linkedMapOf<String, AndroidDeviceRecord>()
        readableDatabase.query("device", arrayOf("device_id", "name", "kind", "updated_at"), null, null, null, null, "name COLLATE NOCASE,device_id").use { while (it.moveToNext()) result[it.getString(0)] = AndroidDeviceRecord(it.getString(0), it.getString(1), it.getString(2), it.getLong(3)) }
        return result
    }
    @Synchronized fun deviceIDs(): List<String> {
        val result = mutableListOf<String>(); readableDatabase.rawQuery("SELECT DISTINCT device_id FROM bitmap WHERE device_id<>'alldevices' ORDER BY device_id", null).use { while (it.moveToNext()) result += it.getString(0) }; return result
    }
    @Synchronized fun rebuildAll(date: String): MinuteBitmap {
        val result = MinuteBitmap(); readableDatabase.query("bitmap", arrayOf("bits"), "device_id<>? AND utc_date=?", arrayOf("alldevices", date), null, null, null).use { while (it.moveToNext()) result.union(MinuteBitmap(it.getBlob(0))) }; upsert("alldevices", date, result); return result
    }
    fun localDayMinutes(deviceID: String, instant: Instant, zoneID: String): Int = TimeModel.localDayInstants(instant, zoneID).count { bitmap(deviceID, TimeModel.utcDate(it))[TimeModel.utcMinute(it)] }
    fun localClockDayBitmap(deviceID: String, instant: Instant, zoneID: String): BooleanArray {
        val result = BooleanArray(1440); TimeModel.localDayInstants(instant, zoneID).forEach { if (bitmap(deviceID, TimeModel.utcDate(it))[TimeModel.utcMinute(it)]) result[TimeModel.localClockMinute(it, zoneID)] = true }; return result
    }
    @Synchronized fun incrementalDownloadCursor(remoteDeviceID: String): String? = readableDatabase.query("incremental_download_cursor", arrayOf("latest_utc_date"), "remote_device_id=?", arrayOf(remoteDeviceID), null, null, null).use { if (it.moveToFirst()) it.getString(0) else null }
    @Synchronized fun saveIncrementalDownloadCursor(remoteDeviceID: String, date: String) {
        writableDatabase.execSQL("INSERT INTO incremental_download_cursor(remote_device_id,latest_utc_date,updated_at) VALUES(?,?,?) ON CONFLICT(remote_device_id) DO UPDATE SET latest_utc_date=CASE WHEN excluded.latest_utc_date>incremental_download_cursor.latest_utc_date THEN excluded.latest_utc_date ELSE incremental_download_cursor.latest_utc_date END,updated_at=excluded.updated_at", arrayOf<Any>(remoteDeviceID, date, System.currentTimeMillis()))
    }
    @Synchronized fun incrementalUploadCursor(syncTarget: String): String? = readableDatabase.query("incremental_upload_cursor", arrayOf("latest_utc_date"), "sync_target=?", arrayOf(syncTarget), null, null, null).use { if (it.moveToFirst()) it.getString(0) else null }
    @Synchronized fun saveIncrementalUploadCursor(syncTarget: String, date: String) {
        writableDatabase.execSQL("INSERT INTO incremental_upload_cursor(sync_target,latest_utc_date,updated_at) VALUES(?,?,?) ON CONFLICT(sync_target) DO UPDATE SET latest_utc_date=CASE WHEN excluded.latest_utc_date>incremental_upload_cursor.latest_utc_date THEN excluded.latest_utc_date ELSE incremental_upload_cursor.latest_utc_date END,updated_at=excluded.updated_at", arrayOf<Any>(syncTarget, date, System.currentTimeMillis()))
    }
    @Synchronized fun latestOpenRouterWeekEnd(): String? = readableDatabase.rawQuery("SELECT MAX(window_end) FROM openrouter_weekly", null).use { if (it.moveToFirst() && !it.isNull(0)) it.getString(0) else null }
    @Synchronized fun latestOpenRouterDetailWeekEnd(): String? = readableDatabase.query("maintenance_state", arrayOf("completed_period"), "action=?", arrayOf("openrouter_detail"), null, null, null).use { if (it.moveToFirst()) it.getString(0) else null }
    @Synchronized fun saveOpenRouterWeeks(rows: List<WeeklyRankingRow>) {
        val db = writableDatabase; db.beginTransaction()
        try { rows.forEach { row -> db.execSQL("INSERT OR REPLACE INTO openrouter_weekly(window_start,window_end,rank,model,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)", arrayOf(row.weekStart.toString(), row.weekEnd.toString(), row.rank, row.model, row.promptTokens, row.completionTokens, row.totalTokens, row.promptPrice, row.completionPrice, row.revenue, System.currentTimeMillis())) }; db.setTransactionSuccessful() } finally { db.endTransaction() }
    }
    @Synchronized fun latestOpenRouterTopModels(limit: Int = 10): List<String> {
        val result = mutableListOf<String>(); readableDatabase.rawQuery("SELECT model FROM openrouter_weekly WHERE window_start=(SELECT MAX(window_start) FROM openrouter_weekly) ORDER BY rank LIMIT ?", arrayOf(limit.toString())).use { while (it.moveToNext()) result += it.getString(0) }; return result
    }
    @Synchronized fun openRouterWeeks(models: List<String>): List<WeeklyRankingRow> {
        if (models.isEmpty()) return emptyList(); val marks = models.joinToString(",") { "?" }; val result = mutableListOf<WeeklyRankingRow>()
        readableDatabase.rawQuery("SELECT window_start,window_end,rank,model,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue FROM openrouter_weekly WHERE model IN ($marks) ORDER BY window_start,rank", models.toTypedArray()).use { while (it.moveToNext()) result += WeeklyRankingRow(java.time.LocalDate.parse(it.getString(0)), java.time.LocalDate.parse(it.getString(1)), it.getInt(2), it.getString(3), it.getLong(4), it.getLong(5), it.getLong(6), if (it.isNull(7)) null else it.getDouble(7), if (it.isNull(8)) null else it.getDouble(8), if (it.isNull(9)) null else it.getDouble(9)) }; return result
    }
    @Synchronized fun weeklyActionCompletedPeriod(): String? = readableDatabase.query("maintenance_state", arrayOf("completed_period"), "action=?", arrayOf("weekly"), null, null, null).use { if (it.moveToFirst()) it.getString(0) else null }
    @Synchronized fun completeWeeklyAction(period: String) { writableDatabase.execSQL("INSERT OR REPLACE INTO maintenance_state(action,completed_period,updated_at) VALUES('weekly',?,?)", arrayOf<Any>(period, System.currentTimeMillis())) }
    @Synchronized fun completeOpenRouterDetailWeek(period: String) { writableDatabase.execSQL("INSERT OR REPLACE INTO maintenance_state(action,completed_period,updated_at) VALUES('openrouter_detail',?,?)", arrayOf<Any>(period, System.currentTimeMillis())) }
}
