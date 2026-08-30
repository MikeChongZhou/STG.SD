package com.timbertrail.stg

import android.content.Context
import android.media.AudioManager
import android.telecom.TelecomManager
import android.util.Log

data class MeetingDetectionResult(val isInMeeting: Boolean, val reason: String)

class MeetingDetector(private val context: Context) {
    fun check(): MeetingDetectionResult {
        val audio = context.getSystemService(AudioManager::class.java)
        if (audio.mode == AudioManager.MODE_IN_COMMUNICATION || audio.mode == AudioManager.MODE_IN_CALL) {
            return MeetingDetectionResult(true, "Android audio mode=${audio.mode}")
        }
        val telecomInCall = runCatching { context.getSystemService(TelecomManager::class.java).isInCall }.getOrDefault(false)
        if (telecomInCall) return MeetingDetectionResult(true, "Android telecom reports an active call")
        return MeetingDetectionResult(false, "no active call or communication audio mode")
    }

    fun checkAndLog(): MeetingDetectionResult = check().also { Log.i("STGMeeting", "detected=${it.isInMeeting}; reason=${it.reason}") }
}
