package com.timbertrail.stg

import java.time.*
import java.time.format.DateTimeFormatter

object TimeModel {
    fun utcDate(instant: Instant): String = DateTimeFormatter.ISO_LOCAL_DATE.format(instant.atZone(ZoneOffset.UTC))
    fun utcMinute(instant: Instant): Int { val value = instant.atZone(ZoneOffset.UTC); return value.hour * 60 + value.minute }
    fun localClockMinute(instant: Instant, zoneID: String): Int { val value = instant.atZone(runCatching { ZoneId.of(zoneID) }.getOrDefault(ZoneId.systemDefault())); return value.hour * 60 + value.minute }
    fun localDateInstant(date: LocalDate, zoneID: String): Instant = date.atTime(12, 0).atZone(runCatching { ZoneId.of(zoneID) }.getOrDefault(ZoneId.systemDefault())).toInstant()
    fun incrementalUploadUtcDates(cursor: String?, now: Instant = Instant.now(), initialDays: Int = 14): List<String> {
        val today = now.atZone(ZoneOffset.UTC).toLocalDate()
        var start = cursor?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: today.minusDays(initialDays.coerceIn(1, 14).toLong() - 1)
        if (start.isAfter(today)) start = today
        return generateSequence(start) { it.plusDays(1).takeIf { next -> !next.isAfter(today) } }.map { it.toString() }.toList()
    }
    fun localDayInstants(instant: Instant, zoneID: String): Sequence<Instant> {
        val zone = runCatching { ZoneId.of(zoneID) }.getOrDefault(ZoneId.systemDefault())
        val date = instant.atZone(zone).toLocalDate()
        val start = date.atStartOfDay(zone).toInstant(); val end = date.plusDays(1).atStartOfDay(zone).toInstant()
        return generateSequence(start) { it.plusSeconds(60).takeIf { next -> next < end } }
    }
}
