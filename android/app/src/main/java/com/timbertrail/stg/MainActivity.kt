package com.timbertrail.stg

import android.Manifest
import android.app.*
import android.content.*
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.core.content.ContextCompat
import java.text.NumberFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Locale

class MainActivity : Activity() {
    private lateinit var store: SettingsStore; private lateinit var database: BitmapDatabase; private lateinit var settings: AppSettings; private lateinit var status: TextView; private val chooseFolder = 42; private var onboarding = false; private var onboardingStep = 0
    override fun onCreate(state: Bundle?) { super.onCreate(state); store = SettingsStore(this); database = BitmapDatabase(this); settings = store.load(); ensureNotificationChannels(); onboarding = !store.onboardingComplete(); if (onboarding) showOnboarding() else { startMonitorService(); showHome() } }
    override fun onResume() { super.onResume(); if (onboarding) window.decorView.postDelayed({ if (onboarding) showOnboarding() }, 150) else if (::status.isInitialized) refreshStatus() }
    private fun showHome() { val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(36,64,36,36) }; root.addView(TextView(this).apply { text = "🛡  Screen Time Guardian"; textSize = 28f; gravity = Gravity.CENTER }); status = TextView(this).apply { textSize = 18f; setPadding(0,36,0,24) }; root.addView(status); listOf("Report" to ::showReport, "Tracking" to ::showTracking, "Settings" to ::showSettings, "About" to ::showAbout).forEach { (name, action) -> root.addView(Button(this).apply { text = name; setOnClickListener { action() } }) }; root.addView(Button(this).apply { text = "Sync now"; setOnClickListener { sync() } }); setContentView(ScrollView(this).apply { addView(root) }); refreshStatus() }
    private fun showOnboarding() {
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(42, 54, 42, 36) }
        root.addView(TextView(this).apply { text = "Setup · Step ${onboardingStep + 1} of 4"; textSize = 15f; setTextColor(Color.rgb(71,85,105)) })
        root.addView(ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply { max = 4; progress = onboardingStep + 1; setPadding(0, 14, 0, 28) })
        fun title(value: String) = root.addView(TextView(this).apply { text = value; textSize = 27f; setTextColor(Color.rgb(15,23,42)); setPadding(0, 8, 0, 18) })
        fun detail(value: String) = root.addView(TextView(this).apply { text = value; textSize = 16f; setTextColor(Color.rgb(71,85,105)); setPadding(0, 0, 0, 18) })
        fun statusRow(name: String, enabled: Boolean, note: String = if (enabled) "Enabled" else "Needs attention") = root.addView(TextView(this).apply { text = "$name\n$note"; textSize = 16f; setTextColor(if (enabled) Color.rgb(15,118,110) else Color.rgb(180,83,9)); setPadding(22, 18, 22, 18); setBackgroundColor(Color.rgb(241,245,249)) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(10) })
        when (onboardingStep) {
            0 -> { title("Welcome to Screen Time Guardian"); detail("We’ll configure reminder delivery and Usage Stats access before starting the screen-time monitor. Every permission remains under your control in Android Settings.") }
            1 -> {
                title("Notifications and sound"); val notifications = androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled(); val channel = if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java).getNotificationChannel("stg-alert") else null; val sound = if (Build.VERSION.SDK_INT < 26) notifications else channel != null && channel.importance >= NotificationManager.IMPORTANCE_HIGH && channel.sound != null
                statusRow("Display notifications", notifications); statusRow("Reminder sound / high priority", sound, if (sound) "Enabled" else "Open notification settings and enable sound")
                root.addView(Button(this).apply { text = "Allow notifications"; setOnClickListener { if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7) else openNotificationSettings() } })
                root.addView(Button(this).apply { text = "Open notification settings"; setOnClickListener { openNotificationSettings() } })
            }
            2 -> {
                title("On-screen reminder presentation"); val overlay = Settings.canDrawOverlays(this); val fullScreen = if (Build.VERSION.SDK_INT >= 34) getSystemService(NotificationManager::class.java).canUseFullScreenIntent() else true
                statusRow("Display over other apps", overlay); statusRow("Full-screen reminder", fullScreen, if (fullScreen) "Allowed" else "Allow full-screen notifications in Special app access")
                detail("These permissions let a break reminder appear above the current app. Android may place full-screen notification access under Special app access on newer versions.")
                root.addView(Button(this).apply { text = "Allow display over other apps"; setOnClickListener { startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${this@MainActivity.packageName}"))) } })
                if (Build.VERSION.SDK_INT >= 34) root.addView(Button(this).apply { text = "Open full-screen notification access"; setOnClickListener { startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:${this@MainActivity.packageName}"))) } })
            }
            else -> {
                title("Usage Stats access"); val usage = hasUsageStatsAccess(); statusRow("Usage Stats", usage); detail("Usage Stats lets STG determine whether the device is actively being used. STG stores only minute-level bitmap estimates in its local database and your selected private cloud.")
                root.addView(Button(this).apply { text = "Open Usage Stats permission"; setOnClickListener { startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)) } })
            }
        }
        val navigation = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.END; setPadding(0, 28, 0, 0) }
        if (onboardingStep > 0) navigation.addView(Button(this).apply { text = "Back"; setOnClickListener { onboardingStep--; showOnboarding() } })
        navigation.addView(Button(this).apply { text = if (onboardingStep < 3) "Continue" else "Finish setup"; setOnClickListener { if (onboardingStep < 3) { onboardingStep++; showOnboarding() } else { store.completeOnboarding(); onboarding = false; startMonitorService(); showHome() } } })
        root.addView(navigation); setContentView(ScrollView(this).apply { addView(root) })
    }
    private fun ensureNotificationChannels() { if (Build.VERSION.SDK_INT < 26) return; val manager = getSystemService(NotificationManager::class.java); manager.createNotificationChannel(NotificationChannel("stg-service", "STG service", NotificationManager.IMPORTANCE_LOW)); manager.createNotificationChannel(NotificationChannel("stg-alert", "STG reminders", NotificationManager.IMPORTANCE_HIGH)); manager.createNotificationChannel(NotificationChannel("stg-silent", "STG meeting reminders", NotificationManager.IMPORTANCE_DEFAULT).apply { setSound(null, null) }) }
    private fun openNotificationSettings() { val intent = if (Build.VERSION.SDK_INT >= 26) Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName) else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")); startActivity(intent) }
    private fun hasUsageStatsAccess(): Boolean { val manager = getSystemService(android.app.AppOpsManager::class.java); val mode = if (Build.VERSION.SDK_INT >= 29) manager.unsafeCheckOpNoThrow(android.app.AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), packageName) else manager.checkOpNoThrow(android.app.AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), packageName); return mode == android.app.AppOpsManager.MODE_ALLOWED }
    private fun startMonitorService() = ContextCompat.startForegroundService(this, Intent(this, UsageMonitorService::class.java))
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) { super.onRequestPermissionsResult(requestCode, permissions, grantResults); if (onboarding) showOnboarding() }
    private fun refreshStatus() { val now = Instant.now(); database.rebuildAll(TimeModel.utcDate(now)); database.upsertDevice(AndroidDeviceRecord(settings.deviceID, settings.deviceName, "android", settings.updatedAt)); val local = database.localDayMinutes(settings.deviceID, now, settings.reportTimeZone); val all = database.localDayMinutes("alldevices", now, settings.reportTimeZone); status.text = "All devices today: ${duration(all)}\nThis device: ${duration(local)}\nPlan: ${duration(settings.dailyPlanMinutes)}\nReport timezone: ${settings.reportTimeZone}" }
    private fun showReport() {
        var dailyDate = LocalDate.now(runCatching { java.time.ZoneId.of(settings.reportTimeZone) }.getOrDefault(java.time.ZoneId.systemDefault()))
        var rangeStart = dailyDate.minusDays(6); var rangeEnd = dailyDate; var mode = 0
        var daily = dayReport(dailyDate); var points = multiDayReport(rangeStart, rangeEnd)
        val modes = Spinner(this).apply { adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, listOf("Daily report", "Multiple days")) }
        val dailyDateButton = Button(this).apply { text = "Report date: $dailyDate" }
        val startButton = Button(this).apply { text = "Start: $rangeStart" }; val endButton = Button(this).apply { text = "End: $rangeEnd" }
        val dailyControls = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; addView(dailyDateButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)) }
        val rangeControls = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; addView(startButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)); addView(endButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)); visibility = View.GONE }
        val content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(26, 8, 26, 0); addView(modes); addView(dailyControls); addView(rangeControls); addView(ScrollView(this@MainActivity).apply { addView(content) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)) }
        lateinit var render: () -> Unit
        render = {
            content.removeAllViews()
            if (mode == 0) {
                val aggregate = daily.firstOrNull { it.aggregate }; val local = daily.firstOrNull { it.deviceID == settings.deviceID }
                content.addView(TextView(this).apply { text = "All devices: ${duration(aggregate?.usedMinutes ?: 0)}    This device: ${duration(local?.usedMinutes ?: 0)}    Plan: ${duration(settings.dailyPlanMinutes)}\nReport timezone: ${settings.reportTimeZone}"; textSize = 16f; setPadding(8, 18, 8, 18) })
                daily.forEach { report -> content.addView(LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(8, 12, 8, 18); addView(TextView(this@MainActivity).apply { text = "${report.displayName}    ${duration(report.usedMinutes)}"; textSize = 17f }); addView(AndroidMinuteBitmapView(this@MainActivity).apply { minutes = report.minutes; contentDescription = "${report.displayName}, ${report.usedMinutes} used minutes" }) }) }
            } else {
                content.addView(TextView(this).apply { text = "One line per device; All devices is the deduplicated device-set line.\n$rangeStart – $rangeEnd · ${settings.reportTimeZone}"; setPadding(8, 16, 8, 10) })
                content.addView(AndroidUsageLineChartView(this).apply { this.points = points })
            }
        }
        dailyDateButton.setOnClickListener { chooseDate(dailyDate) { dailyDate = it; dailyDateButton.text = "Report date: $it"; daily = dayReport(it); render() } }
        startButton.setOnClickListener { chooseDate(rangeStart) { rangeStart = it; startButton.text = "Start: $it"; points = multiDayReport(rangeStart, rangeEnd); render() } }
        endButton.setOnClickListener { chooseDate(rangeEnd) { rangeEnd = it; endButton.text = "End: $it"; points = multiDayReport(rangeStart, rangeEnd); render() } }
        modes.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener { override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) { mode = position; dailyControls.visibility = if (mode == 0) View.VISIBLE else View.GONE; rangeControls.visibility = if (mode == 1) View.VISIBLE else View.GONE; render() }; override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {} }
        render()
        val dialog = AlertDialog.Builder(this).setTitle("Screen Time Report").setView(root).setNegativeButton("Close", null).setNeutralButton("Export CSV", null).setPositiveButton("Refresh", null).create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { if (mode == 0) daily = dayReport(dailyDate) else points = multiDayReport(rangeStart, rangeEnd); render() }
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener { val csv = if (mode == 0) dailyCsv(dailyDate, daily) else multiDayCsv(points); startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/csv").putExtra(Intent.EXTRA_TEXT, csv).putExtra(Intent.EXTRA_TITLE, if (mode == 0) "stg-daily-report.csv" else "stg-multi-day-report.csv"), "Export report")) }
        }
        dialog.show()
    }
    private fun showTracking() {
        var customStart = LocalDate.now(ZoneOffset.UTC).minusDays(7)
        val startButton = Button(this).apply { text = "Start: $customStart" }
        startButton.setOnClickListener { chooseDate(customStart) { chosen -> val latest = LocalDate.now(ZoneOffset.UTC).minusDays(1); customStart = minOf(chosen, latest); startButton.text = "Start: $customStart" } }
        val statusText = TextView(this).apply { text = "Public data; no OpenRouter account or API key is needed. Prices are effective weighted prices; revenue is estimated."; setPadding(0, 12, 0, 12) }
        val table = TableLayout(this).apply { isStretchAllColumns = false }
        val tableScroll = HorizontalScrollView(this).apply { addView(ScrollView(this@MainActivity).apply { addView(table) }); layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f) }
        val chart = AndroidTrackingLineChartView(this)
        val metric = Spinner(this).apply { adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, listOf("Total tokens", "Input tokens", "Output tokens", "Rank", "Input price / M", "Output price / M", "Revenue")) }
        val weeklyPanel = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; addView(metric); addView(chart, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)) }
        val topPanel = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; addView(startButton); addView(TextView(this@MainActivity).apply { text = "Top 20 through the latest completed UTC day. Data loads only when this view is opened." }); addView(tableScroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)) }
        val modes = Spinner(this).apply { adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, listOf("Weekly trends", "Top 20 from date")) }
        val refresh = Button(this).apply { text = "Refresh Top 20" }
        val export = Button(this).apply { text = "Export Top 20 CSV" }
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(24, 8, 24, 0); minimumHeight = dp(560); addView(modes); addView(LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL; addView(refresh); addView(export) }); addView(statusText); addView(weeklyPanel, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)); addView(topPanel, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)) }
        var snapshot: RankingSnapshot? = null; var sortField = "rank"; var descending = false
        lateinit var render: () -> Unit
        render = {
            table.removeAllViews()
            val headers = listOf("Rank" to "rank", "Model" to "model", "Input tokens" to "prompt", "Output tokens" to "completion", "Total tokens" to "total", "Input price" to "promptPrice", "Output price" to "completionPrice", "Revenue" to "revenue")
            table.addView(TableRow(this).apply { headers.forEach { (label, field) -> addView(Button(this@MainActivity).apply { text = label + if (sortField == field) if (descending) " ↓" else " ↑" else ""; setOnClickListener { if (sortField == field) descending = !descending else { sortField = field; descending = true }; render() } }) } })
            val source = snapshot?.rows.orEmpty(); val ordered = source.sortedWith { a, b ->
                val nullableResult = when (sortField) { "promptPrice" -> compareNullable(a.promptPrice, b.promptPrice, descending); "completionPrice" -> compareNullable(a.completionPrice, b.completionPrice, descending); "revenue" -> compareNullable(a.revenue, b.revenue, descending); else -> null }
                nullableResult ?: run { val result = when (sortField) { "model" -> a.model.compareTo(b.model, true); "prompt" -> a.promptTokens.compareTo(b.promptTokens); "completion" -> a.completionTokens.compareTo(b.completionTokens); "total" -> a.totalTokens.compareTo(b.totalTokens); else -> a.rank.compareTo(b.rank) }; if (descending) -result else result }
            }
            ordered.forEach { row -> table.addView(TableRow(this).apply { listOf(row.rank.toString(), row.model, number(row.promptTokens), number(row.completionTokens), number(row.totalTokens), price(row.promptPrice), price(row.completionPrice), revenue(row.revenue)).forEachIndexed { index, value -> addView(TextView(this@MainActivity).apply { text = value; setPadding(18, 12, 18, 12); setTextColor(Color.rgb(24, 35, 48)); gravity = if (index == 1) Gravity.START else Gravity.END; setSingleLine(true) }) } }) }
        }
        render()
        fun loadTop() { statusText.text = "Loading public ranking data…"; Thread { val result = runCatching { OpenRouterClient().top20(customStart, LocalDate.now(ZoneOffset.UTC).minusDays(1)) }; runOnUiThread { result.onSuccess { snapshot = it; statusText.text = "${it.startDate} – ${it.endDate} UTC · ${it.citation}"; render() }.onFailure { statusText.text = "Failed: ${it.message}" } } }.start() }
        fun loadWeeks() { val models = snapshot?.rows?.sortedBy { it.rank }?.take(10)?.map { it.model } ?: database.latestOpenRouterTopModels(); chart.rows = database.openRouterWeeks(models); statusText.text = if (chart.rows.isEmpty()) "Weekly data will be collected by the weekly action during incremental sync." else "Showing saved weekly data for the latest Top 10 models. Historical seed data contains Rank and Total tokens; OpenRouter does not publish its historical input/output split and returned no rows for 2025-06-15 or 2025-07-15." }
        refresh.setOnClickListener { loadTop() }; export.setOnClickListener { snapshot?.let(::exportTracking) ?: Toast.makeText(this, "Open or refresh Top 20 first", Toast.LENGTH_SHORT).show() }
        metric.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener { override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) { chart.metric = metric.selectedItem.toString() }; override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {} }
        modes.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener { override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) { weeklyPanel.visibility = if (position == 0) View.VISIBLE else View.GONE; topPanel.visibility = if (position == 1) View.VISIBLE else View.GONE; refresh.visibility = if (position == 1) View.VISIBLE else View.GONE; export.visibility = refresh.visibility; if (position == 0) loadWeeks() else if (snapshot == null) loadTop() }; override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {} }
        AlertDialog.Builder(this).setTitle("OpenRouter Tracking").setView(layout).setNegativeButton("Close", null).create().also { dialog ->
            dialog.setOnShowListener { dialog.window?.setLayout((resources.displayMetrics.widthPixels * 0.96).toInt(), (resources.displayMetrics.heightPixels * 0.88).toInt()) }
            dialog.show()
        }
    }
    private fun showAbout() { AlertDialog.Builder(this).setTitle("Screen Time Guardian 1.1.6").setMessage("Developer: TimberTrail\n\nScreen use stays on this device and your authorized private cloud.\n\nReminders support configurable close countdowns. During an automatically detected call or meeting, reminders are silent and can be closed immediately.\n\nOpen-source claim: STG includes open-source Android and SQLite components under their respective licenses; STG does not claim ownership of those components.").setPositiveButton("Close", null).show() }
    private fun showSettings() {
        val plan = numberInput("Daily plan minutes", settings.dailyPlanMinutes); val zone = EditText(this).apply { setText(settings.reportTimeZone); hint = "IANA report timezone" }; val eye = numberInput("Eye reminder close countdown (minutes)", settings.eyeCountdown); val posture = numberInput("Posture reminder close countdown (minutes)", settings.postureCountdown); val daily = numberInput("Daily-limit close countdown (minutes)", settings.dailyCountdown); val meeting = CheckBox(this).apply { text = "Manual meeting mode override"; isChecked = settings.meetingMode }
        val meetingStatus = TextView(this).apply { val result = MeetingDetector(this@MainActivity).checkAndLog(); text = "Automatic meeting detection: ${if (result.isInMeeting) "In meeting" else "Not in meeting"}\n${result.reason}"; setPadding(0, 8, 0, 8) }
        val permissionStatus = TextView(this).apply { text = "Notifications: ${if (androidx.core.app.NotificationManagerCompat.from(this@MainActivity).areNotificationsEnabled()) "Enabled" else "Needs attention"}\nDisplay over apps: ${if (Settings.canDrawOverlays(this@MainActivity)) "Enabled" else "Needs attention"}\nUsage Stats: ${if (hasUsageStatsAccess()) "Enabled" else "Needs attention"}"; setPadding(0, 12, 0, 12) }
        val cloudStatus = TextView(this).apply { text = "Private cloud: ${providerLabel(settings.cloudProvider)}\n${if (settings.cloudTreeUri == null) "Not connected" else "Connected storage authorized"}"; setPadding(0, 12, 0, 8) }
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(40,10,40,0); addView(plan); addView(zone); addView(eye); addView(posture); addView(daily); addView(meeting); addView(meetingStatus)
            addView(Button(this@MainActivity).apply { text = "Check meeting status now"; setOnClickListener { val result = MeetingDetector(this@MainActivity).checkAndLog(); meetingStatus.text = "Automatic meeting detection: ${if (result.isInMeeting) "In meeting" else "Not in meeting"}\n${result.reason}" } })
            addView(cloudStatus); addView(Button(this@MainActivity).apply { text = "Configure private cloud"; setOnClickListener { showCloudSetup(cloudStatus) } })
            addView(permissionStatus); addView(Button(this@MainActivity).apply { text = "Open notification settings"; setOnClickListener { openNotificationSettings() } }); addView(Button(this@MainActivity).apply { text = "Open display-over-apps permission"; setOnClickListener { startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${this@MainActivity.packageName}"))) } }); addView(Button(this@MainActivity).apply { text = "Open Usage Stats permission"; setOnClickListener { startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)) } })
        }
        AlertDialog.Builder(this).setTitle("Settings").setView(ScrollView(this).apply { addView(layout) }).setNegativeButton("Cancel", null).setPositiveButton("Save") { _, _ -> settings.dailyPlanMinutes = plan.text.toString().toIntOrNull()?.coerceIn(20,1440) ?: 600; settings.reportTimeZone = zone.text.toString(); settings.eyeCountdown = eye.text.toString().toIntOrNull()?.coerceIn(0,10) ?: 1; settings.postureCountdown = posture.text.toString().toIntOrNull()?.coerceIn(0,10) ?: 2; settings.dailyCountdown = daily.text.toString().toIntOrNull()?.coerceIn(0,10) ?: 3; settings.meetingMode = meeting.isChecked; store.save(settings); refreshStatus() }.show()
    }
    private fun showCloudSetup(summary: TextView? = null) {
        val ios = CheckBox(this).apply { text = "iPhone / iPad" }; val mac = CheckBox(this).apply { text = "Mac" }; val windows = CheckBox(this).apply { text = "Windows" }; val currentAndroid = CheckBox(this).apply { text = "This Android device"; isChecked = true; isEnabled = false }; val china = CheckBox(this).apply { text = "Use while travelling in mainland China" }
        val recommendation = TextView(this).apply { textSize = 20f; setPadding(0,16,0,12) }
        val provider = Spinner(this).apply { adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, listOf("Off — single device", "Microsoft OneDrive", "Google Drive")); setSelection(when(settings.cloudProvider){"onedrive"->1;"google"->2;else->0}) }
        fun update() { recommendation.text = "Recommended: ${if(china.isChecked) "Microsoft OneDrive" else "Google Drive"}"; provider.setSelection(if(china.isChecked) 1 else 2) }
        china.setOnCheckedChangeListener { _, _ -> update() }; update()
        val connect = Button(this).apply { text = "Connect selected provider"; setOnClickListener { settings.cloudProvider = if(provider.selectedItemPosition==1) "onedrive" else "google"; store.save(settings); startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION), chooseFolder) } }
        val layout = LinearLayout(this).apply { orientation=LinearLayout.VERTICAL; setPadding(36,8,36,0); addView(TextView(this@MainActivity).apply{text="Which devices will share this data?";textSize=18f}); addView(currentAndroid);addView(ios);addView(mac);addView(windows);addView(china);addView(recommendation);addView(provider);addView(connect);addView(TextView(this@MainActivity).apply{text="Android currently authorizes the provider through the system document-provider account surface. STG stores only its own sync folder.";setPadding(0,12,0,0)}) }
        AlertDialog.Builder(this).setTitle("Configure private cloud").setView(ScrollView(this).apply{addView(layout)}).setNegativeButton("Cancel",null).setPositiveButton("Save") { _,_-> settings.cloudProvider=when(provider.selectedItemPosition){1->"onedrive";2->"google";else->"off"};store.save(settings);summary?.text="Private cloud: ${providerLabel(settings.cloudProvider)}\n${if(settings.cloudTreeUri==null)"Not connected" else "Connected storage authorized"}" }.show()
    }
    private fun providerLabel(value: String) = when(value){"onedrive"->"Microsoft OneDrive";"google"->"Google Drive";else->"Off — single device"}
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) { super.onActivityResult(requestCode, resultCode, data); if (requestCode == chooseFolder && resultCode == RESULT_OK) data?.data?.let { contentResolver.takePersistableUriPermission(it, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION); settings.cloudTreeUri = it.toString(); store.save(settings) } }
    private fun sync() { Thread { val message = runCatching { val result = SafCloudSync(this, database, settings).incremental(); runWeeklyActionIfDue(); val cursors = result.downloadCursors.entries.sortedBy { it.key }.joinToString { "${it.key.take(8)}=${it.value}" }; "Uploaded ${result.uploaded}, downloaded ${result.downloaded}\nUpload cursor: ${result.uploadCursor ?: "none"}" + if (cursors.isEmpty()) "" else "\nLatest downloads: $cursors" }.getOrElse { "Sync failed: ${it.message}" }; runOnUiThread { Toast.makeText(this, message, Toast.LENGTH_LONG).show(); refreshStatus() } }.start() }
    private fun runWeeklyActionIfDue() {
        val today = LocalDate.now(ZoneOffset.UTC)
        val monday = today.with(java.time.temporal.TemporalAdjusters.previousOrSame(java.time.DayOfWeek.MONDAY))
        val lastSunday = monday.minusDays(1)
        val period = lastSunday.toString()
        if (database.weeklyActionCompletedPeriod() == period) return
        val start = database.latestOpenRouterWeekEnd()?.let(LocalDate::parse)?.plusDays(1) ?: LocalDate.of(2025, 1, 1)
        if (!start.isAfter(lastSunday)) {
            val rows = OpenRouterClient().weeklyHistory(start, lastSunday)
            check(rows.isNotEmpty()) { "OpenRouter returned no weekly model-activity rows; detail cursor was not advanced" }
            database.saveOpenRouterWeeks(rows)
        }
        database.completeOpenRouterDetailWeek(period)
        database.completeWeeklyAction(period)
    }
    private fun dayReport(date: LocalDate): List<AndroidDayReport> {
        val instant = TimeModel.localDateInstant(date, settings.reportTimeZone); TimeModel.localDayInstants(instant, settings.reportTimeZone).map(TimeModel::utcDate).distinct().forEach(database::rebuildAll)
        database.upsertDevice(AndroidDeviceRecord(settings.deviceID, settings.deviceName, "android", settings.updatedAt)); val names = database.devices(); val ids = database.deviceIDs().toMutableList().apply { if (!contains(settings.deviceID)) add(0, settings.deviceID) }
        val result = mutableListOf(AndroidDayReport("alldevices", "All devices", database.localClockDayBitmap("alldevices", instant, settings.reportTimeZone), database.localDayMinutes("alldevices", instant, settings.reportTimeZone), true))
        ids.forEach { id -> result += AndroidDayReport(id, if (id == settings.deviceID) settings.deviceName else names[id]?.name ?: "Other device", database.localClockDayBitmap(id, instant, settings.reportTimeZone), database.localDayMinutes(id, instant, settings.reportTimeZone), false) }; return result
    }
    private fun multiDayReport(start: LocalDate, end: LocalDate): List<AndroidDailyUsagePoint> { val first = minOf(start, end); val last = maxOf(start, end); val result = mutableListOf<AndroidDailyUsagePoint>(); var date = first; while (!date.isAfter(last)) { result += dayReport(date).map { AndroidDailyUsagePoint(date, it.deviceID, it.displayName, it.usedMinutes, it.aggregate) }; date = date.plusDays(1) }; return result }
    private fun dailyCsv(date: LocalDate, reports: List<AndroidDayReport>) = buildString { append("date,device_id,device_name,minutes,report_timezone,estimated,bitmap\n"); reports.forEach { report -> append("$date,${report.deviceID},\"${report.displayName.replace("\"", "\"\"")}\",${report.usedMinutes},${settings.reportTimeZone},true,${report.minutes.joinToString("") { if (it) "1" else "0" }}\n") } }
    private fun multiDayCsv(points: List<AndroidDailyUsagePoint>) = buildString { append("date,device_id,device_name,minutes,report_timezone,estimated\n"); points.sortedWith(compareBy<AndroidDailyUsagePoint> { it.date }.thenBy { it.displayName }).forEach { point -> append("${point.date},${point.deviceID},\"${point.displayName.replace("\"", "\"\"")}\",${point.minutes},${settings.reportTimeZone},true\n") } }
    private fun duration(minutes: Int) = "${minutes / 60}h ${minutes % 60}m"
    private fun numberInput(label: String, value: Int) = EditText(this).apply { inputType = android.text.InputType.TYPE_CLASS_NUMBER; hint = label; setText(value.toString()) }
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
}
