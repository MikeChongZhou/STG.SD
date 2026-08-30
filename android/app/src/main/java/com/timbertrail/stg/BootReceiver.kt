package com.timbertrail.stg
import android.content.*
import androidx.core.content.ContextCompat
class BootReceiver : BroadcastReceiver() { override fun onReceive(context: Context, intent: Intent) { if (intent.action == Intent.ACTION_BOOT_COMPLETED) ContextCompat.startForegroundService(context, Intent(context, UsageMonitorService::class.java)) } }
