package com.timbertrail.stg

import android.app.*
import android.content.*
import android.os.*
import androidx.core.app.NotificationCompat
import java.time.Instant

class UsageMonitorService : Service() {
    private val handler = Handler(Looper.getMainLooper()); private lateinit var database: BitmapDatabase; private lateinit var store: SettingsStore; private lateinit var diagnosticLog: DiagnosticLog
    private var continuous = 0; private var lastEye = 0L; private var lastPosture = 0L; private var lastReminder = "posture"; private var reminderLocalDate = ""
    private var screenAvailable = false
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.action ?: "unknown"
            when (action) {
                Intent.ACTION_SCREEN_OFF -> { diagnosticLog.record("sync", "incremental sync requested; trigger=screen_lock"); AppSyncCoordinator.request(this@UsageMonitorService, "screen_lock") }
                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> if (getSystemService(PowerManager::class.java).isDeviceIdleMode) AppSyncCoordinator.requestQuickUpload(this@UsageMonitorService, "device_idle")
                Intent.ACTION_SHUTDOWN -> AppSyncCoordinator.requestQuickUpload(this@UsageMonitorService, "shutdown")
            }
            updateScreenAvailability("broadcast:$action")
        }
    }
    override fun attachBaseContext(newBase: Context) { super.attachBaseContext(LanguageSupport.wrap(newBase)) }
    override fun onCreate() { super.onCreate(); diagnosticLog = DiagnosticLog.get(this); database = BitmapDatabase(this); store = SettingsStore(this); val settings = store.load(); val reminderState = database.loadReminderState(settings.deviceID); lastEye = reminderState.lastEyeAt; lastPosture = reminderState.lastPostureAt; lastReminder = reminderState.lastReminder ?: "posture"; val today = java.time.LocalDate.now(java.time.ZoneId.systemDefault()).toString(); val storedDate = reminderState.updatedAt.takeIf { it > 0 }?.let { Instant.ofEpochSecond(it).atZone(java.time.ZoneId.systemDefault()).toLocalDate().toString() }; reminderLocalDate = today; if (storedDate != today) { lastReminder = "posture"; database.saveReminderState(settings.deviceID, AndroidReminderState(lastEye, lastPosture, lastReminder)); diagnosticLog.record("reminder", "daily reminder slot reset; local_date=$today; previous_date=${storedDate ?: "none"}; next_slot=posture") }; diagnosticLog.record("monitor", "service created; database=ready; reminder_state=restored; last=$lastReminder; last_eye=$lastEye; last_posture=$lastPosture"); createChannels(); startForeground(1, NotificationCompat.Builder(this, "stg-service").setSmallIcon(R.drawable.ic_stg_notification).setContentTitle(getString(R.string.app_name)).setContentText(getString(R.string.screen_reminders_active)).setOngoing(true).build()); registerReceiver(screenReceiver, IntentFilter().apply { addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_USER_PRESENT); addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED); addAction(Intent.ACTION_SHUTDOWN) }); updateScreenAvailability("service_created") }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int { diagnosticLog.record("monitor", "service start command; flags=$flags; start_id=$startId"); updateScreenAvailability("start_command"); return START_STICKY }
    override fun onBind(intent: Intent?) = null
    override fun onDestroy() { handler.removeCallbacks(tick); runCatching { unregisterReceiver(screenReceiver) }; diagnosticLog.record("monitor", "service destroyed; minute_timer_paused=true"); super.onDestroy() }
    private val tick = object : Runnable { override fun run() { if (!screenAvailable) return; record(); if (screenAvailable) handler.postDelayed(this, 60_000) } }
    private fun updateScreenAvailability(trigger: String) {
        val power = getSystemService(PowerManager::class.java); val keyguard = getSystemService(KeyguardManager::class.java); val available = power.isInteractive && !keyguard.isKeyguardLocked
        if (available == screenAvailable) { diagnosticLog.record("lifecycle", "screen availability unchanged; trigger=$trigger; screen_available=$screenAvailable; minute_timer_running=$screenAvailable"); return }
        screenAvailable = available; handler.removeCallbacks(tick)
        if (available) { diagnosticLog.record("lifecycle", "screen available; trigger=$trigger; minute_timer_resumed=true; immediate_tick=true"); handler.post(tick) }
        else { continuous = 0; diagnosticLog.record("lifecycle", "screen unavailable; trigger=$trigger; minute_timer_paused=true") }
    }
    private fun record() {
        val power = getSystemService(PowerManager::class.java); val keyguard = getSystemService(KeyguardManager::class.java); val active = power.isInteractive && !keyguard.isKeyguardLocked
        if (!active) { if (continuous > 0) diagnosticLog.record("record", "inactive sample; continuous_reset=${continuous}m"); continuous = 0; updateScreenAvailability("inactive_sample"); return }
        val settings = store.load(); val now = Instant.now(); val today = now.atZone(java.time.ZoneId.systemDefault()).toLocalDate().toString(); if (today != reminderLocalDate) { val previousDate = reminderLocalDate; reminderLocalDate = today; lastReminder = "posture"; database.saveReminderState(settings.deviceID, AndroidReminderState(lastEye, lastPosture, lastReminder)); diagnosticLog.record("reminder", "daily reminder slot reset; previous_date=$previousDate; local_date=$today; next_slot=posture") }; val newlyMarked = database.mark(settings.deviceID, now); database.rebuildAll(TimeModel.utcDate(now)); continuous++
        val used = database.localDayMinutes("alldevices", now, java.time.ZoneId.systemDefault().id); val elapsed = now.epochSecond
        val localUsed = database.localDayMinutes(settings.deviceID, now, java.time.ZoneId.systemDefault().id)
        diagnosticLog.record("record", "active minute sample; device=${settings.deviceID.take(8)}; utc_date=${TimeModel.utcDate(now)}; newly_marked=$newlyMarked; continuous=${continuous}m; aggregate=${used}m")
        var kind: String? = null; val previousSlot = lastReminder
        if (continuous >= 20) {
            continuous = 0
            if (lastReminder == "eye") {
                if (used >= settings.dailyPlanMinutes) { kind = "daily"; lastReminder = "posture"; lastEye = elapsed; lastPosture = elapsed }
                else if (elapsed - lastPosture >= 37 * 60) { kind = "posture"; lastReminder = "posture"; lastEye = elapsed; lastPosture = elapsed }
            } else {
                if (used >= settings.dailyPlanMinutes) { kind = "daily"; lastReminder = "eye"; lastEye = elapsed; lastPosture = elapsed }
                else if (elapsed - lastEye >= 17 * 60) { kind = "eye"; lastReminder = "eye"; lastEye = elapsed }
            }
        }
        if (kind != null) { database.saveReminderState(settings.deviceID, AndroidReminderState(lastEye, lastPosture, lastReminder)); diagnosticLog.record("reminder", "reminder selected; kind=$kind; previous_slot=$previousSlot; next_slot=$lastReminder; used=${used}m; continuous=${continuous}m; state_saved=true"); showReminder(kind, used, settings); diagnosticLog.record("sync", "incremental sync requested; trigger=reminder; kind=$kind"); AppSyncCoordinator.request(this, "reminder:$kind") }
        database.updateRuntimeState(settings.deviceID, continuous, localUsed, used, now.atZone(java.time.ZoneId.systemDefault()).toLocalDate().toString(), elapsed)
    }
    private fun showReminder(kind: String, used: Int, settings: AppSettings) {
        val detected = MeetingDetector(this).checkAndLog(); val meeting = settings.meetingMode || detected.isInMeeting
        val intent = Intent(this, ReminderActivity::class.java).putExtra("kind", kind).putExtra("used", used).putExtra("countdown", when(kind) { "eye" -> settings.eyeCountdown; "posture" -> settings.postureCountdown; else -> settings.dailyCountdown }).putExtra("meeting", meeting).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pending = PendingIntent.getActivity(this, kind.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val title = getString(if (kind == "eye") R.string.eye_break_title else if (kind == "posture") R.string.posture_break_title else R.string.daily_limit_title)
        val message = if (kind == "eye") getString(R.string.eye_break_body) else if (kind == "posture") getString(R.string.posture_break_body) else getString(R.string.daily_limit_body, used / 60, used % 60)
        val channel = if (meeting) "stg-silent" else "stg-alert"; val notification = NotificationCompat.Builder(this, channel).setSmallIcon(R.drawable.ic_stg_notification).setContentTitle(title).setContentText(message).setPriority(NotificationCompat.PRIORITY_HIGH).setContentIntent(pending).setFullScreenIntent(pending, true).setAutoCancel(true).build()
        val notificationID = (System.currentTimeMillis() % Int.MAX_VALUE).toInt(); getSystemService(NotificationManager::class.java).notify(notificationID, notification); diagnosticLog.record("reminder", "notification enqueued; id=$notificationID; kind=$kind; used=${used}m; meeting=$meeting; silent=$meeting"); startActivity(intent)
    }
    private fun createChannels() { if (Build.VERSION.SDK_INT < 26) return; val manager = getSystemService(NotificationManager::class.java); manager.createNotificationChannel(NotificationChannel("stg-service", "STG service", NotificationManager.IMPORTANCE_LOW)); manager.createNotificationChannel(NotificationChannel("stg-alert", "STG reminders", NotificationManager.IMPORTANCE_HIGH)); manager.createNotificationChannel(NotificationChannel("stg-silent", "STG meeting reminders", NotificationManager.IMPORTANCE_DEFAULT).apply { setSound(null, null) }) }
}
