package com.timbertrail.stg

import android.Manifest
import android.app.*
import android.content.*
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import java.text.NumberFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import androidx.core.content.FileProvider

class MainActivity : Activity() {
    private lateinit var store: SettingsStore; private lateinit var database: BitmapDatabase; private lateinit var settings: AppSettings; private lateinit var status: TextView; private lateinit var diagnosticLog: DiagnosticLog; private var onboarding = false; private var onboardingStep = 0
    private var shell: LinearLayout? = null
    private var contentHost: FrameLayout? = null
    private var currentPage = 0
    private var permissionReturnStep: Int? = null
    private var cloudSetupForOnboarding = false
    private var cloudSetupDialog: AlertDialog? = null
    private var cloudConnectionStatus: TextView? = null
    private var cloudSetupSummary: TextView? = null
    private val navItems = mutableListOf<TextView>()
    private val reportTimeZone: String get() = java.time.ZoneId.systemDefault().id
    override fun attachBaseContext(newBase: Context) { super.attachBaseContext(LanguageSupport.wrap(newBase)) }
    override fun onCreate(state: Bundle?) { super.onCreate(state); WindowCompat.setDecorFitsSystemWindows(window, false); diagnosticLog = DiagnosticLog.get(this); store = SettingsStore(this); database = BitmapDatabase(this); settings = store.load(); settings.reportTimeZone = reportTimeZone; diagnosticLog.record("lifecycle", "launch; device=${settings.deviceID.take(8)}; provider=${settings.cloudProvider}; database=ready; timezone=$reportTimeZone; language=${store.language()}"); ensureNotificationChannels(); onboarding = !store.onboardingComplete(); if (onboarding) showOnboarding() else { startMonitorService(); showHome() }; handleCloudCallback(intent) }
    override fun onNewIntent(intent: Intent?) { super.onNewIntent(intent); setIntent(intent); handleCloudCallback(intent) }
    override fun onResume() { super.onResume(); if (::diagnosticLog.isInitialized) diagnosticLog.record("lifecycle", "activity resumed; onboarding=$onboarding"); if (onboarding) window.decorView.postDelayed({ if (onboarding) resumeOnboardingAfterSettings() }, 150) else if (::status.isInitialized) refreshStatus() }
    override fun onPause() { if (::diagnosticLog.isInitialized) diagnosticLog.record("lifecycle", "activity paused"); super.onPause() }
    private fun showHome() {
        ensureShell()
        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(22), dp(24), dp(22), dp(24)) }
        column.addView(ImageView(this).apply { setImageResource(R.mipmap.ic_launcher); contentDescription = getString(R.string.app_name) }, LinearLayout.LayoutParams(dp(72), dp(72)).apply { gravity = Gravity.CENTER_HORIZONTAL })
        column.addView(TextView(this).apply { text = getString(R.string.app_name); textSize = 29f; typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER; setTextColor(Color.rgb(15, 23, 42)); setPadding(0, dp(8), 0, dp(18)) })
        val metrics = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        status = TextView(this)
        metrics.addView(metricCard(getString(R.string.all_devices), "", "all"))
        metrics.addView(metricCard(getString(R.string.this_device), "", "local"))
        metrics.addView(metricCard(getString(R.string.daily_limit), duration(settings.dailyPlanMinutes), "limit"))
        column.addView(metrics)
        val top = database.latestOpenRouterTopModels("Total tokens", 2)
        column.addView(card(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(TextView(this@MainActivity).apply { text = getString(R.string.latest_week_top_models); textSize = 17f; typeface = Typeface.DEFAULT_BOLD; setTextColor(Color.rgb(15, 23, 42)) })
            addView(TextView(this@MainActivity).apply { text = if (top.isEmpty()) getString(R.string.weekly_data_after_sync) else top.mapIndexed { index, name -> "${index + 1}. $name" }.joinToString("\n"); textSize = 15f; setTextColor(Color.rgb(71, 85, 105)); setPadding(0, dp(8), 0, 0) })
        }))
        column.addView(Button(this).apply { text = getString(R.string.sync_now); isAllCaps = false; setOnClickListener { sync() } }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(52)).apply { topMargin = dp(14) })
        status = TextView(this).apply { textSize = 13f; gravity = Gravity.CENTER; setTextColor(Color.rgb(100, 116, 139)); setPadding(0, dp(10), 0, 0) }
        column.addView(status)
        setPage(ScrollView(this).apply { addView(column) }, 0)
        refreshStatus()
    }

    private fun ensureShell() {
        if (shell != null) return
        contentHost = FrameLayout(this)
        val navigation = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER; setPadding(dp(4), dp(4), dp(4), dp(6)); background = solidDrawable(Color.WHITE) }
        val labels = listOf(R.string.today, R.string.report, R.string.tracking, R.string.settings, R.string.about)
        val glyphs = listOf("◆", "▥", "⌁", "⚙", "ⓘ")
        labels.forEachIndexed { index, label ->
            val item = TextView(this).apply {
                text = "${glyphs[index]}\n${getString(label)}"; gravity = Gravity.CENTER; textSize = 12f; isClickable = true; isFocusable = true; setPadding(dp(2), dp(5), dp(2), dp(3))
                setOnClickListener { when (index) { 0 -> showHome(); 1 -> showReport(); 2 -> showTracking(); 3 -> showSettings(); else -> showAbout() } }
            }
            navItems += item; navigation.addView(item, LinearLayout.LayoutParams(0, dp(62), 1f))
        }
        shell = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.rgb(248, 250, 252)); addView(contentHost, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)); addView(View(this@MainActivity).apply { setBackgroundColor(Color.rgb(226,232,240)) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(1))); addView(navigation) }
        setContentViewWithInsets(shell!!)
    }

    private fun setPage(view: View, selected: Int) {
        ensureShell(); currentPage = selected; contentHost!!.removeAllViews(); contentHost!!.addView(view, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        navItems.forEachIndexed { index, item -> item.setTextColor(if (index == selected) Color.rgb(37, 99, 235) else Color.rgb(100, 116, 139)); item.typeface = if (index == selected) Typeface.DEFAULT_BOLD else Typeface.DEFAULT }
    }

    private fun setContentViewWithInsets(view: View) {
        setContentView(view)
        ViewCompat.setOnApplyWindowInsetsListener(view) { target, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.statusBars() or WindowInsetsCompat.Type.displayCutout() or WindowInsetsCompat.Type.navigationBars())
            target.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        ViewCompat.requestApplyInsets(view)
    }

    private fun page(title: String, body: View, actions: List<Pair<String, () -> Unit>> = emptyList()): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL; setPadding(dp(18), dp(18), dp(18), dp(8))
        addView(LinearLayout(this@MainActivity).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            addView(TextView(this@MainActivity).apply { text = title; textSize = 27f; typeface = Typeface.DEFAULT_BOLD; setTextColor(Color.rgb(15,23,42)) }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            actions.forEach { (label, action) -> addView(Button(this@MainActivity).apply { text = label; isAllCaps = false; setOnClickListener { action() } }) }
        })
        addView(body, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f).apply { topMargin = dp(10) })
    }

    private fun metricCard(label: String, initial: String, tagValue: String): View = card(LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        addView(TextView(this@MainActivity).apply { text = label; textSize = 16f; setTextColor(Color.rgb(71,85,105)) }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(TextView(this@MainActivity).apply { text = initial; tag = "metric_$tagValue"; textSize = 22f; typeface = Typeface.DEFAULT_BOLD; setTextColor(Color.rgb(15,23,42)) })
    })

    private fun card(content: View): View = FrameLayout(this).apply { background = roundedDrawable(Color.WHITE, Color.rgb(226,232,240), 14f); setPadding(dp(16), dp(14), dp(16), dp(14)); addView(content) }.also { it.layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(10) } }
    private fun solidDrawable(color: Int) = GradientDrawable().apply { setColor(color) }
    private fun roundedDrawable(fill: Int, stroke: Int, radius: Float) = GradientDrawable().apply { setColor(fill); cornerRadius = dp(radius.toInt()).toFloat(); setStroke(dp(1), stroke) }
    private fun showOnboarding() {
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(42, 54, 42, 36) }
        root.addView(TextView(this).apply { text = getString(R.string.setup_step, onboardingStep + 1, 4); textSize = 15f; setTextColor(Color.rgb(71,85,105)) })
        root.addView(ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply { max = 4; progress = onboardingStep + 1; setPadding(0, 14, 0, 28) })
        fun title(value: String) = root.addView(TextView(this).apply { text = value; textSize = 27f; setTextColor(Color.rgb(15,23,42)); setPadding(0, 8, 0, 18) })
        fun detail(value: String) = root.addView(TextView(this).apply { text = value; textSize = 16f; setTextColor(Color.rgb(71,85,105)); setPadding(0, 0, 0, 18) })
        fun statusRow(name: String, enabled: Boolean, note: String = getString(if (enabled) R.string.enabled else R.string.needs_attention)) = root.addView(TextView(this).apply { text = "$name\n$note"; textSize = 16f; setTextColor(if (enabled) Color.rgb(15,118,110) else Color.rgb(180,83,9)); setPadding(22, 18, 22, 18); setBackgroundColor(Color.rgb(241,245,249)) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(10) })
        when (onboardingStep) {
            0 -> {
                title(getString(R.string.notifications_title)); val notifications = androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled(); val channel = if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java).getNotificationChannel("stg-alert") else null; val sound = if (Build.VERSION.SDK_INT < 26) notifications else channel != null && channel.importance >= NotificationManager.IMPORTANCE_HIGH && channel.sound != null
                statusRow(getString(R.string.display_notifications), notifications); statusRow(getString(R.string.reminder_sound), sound, getString(if (sound) R.string.enabled else R.string.open_notification_sound))
                detail(getString(R.string.notifications_onboarding_detail))
                root.addView(primaryButton(getString(R.string.allow_notifications)) { allowNotificationsAndAdvance() })
            }
            1 -> {
                title(getString(R.string.presentation_title)); val overlay = Settings.canDrawOverlays(this); val fullScreen = if (Build.VERSION.SDK_INT >= 34) getSystemService(NotificationManager::class.java).canUseFullScreenIntent() else true
                statusRow(getString(R.string.display_over_apps), overlay); statusRow(getString(R.string.full_screen_reminder), fullScreen, getString(if (fullScreen) R.string.enabled else R.string.full_screen_detail))
                detail(getString(R.string.presentation_detail))
                val label = if (!overlay) getString(R.string.allow_overlay) else if (!fullScreen) getString(R.string.open_full_screen_access) else getString(R.string.reminders_ready)
                root.addView(primaryButton(label) { configureReminderPresentationAndAdvance() })
            }
            2 -> {
                title(getString(R.string.usage_stats_title)); val usage = hasUsageStatsAccess(); statusRow(getString(R.string.usage_stats), usage); detail(getString(R.string.usage_stats_detail))
                root.addView(primaryButton(getString(R.string.open_usage_access)) { if (usage) advanceOnboarding() else { permissionReturnStep = 2; startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)) } })
            }
            else -> {
                title(getString(R.string.private_cloud_question)); detail(getString(R.string.cloud_onboarding_detail))
                statusRow(getString(R.string.configure_private_cloud), cloudConfigured(), if (cloudConfigured()) "${providerLabel(settings.cloudProvider)} · ${settings.cloudAccount}" else getString(R.string.optional))
                root.addView(primaryButton(if (!cloudConfigured()) getString(R.string.setup_private_cloud) else getString(R.string.manage_private_cloud)) { cloudSetupForOnboarding = true; showCloudSetup() })
                root.addView(Button(this).apply { text = getString(R.string.device_only); isAllCaps = false; setOnClickListener { disconnectCloud(); completeOnboarding() } })
                if (cloudConfigured()) root.addView(primaryButton(getString(R.string.done)) { completeOnboarding() })
            }
        }
        val navigation = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.END; setPadding(0, 28, 0, 0) }
        if (onboardingStep > 0) navigation.addView(Button(this).apply { text = getString(R.string.back); setOnClickListener { onboardingStep--; showOnboarding() } })
        root.addView(navigation); setContentViewWithInsets(ScrollView(this).apply { addView(root) })
    }
    private fun primaryButton(label: String, action: () -> Unit) = Button(this).apply { text = label; isAllCaps = false; setOnClickListener { action() } }
    private fun advanceOnboarding() { onboardingStep = (onboardingStep + 1).coerceAtMost(3); permissionReturnStep = null; showOnboarding() }
    private fun allowNotificationsAndAdvance() {
        if (androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled() && (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED)) { advanceOnboarding(); return }
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
        else { permissionReturnStep = 0; openNotificationSettings() }
    }
    private fun configureReminderPresentationAndAdvance() {
        if (!Settings.canDrawOverlays(this)) { permissionReturnStep = 1; startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))); return }
        if (Build.VERSION.SDK_INT >= 34 && !getSystemService(NotificationManager::class.java).canUseFullScreenIntent()) { permissionReturnStep = 1; startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$packageName"))); return }
        advanceOnboarding()
    }
    private fun resumeOnboardingAfterSettings() {
        val returning = permissionReturnStep
        if (returning == 0 && androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled()) advanceOnboarding()
        else if (returning == 1 && Settings.canDrawOverlays(this) && (Build.VERSION.SDK_INT < 34 || getSystemService(NotificationManager::class.java).canUseFullScreenIntent())) advanceOnboarding()
        else if (returning == 2 && hasUsageStatsAccess()) advanceOnboarding()
        else showOnboarding()
    }
    private fun completeOnboarding() { store.completeOnboarding(); onboarding = false; cloudSetupForOnboarding = false; shell = null; contentHost = null; navItems.clear(); startMonitorService(); showHome() }
    private fun ensureNotificationChannels() { if (Build.VERSION.SDK_INT < 26) return; val manager = getSystemService(NotificationManager::class.java); manager.createNotificationChannel(NotificationChannel("stg-service", "STG service", NotificationManager.IMPORTANCE_LOW)); manager.createNotificationChannel(NotificationChannel("stg-alert", "STG reminders", NotificationManager.IMPORTANCE_HIGH)); manager.createNotificationChannel(NotificationChannel("stg-silent", "STG meeting reminders", NotificationManager.IMPORTANCE_DEFAULT).apply { setSound(null, null) }) }
    private fun openNotificationSettings() { val intent = if (Build.VERSION.SDK_INT >= 26) Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName) else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")); startActivity(intent) }
    private fun hasUsageStatsAccess(): Boolean { val manager = getSystemService(android.app.AppOpsManager::class.java); val mode = if (Build.VERSION.SDK_INT >= 29) manager.unsafeCheckOpNoThrow(android.app.AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), packageName) else manager.checkOpNoThrow(android.app.AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), packageName); return mode == android.app.AppOpsManager.MODE_ALLOWED }
    private fun startMonitorService() { diagnosticLog.record("monitor", "foreground monitor service requested"); ContextCompat.startForegroundService(this, Intent(this, UsageMonitorService::class.java)) }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) { super.onRequestPermissionsResult(requestCode, permissions, grantResults); if (onboarding && requestCode == 7 && grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED) advanceOnboarding() else if (onboarding) showOnboarding() }
    private fun refreshStatus() { val now = Instant.now(); database.rebuildAll(TimeModel.utcDate(now)); database.upsertDevice(AndroidDeviceRecord(settings.deviceID, settings.deviceName, "android", settings.updatedAt)); val local = database.localDayMinutes(settings.deviceID, now, reportTimeZone); val all = database.localDayMinutes("alldevices", now, reportTimeZone); database.updateRuntimeState(settings.deviceID, 0, local, all, now.atZone(java.time.ZoneId.systemDefault()).toLocalDate().toString()); shell?.findViewWithTag<TextView>("metric_all")?.text = duration(all); shell?.findViewWithTag<TextView>("metric_local")?.text = duration(local); shell?.findViewWithTag<TextView>("metric_limit")?.text = duration(settings.dailyPlanMinutes); if (::status.isInitialized) status.text = if (!cloudConfigured()) getString(R.string.sync_off_status) else getString(R.string.private_cloud_status_short, providerLabel(settings.cloudProvider)) }
    private fun showReport() {
        diagnosticLog.record("report", "report opened; timezone=$reportTimeZone")
        var dailyDate = LocalDate.now(java.time.ZoneId.systemDefault())
        var rangeStart = dailyDate.minusDays(6); var rangeEnd = dailyDate; var mode = 0
        database.refreshStatistics(settings); var summary = database.statisticsSummary(settings)
        var daily = dayReport(dailyDate); var points = multiDayReport(rangeStart, rangeEnd)
        var unavailablePeriods = emptyList<AndroidPeriodUsagePoint>()
        fun periodPoints(values: List<AndroidPeriodUsagePoint>): List<AndroidDailyUsagePoint> { unavailablePeriods = values.filter { it.includedDays == 0 }; return periodAsDaily(values) }
        fun loadPoints() { unavailablePeriods = emptyList(); points = when (mode) { 1 -> multiDayReport(rangeStart, rangeEnd); 2 -> periodPoints(database.periodUsage("week", dailyDate.withDayOfYear(1), dailyDate)); else -> periodPoints(database.periodUsage("month", dailyDate.minusYears(2).withDayOfYear(1), dailyDate)) } }
        val modes = Spinner(this).apply { adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, listOf(getString(R.string.daily), getString(R.string.multiple_days), getString(R.string.year_by_week), getString(R.string.years_by_month))) }
        val dailyDateButton = Button(this).apply { text = getString(R.string.report_date, dailyDate) }
        val startButton = Button(this).apply { text = getString(R.string.start_date, rangeStart) }; val endButton = Button(this).apply { text = getString(R.string.end_date, rangeEnd) }
        val dailyControls = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; addView(dailyDateButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)) }
        val rangeControls = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; addView(startButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)); addView(endButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)); visibility = View.GONE }
        val content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(26, 8, 26, 0); addView(modes); addView(dailyControls); addView(rangeControls); addView(ScrollView(this@MainActivity).apply { addView(content) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)) }
        lateinit var render: () -> Unit
        render = {
            content.removeAllViews()
            if (mode == 0) {
                val aggregate = daily.firstOrNull { it.aggregate }; val local = daily.firstOrNull { it.deviceID == settings.deviceID }
                content.addView(TextView(this).apply { text = "${getString(R.string.all_devices)}: ${duration(aggregate?.usedMinutes ?: 0)}    ${getString(R.string.this_device)}: ${duration(local?.usedMinutes ?: 0)}    ${getString(R.string.daily_limit)}: ${duration(settings.dailyPlanMinutes)}"; textSize = 16f; setPadding(8, 18, 8, 18) })
                content.addView(TextView(this).apply { text = "${getString(R.string.this_week_avg)}: ${average(summary.thisWeek)} · ${getString(R.string.last_week_avg)}: ${average(summary.lastWeek)}\n${getString(R.string.this_month_avg)}: ${average(summary.thisMonth)} · ${getString(R.string.last_month_avg)}: ${average(summary.lastMonth)} · ${getString(R.string.this_year_avg)}: ${average(summary.thisYear)}" + if (summary.estimated) "\n${getString(R.string.includes_estimated_ios)}" else ""; setPadding(8, 0, 8, 16) })
                daily.forEach { report -> content.addView(LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(8, 12, 8, 18); addView(TextView(this@MainActivity).apply { text = "${report.displayName}    ${duration(report.usedMinutes)}"; textSize = 17f }); addView(AndroidMinuteBitmapView(this@MainActivity).apply { minutes = report.minutes; contentDescription = "${report.displayName}, ${report.usedMinutes} used minutes" }); val intervals = TextView(this@MainActivity).apply { text = "Active intervals: ${usageIntervals(report.minutes)}"; textSize = 12f; ellipsize = android.text.TextUtils.TruncateAt.END }; val expand = Button(this@MainActivity).apply { text = "⌄"; isAllCaps = false; visibility = View.GONE; setOnClickListener { val expanded = intervals.maxLines != 1; intervals.maxLines = if (expanded) 1 else Int.MAX_VALUE; text = if (expanded) "⌄" else "⌃" } }; addView(LinearLayout(this@MainActivity).apply { gravity = Gravity.CENTER_VERTICAL; addView(intervals, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)); addView(expand); intervals.post { if (intervals.lineCount > 1) { intervals.maxLines = 1; expand.visibility = View.VISIBLE } } }) }) }
            } else {
                val aggregate = points.filter { it.aggregate }; val average = if (aggregate.isEmpty()) 0 else aggregate.map { it.minutes }.average().toInt()
                content.addView(TextView(this).apply { text = "${when(mode){1->"$rangeStart – $rangeEnd";2->"${dailyDate.year} · ${getString(R.string.year_by_week)}";else->getString(R.string.years_by_month)}} · ${getString(R.string.interval_average)}: ${if (aggregate.isEmpty()) "—" else duration(average)}" + if (points.any { it.estimated }) "\n${getString(R.string.includes_estimated_ios)}" else ""; setPadding(8, 16, 8, 10) })
                if (mode > 1 && unavailablePeriods.isNotEmpty()) content.addView(TextView(this).apply { text = unavailablePeriods.joinToString("\n") { "${it.label} · ${it.displayName}: —" }; setPadding(8, 0, 8, 10) })
                content.addView(AndroidUsageLineChartView(this).apply { period = when (mode) { 2 -> "week"; 3 -> "month"; else -> "day" }; this.points = points })
            }
        }
        dailyDateButton.setOnClickListener { chooseDate(dailyDate) { dailyDate = it; dailyDateButton.text = getString(R.string.report_date, it); daily = dayReport(it); render() } }
        startButton.setOnClickListener { chooseDate(rangeStart) { rangeStart = it; startButton.text = getString(R.string.start_date, it); points = multiDayReport(rangeStart, rangeEnd); render() } }
        endButton.setOnClickListener { chooseDate(rangeEnd) { rangeEnd = it; endButton.text = getString(R.string.end_date, it); points = multiDayReport(rangeStart, rangeEnd); render() } }
        modes.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener { override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) { mode = position; dailyControls.visibility = if (mode == 0) View.VISIBLE else View.GONE; rangeControls.visibility = if (mode == 1) View.VISIBLE else View.GONE; if (mode > 0) loadPoints(); render() }; override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {} }
        render()
        val refreshAction = { database.refreshStatistics(settings); summary = database.statisticsSummary(settings); if (mode == 0) daily = dayReport(dailyDate) else loadPoints(); diagnosticLog.record("report", "refresh; mode=$mode; date=$dailyDate; range=$rangeStart..$rangeEnd"); render() }
        val exportAction = { diagnosticLog.record("report", "CSV export requested; mode=${if (mode == 0) "daily" else "multiple_days"}"); val csv = if (mode == 0) dailyCsv(dailyDate, daily) else multiDayCsv(points); startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/csv").putExtra(Intent.EXTRA_TEXT, csv).putExtra(Intent.EXTRA_TITLE, if (mode == 0) "stg-daily-report.csv" else "stg-multi-day-report.csv"), getString(R.string.export_report))) }
        setPage(page(getString(R.string.report_title), root, listOf(getString(R.string.refresh) to refreshAction, getString(R.string.export_csv) to exportAction)), 1)
    }
    private fun showTracking() {
        diagnosticLog.record("tracking", "tracking opened; default_view=weekly_trends")
        var customStart = LocalDate.now(ZoneOffset.UTC).minusDays(7)
        val startButton = Button(this).apply { text = getString(R.string.start_date, customStart) }
        startButton.setOnClickListener { chooseDate(customStart) { chosen -> val latest = LocalDate.now(ZoneOffset.UTC).minusDays(1); customStart = minOf(chosen, latest); startButton.text = getString(R.string.start_date, customStart) } }
        val statusText = TextView(this).apply { text = getString(R.string.tracking_public_detail); setPadding(0, 12, 0, 12) }
        val table = TableLayout(this).apply { isStretchAllColumns = false }
        val tableScroll = HorizontalScrollView(this).apply { addView(ScrollView(this@MainActivity).apply { addView(table) }); layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f) }
        val chart = AndroidTrackingLineChartView(this)
        val metricKeys = listOf("Total tokens", "Input tokens", "Output tokens", "Rank", "Input price / M", "Output price / M", "Estimated Revenue")
        val metricLabels = listOf(getString(R.string.total_tokens), getString(R.string.input_tokens), getString(R.string.output_tokens), getString(R.string.rank), getString(R.string.input_price_per_m), getString(R.string.output_price_per_m), getString(R.string.estimated_revenue))
        val metric = Spinner(this).apply { adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, metricLabels) }
        val weeklyPanel = ScrollView(this).apply { addView(LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL; addView(metric); addView(HorizontalScrollView(this@MainActivity).apply { isFillViewport = true; addView(chart, android.view.ViewGroup.LayoutParams(android.view.ViewGroup.LayoutParams.WRAP_CONTENT, dp(650))) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(650))) }) }
        val topPanel = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; addView(startButton); addView(TextView(this@MainActivity).apply { text = getString(R.string.top20_detail) }); addView(tableScroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)) }
        val modes = Spinner(this).apply { adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, listOf(getString(R.string.weekly_trends), getString(R.string.top20_since_date))) }
        val refresh = Button(this).apply { text = getString(R.string.refresh_top20) }
        val export = Button(this).apply { text = getString(R.string.export_top20) }
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(24, 8, 24, 0); minimumHeight = dp(560); addView(modes); addView(LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL; addView(refresh); addView(export) }); addView(statusText); addView(weeklyPanel, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)); addView(topPanel, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)) }
        var snapshot: RankingSnapshot? = null; var sortField = "rank"; var descending = false
        lateinit var render: () -> Unit
        render = {
            table.removeAllViews()
            val headers = listOf(getString(R.string.rank) to "rank", getString(R.string.model) to "model", getString(R.string.input_tokens) to "prompt", getString(R.string.output_tokens) to "completion", getString(R.string.total_tokens) to "total", getString(R.string.input_price) to "promptPrice", getString(R.string.output_price) to "completionPrice", getString(R.string.estimated_revenue) to "revenue")
            table.addView(TableRow(this).apply { headers.forEach { (label, field) -> addView(Button(this@MainActivity).apply { text = label + if (sortField == field) if (descending) " ↓" else " ↑" else ""; setOnClickListener { if (sortField == field) descending = !descending else { sortField = field; descending = true }; render() } }) } })
            val source = snapshot?.rows.orEmpty(); val ordered = source.sortedWith { a, b ->
                val nullableResult = when (sortField) { "promptPrice" -> compareNullable(a.promptPrice, b.promptPrice, descending); "completionPrice" -> compareNullable(a.completionPrice, b.completionPrice, descending); "revenue" -> compareNullable(a.revenue, b.revenue, descending); else -> null }
                nullableResult ?: run { val result = when (sortField) { "model" -> a.model.compareTo(b.model, true); "prompt" -> a.promptTokens.compareTo(b.promptTokens); "completion" -> a.completionTokens.compareTo(b.completionTokens); "total" -> a.totalTokens.compareTo(b.totalTokens); else -> a.rank.compareTo(b.rank) }; if (descending) -result else result }
            }
            ordered.forEach { row -> table.addView(TableRow(this).apply { listOf(row.rank.toString(), row.model, number(row.promptTokens), number(row.completionTokens), number(row.totalTokens), price(row.promptPrice), price(row.completionPrice), revenue(row.revenue)).forEachIndexed { index, value -> addView(TextView(this@MainActivity).apply { text = value; setPadding(18, 12, 18, 12); setTextColor(Color.rgb(24, 35, 48)); gravity = if (index == 1) Gravity.START else Gravity.END; setSingleLine(true) }) } }) }
        }
        render()
        fun loadTop() { statusText.text = getString(R.string.loading_rankings); diagnosticLog.record("tracking", "Top 20 refresh begin; start=$customStart"); Thread { val result = runCatching { OpenRouterClient().top20(customStart, LocalDate.now(ZoneOffset.UTC).minusDays(1)) }; runOnUiThread { result.onSuccess { snapshot = it; diagnosticLog.record("tracking", "Top 20 refresh complete; range=${it.startDate}..${it.endDate}; rows=${it.rows.size}"); statusText.text = "${it.startDate} – ${it.endDate} UTC · ${it.citation}"; render() }.onFailure { diagnosticLog.record("tracking", "Top 20 refresh failed; error=${it.message ?: it.javaClass.simpleName}"); statusText.text = getString(R.string.tracking_load_failed, it.message ?: it.javaClass.simpleName) } } }.start() }
        fun loadWeeks() { val selectedMetric = metricKeys[metric.selectedItemPosition.coerceIn(metricKeys.indices)]; val selectedLabel = metricLabels[metric.selectedItemPosition.coerceIn(metricLabels.indices)]; val models = database.latestOpenRouterTopModels(selectedMetric); chart.metric = selectedMetric; chart.rows = database.openRouterWeeks(models); diagnosticLog.record("tracking", "weekly trends loaded; metric=$selectedMetric; models=${models.size}; rows=${chart.rows.size}"); statusText.text = if (chart.rows.isEmpty()) getString(R.string.no_saved_metric, selectedLabel) else getString(R.string.showing_saved_weeks, selectedLabel, models.size) }
        refresh.setOnClickListener { loadTop() }; export.setOnClickListener { snapshot?.let(::exportTracking) ?: Toast.makeText(this, R.string.open_top20_first, Toast.LENGTH_SHORT).show() }
        metric.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener { override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) { loadWeeks() }; override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {} }
        modes.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener { override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) { weeklyPanel.visibility = if (position == 0) View.VISIBLE else View.GONE; topPanel.visibility = if (position == 1) View.VISIBLE else View.GONE; refresh.visibility = if (position == 1) View.VISIBLE else View.GONE; export.visibility = refresh.visibility; if (position == 0) loadWeeks() else if (snapshot == null) loadTop() }; override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {} }
        setPage(page(getString(R.string.openrouter_tracking), layout), 2)
    }
    private fun showAbout() {
        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(14), dp(8), dp(14), dp(20)); addView(ImageView(this@MainActivity).apply { setImageResource(R.mipmap.ic_launcher) }, LinearLayout.LayoutParams(dp(64), dp(64))); addView(TextView(this@MainActivity).apply { text = getString(R.string.app_name); textSize = 24f; typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER; setPadding(0, dp(8), 0, dp(16)) }); addView(TextView(this@MainActivity).apply { text = android.text.Html.fromHtml(getString(R.string.about_body_html), android.text.Html.FROM_HTML_MODE_LEGACY); movementMethod = android.text.method.LinkMovementMethod.getInstance(); textSize = 15f }) }
        setPage(page(getString(R.string.about), ScrollView(this).apply { addView(column) }), 4)
    }
    private fun showSettings() {
        val planHours = Spinner(this).apply { adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, (0..24).toList()); setSelection(settings.dailyPlanMinutes / 60) }
        val minuteValues = listOf(0, 15, 30, 45); val planMinutes = Spinner(this).apply { adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, minuteValues); setSelection((settings.dailyPlanMinutes % 60 / 15).coerceIn(0, 3)) }
        val languageCodes = LanguageSupport.codes; val language = Spinner(this).apply { adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, listOf(getString(R.string.follow_system), getString(R.string.language_english), getString(R.string.language_chinese), getString(R.string.language_spanish))); setSelection(languageCodes.indexOf(store.language()).coerceAtLeast(0)) }
        val planRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; addView(TextView(this@MainActivity).apply { text = getString(R.string.daily_limit); textSize = 16f }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)); addView(planHours); addView(TextView(this@MainActivity).apply { text = " h "; gravity = Gravity.CENTER_VERTICAL }); addView(planMinutes); addView(TextView(this@MainActivity).apply { text = " m"; gravity = Gravity.CENTER_VERTICAL }) }
        val (eyeRow, eye) = labeledNumberInput(getString(R.string.eye_countdown), settings.eyeCountdown); val (postureRow, posture) = labeledNumberInput(getString(R.string.posture_countdown), settings.postureCountdown); val (dailyRow, daily) = labeledNumberInput(getString(R.string.daily_countdown), settings.dailyCountdown); val meeting = CheckBox(this).apply { text = getString(R.string.manual_meeting); isChecked = settings.meetingMode }
        val eyeNotifications = CheckBox(this).apply { text = getString(R.string.eye_notifications); isChecked = settings.eyeNotificationsEnabled }
        val postureNotifications = CheckBox(this).apply { text = getString(R.string.posture_notifications); isChecked = settings.postureNotificationsEnabled }
        val dailyNotifications = CheckBox(this).apply { text = getString(R.string.daily_notifications); isChecked = settings.dailyNotificationsEnabled }
        val meetingStatus = TextView(this).apply { val result = MeetingDetector(this@MainActivity).checkAndLog(); text = "${getString(R.string.automatic_meeting)}: ${getString(if (result.isInMeeting) R.string.in_meeting else R.string.not_in_meeting)}\n${result.reason}"; setPadding(0, 8, 0, 8) }
        val usageStatus = TextView(this).apply { text = "${getString(R.string.usage_stats)}: ${getString(if (hasUsageStatsAccess()) R.string.enabled else R.string.needs_attention)}"; setPadding(0, 12, 0, 12) }
        val notificationStatus = TextView(this).apply { val enabled = getString(R.string.enabled); val attention = getString(R.string.needs_attention); text = "${getString(R.string.notifications)}: ${if (androidx.core.app.NotificationManagerCompat.from(this@MainActivity).areNotificationsEnabled()) enabled else attention}\n${getString(R.string.display_over_apps)}: ${if (Settings.canDrawOverlays(this@MainActivity)) enabled else attention}"; setPadding(0, 12, 0, 12) }
        val cloudStatus = TextView(this).apply { text = cloudStatusText(); setPadding(0, 12, 0, 8) }
        fun section(title: Int, content: View): View = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; addView(TextView(this@MainActivity).apply { text = getString(title); textSize = 14f; typeface = Typeface.DEFAULT_BOLD; setTextColor(Color.rgb(15,118,110)); setPadding(dp(2), dp(8), 0, dp(7)) }); addView(card(content)) }
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(8),0,dp(8),dp(14))
            addView(section(R.string.daily_limit, LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL; addView(planRow); addView(meeting); addView(meetingStatus) }))
            addView(section(R.string.configure_private_cloud, LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL; addView(cloudStatus); addView(Button(this@MainActivity).apply { text = getString(R.string.configure_cloud); isAllCaps = false; setOnClickListener { showCloudSetup(cloudStatus) } }) }))
            addView(section(R.string.usage_stats_title, LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL; addView(usageStatus); addView(Button(this@MainActivity).apply { text = getString(R.string.open_usage_permission); isAllCaps = false; setOnClickListener { startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)) } }) }))
            addView(section(R.string.notification_options, LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL; addView(eyeNotifications); addView(postureNotifications); addView(dailyNotifications); addView(TextView(this@MainActivity).apply { text = getString(R.string.notifications_recording_detail) }) }))
            addView(section(R.string.notifications, LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL; addView(notificationStatus); addView(Button(this@MainActivity).apply { text = getString(R.string.open_notification_settings); isAllCaps = false; setOnClickListener { openNotificationSettings() } }); addView(Button(this@MainActivity).apply { text = getString(R.string.open_overlay_permission); isAllCaps = false; setOnClickListener { startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${this@MainActivity.packageName}"))) } }) }))
            addView(section(R.string.reminders, LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL; addView(eyeRow); addView(postureRow); addView(dailyRow) }))
            addView(section(R.string.language, language))
            addView(section(R.string.diagnostics, LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL; addView(Button(this@MainActivity).apply { text = getString(R.string.export_app_data); isAllCaps = false; setOnClickListener { exportAppData() } }); addView(Button(this@MainActivity).apply { text = getString(R.string.export_test_log); isAllCaps = false; setOnClickListener { runCatching { startActivity(Intent.createChooser(diagnosticLog.shareIntent(), getString(R.string.export_test_log))) }.onFailure { Toast.makeText(this@MainActivity, it.message, Toast.LENGTH_LONG).show() } } }) }))
        }
        val originalPlan = settings.dailyPlanMinutes; val originalEye = settings.eyeCountdown; val originalPosture = settings.postureCountdown; val originalDaily = settings.dailyCountdown; val originalMeeting = settings.meetingMode; val originalLanguage = store.language()
        fun planValue() = ((planHours.selectedItem as? Int ?: 10) * 60 + (planMinutes.selectedItem as? Int ?: 0)).coerceIn(20, 1440)
        fun selectedLanguage() = languageCodes[language.selectedItemPosition.coerceIn(languageCodes.indices)]
        val originalEyeNotifications = settings.eyeNotificationsEnabled; val originalPostureNotifications = settings.postureNotificationsEnabled; val originalDailyNotifications = settings.dailyNotificationsEnabled
        fun dirty() = eyeNotifications.isChecked != originalEyeNotifications || postureNotifications.isChecked != originalPostureNotifications || dailyNotifications.isChecked != originalDailyNotifications || planValue() != originalPlan || eye.text.toString().toIntOrNull() != originalEye || posture.text.toString().toIntOrNull() != originalPosture || daily.text.toString().toIntOrNull() != originalDaily || meeting.isChecked != originalMeeting || selectedLanguage() != originalLanguage
        fun apply() { val languageChanged = selectedLanguage() != store.language(); settings.dailyPlanMinutes = planValue(); settings.reportTimeZone = reportTimeZone; settings.eyeCountdown = eye.text.toString().toIntOrNull()?.coerceIn(0,10) ?: 1; settings.postureCountdown = posture.text.toString().toIntOrNull()?.coerceIn(0,10) ?: 2; settings.dailyCountdown = daily.text.toString().toIntOrNull()?.coerceIn(0,10) ?: 3; settings.meetingMode = meeting.isChecked; settings.eyeNotificationsEnabled = eyeNotifications.isChecked; settings.postureNotificationsEnabled = postureNotifications.isChecked; settings.dailyNotificationsEnabled = dailyNotifications.isChecked; store.save(settings); store.saveLanguage(selectedLanguage()); diagnosticLog.record("settings", "saved; plan=${settings.dailyPlanMinutes}m; timezone=$reportTimeZone; countdowns=${settings.eyeCountdown}/${settings.postureCountdown}/${settings.dailyCountdown}; manual_meeting=${settings.meetingMode}; provider=${settings.cloudProvider}; language=${selectedLanguage()}"); if (languageChanged) recreate() else refreshStatus() }
        val save = Button(this).apply { text = getString(R.string.save); isAllCaps = false; isEnabled = false }
        val close = Button(this).apply { text = getString(R.string.close); isAllCaps = false }
        val actionRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.END; addView(save); addView(close) }
        val pageBody = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; addView(actionRow); addView(ScrollView(this@MainActivity).apply { addView(layout) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)) }
        val changed = { save.isEnabled = dirty() }
        val watcher = object : android.text.TextWatcher { override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}; override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { changed() }; override fun afterTextChanged(s: android.text.Editable?) {} }
        listOf(eye, posture, daily).forEach { it.addTextChangedListener(watcher) }; meeting.setOnCheckedChangeListener { _, _ -> changed() }; eyeNotifications.setOnCheckedChangeListener { _, _ -> changed() }; postureNotifications.setOnCheckedChangeListener { _, _ -> changed() }; dailyNotifications.setOnCheckedChangeListener { _, _ -> changed() }
        val selection = object : android.widget.AdapterView.OnItemSelectedListener { override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) { changed() }; override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {} }; planHours.onItemSelectedListener = selection; planMinutes.onItemSelectedListener = selection; language.onItemSelectedListener = selection
        save.setOnClickListener { apply(); save.isEnabled = false }
        close.setOnClickListener { if (!dirty()) showHome() else AlertDialog.Builder(this).setTitle(R.string.save_changes_question).setPositiveButton(R.string.save) { _, _ -> apply(); showHome() }.setNegativeButton(R.string.discard_changes) { _, _ -> showHome() }.setNeutralButton(R.string.keep_editing, null).show() }
        setPage(page(getString(R.string.settings), pageBody), 3)
    }
    private fun showCloudSetup(summary: TextView? = null) {
        val ios = CheckBox(this).apply { text = getString(R.string.iphone_ipad) }; val mac = CheckBox(this).apply { text = getString(R.string.mac) }; val windows = CheckBox(this).apply { text = getString(R.string.windows) }; val currentAndroid = CheckBox(this).apply { text = getString(R.string.this_android_device); isChecked = true; isEnabled = false }; val china = CheckBox(this).apply { text = getString(R.string.use_mainland_china) }
        val recommendation = TextView(this).apply { textSize = 18f; typeface = Typeface.DEFAULT_BOLD; setPadding(0,16,0,12) }
        val provider = Spinner(this).apply { adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, listOf(getString(R.string.off_single_device), "Microsoft OneDrive", "Google Drive")); setSelection(when(settings.cloudProvider){"onedrive"->1;"google"->2;else->0}) }
        fun recommendationText() { recommendation.text = getString(R.string.recommended_provider, if(china.isChecked) "Microsoft OneDrive" else "Google Drive") }
        recommendationText()
        china.setOnCheckedChangeListener { _, checked -> recommendationText(); provider.setSelection(if (checked) 1 else 2) }
        val connection = TextView(this).apply { text = if (!cloudConfigured()) getString(R.string.not_connected) else "${providerLabel(settings.cloudProvider)} · ${settings.cloudAccount}"; setTextColor(if (!cloudConfigured()) Color.rgb(180,83,9) else Color.rgb(15,118,110)); setPadding(0,12,0,8) }
        val connect = primaryButton(getString(R.string.connect_selected_provider)) {
            val selected = when(provider.selectedItemPosition){1->"onedrive";2->"google";else->null}
            if (selected == null) { Toast.makeText(this, R.string.select_provider_first, Toast.LENGTH_SHORT).show(); return@primaryButton }
            connection.text = getString(R.string.cloud_signing_in)
            if (selected == "onedrive") beginOneDriveConnection(connection, summary) else beginGoogleConnection(connection, summary)
        }
        val disconnect = Button(this).apply { text = getString(R.string.disconnect_private_cloud); isAllCaps = false; visibility = if (!cloudConfigured()) View.GONE else View.VISIBLE; setOnClickListener { disconnectCloud(); summary?.text = cloudStatusText(); cloudSetupDialog?.dismiss(); val returnToOnboarding = cloudSetupForOnboarding || onboarding; cloudSetupForOnboarding = false; if (returnToOnboarding) showOnboarding() else showSettings() } }
        val layout = LinearLayout(this).apply { orientation=LinearLayout.VERTICAL; setPadding(36,8,36,0); addView(TextView(this@MainActivity).apply{text=getString(R.string.shared_devices_question);textSize=18f;typeface=Typeface.DEFAULT_BOLD}); addView(currentAndroid);addView(ios);addView(mac);addView(windows);addView(china);addView(recommendation);addView(provider);addView(connection);addView(connect);addView(disconnect);addView(TextView(this@MainActivity).apply{text=getString(R.string.android_provider_detail);setPadding(0,12,0,0)}) }
        cloudSetupDialog?.dismiss()
        cloudConnectionStatus = connection; cloudSetupSummary = summary
        cloudSetupDialog = AlertDialog.Builder(this).setTitle(R.string.configure_private_cloud).setView(ScrollView(this).apply{addView(layout)}).setNegativeButton(R.string.close, null).create().also { dialog -> dialog.setOnDismissListener { if (cloudSetupDialog === dialog) { cloudSetupDialog = null; cloudConnectionStatus = null; cloudSetupSummary = null } }; dialog.show() }
    }
    private fun providerLabel(value: String) = when(value){"onedrive"->"Microsoft OneDrive";"google"->"Google Drive";else->getString(R.string.off_single_device)}
    private fun cloudConfigured() = PrivateCloudCredentials.isSignedIn(this, settings.cloudProvider)
    private fun cloudStatusText() = "${getString(R.string.configure_private_cloud)}: ${providerLabel(settings.cloudProvider)}\n${if (cloudConfigured()) settings.cloudAccount else getString(R.string.not_connected)}"
    private fun disconnectCloud() {
        if (settings.cloudProvider != "off") PrivateCloudCredentials.remove(this, settings.cloudProvider)
        settings.cloudProvider = "off"; settings.cloudAccount = ""; store.save(settings)
        diagnosticLog.record("sync", "private cloud disconnected by user")
    }

    private fun beginOneDriveConnection(connection: TextView, summary: TextView?) {
        runCatching {
            val request = OneDriveAuthorization.begin(); PrivateCloudCredentials.saveOneDriveRequest(this, request)
            diagnosticLog.record("sync", "OneDrive account authorization begin; callback_registered=true")
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(request.authorizationURL)))
        }.onFailure { showCloudFailure("onedrive", it, connection) }
    }

    private fun beginGoogleConnection(connection: TextView, summary: TextView?) {
        runCatching {
            val request = GoogleAuthorization.begin(); PrivateCloudCredentials.saveGoogleRequest(this, request)
            diagnosticLog.record("sync", "Google Drive account authorization begin; callback_registered=true")
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(request.authorizationURL)))
        }.onFailure { showCloudFailure("google", it, connection) }
    }

    private fun handleGoogleCallback(intent: Intent?) {
        val callback = intent?.data ?: return
        if (callback.scheme != CloudConfiguration.googleCallbackScheme || callback.path != "/oauth2redirect") return
        val request = PrivateCloudCredentials.loadGoogleRequest(this)
        if (request == null) { Toast.makeText(this, R.string.google_sign_in_expired, Toast.LENGTH_LONG).show(); return }
        PrivateCloudCredentials.clearGoogleRequest(this)
        diagnosticLog.record("sync", "Google Drive authorization callback received; state_present=${callback.getQueryParameter("state") != null}; code_present=${callback.getQueryParameter("code") != null}")
        val connection = cloudConnectionStatus ?: TextView(this).apply { text = getString(R.string.cloud_validation) }
        val summary = cloudSetupSummary
        Thread {
            val result = runCatching { GoogleAuthorization.finish(callback, request) }
            runOnUiThread { result.onSuccess { validateCloudConnection("google", it, connection, summary) }.onFailure { showCloudFailure("google", it, connection) } }
        }.start()
    }

    private fun handleCloudCallback(intent: Intent?) {
        handleOneDriveCallback(intent)
        handleGoogleCallback(intent)
    }

    private fun handleOneDriveCallback(intent: Intent?) {
        val callback = intent?.data ?: return
        if (callback.scheme != CloudConfiguration.microsoftCallbackScheme || callback.host != "auth") return
        val request = PrivateCloudCredentials.loadOneDriveRequest(this)
        if (request == null) { Toast.makeText(this, "Microsoft sign-in expired. Try again.", Toast.LENGTH_LONG).show(); return }
        PrivateCloudCredentials.clearOneDriveRequest(this)
        diagnosticLog.record("sync", "OneDrive authorization callback received; state_present=${callback.getQueryParameter("state") != null}; code_present=${callback.getQueryParameter("code") != null}")
        val connection = cloudConnectionStatus ?: TextView(this).apply { text = getString(R.string.cloud_validation) }
        val summary = cloudSetupSummary
        Thread {
            val result = runCatching { OneDriveAuthorization.finish(callback, request) }
            runOnUiThread { result.onSuccess { validateCloudConnection("onedrive", it, connection, summary) }.onFailure { showCloudFailure("onedrive", it, connection) } }
        }.start()
    }

    private fun validateCloudConnection(provider: String, credential: CloudCredential, connection: TextView, summary: TextView?) {
        connection.text = getString(R.string.cloud_validation)
        diagnosticLog.record("sync", "private-cloud account authorized; provider=$provider; initial_sync=begin")
        Thread {
            val validationDatabase = BitmapDatabase(applicationContext)
            val result = runCatching {
                val drive: PrivateCloudDrive = if (provider == "onedrive") OneDriveCloudDrive(applicationContext, credential) else GoogleCloudDrive(applicationContext, credential)
                val account = if (drive is OneDriveCloudDrive) drive.account() else (drive as GoogleCloudDrive).account()
                val candidate = settings.copy(cloudProvider = provider, cloudAccount = account)
                val syncResult = RemoteCloudSync(validationDatabase, candidate, drive).incremental()
                Triple(candidate, drive.credential.copy(accountLabel = account), syncResult)
            }
            validationDatabase.close()
            runOnUiThread {
                result.onSuccess { (candidate, savedCredential, syncResult) ->
                    val previousProvider = settings.cloudProvider
                    if (previousProvider != "off" && previousProvider != provider) PrivateCloudCredentials.remove(this, previousProvider)
                    PrivateCloudCredentials.save(this, provider, savedCredential); settings = candidate; store.save(settings)
                    diagnosticLog.record("sync", "private-cloud setup complete; provider=$provider; credential_store=android_keystore; uploaded=${syncResult.uploaded}; downloaded=${syncResult.downloaded}")
                    summary?.text = cloudStatusText(); Toast.makeText(this, R.string.cloud_connected, Toast.LENGTH_LONG).show(); cloudSetupDialog?.dismiss()
                    val returnToOnboarding = cloudSetupForOnboarding || onboarding; cloudSetupForOnboarding = false
                    if (returnToOnboarding) showOnboarding() else showSettings()
                }.onFailure { error ->
                    showCloudFailure(provider, error, connection)
                }
            }
        }.start()
    }
    private fun showCloudFailure(provider: String, error: Throwable, connection: TextView) {
        val message = error.message ?: error.javaClass.simpleName
        connection.text = getString(R.string.cloud_connection_failed, message); connection.setTextColor(Color.rgb(180,83,9))
        diagnosticLog.record("sync", "private-cloud setup failed; provider=$provider; error=$message")
        Toast.makeText(this, getString(R.string.cloud_connection_failed, message), Toast.LENGTH_LONG).show()
    }
    private fun sync() {
        AppSyncCoordinator.request(this, "manual",
            progress = { message -> runOnUiThread { if (::status.isInitialized) status.text = message } },
            completion = { message -> runOnUiThread { refreshStatus(); if (::status.isInitialized) status.text = message; Toast.makeText(this, message, Toast.LENGTH_LONG).show() } })
    }
    private fun dayReport(date: LocalDate): List<AndroidDayReport> {
        val instant = TimeModel.localDateInstant(date, reportTimeZone); TimeModel.localDayInstants(instant, reportTimeZone).map(TimeModel::utcDate).distinct().forEach(database::rebuildAll)
        database.upsertDevice(AndroidDeviceRecord(settings.deviceID, settings.deviceName, "android", settings.updatedAt)); val names = database.devices(); val ids = database.deviceIDs().toMutableList().apply { if (!contains(settings.deviceID)) add(0, settings.deviceID) }
        val result = mutableListOf(AndroidDayReport("alldevices", getString(R.string.all_devices), database.localClockDayBitmap("alldevices", instant, reportTimeZone), database.localDayMinutes("alldevices", instant, reportTimeZone), true))
        ids.forEach { id -> result += AndroidDayReport(id, if (id == settings.deviceID) settings.deviceName else names[id]?.name ?: getString(R.string.other_device), database.localClockDayBitmap(id, instant, reportTimeZone), database.localDayMinutes(id, instant, reportTimeZone), false) }; return result
    }
    private fun multiDayReport(start: LocalDate, end: LocalDate): List<AndroidDailyUsagePoint> { val first = minOf(start, end); val last = maxOf(start, end); database.refreshStatistics(settings); return database.dailyStatistics(first, last).map { AndroidDailyUsagePoint(it.date, it.deviceID, it.displayName, it.minutes, it.aggregate, it.estimated) } }
    private fun periodAsDaily(values: List<AndroidPeriodUsagePoint>) = values.filter { it.includedDays > 0 }.map { AndroidDailyUsagePoint(LocalDate.parse(it.start), it.deviceID, it.displayName, it.averageMinutes.toInt(), it.deviceID == "alldevices", it.estimated) }
    private fun average(value: Double?) = value?.let { duration(it.toInt()) } ?: "—"
    private fun dailyCsv(date: LocalDate, reports: List<AndroidDayReport>) = buildString { append("date,device_id,device_name,minutes,report_timezone,estimated,bitmap\n"); reports.forEach { report -> append("$date,${report.deviceID},\"${report.displayName.replace("\"", "\"\"")}\",${report.usedMinutes},$reportTimeZone,true,${report.minutes.joinToString("") { if (it) "1" else "0" }}\n") } }
    private fun multiDayCsv(points: List<AndroidDailyUsagePoint>) = buildString { append("date,device_id,device_name,minutes,report_timezone,estimated\n"); points.sortedWith(compareBy<AndroidDailyUsagePoint> { it.date }.thenBy { it.displayName }).forEach { point -> append("${point.date},${point.deviceID},\"${point.displayName.replace("\"", "\"\"")}\",${point.minutes},$reportTimeZone,true\n") } }
    private fun duration(minutes: Int) = "${minutes / 60}h ${minutes % 60}m"
    private fun usageIntervals(minutes: BooleanArray): String { val values = mutableListOf<String>(); var start = -1; for (index in 0..minutes.size) { val active = index < minutes.size && minutes[index]; if (active && start < 0) start = index; if (!active && start >= 0) { values += String.format(Locale.US, "%02d:%02d–%02d:%02d", start / 60, start % 60, (index - 1) / 60, (index - 1) % 60); start = -1 } }; return values.ifEmpty { listOf("None") }.joinToString(", ") }
    private fun labeledNumberInput(label: String, value: Int): Pair<View, EditText> {
        val input = EditText(this).apply { inputType = android.text.InputType.TYPE_CLASS_NUMBER; setText(value.toString()); gravity = Gravity.CENTER; setSelectAllOnFocus(true) }
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; addView(TextView(this@MainActivity).apply { text = label; textSize = 15f; setTextColor(Color.rgb(71,85,105)) }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)); addView(input, LinearLayout.LayoutParams(dp(64), LinearLayout.LayoutParams.WRAP_CONTENT)); addView(TextView(this@MainActivity).apply { text = " min"; setTextColor(Color.rgb(71,85,105)) }) }
        return row to input
    }
    private fun chooseDate(initial: LocalDate, update: (LocalDate) -> Unit) { DatePickerDialog(this, { _, year, month, day -> update(LocalDate.of(year, month + 1, day)) }, initial.year, initial.monthValue - 1, initial.dayOfMonth).show() }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun number(value: Long) = NumberFormat.getIntegerInstance(Locale.US).format(value)
    private fun price(value: Double?) = value?.let { "$" + String.format(Locale.US, "%.4f", it * 1_000_000) + "/M" } ?: "N/A"
    private fun revenue(value: Double?) = value?.let { NumberFormat.getCurrencyInstance(Locale.US).apply { maximumFractionDigits = 0 }.format(it) } ?: "N/A"
    private fun compareNullable(a: Double?, b: Double?, descending: Boolean) = when { a == null && b == null -> 0; a == null -> 1; b == null -> -1; descending -> -a.compareTo(b); else -> a.compareTo(b) }
    private fun exportTracking(snapshot: RankingSnapshot) {
        val csv = buildString { append("window_start_utc,window_end_utc,rank,model,input_tokens,output_tokens,total_tokens,input_price_usd_per_token,output_price_usd_per_token,estimated_revenue_usd\n"); snapshot.rows.forEach { row -> append("${snapshot.startDate},${snapshot.endDate},${row.rank},\"${row.model.replace("\"", "\"\"")}\",${row.promptTokens},${row.completionTokens},${row.totalTokens},${row.promptPrice ?: ""},${row.completionPrice ?: ""},${row.revenue ?: ""}\n") } }
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/csv").putExtra(Intent.EXTRA_TEXT, csv).putExtra(Intent.EXTRA_TITLE, "stg-openrouter-${snapshot.startDate}-${snapshot.endDate}.csv"), "Export tracking"))
    }

    private fun exportAppData() {
        runCatching {
            val directory = java.io.File(cacheDir, "data-share").apply { mkdirs() }; val snapshot = java.io.File(directory, "stg.sqlite"); database.exportDatabaseSnapshot(snapshot)
            val settingsFile = java.io.File(directory, "global-settings.json").apply { writeText(settings.toJson().toString(2)) }; val archive = java.io.File(directory, "STG-data-${System.currentTimeMillis()}.zip")
            ZipOutputStream(archive.outputStream()).use { zip -> listOf(snapshot, settingsFile).forEach { file -> zip.putNextEntry(ZipEntry(file.name)); file.inputStream().use { it.copyTo(zip) }; zip.closeEntry() } }
            val uri = FileProvider.getUriForFile(this, "$packageName.files", archive); startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("application/zip").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), getString(R.string.export_app_data))); diagnosticLog.record("diagnostics", "database and global data export prepared")
        }.onFailure { Toast.makeText(this, getString(R.string.export_app_data_failed, it.message ?: it.javaClass.simpleName), Toast.LENGTH_LONG).show() }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (onboarding) {
            if (onboardingStep > 0) { onboardingStep--; showOnboarding() } else finish()
        } else if (currentPage != 0) showHome() else super.onBackPressed()
    }
}
