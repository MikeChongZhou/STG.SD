package com.timbertrail.stg
import android.content.*
import androidx.core.content.ContextCompat
class BootReceiver : BroadcastReceiver() { override fun onReceive(context: Context, intent: Intent) { if (intent.action == Intent.ACTION_BOOT_COMPLETED) { val enabled = SettingsStore(context).load().launchAtLogin; DiagnosticLog.get(context).record("lifecycle", "boot completed; automatic_start=$enabled"); if (enabled) ContextCompat.startForegroundService(context, Intent(context, UsageMonitorService::class.java)) } } }
