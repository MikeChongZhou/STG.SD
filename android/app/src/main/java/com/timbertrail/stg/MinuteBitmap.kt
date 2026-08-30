package com.timbertrail.stg

import android.util.Base64

class MinuteBitmap(bytes: ByteArray = ByteArray(BYTE_COUNT)) {
    val data: ByteArray = bytes.copyOf().also { require(it.size == BYTE_COUNT) }
    operator fun get(minute: Int): Boolean = minute in 0 until MINUTE_COUNT && data[minute / 8].toInt() and (1 shl minute % 8) != 0
    fun mark(minute: Int): Boolean {
        require(minute in 0 until MINUTE_COUNT)
        val changed = !get(minute)
        data[minute / 8] = (data[minute / 8].toInt() or (1 shl minute % 8)).toByte()
        return changed
    }
    fun union(other: MinuteBitmap) { data.indices.forEach { data[it] = (data[it].toInt() or other.data[it].toInt()).toByte() } }
    fun count(): Int = data.sumOf { Integer.bitCount(it.toInt() and 0xff) }
    fun base64(): String = Base64.encodeToString(data, Base64.NO_WRAP)
    companion object { const val MINUTE_COUNT = 1440; const val BYTE_COUNT = 180; fun fromBase64(value: String) = MinuteBitmap(Base64.decode(value, Base64.DEFAULT)) }
}
