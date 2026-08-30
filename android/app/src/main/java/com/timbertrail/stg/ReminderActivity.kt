package com.timbertrail.stg

import android.app.Activity
import android.os.*
import android.view.Gravity
import android.widget.*

class ReminderActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper()); private lateinit var close: Button; private lateinit var countdown: TextView; private var seconds = 0
    override fun onCreate(state: Bundle?) { super.onCreate(state); val kind = intent.getStringExtra("kind") ?: "eye"; val meeting = intent.getBooleanExtra("meeting", false); seconds = if (meeting) 0 else intent.getIntExtra("countdown", 1) * 60
        val title = if (kind == "eye") "Time for an Eye Break" else if (kind == "posture") "Stand Up & Stretch" else "Daily Limit Reached"; val message = if (kind == "eye") "Look at something 20 feet away for 20 seconds." else if (kind == "posture") "Stand or walk around for 4 minutes and rest your eyes." else "You've used your screen for ${intent.getIntExtra("used", 0) / 60}h ${intent.getIntExtra("used", 0) % 60}m."
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER; setPadding(48,48,48,48) }; layout.addView(TextView(this).apply { text = "🛡"; textSize = 56f; gravity = Gravity.CENTER }); layout.addView(TextView(this).apply { text = title; textSize = 28f; gravity = Gravity.CENTER }); layout.addView(TextView(this).apply { text = message; textSize = 18f; gravity = Gravity.CENTER; setPadding(0,30,0,30) }); countdown = TextView(this).apply { gravity = Gravity.CENTER }; layout.addView(countdown); close = Button(this).apply { text = "Close"; isEnabled = seconds == 0; setOnClickListener { finish() } }; layout.addView(close); setContentView(layout); update() }
    private fun update() { countdown.text = if (seconds > 0) "Close available in ${seconds}s" else if (intent.getBooleanExtra("meeting", false)) "Meeting mode: can close immediately" else ""; close.isEnabled = seconds <= 0; if (seconds-- > 0) handler.postDelayed({ update() }, 1000) }
    override fun onBackPressed() { if (seconds <= 0) super.onBackPressed() }
}

