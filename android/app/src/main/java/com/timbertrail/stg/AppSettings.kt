package com.timbertrail.stg

import android.content.Context
import android.content.res.Configuration
import android.provider.Settings
import org.json.JSONObject
import java.time.ZoneId
import java.util.Locale
import java.util.UUID

data class AppSettings(
    var deviceID: String,
    var deviceName: String,
    var dailyPlanMinutes: Int = 600,
    var reportTimeZone: String = ZoneId.systemDefault().id,
    var eyeCountdown: Int = 1,
    var postureCountdown: Int = 2,
    var dailyCountdown: Int = 3,
    var meetingMode: Boolean = false,
    var cloudProvider: String = "off",
    var cloudAccount: String = "",
    var eyeNotificationsEnabled: Boolean = true,
    var postureNotificationsEnabled: Boolean = true,
    var dailyNotificationsEnabled: Boolean = true,
    var updatedAt: Long = java.time.Instant.now().epochSecond
) {
    fun toJson() = JSONObject().apply {
        put("device_id", deviceID); put("device_name", deviceName); put("device_kind", "android")
        put("daily_plan_minutes", dailyPlanMinutes); put("report_time_zone", reportTimeZone)
        put("eye_close_countdown_minutes", eyeCountdown); put("posture_close_countdown_minutes", postureCountdown)
        put("daily_close_countdown_minutes", dailyCountdown); put("launch_at_login", true); put("meeting_mode", meetingMode)
        put("updated_at", java.time.Instant.ofEpochSecond(updatedAt).toString()); put("reserved", JSONObject())
    }
}

class SettingsStore(context: Context) {
    private val preferences = context.getSharedPreferences("stg", Context.MODE_PRIVATE)
    private val defaultID = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)?.let { UUID.nameUUIDFromBytes(it.toByteArray()).toString() } ?: UUID.randomUUID().toString()
    fun load() = AppSettings(
        preferences.getString("deviceID", defaultID)!!,
        preferences.getString("deviceName", android.os.Build.MODEL)!!,
        preferences.getInt("dailyPlan", 600), preferences.getString("reportZone", ZoneId.systemDefault().id)!!,
        preferences.getInt("eyeCountdown", 1), preferences.getInt("postureCountdown", 2), preferences.getInt("dailyCountdown", 3),
        preferences.getBoolean("meetingMode", false), preferences.getString("cloudProvider", "off")!!, preferences.getString("cloudAccount", "")!!, preferences.getBoolean("eyeNotificationsEnabled", preferences.getBoolean("breakNotificationsEnabled", true)), preferences.getBoolean("postureNotificationsEnabled", preferences.getBoolean("breakNotificationsEnabled", true)), preferences.getBoolean("dailyNotificationsEnabled", true), normalizeSeconds(preferences.getLong("updatedAt", java.time.Instant.now().epochSecond))
    )
    fun save(value: AppSettings) { value.updatedAt = java.time.Instant.now().epochSecond; preferences.edit().putString("deviceID", value.deviceID).putString("deviceName", value.deviceName).putInt("dailyPlan", value.dailyPlanMinutes).putString("reportZone", value.reportTimeZone).putInt("eyeCountdown", value.eyeCountdown).putInt("postureCountdown", value.postureCountdown).putInt("dailyCountdown", value.dailyCountdown).putBoolean("meetingMode", value.meetingMode).putBoolean("eyeNotificationsEnabled", value.eyeNotificationsEnabled).putBoolean("postureNotificationsEnabled", value.postureNotificationsEnabled).putBoolean("dailyNotificationsEnabled", value.dailyNotificationsEnabled).putString("cloudProvider", value.cloudProvider).putString("cloudAccount", value.cloudAccount).remove("cloudTreeUri").putLong("updatedAt", value.updatedAt).apply() }
    fun language() = preferences.getString("appLanguage", "system") ?: "system"
    fun saveLanguage(value: String) = preferences.edit().putString("appLanguage", value).apply()
    private fun normalizeSeconds(value: Long) = if (kotlin.math.abs(value) >= 100_000_000_000L) value / 1000 else value
    fun onboardingComplete() = preferences.getBoolean("permissionOnboardingV1Complete", false)
    fun completeOnboarding() = preferences.edit().putBoolean("permissionOnboardingV1Complete", true).apply()
}

object LanguageSupport {
    val codes = listOf("system", "en", "zh", "es")
    fun wrap(context: Context): Context {
        val code = context.getSharedPreferences("stg", Context.MODE_PRIVATE).getString("appLanguage", "system") ?: "system"
        if (code == "system") return context
        val locale = when (code) { "zh" -> Locale.SIMPLIFIED_CHINESE; "es" -> Locale.forLanguageTag("es"); else -> Locale.ENGLISH }
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocale(locale)
        configuration.setLayoutDirection(locale)
        return context.createConfigurationContext(configuration)
    }
}
