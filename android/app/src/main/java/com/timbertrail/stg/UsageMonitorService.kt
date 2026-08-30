package com.timbertrail.stg

import android.app.*
import android.content.*
import android.os.*
import androidx.core.app.NotificationCompat
import java.time.Instant

class UsageMonitorService : Service() {
    private val handler = Handler(Looper.getMainLooper()); private lateinit var database: BitmapDatabase; private lateinit var store: SettingsStore
    private var continuous = 0; private var lastEye = 0L; private var lastPosture = 0L
    override fun onCreate() { super.onCreate(); database = BitmapDatabase(this); store = SettingsStore(this); createChannels(); startForeground(1, NotificationCompat.Builder(this, "stg-service").setSmallIcon(android.R.drawable.ic_secure).setContentTitle("Screen Time Guardian").setContentText("Screen-time reminders are active").setOngoing(true).build()); handler.post(tick) }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_STICKY
    override fun onBind(intent: Intent?) = null
    override fun onDestroy() { handler.removeCallbacks(tick); super.onDestroy() }
    private val tick = object : Runnable { override fun run() { record(); handler.postDelayed(this, 60_000) } }
    private fun record() {
        val power = getSystemService(PowerManager::class.java); val keyguard = getSystemService(KeyguardManager::class.java); val active = power.isInteractive && !keyguard.isKeyguardLocked
        if (!active) { continuous = 0; return }
        val settings = store.load(); val now = Instant.now(); database.mark(settings.deviceID, now); database.rebuildAll(TimeModel.utcDate(now)); continuous++
        val used = database.localDayMinutes("alldevices", now, java.time.ZoneId.systemDefault().id); val elapsed = System.currentTimeMillis()
        val kind = when { continuous >= 40 && used >= settings.dailyPlanMinutes -> "daily"; continuous >= 40 && elapsed - lastPosture >= 37 * 60_000 -> "posture"; continuous >= 20 && used >= settings.dailyPlanMinutes -> "daily"; continuous >= 20 && elapsed - lastEye >= 17 * 60_000 -> "eye"; else -> null }
        if (continuous >= 40) continuous = 0
        if (kind != null) { if (kind == "posture" || kind == "daily") lastPosture = elapsed; lastEye = elapsed; showReminder(kind, used, settings) }
    }
    private fun showReminder(kind: String, used: Int, settings: AppSettings) {
        val detected = MeetingDetector(this).checkAndLog(); val meeting = settings.meetingMode || detected.isInMeeting
        val intent = Intent(this, ReminderActivity::class.java).putExtra("kind", kind).putExtra("used", used).putExtra("countdown", when(kind) { "eye" -> settings.eyeCountdown; "posture" -> settings.postureCountdown; else -> settings.dailyCountdown }).putExtra("meeting", meeting).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pending = PendingIntent.getActivity(this, kind.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val channel = if (meeting) "stg-silent" else "stg-alert"; val notification = NotificationCompat.Builder(this, channel).setSmallIcon(android.R.drawable.ic_secure).setContentTitle(if (kind == "eye") "Time for an Eye Break" else if (kind == "posture") "Stand Up & Stretch" else "Daily Limit Reached").setContentText(if (kind == "eye") "Look at something 20 feet away for 20 seconds." else if (kind == "posture") "Stand or walk around for 4 minutes." else "Used ${used / 60}h ${used % 60}m today.").setPriority(NotificationCompat.PRIORITY_HIGH).setContentIntent(pending).setFullScreenIntent(pending, true).setAutoCancel(true).build()
        getSystemService(NotificationManager::class.java).notify((System.currentTimeMillis() % Int.MAX_VALUE).toInt(), notification); startActivity(intent)
    }
    private fun createChannels() { if (Build.VERSION.SDK_INT < 26) return; val manager = getSystemService(NotificationManager::class.java); manager.createNotificationChannel(NotificationChannel("stg-service", "STG service", NotificationManager.IMPORTANCE_LOW)); manager.createNotificationChannel(NotificationChannel("stg-alert", "STG reminders", NotificationManager.IMPORTANCE_HIGH)); manager.createNotificationChannel(NotificationChannel("stg-silent", "STG meeting reminders", NotificationManager.IMPORTANCE_DEFAULT).apply { setSound(null, null) }) }
}
