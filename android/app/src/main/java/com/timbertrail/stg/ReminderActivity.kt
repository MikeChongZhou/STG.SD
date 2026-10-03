package com.timbertrail.stg

import android.app.Activity
import android.content.Context
import android.os.*
import android.view.Gravity
import android.widget.*

class ReminderActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper()); private lateinit var close: Button; private lateinit var countdown: TextView; private var seconds = 0
    override fun attachBaseContext(newBase: Context) { super.attachBaseContext(LanguageSupport.wrap(newBase)) }
    override fun onCreate(state: Bundle?) { super.onCreate(state); val kind = intent.getStringExtra("kind") ?: "eye"; val meeting = intent.getBooleanExtra("meeting", false); seconds = if (meeting) 0 else intent.getIntExtra("countdown", 1) * 60
        val settings = SettingsStore(this).load()
        if (when (kind) { "daily" -> !settings.dailyNotificationsEnabled; "posture" -> !settings.postureNotificationsEnabled; else -> !settings.eyeNotificationsEnabled }) { finish(); return }
        val used = intent.getIntExtra("used", 0); val title = getString(if (kind == "eye") R.string.eye_break_title else if (kind == "posture") R.string.posture_break_title else R.string.daily_limit_title); val message = if (kind == "eye") getString(R.string.eye_break_body) else if (kind == "posture") getString(R.string.posture_break_body) else getString(R.string.daily_limit_body, used / 60, used % 60)
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER; setPadding(48,48,48,48) }; layout.addView(TextView(this).apply { text = "🛡"; textSize = 56f; gravity = Gravity.CENTER }); layout.addView(TextView(this).apply { text = title; textSize = 28f; gravity = Gravity.CENTER }); layout.addView(TextView(this).apply { text = message; textSize = 18f; gravity = Gravity.CENTER; setPadding(0,30,0,30) }); countdown = TextView(this).apply { gravity = Gravity.CENTER }; layout.addView(countdown); close = Button(this).apply { text = getString(R.string.close); isEnabled = seconds == 0; setOnClickListener { finish() } }; layout.addView(close); setContentView(layout); update() }
    private fun update() { countdown.text = if (seconds > 0) getString(R.string.close_available, seconds) else if (intent.getBooleanExtra("meeting", false)) getString(R.string.meeting_close) else ""; close.isEnabled = seconds <= 0; if (seconds-- > 0) handler.postDelayed({ update() }, 1000) }
    override fun onBackPressed() { if (seconds <= 0) super.onBackPressed() }
}
