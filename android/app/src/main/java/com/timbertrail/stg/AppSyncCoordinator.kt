package com.timbertrail.stg

import android.content.Context
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.temporal.TemporalAdjusters
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

object AppSyncCoordinator {
    private val executor = Executors.newSingleThreadExecutor()
    private val running = AtomicBoolean(false)

    fun request(context: Context, trigger: String, progress: ((String) -> Unit)? = null, completion: ((String) -> Unit)? = null) {
        val appContext = context.applicationContext
        val log = DiagnosticLog.get(appContext)
        if (!running.compareAndSet(false, true)) {
            log.record("sync", "sync request coalesced; trigger=$trigger; another sync is running")
            completion?.invoke("Sync already in progress")
            return
        }
        executor.execute {
            val database = BitmapDatabase(appContext)
            val settings = SettingsStore(appContext).load()
            val message = try {
                if (!PrivateCloudCredentials.isSignedIn(appContext, settings.cloudProvider)) {
                    log.record("sync", "sync skipped; trigger=$trigger; provider=${settings.cloudProvider}; private_cloud_not_configured=true")
                    "Private cloud is not configured"
                } else {
                    log.record("sync", "sync begin; trigger=$trigger; provider=${settings.cloudProvider}; local_device=${settings.deviceID.take(8)}")
                    val providerName = when (settings.cloudProvider) { "onedrive" -> "OneDrive"; "google" -> "Google Drive"; else -> "private cloud" }
                    progress?.invoke("Connecting to $providerName…")
                    val result = RemoteCloudSync(database, settings, PrivateCloudDriveFactory.fromStore(appContext, settings.cloudProvider)).incremental { progress?.invoke(it) }
                    database.completeIncrementalSync(settings.deviceID)
                    val weeklyWarning = runWeeklyActionIfDue(appContext, database, settings, log, progress)
                    val cursors = result.downloadCursors.entries.sortedBy { it.key }.joinToString { "${it.key.take(8)}=${it.value}" }
                    result.warnings.forEach { log.record("sync-warning", it) }
                    log.record("sync", "sync complete; trigger=$trigger; provider=${settings.cloudProvider}; uploaded=${result.uploaded}; downloaded=${result.downloaded}; upload_cursor=${result.uploadCursor ?: "none"}; download_cursors=[$cursors]")
                    "Synced · ${result.uploaded} activity files uploaded, ${result.downloaded} downloaded" + (weeklyWarning?.let { " · $it" } ?: "")
                }
            } catch (error: Exception) {
                log.record("sync", "sync failed; trigger=$trigger; provider=${settings.cloudProvider}; ${error.diagnosticSummary()}")
                "Sync failed: ${error.message}"
            } finally {
                database.close(); running.set(false)
            }
            completion?.invoke(message)
        }
    }

    fun requestQuickUpload(context: Context, trigger: String) {
        val appContext = context.applicationContext; val log = DiagnosticLog.get(appContext)
        if (!running.compareAndSet(false, true)) { log.record("sync", "quick upload covered by running sync; trigger=$trigger"); return }
        executor.execute {
            val database = BitmapDatabase(appContext); val settings = SettingsStore(appContext).load()
            try {
                if (!PrivateCloudCredentials.isSignedIn(appContext, settings.cloudProvider)) log.record("sync", "quick upload skipped; trigger=$trigger; private_cloud_not_configured=true")
                else { log.record("sync", "quick upload begin; trigger=$trigger; provider=${settings.cloudProvider}"); val files = RemoteCloudSync(database, settings, PrivateCloudDriveFactory.fromStore(appContext, settings.cloudProvider)).quickUpload(); log.record("sync", "quick upload complete; trigger=$trigger; files=$files") }
            } catch (error: Exception) { log.record("sync", "quick upload failed; trigger=$trigger; provider=${settings.cloudProvider}; ${error.diagnosticSummary()}") }
            finally { database.close(); running.set(false) }
        }
    }

    private fun runWeeklyActionIfDue(context: Context, database: BitmapDatabase, settings: AppSettings, log: DiagnosticLog, progress: ((String) -> Unit)? = null): String? {
        val today = LocalDate.now(ZoneOffset.UTC)
        val monday = today.with(TemporalAdjusters.previousOrSame(java.time.DayOfWeek.MONDAY))
        val lastSunday = monday.minusDays(1); val period = lastSunday.toString()
        val start = database.latestOpenRouterWeekEnd()?.let(LocalDate::parse)?.plusDays(1) ?: LocalDate.of(2025, 1, 1)
        val cloudDue = database.weeklyActionCompletedPeriod() != period
        val trackingDue = !start.isAfter(lastSunday)
        if (!cloudDue && !trackingDue) return null
        log.record("sync", "weekly action begin; cloud_due=$cloudDue; tracking_due=$trackingDue; openrouter_start=$start; openrouter_end=$lastSunday")
        val warnings = mutableListOf<String>(); var cloudCompleted = false
        if (cloudDue) {
            progress?.invoke("Updating weekly archive…")
            try {
                val maintenance = RemoteCloudSync(database, settings, PrivateCloudDriveFactory.fromStore(context, settings.cloudProvider)).weeklyMaintenance(monday, monday.minusWeeks(1), lastSunday)
                database.completeWeeklyAction(period); database.completeWeeklyActionState(settings.deviceID); cloudCompleted = true
                log.record("sync", "weekly cloud maintenance complete; completed_period=$period; bitmap_uploaded=${maintenance.uploaded}; daily_deleted=${maintenance.deletedDaily}; weekly_moved=${maintenance.movedWeekly}; history_ready=true")
            } catch (error: Exception) {
                warnings += "Weekly archive failed"
                log.record("sync", "weekly cloud maintenance failed; completed_period=$period; completion_not_recorded=true; ${error.diagnosticSummary()}")
            }
        }
        if (trackingDue) {
            progress?.invoke("Updating tracking data…")
            try {
                val rows = OpenRouterClient().weeklyHistory(start, lastSunday)
                check(rows.isNotEmpty()) { "OpenRouter returned no weekly model-activity rows; detail cursor was not advanced" }
                database.saveOpenRouterWeeks(rows); database.completeOpenRouterDetailWeek(period)
                log.record("sync", "weekly tracking complete; openrouter_rows=${rows.size}; completion_recorded=true")
            } catch (error: Exception) {
                warnings += "Tracking update failed"
                log.record("sync", "weekly tracking failed; start=$start; end=$lastSunday; completion_not_recorded=true; ${error.diagnosticSummary()}")
            }
        }
        if (cloudCompleted) runYearlyActionIfDue(context, database, settings, log)
        return warnings.takeIf { it.isNotEmpty() }?.joinToString(" · ")
    }

    private fun runYearlyActionIfDue(context: Context, database: BitmapDatabase, settings: AppSettings, log: DiagnosticLog) {
        if (!database.yearlyActionDue(settings.deviceID)) return
        val year = LocalDate.now(ZoneOffset.UTC).year - 1; val cleanupYear = year - 1
        val rows = OpenRouterClient().weeklyHistory(LocalDate.of(year, 1, 1), LocalDate.of(year, 12, 31)); if (rows.isNotEmpty()) database.saveOpenRouterWeeks(rows)
        val result = RemoteCloudSync(database, settings, PrivateCloudDriveFactory.fromStore(context, settings.cloudProvider)).yearlyMaintenance(year, cleanupYear); database.completeYearlyAction(settings.deviceID)
        log.record("sync", "yearly action complete; year=$year; uploaded=${result.uploaded}; deleted_bitmaps=${result.deletedBitmaps}; deleted_weekly=${result.deletedWeekly}")
    }
}
