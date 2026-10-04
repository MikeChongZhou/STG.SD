package com.timbertrail.stg

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.time.Instant

data class AndroidDeviceRecord(val id: String, val name: String, val kind: String, val updatedAt: Long)
data class AndroidReminderState(val lastEyeAt: Long = 0, val lastPostureAt: Long = 0, val lastReminder: String? = null, val updatedAt: Long = 0)
data class AndroidStoredBitmap(val bitmap: MinuteBitmap, val updatedAt: Long)
data class AndroidBitmapArchiveRow(val deviceID: String, val utcDate: String, val bitmapBase64: String, val updatedAt: Long)
data class AndroidStatisticsSummary(val thisWeek: Double?, val lastWeek: Double?, val thisMonth: Double?, val lastMonth: Double?, val thisYear: Double?, val estimated: Boolean)
data class AndroidPeriodUsagePoint(val kind: String, val label: String, val start: String, val end: String, val deviceID: String, val displayName: String, val averageMinutes: Double, val includedDays: Int, val excludedDays: Int, val estimated: Boolean)
data class AndroidDailyStatistic(val date: java.time.LocalDate, val deviceID: String, val displayName: String, val minutes: Int, val aggregate: Boolean, val estimated: Boolean)
private const val STG_APPLICATION_ID = 0x535447

private fun prepareDatabase(context: Context): Context {
    val app = context.applicationContext
    val destination = app.getDatabasePath("stg.sqlite")
    if (!destination.exists()) {
        destination.parentFile?.mkdirs()
        val temporary = java.io.File(destination.parentFile, "stg.sqlite.installing")
        app.assets.open("stg.sqlite").use { input -> temporary.outputStream().use { output -> input.copyTo(output) } }
        if (!temporary.renameTo(destination)) {
            temporary.copyTo(destination, overwrite = false)
            temporary.delete()
        }
    }
    return app
}

class BitmapDatabase(context: Context) : SQLiteOpenHelper(prepareDatabase(context), "stg.sqlite", null, 7) {
    private val appContext = context.applicationContext

    init {
        setWriteAheadLoggingEnabled(true)
    }

    override fun onConfigure(db: SQLiteDatabase) {
        db.rawQuery("PRAGMA busy_timeout=3000", null).use { cursor ->
            while (cursor.moveToNext()) { /* Apply and consume the PRAGMA result. */ }
        }
    }

    override fun onCreate(db: SQLiteDatabase) {
        createCanonicalSchema(db)
        db.execSQL("INSERT OR IGNORE INTO statistics_state(id,last_statistics_at,dirty_from_date,updated_at) VALUES(1,0,NULL,strftime('%s','now'))")
    }

    override fun onOpen(db: SQLiteDatabase) {
        super.onOpen(db)
        if (!db.isReadOnly) {
            createCanonicalSchema(db)
            ensureCanonicalColumns(db)
            db.execSQL("INSERT OR IGNORE INTO statistics_state(id,last_statistics_at,dirty_from_date,updated_at) VALUES(1,0,NULL,strftime('%s','now'))")
            importTemplateHistoryIfNeeded(db)
        }
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 6) {
            prepareLegacyTables(db, oldVersion)
            val tables = listOf("bitmap", "device", "reminder_state", "sync_state", "pending_quick_upload", "incremental_download_cursor", "incremental_upload_cursor", "maintenance_state", "openrouter_weekly")
            tables.forEach { db.execSQL("ALTER TABLE $it RENAME TO ${it}_legacy") }
            createCanonicalSchema(db)
            val seconds: (String) -> String = { "CASE WHEN ABS($it)>=100000000000 THEN CAST($it/1000 AS INTEGER) ELSE CAST($it AS INTEGER) END" }
            db.execSQL("INSERT INTO bitmap SELECT device_id,utc_date,bits,${seconds("updated_at")} FROM bitmap_legacy")
            db.execSQL("INSERT INTO device SELECT device_id,name,kind,${seconds("updated_at")} FROM device_legacy")
            db.execSQL("INSERT INTO reminder_state SELECT device_id,${seconds("last_eye_at")},${seconds("last_posture_at")},last_reminder,${seconds("updated_at")} FROM reminder_state_legacy")
            db.execSQL("INSERT INTO sync_state(device_id,last_quick_upload_at,last_quick_bidirectional_at) SELECT device_id,${seconds("last_quick_upload_at")},${seconds("last_quick_bidirectional_at")} FROM sync_state_legacy")
            db.execSQL("INSERT INTO pending_quick_upload SELECT device_id,utc_date,${seconds("queued_at")} FROM pending_quick_upload_legacy")
            db.execSQL("INSERT INTO incremental_download_cursor SELECT remote_device_id,latest_utc_date,${seconds("updated_at")} FROM incremental_download_cursor_legacy")
            db.execSQL("INSERT INTO incremental_upload_cursor SELECT sync_target,latest_utc_date,${seconds("updated_at")} FROM incremental_upload_cursor_legacy")
            db.execSQL("INSERT INTO maintenance_state SELECT action,completed_period,${seconds("updated_at")} FROM maintenance_state_legacy")
            db.execSQL("INSERT OR REPLACE INTO openrouter_weekly(week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price) SELECT window_start,window_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price FROM openrouter_weekly_legacy")
            tables.forEach { db.execSQL("DROP TABLE ${it}_legacy") }
        }
        ensureCanonicalColumns(db)
        createCanonicalSchema(db)
        db.execSQL("INSERT OR IGNORE INTO statistics_state(id,last_statistics_at,dirty_from_date,updated_at) VALUES(1,0,NULL,strftime('%s','now'))")
        db.execSQL("UPDATE openrouter_weekly SET revenue=CASE WHEN prompt_tokens>=0 AND completion_tokens>=0 AND prompt_price IS NOT NULL AND completion_price IS NOT NULL THEN prompt_tokens*prompt_price+completion_tokens*completion_price ELSE NULL END WHERE revenue IS NULL")
        db.execSQL("UPDATE openrouter_weekly SET updated_at=strftime('%s','now') WHERE updated_at=0")
    }

    private fun prepareLegacyTables(db: SQLiteDatabase, oldVersion: Int) {
        db.execSQL("CREATE TABLE IF NOT EXISTS bitmap(device_id TEXT NOT NULL,utc_date TEXT NOT NULL,bits BLOB NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(device_id,utc_date))")
        db.execSQL("CREATE TABLE IF NOT EXISTS device(device_id TEXT PRIMARY KEY,name TEXT NOT NULL,kind TEXT NOT NULL,updated_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS incremental_download_cursor(remote_device_id TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS incremental_upload_cursor(sync_target TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS reminder_state(device_id TEXT PRIMARY KEY,last_eye_at INTEGER NOT NULL,last_posture_at INTEGER NOT NULL,last_reminder TEXT,updated_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS sync_state(device_id TEXT PRIMARY KEY,last_quick_upload_at INTEGER NOT NULL DEFAULT 0,last_quick_bidirectional_at INTEGER NOT NULL DEFAULT 0,last_incremental_sync_at INTEGER NOT NULL DEFAULT 0,last_statistics_at INTEGER NOT NULL DEFAULT 0,last_weekly_action_at INTEGER NOT NULL DEFAULT 0,last_yearly_action_at INTEGER NOT NULL DEFAULT 0,last_posture_at INTEGER NOT NULL DEFAULT 0,last_eye_at INTEGER NOT NULL DEFAULT 0,bitmap_updated_at INTEGER NOT NULL DEFAULT 0,continuous_minutes INTEGER NOT NULL DEFAULT 0,local_daily_minutes INTEGER NOT NULL DEFAULT 0,aggregate_daily_minutes INTEGER NOT NULL DEFAULT 0,state_local_date TEXT)")
        db.execSQL("CREATE TABLE IF NOT EXISTS pending_quick_upload(device_id TEXT NOT NULL,utc_date TEXT NOT NULL,queued_at INTEGER NOT NULL,PRIMARY KEY(device_id,utc_date))")
        db.execSQL("CREATE TABLE IF NOT EXISTS maintenance_state(action TEXT PRIMARY KEY,completed_period TEXT NOT NULL,updated_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS openrouter_weekly(window_start TEXT NOT NULL,window_end TEXT NOT NULL,rank INTEGER NOT NULL,model TEXT NOT NULL,prompt_tokens INTEGER NOT NULL,completion_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,prompt_price REAL,completion_price REAL,revenue REAL,updated_at INTEGER NOT NULL,PRIMARY KEY(window_start,model))")
        if (oldVersion == 4) {
            runCatching { db.execSQL("ALTER TABLE openrouter_weekly ADD COLUMN total_tokens INTEGER NOT NULL DEFAULT 0") }
            db.execSQL("UPDATE openrouter_weekly SET total_tokens=prompt_tokens+completion_tokens WHERE total_tokens=0")
        }
    }

    private fun createCanonicalSchema(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE IF NOT EXISTS bitmap(device_id TEXT NOT NULL,utc_date TEXT NOT NULL,bits BLOB NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(device_id,utc_date))")
        db.execSQL("CREATE TABLE IF NOT EXISTS device(device_id TEXT PRIMARY KEY,name TEXT NOT NULL,kind TEXT NOT NULL,updated_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS reminder_state(device_id TEXT PRIMARY KEY,last_eye_at INTEGER NOT NULL,last_posture_at INTEGER NOT NULL,last_reminder TEXT,updated_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS sync_state(device_id TEXT PRIMARY KEY,last_quick_upload_at INTEGER NOT NULL DEFAULT 0,last_quick_bidirectional_at INTEGER NOT NULL DEFAULT 0,last_incremental_sync_at INTEGER NOT NULL DEFAULT 0,last_statistics_at INTEGER NOT NULL DEFAULT 0,last_weekly_action_at INTEGER NOT NULL DEFAULT 0,last_yearly_action_at INTEGER NOT NULL DEFAULT 0,last_posture_at INTEGER NOT NULL DEFAULT 0,last_eye_at INTEGER NOT NULL DEFAULT 0,bitmap_updated_at INTEGER NOT NULL DEFAULT 0,continuous_minutes INTEGER NOT NULL DEFAULT 0,local_daily_minutes INTEGER NOT NULL DEFAULT 0,aggregate_daily_minutes INTEGER NOT NULL DEFAULT 0,state_local_date TEXT)")
        db.execSQL("CREATE TABLE IF NOT EXISTS pending_quick_upload(device_id TEXT NOT NULL,utc_date TEXT NOT NULL,queued_at INTEGER NOT NULL,PRIMARY KEY(device_id,utc_date))")
        db.execSQL("CREATE TABLE IF NOT EXISTS incremental_download_cursor(remote_device_id TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS incremental_upload_cursor(sync_target TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS maintenance_state(action TEXT PRIMARY KEY,completed_at TEXT NOT NULL,updated_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS statistics_state(id INTEGER PRIMARY KEY CHECK(id=1),last_statistics_at INTEGER NOT NULL DEFAULT 0,dirty_from_date TEXT,updated_at INTEGER NOT NULL DEFAULT 0)")
        db.execSQL("CREATE TABLE IF NOT EXISTS daily_statistics(device_id TEXT NOT NULL,report_date TEXT NOT NULL,minutes INTEGER NOT NULL,daily_limit_minutes INTEGER NOT NULL,source_updated_at INTEGER NOT NULL,calculated_at INTEGER NOT NULL,estimated INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(device_id,report_date))")
        db.execSQL("CREATE TABLE IF NOT EXISTS weekly_statistics(device_id TEXT NOT NULL,iso_year INTEGER NOT NULL,iso_week INTEGER NOT NULL,period_start TEXT NOT NULL,period_end TEXT NOT NULL,average_daily_minutes REAL NOT NULL,included_days INTEGER NOT NULL,excluded_days INTEGER NOT NULL,calculated_at INTEGER NOT NULL,estimated INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(device_id,iso_year,iso_week))")
        db.execSQL("CREATE TABLE IF NOT EXISTS monthly_statistics(device_id TEXT NOT NULL,year INTEGER NOT NULL,month INTEGER NOT NULL,period_start TEXT NOT NULL,period_end TEXT NOT NULL,average_daily_minutes REAL NOT NULL,included_days INTEGER NOT NULL,excluded_days INTEGER NOT NULL,calculated_at INTEGER NOT NULL,estimated INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(device_id,year,month))")
        db.execSQL("CREATE TABLE IF NOT EXISTS yearly_statistics(device_id TEXT NOT NULL,year INTEGER NOT NULL,period_start TEXT NOT NULL,period_end TEXT NOT NULL,average_daily_minutes REAL NOT NULL,included_days INTEGER NOT NULL,excluded_days INTEGER NOT NULL,calculated_at INTEGER NOT NULL,estimated INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(device_id,year))")
        db.execSQL("CREATE TABLE IF NOT EXISTS openrouter_weekly(week_start TEXT NOT NULL,week_end TEXT NOT NULL,model TEXT NOT NULL,rank INTEGER NOT NULL,prompt_tokens INTEGER NOT NULL,completion_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,prompt_price REAL,completion_price REAL,revenue REAL,as_of TEXT,missing_dates TEXT NOT NULL DEFAULT '[]',is_complete INTEGER NOT NULL DEFAULT 1,updated_at INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(week_start,model))")
        db.execSQL("CREATE TABLE IF NOT EXISTS archive_manifest(archive_id TEXT PRIMARY KEY,kind TEXT NOT NULL,period_start TEXT NOT NULL,period_end TEXT NOT NULL,local_path TEXT,cloud_path TEXT,checksum TEXT,created_at INTEGER NOT NULL,uploaded_at INTEGER,status TEXT NOT NULL)")
    }

    private fun ensureCanonicalColumns(db: SQLiteDatabase) {
        ensureColumns(db, "sync_state", listOf("last_incremental_sync_at INTEGER NOT NULL DEFAULT 0", "last_statistics_at INTEGER NOT NULL DEFAULT 0", "last_weekly_action_at INTEGER NOT NULL DEFAULT 0", "last_yearly_action_at INTEGER NOT NULL DEFAULT 0", "last_posture_at INTEGER NOT NULL DEFAULT 0", "last_eye_at INTEGER NOT NULL DEFAULT 0", "bitmap_updated_at INTEGER NOT NULL DEFAULT 0", "continuous_minutes INTEGER NOT NULL DEFAULT 0", "local_daily_minutes INTEGER NOT NULL DEFAULT 0", "aggregate_daily_minutes INTEGER NOT NULL DEFAULT 0", "state_local_date TEXT"))
        ensureColumns(db, "openrouter_weekly", listOf("revenue REAL", "as_of TEXT", "missing_dates TEXT NOT NULL DEFAULT '[]'", "is_complete INTEGER NOT NULL DEFAULT 1", "updated_at INTEGER NOT NULL DEFAULT 0"))
    }

    private fun ensureColumns(db: SQLiteDatabase, table: String, definitions: List<String>) {
        val existing = mutableSetOf<String>()
        db.rawQuery("PRAGMA table_info($table)", null).use { cursor -> while (cursor.moveToNext()) existing += cursor.getString(1) }
        definitions.forEach { definition ->
            val name = definition.substringBefore(' ')
            if (name !in existing) db.execSQL("ALTER TABLE $table ADD COLUMN $definition")
        }
    }

    private fun importTemplateHistoryIfNeeded(db: SQLiteDatabase) {
        val imported = db.rawQuery("PRAGMA application_id", null).use { it.moveToFirst() && it.getInt(0) == STG_APPLICATION_ID }
        val missingSeedMetadata = db.rawQuery("SELECT COUNT(*) FROM openrouter_weekly WHERE prompt_tokens<0 AND as_of IS NULL", null).use { it.moveToFirst() && it.getLong(0) > 0 }
        if (imported && !missingSeedMetadata) return
        val template = java.io.File(appContext.cacheDir, "stg-template.sqlite")
        appContext.assets.open("stg.sqlite").use { input -> template.outputStream().use { output -> input.copyTo(output) } }
        var attached = false
        try {
            db.execSQL("ATTACH DATABASE ? AS bundled_seed", arrayOf(template.path))
            attached = true
            db.beginTransaction()
            try {
                db.execSQL("INSERT OR IGNORE INTO openrouter_weekly(week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete,updated_at) SELECT week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete,updated_at FROM bundled_seed.openrouter_weekly")
                db.execSQL("UPDATE openrouter_weekly SET as_of=(SELECT seed.as_of FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model),missing_dates=(SELECT seed.missing_dates FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model),is_complete=(SELECT seed.is_complete FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model),updated_at=MAX(updated_at,COALESCE((SELECT seed.updated_at FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model),0)) WHERE prompt_tokens<0 AND as_of IS NULL AND EXISTS(SELECT 1 FROM bundled_seed.openrouter_weekly seed WHERE seed.week_start=openrouter_weekly.week_start AND seed.model=openrouter_weekly.model)")
                db.setTransactionSuccessful()
            } finally { db.endTransaction() }
            db.execSQL("PRAGMA application_id=$STG_APPLICATION_ID")
        } finally {
            if (attached) runCatching { db.execSQL("DETACH DATABASE bundled_seed") }
            template.delete()
        }
    }

    private fun normalizeSeconds(value: Long): Long = if (kotlin.math.abs(value) >= 100_000_000_000L) value / 1000 else value
    private fun nowSeconds(): Long = Instant.now().epochSecond

    private fun ensureSyncState(db: SQLiteDatabase, deviceID: String) {
        db.execSQL("INSERT OR IGNORE INTO sync_state(device_id) VALUES(?)", arrayOf<Any>(deviceID))
    }

    private fun ensureStatisticsState(db: SQLiteDatabase) {
        db.execSQL("INSERT OR IGNORE INTO statistics_state(id,last_statistics_at,dirty_from_date,updated_at) VALUES(1,0,NULL,0)")
    }

    @Synchronized fun exportDatabaseSnapshot(destination: java.io.File) {
        writableDatabase.rawQuery("PRAGMA wal_checkpoint(FULL)", null).use { while (it.moveToNext()) { } }
        appContext.getDatabasePath("stg.sqlite").copyTo(destination, overwrite = true)
    }

    @Synchronized fun bitmap(deviceID: String, utcDate: String): MinuteBitmap {
        readableDatabase.query("bitmap", arrayOf("bits"), "device_id=? AND utc_date=?", arrayOf(deviceID, utcDate), null, null, null).use { if (it.moveToFirst()) return MinuteBitmap(it.getBlob(0)) }
        return MinuteBitmap()
    }
    @Synchronized fun storedBitmap(deviceID: String, utcDate: String): AndroidStoredBitmap? {
        readableDatabase.query("bitmap", arrayOf("bits", "updated_at"), "device_id=? AND utc_date=?", arrayOf(deviceID, utcDate), null, null, null).use {
            if (!it.moveToFirst()) return null
            return AndroidStoredBitmap(MinuteBitmap(it.getBlob(0)), normalizeSeconds(it.getLong(1)))
        }
    }
    @Synchronized fun mark(deviceID: String, instant: Instant): Boolean {
        val date = TimeModel.utcDate(instant); val bitmap = bitmap(deviceID, date); val changed = bitmap.mark(TimeModel.utcMinute(instant)); if (changed) upsert(deviceID, date, bitmap, instant.epochSecond); return changed
    }
    @Synchronized fun upsert(deviceID: String, date: String, bitmap: MinuteBitmap, updatedAt: Long = nowSeconds()) {
        val values = ContentValues().apply { put("device_id", deviceID); put("utc_date", date); put("bits", bitmap.data); put("updated_at", normalizeSeconds(updatedAt)) }
        writableDatabase.insertWithOnConflict("bitmap", null, values, SQLiteDatabase.CONFLICT_REPLACE)
        markStatisticsDirty(date, normalizeSeconds(updatedAt))
        if (deviceID != "alldevices") {
            val db = writableDatabase; ensureSyncState(db, deviceID)
            db.execSQL("UPDATE sync_state SET bitmap_updated_at=MAX(bitmap_updated_at,?) WHERE device_id=?", arrayOf<Any>(normalizeSeconds(updatedAt), deviceID))
        }
    }

    private fun markStatisticsDirty(date: String, updatedAt: Long) {
        val db = writableDatabase; ensureStatisticsState(db)
        db.execSQL("UPDATE statistics_state SET dirty_from_date=CASE WHEN dirty_from_date IS NULL OR ?<dirty_from_date THEN ? ELSE dirty_from_date END,updated_at=? WHERE id=1", arrayOf<Any>(date, date, updatedAt))
    }
    @Synchronized fun upsertIfNewer(deviceID: String, date: String, bitmap: MinuteBitmap, updatedAt: Long) {
        val normalized = normalizeSeconds(updatedAt)
        val existing = readableDatabase.query("bitmap", arrayOf("updated_at"), "device_id=? AND utc_date=?", arrayOf(deviceID, date), null, null, null).use { if (it.moveToFirst()) it.getLong(0) else Long.MIN_VALUE }
        if (normalized >= existing) upsert(deviceID, date, bitmap, normalized)
    }
    @Synchronized fun mergeBitmap(deviceID: String, date: String, bitmap: MinuteBitmap, updatedAt: Long) {
        val stored = storedBitmap(deviceID, date)
        val merged = stored?.bitmap ?: MinuteBitmap()
        merged.union(bitmap)
        upsert(deviceID, date, merged, maxOf(stored?.updatedAt ?: Long.MIN_VALUE, normalizeSeconds(updatedAt)))
    }
    @Synchronized fun upsertDevice(record: AndroidDeviceRecord) {
        val values = ContentValues().apply { put("device_id", record.id); put("name", record.name); put("kind", record.kind); put("updated_at", normalizeSeconds(record.updatedAt)) }
        writableDatabase.insertWithOnConflict("device", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }
    @Synchronized fun devices(): Map<String, AndroidDeviceRecord> {
        val result = linkedMapOf<String, AndroidDeviceRecord>(); readableDatabase.query("device", arrayOf("device_id", "name", "kind", "updated_at"), null, null, null, null, "name COLLATE NOCASE,device_id").use { while (it.moveToNext()) result[it.getString(0)] = AndroidDeviceRecord(it.getString(0), it.getString(1), it.getString(2), it.getLong(3)) }; return result
    }
    @Synchronized fun deviceIDs(): List<String> { val result = mutableListOf<String>(); readableDatabase.rawQuery("SELECT DISTINCT device_id FROM bitmap WHERE device_id<>'alldevices' ORDER BY device_id", null).use { while (it.moveToNext()) result += it.getString(0) }; return result }
    @Synchronized fun rebuildAll(date: String): MinuteBitmap { val result = MinuteBitmap(); readableDatabase.query("bitmap", arrayOf("bits"), "device_id<>? AND utc_date=?", arrayOf("alldevices", date), null, null, null).use { while (it.moveToNext()) result.union(MinuteBitmap(it.getBlob(0))) }; upsert("alldevices", date, result); return result }
    fun localDayMinutes(deviceID: String, instant: Instant, zoneID: String): Int = TimeModel.localDayInstants(instant, zoneID).count { bitmap(deviceID, TimeModel.utcDate(it))[TimeModel.utcMinute(it)] }
    fun localClockDayBitmap(deviceID: String, instant: Instant, zoneID: String): BooleanArray { val result = BooleanArray(1440); TimeModel.localDayInstants(instant, zoneID).forEach { if (bitmap(deviceID, TimeModel.utcDate(it))[TimeModel.utcMinute(it)]) result[TimeModel.localClockMinute(it, zoneID)] = true }; return result }
    @Synchronized fun incrementalDownloadCursor(remoteDeviceID: String): String? = readableDatabase.query("incremental_download_cursor", arrayOf("latest_utc_date"), "remote_device_id=?", arrayOf(remoteDeviceID), null, null, null).use { if (it.moveToFirst()) it.getString(0) else null }
    @Synchronized fun saveIncrementalDownloadCursor(remoteDeviceID: String, date: String) {
        val current = incrementalDownloadCursor(remoteDeviceID); val latest = if (current == null || date > current) date else current
        val values = ContentValues().apply { put("remote_device_id", remoteDeviceID); put("latest_utc_date", latest); put("updated_at", nowSeconds()) }
        writableDatabase.insertWithOnConflict("incremental_download_cursor", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }
    @Synchronized fun incrementalUploadCursor(syncTarget: String): String? = readableDatabase.query("incremental_upload_cursor", arrayOf("latest_utc_date"), "sync_target=?", arrayOf(syncTarget), null, null, null).use { if (it.moveToFirst()) it.getString(0) else null }
    @Synchronized fun saveIncrementalUploadCursor(syncTarget: String, date: String) {
        val current = incrementalUploadCursor(syncTarget); val latest = if (current == null || date > current) date else current
        val values = ContentValues().apply { put("sync_target", syncTarget); put("latest_utc_date", latest); put("updated_at", nowSeconds()) }
        writableDatabase.insertWithOnConflict("incremental_upload_cursor", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    @Synchronized fun loadReminderState(deviceID: String): AndroidReminderState = readableDatabase.query("reminder_state", arrayOf("last_eye_at", "last_posture_at", "last_reminder", "updated_at"), "device_id=?", arrayOf(deviceID), null, null, null).use { if (it.moveToFirst()) AndroidReminderState(it.getLong(0), it.getLong(1), if (it.isNull(2)) null else it.getString(2), normalizeSeconds(it.getLong(3))) else AndroidReminderState() }
    @Synchronized fun saveReminderState(deviceID: String, state: AndroidReminderState) {
        val values = ContentValues().apply { put("device_id", deviceID); put("last_eye_at", state.lastEyeAt); put("last_posture_at", state.lastPostureAt); put("last_reminder", state.lastReminder); put("updated_at", nowSeconds()) }
        writableDatabase.insertWithOnConflict("reminder_state", null, values, SQLiteDatabase.CONFLICT_REPLACE)
        val db = writableDatabase; ensureSyncState(db, deviceID)
        db.execSQL("UPDATE sync_state SET last_eye_at=?,last_posture_at=? WHERE device_id=?", arrayOf<Any>(state.lastEyeAt, state.lastPostureAt, deviceID))
    }

    @Synchronized fun updateRuntimeState(deviceID: String, continuousMinutes: Int, localDailyMinutes: Int, aggregateDailyMinutes: Int, localDate: String, updatedAt: Long = nowSeconds()) {
        val db = writableDatabase; ensureSyncState(db, deviceID)
        db.execSQL("UPDATE sync_state SET continuous_minutes=?,local_daily_minutes=?,aggregate_daily_minutes=?,state_local_date=?,bitmap_updated_at=MAX(bitmap_updated_at,?) WHERE device_id=?", arrayOf<Any>(continuousMinutes.coerceAtLeast(0), localDailyMinutes.coerceAtLeast(0), aggregateDailyMinutes.coerceAtLeast(0), localDate, normalizeSeconds(updatedAt), deviceID))
    }

    @Synchronized fun latestOpenRouterWeekEnd(): String? = readableDatabase.rawQuery("SELECT MAX(week_end) FROM openrouter_weekly", null).use { if (it.moveToFirst() && !it.isNull(0)) it.getString(0) else null }
    @Synchronized fun latestOpenRouterDetailWeekEnd(): String? = readableDatabase.query("maintenance_state", arrayOf("completed_at"), "action=?", arrayOf("openrouter_detail"), null, null, null).use { if (it.moveToFirst()) it.getString(0) else null }
    @Synchronized fun saveOpenRouterWeeks(rows: List<WeeklyRankingRow>) {
        val db = writableDatabase; db.beginTransaction()
        try { rows.forEach { row -> db.execSQL("INSERT OR REPLACE INTO openrouter_weekly(week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)", arrayOf<Any?>(row.weekStart.toString(), row.weekEnd.toString(), row.model, row.rank, row.promptTokens, row.completionTokens, row.totalTokens, row.promptPrice, row.completionPrice, row.revenue, row.asOf ?: row.weekEnd.toString(), org.json.JSONArray(row.missingDates).toString(), if (row.isComplete) 1 else 0, nowSeconds())) }; db.setTransactionSuccessful() } finally { db.endTransaction() }
    }
    @Synchronized fun latestOpenRouterTopModels(metric: String, limit: Int = 10): List<String> {
        val (requirement, order) = when (metric) {
            "Rank" -> "1=1" to "rank ASC"; "Input tokens" -> "prompt_tokens>=0" to "prompt_tokens DESC, rank ASC"; "Output tokens" -> "completion_tokens>=0" to "completion_tokens DESC, rank ASC"; "Input price / M" -> "prompt_price IS NOT NULL" to "prompt_price DESC, rank ASC"; "Output price / M" -> "completion_price IS NOT NULL" to "completion_price DESC, rank ASC"; "Estimated Revenue" -> "prompt_tokens>=0 AND completion_tokens>=0 AND prompt_price IS NOT NULL AND completion_price IS NOT NULL" to "(prompt_tokens*prompt_price+completion_tokens*completion_price) DESC, rank ASC"; else -> "total_tokens>=0" to "total_tokens DESC, rank ASC"
        }
        val result = mutableListOf<String>(); readableDatabase.rawQuery("SELECT model FROM openrouter_weekly WHERE week_start=(SELECT MAX(week_start) FROM openrouter_weekly) AND $requirement ORDER BY $order, model ASC LIMIT ?", arrayOf(limit.toString())).use { while (it.moveToNext()) result += it.getString(0) }; return result
    }
    @Synchronized fun openRouterWeeks(models: List<String>): List<WeeklyRankingRow> {
        if (models.isEmpty()) return emptyList(); val marks = models.joinToString(",") { "?" }; val result = mutableListOf<WeeklyRankingRow>()
        readableDatabase.rawQuery("SELECT week_start,week_end,rank,model,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete FROM openrouter_weekly WHERE model IN ($marks) ORDER BY week_start,rank", models.toTypedArray()).use { while (it.moveToNext()) { val promptPrice = if (it.isNull(7)) null else it.getDouble(7); val completionPrice = if (it.isNull(8)) null else it.getDouble(8); val revenue = if (it.isNull(9)) null else it.getDouble(9); result += WeeklyRankingRow(java.time.LocalDate.parse(it.getString(0)), java.time.LocalDate.parse(it.getString(1)), it.getInt(2), it.getString(3), it.getLong(4), it.getLong(5), it.getLong(6), promptPrice, completionPrice, revenue, if (it.isNull(10)) null else it.getString(10), if (it.isNull(11)) emptyList() else jsonStringList(it.getString(11)), it.getInt(12) != 0) } }; return result
    }
    @Synchronized fun weeklyActionCompletedPeriod(): String? = readableDatabase.query("maintenance_state", arrayOf("completed_at"), "action=?", arrayOf("weekly"), null, null, null).use { if (it.moveToFirst()) it.getString(0) else null }
    @Synchronized fun completeWeeklyAction(period: String) { writableDatabase.execSQL("INSERT OR REPLACE INTO maintenance_state(action,completed_at,updated_at) VALUES('weekly',?,?)", arrayOf<Any>(period, nowSeconds())) }
    @Synchronized fun completeOpenRouterDetailWeek(period: String) { writableDatabase.execSQL("INSERT OR REPLACE INTO maintenance_state(action,completed_at,updated_at) VALUES('openrouter_detail',?,?)", arrayOf<Any>(period, nowSeconds())) }
    @Synchronized fun completeIncrementalSync(deviceID: String) { updateSyncTime(deviceID, "last_incremental_sync_at") }
    @Synchronized fun lastIncrementalSync(deviceID: String): Long? = readableDatabase.query("sync_state", arrayOf("last_incremental_sync_at"), "device_id=?", arrayOf(deviceID), null, null, null).use { if (it.moveToFirst() && it.getLong(0) > 0) it.getLong(0) else null }
    @Synchronized fun completeQuickUpload(deviceID: String) { updateSyncTime(deviceID, "last_quick_upload_at") }
    @Synchronized fun completeYearlyAction(deviceID: String) { updateSyncTime(deviceID, "last_yearly_action_at") }
    @Synchronized fun completeWeeklyActionState(deviceID: String) { updateSyncTime(deviceID, "last_weekly_action_at") }
    private fun updateSyncTime(deviceID: String, field: String) {
        require(field in setOf("last_incremental_sync_at", "last_quick_upload_at", "last_weekly_action_at", "last_yearly_action_at"))
        val db = writableDatabase; ensureSyncState(db, deviceID)
        db.execSQL("UPDATE sync_state SET $field=? WHERE device_id=?", arrayOf<Any>(nowSeconds(), deviceID))
    }

    @Synchronized fun bitmapArchive(deviceID: String, start: java.time.LocalDate, end: java.time.LocalDate): List<AndroidBitmapArchiveRow> {
        val result = mutableListOf<AndroidBitmapArchiveRow>()
        readableDatabase.rawQuery("SELECT utc_date,bits,updated_at FROM bitmap WHERE device_id=? AND utc_date>=? AND utc_date<=? ORDER BY utc_date", arrayOf(deviceID, start.toString(), end.toString())).use { cursor -> while (cursor.moveToNext()) result += AndroidBitmapArchiveRow(deviceID, cursor.getString(0), MinuteBitmap(cursor.getBlob(1)).base64(), cursor.getLong(2)) }
        return result
    }

    @Synchronized fun deleteBitmapRows(deviceID: String, start: java.time.LocalDate, end: java.time.LocalDate): Int = writableDatabase.delete("bitmap", "device_id IN (?,'alldevices') AND utc_date>=? AND utc_date<=?", arrayOf(deviceID, start.toString(), end.toString()))

    @Synchronized fun openRouterArchive(year: Int): List<WeeklyRankingRow> {
        val result = mutableListOf<WeeklyRankingRow>(); readableDatabase.rawQuery("SELECT week_start,week_end,rank,model,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete FROM openrouter_weekly WHERE week_start>=? AND week_start<=? ORDER BY week_start,rank", arrayOf("%04d-01-01".format(year), "%04d-12-31".format(year))).use { cursor -> while (cursor.moveToNext()) result += WeeklyRankingRow(java.time.LocalDate.parse(cursor.getString(0)), java.time.LocalDate.parse(cursor.getString(1)), cursor.getInt(2), cursor.getString(3), cursor.getLong(4), cursor.getLong(5), cursor.getLong(6), if (cursor.isNull(7)) null else cursor.getDouble(7), if (cursor.isNull(8)) null else cursor.getDouble(8), if (cursor.isNull(9)) null else cursor.getDouble(9), if (cursor.isNull(10)) null else cursor.getString(10), if (cursor.isNull(11)) emptyList() else jsonStringList(cursor.getString(11)), cursor.getInt(12) != 0) }; return result
    }

    private fun jsonStringList(value: String): List<String> = runCatching { val values = org.json.JSONArray(value); (0 until values.length()).map { values.getString(it) } }.getOrDefault(emptyList())

    @Synchronized fun deleteOpenRouterWeeks(throughYear: Int): Int = writableDatabase.delete("openrouter_weekly", "week_start<=?", arrayOf("%04d-12-31".format(throughYear)))

    @Synchronized fun yearlyActionDue(deviceID: String, now: Instant = Instant.now()): Boolean {
        val last = readableDatabase.query("sync_state", arrayOf("last_yearly_action_at"), "device_id=?", arrayOf(deviceID), null, null, null).use { if (it.moveToFirst()) it.getLong(0) else 0L }
        return last == 0L || Instant.ofEpochSecond(last).atZone(java.time.ZoneOffset.UTC).year < now.atZone(java.time.ZoneOffset.UTC).year
    }

    @Synchronized fun recordArchive(id: String, kind: String, start: java.time.LocalDate, end: java.time.LocalDate, cloudPath: String, status: String = "uploaded") {
        writableDatabase.execSQL("INSERT OR REPLACE INTO archive_manifest(archive_id,kind,period_start,period_end,cloud_path,created_at,uploaded_at,status) VALUES(?,?,?,?,?,?,?,?)", arrayOf<Any>(id, kind, start.toString(), end.toString(), cloudPath, nowSeconds(), nowSeconds(), status))
    }

    @Synchronized fun refreshStatistics(settings: AppSettings, now: Instant = Instant.now()): Pair<java.time.LocalDate, java.time.LocalDate> {
        val zone = runCatching { java.time.ZoneId.of(settings.reportTimeZone) }.getOrDefault(java.time.ZoneId.systemDefault())
        val end = now.atZone(zone).toLocalDate(); migratePeriodAverages(end.toString()); var last = 0L; var dirty: String? = null
        readableDatabase.rawQuery("SELECT last_statistics_at,dirty_from_date FROM statistics_state WHERE id=1", null).use { if (it.moveToFirst()) { last = it.getLong(0); dirty = if (it.isNull(1)) null else it.getString(1) } }
        val candidates = mutableListOf<java.time.LocalDate>()
        if (last > 0) candidates += Instant.ofEpochSecond(last).atZone(zone).toLocalDate()
        dirty?.let { value -> runCatching { java.time.LocalDate.parse(value).minusDays(1) }.getOrNull()?.let(candidates::add) }
        if (candidates.isEmpty()) readableDatabase.rawQuery("SELECT MIN(utc_date) FROM bitmap WHERE device_id<>'alldevices'", null).use { if (it.moveToFirst() && !it.isNull(0)) candidates += java.time.LocalDate.parse(it.getString(0)).minusDays(1) }
        var start = candidates.minOrNull() ?: end; if (start.isAfter(end)) start = end
        upsertDevice(AndroidDeviceRecord(settings.deviceID, settings.deviceName, "android", settings.updatedAt))
        val records = devices(); val ids = (deviceIDs() + settings.deviceID).distinct().sorted(); val reportIDs = listOf("alldevices") + ids
        val iosIDs = records.values.filter { it.kind.equals("ios", true) }.map { it.id }.toSet(); val aggregateEstimated = ids.any(iosIDs::contains)
        val weeks = linkedSetOf<Pair<Int, Int>>(); val months = linkedSetOf<Pair<Int, Int>>(); val years = linkedSetOf<Int>(); val weekFields = java.time.temporal.WeekFields.ISO
        var date = start
        while (!date.isAfter(end)) {
            val instant = TimeModel.localDateInstant(date, settings.reportTimeZone); val utcDates = TimeModel.localDayInstants(instant, settings.reportTimeZone).map(TimeModel::utcDate).distinct().toList()
            utcDates.forEach(::rebuildAll)
            reportIDs.forEach { id ->
                val minutes = localDayMinutes(id, instant, settings.reportTimeZone)
                val sourceUpdated = utcDates.mapNotNull { storedBitmap(id, it)?.updatedAt }.maxOrNull() ?: 0
                val values = ContentValues().apply { put("device_id", id); put("report_date", date.toString()); put("minutes", minutes); put("daily_limit_minutes", settings.dailyPlanMinutes.coerceAtLeast(1)); put("source_updated_at", sourceUpdated); put("calculated_at", now.epochSecond); put("estimated", if (id == "alldevices") if (aggregateEstimated) 1 else 0 else if (iosIDs.contains(id)) 1 else 0) }
                writableDatabase.insertWithOnConflict("daily_statistics", null, values, SQLiteDatabase.CONFLICT_REPLACE)
            }
            weeks += date.get(weekFields.weekBasedYear()) to date.get(weekFields.weekOfWeekBasedYear()); months += date.year to date.monthValue; years += date.year; date = date.plusDays(1)
        }
        weeks.forEach { (year, week) -> val monday = java.time.LocalDate.of(year, 1, 4).with(weekFields.weekOfWeekBasedYear(), week.toLong()).with(java.time.DayOfWeek.MONDAY); reportIDs.forEach { rebuildPeriod("weekly_statistics", it, monday, monday.plusDays(6), year, week, now.epochSecond, end.toString()) } }
        months.forEach { (year, month) -> val first = java.time.LocalDate.of(year, month, 1); reportIDs.forEach { rebuildPeriod("monthly_statistics", it, first, first.with(java.time.temporal.TemporalAdjusters.lastDayOfMonth()), year, month, now.epochSecond, end.toString()) } }
        years.forEach { year -> reportIDs.forEach { rebuildPeriod("yearly_statistics", it, java.time.LocalDate.of(year, 1, 1), java.time.LocalDate.of(year, 12, 31), year, null, now.epochSecond, end.toString()) } }
        ensureStatisticsState(writableDatabase)
        writableDatabase.execSQL("UPDATE statistics_state SET last_statistics_at=?,dirty_from_date=NULL,updated_at=? WHERE id=1", arrayOf<Any>(now.epochSecond, now.epochSecond))
        ensureSyncState(writableDatabase, settings.deviceID)
        writableDatabase.execSQL("UPDATE sync_state SET last_statistics_at=? WHERE device_id=?", arrayOf<Any>(now.epochSecond, settings.deviceID))
        return start to end
    }

    @Synchronized fun statisticsSummary(settings: AppSettings, now: Instant = Instant.now()): AndroidStatisticsSummary {
        val zone = runCatching { java.time.ZoneId.of(settings.reportTimeZone) }.getOrDefault(java.time.ZoneId.systemDefault()); val date = now.atZone(zone).toLocalDate(); val previousWeek = date.minusWeeks(1); val previousMonth = date.minusMonths(1); val wf = java.time.temporal.WeekFields.ISO
        return AndroidStatisticsSummary(periodAverage("weekly_statistics", date.get(wf.weekBasedYear()), date.get(wf.weekOfWeekBasedYear())), periodAverage("weekly_statistics", previousWeek.get(wf.weekBasedYear()), previousWeek.get(wf.weekOfWeekBasedYear())), periodAverage("monthly_statistics", date.year, date.monthValue), periodAverage("monthly_statistics", previousMonth.year, previousMonth.monthValue), periodAverage("yearly_statistics", date.year, null), devices().values.any { it.kind.equals("ios", true) })
    }

    @Synchronized fun periodUsage(kind: String, start: java.time.LocalDate, end: java.time.LocalDate): List<AndroidPeriodUsagePoint> {
        val table = when (kind) { "week" -> "weekly_statistics"; "month" -> "monthly_statistics"; else -> error("Unsupported statistics period") }; val names = devices(); val result = mutableListOf<AndroidPeriodUsagePoint>()
        readableDatabase.rawQuery("SELECT device_id,period_start,period_end,average_daily_minutes,included_days,excluded_days,estimated FROM $table WHERE period_end>=? AND period_start<=? ORDER BY period_start,device_id", arrayOf(start.toString(), end.toString())).use { cursor -> while (cursor.moveToNext()) { val id = cursor.getString(0); val from = cursor.getString(1); val through = cursor.getString(2); result += AndroidPeriodUsagePoint(kind, if (kind == "week") "$from – $through" else from.take(7), from, through, id, if (id == "alldevices") "All devices" else names[id]?.name ?: "Other device", cursor.getDouble(3), cursor.getInt(4), cursor.getInt(5), cursor.getInt(6) != 0) } }
        return result
    }

    @Synchronized fun dailyStatistics(start: java.time.LocalDate, end: java.time.LocalDate): List<AndroidDailyStatistic> {
        val names = devices(); val result = mutableListOf<AndroidDailyStatistic>()
        readableDatabase.rawQuery("SELECT device_id,report_date,minutes,estimated FROM daily_statistics WHERE report_date>=? AND report_date<=? ORDER BY report_date,device_id", arrayOf(start.toString(), end.toString())).use { cursor -> while (cursor.moveToNext()) { val id = cursor.getString(0); result += AndroidDailyStatistic(java.time.LocalDate.parse(cursor.getString(1)), id, if (id == "alldevices") "All devices" else names[id]?.name ?: "Other device", cursor.getInt(2), id == "alldevices", cursor.getInt(3) != 0) } }
        return result
    }

    private fun rebuildPeriod(table: String, deviceID: String, start: java.time.LocalDate, end: java.time.LocalDate, a: Int, b: Int?, now: Long, completedBefore: String) {
        val rows = mutableListOf<Triple<Int, Int, Boolean>>(); readableDatabase.rawQuery("SELECT minutes,daily_limit_minutes,estimated FROM daily_statistics WHERE device_id=? AND report_date>=? AND report_date<=? AND report_date<? ORDER BY report_date", arrayOf(deviceID, start.toString(), end.toString(), completedBefore)).use { while (it.moveToNext()) rows += Triple(it.getInt(0), it.getInt(1), it.getInt(2) != 0) }
        val included = rows.filter { deviceID != "alldevices" || it.first >= it.second * .60 }; val average = if (included.isEmpty()) 0.0 else included.map { it.first }.average(); val args = mutableListOf<Any>(deviceID, a); if (b != null) args.add(b); args.addAll(listOf(start.toString(), end.toString(), average, included.size, rows.size - included.size, now, if (rows.any { it.third }) 1 else 0))
        val sql = when (table) { "weekly_statistics" -> "INSERT OR REPLACE INTO weekly_statistics(device_id,iso_year,iso_week,period_start,period_end,average_daily_minutes,included_days,excluded_days,calculated_at,estimated) VALUES(?,?,?,?,?,?,?,?,?,?)"; "monthly_statistics" -> "INSERT OR REPLACE INTO monthly_statistics(device_id,year,month,period_start,period_end,average_daily_minutes,included_days,excluded_days,calculated_at,estimated) VALUES(?,?,?,?,?,?,?,?,?,?)"; else -> "INSERT OR REPLACE INTO yearly_statistics(device_id,year,period_start,period_end,average_daily_minutes,included_days,excluded_days,calculated_at,estimated) VALUES(?,?,?,?,?,?,?,?,?)" }
        writableDatabase.execSQL(sql, args.toTypedArray())
    }

    private fun migratePeriodAverages(completedBefore: String) {
        val db = writableDatabase
        db.execSQL("CREATE TABLE IF NOT EXISTS statistics_rules(version INTEGER PRIMARY KEY)")
        db.rawQuery("SELECT 1 FROM statistics_rules WHERE version=2", null).use { if (it.moveToFirst()) return }
        db.beginTransaction()
        try {
            for (table in listOf("weekly_statistics", "monthly_statistics", "yearly_statistics")) {
                db.execSQL("""
                    UPDATE $table SET
                    average_daily_minutes=COALESCE((SELECT AVG(minutes * 1.0) FROM daily_statistics d WHERE d.device_id=$table.device_id AND d.report_date>=$table.period_start AND d.report_date<=$table.period_end AND d.report_date<?1 AND (d.device_id<>'alldevices' OR d.minutes>=d.daily_limit_minutes*0.60)),0),
                    included_days=(SELECT COUNT(*) FROM daily_statistics d WHERE d.device_id=$table.device_id AND d.report_date>=$table.period_start AND d.report_date<=$table.period_end AND d.report_date<?1 AND (d.device_id<>'alldevices' OR d.minutes>=d.daily_limit_minutes*0.60)),
                    excluded_days=(SELECT COUNT(*) FROM daily_statistics d WHERE d.device_id=$table.device_id AND d.report_date>=$table.period_start AND d.report_date<=$table.period_end AND d.report_date<?1 AND NOT ((d.device_id<>'alldevices' OR d.minutes>=d.daily_limit_minutes*0.60)))
                """.trimIndent(), arrayOf<Any>(completedBefore))
            }
            db.execSQL("INSERT INTO statistics_rules(version) VALUES(2)")
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }

    private fun periodAverage(table: String, a: Int, b: Int?): Double? {
        val sql = when (table) { "weekly_statistics" -> "SELECT average_daily_minutes FROM weekly_statistics WHERE included_days>0 AND device_id='alldevices' AND iso_year=? AND iso_week=?"; "monthly_statistics" -> "SELECT average_daily_minutes FROM monthly_statistics WHERE included_days>0 AND device_id='alldevices' AND year=? AND month=?"; else -> "SELECT average_daily_minutes FROM yearly_statistics WHERE included_days>0 AND device_id='alldevices' AND year=?" }
        return readableDatabase.rawQuery(sql, if (b == null) arrayOf(a.toString()) else arrayOf(a.toString(), b.toString())).use { if (it.moveToFirst()) it.getDouble(0) else null }
    }
}
