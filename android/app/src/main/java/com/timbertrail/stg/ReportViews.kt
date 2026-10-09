package com.timbertrail.stg

import android.content.Context
import android.graphics.*
import android.view.View
import java.time.LocalDate
import kotlin.math.ceil
import kotlin.math.max

data class AndroidDayReport(val deviceID: String, val displayName: String, val minutes: BooleanArray, val usedMinutes: Int, val aggregate: Boolean)
data class AndroidDailyUsagePoint(val date: LocalDate, val deviceID: String, val displayName: String, val minutes: Int, val aggregate: Boolean, val estimated: Boolean = false)

class AndroidMinuteBitmapView(context: Context) : View(context) {
    var minutes: BooleanArray = BooleanArray(1440); set(value) { field = value; requestLayout(); invalidate() }
    private val active = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(15, 118, 110) }
    private val inactive = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(56, 100, 116, 139) }
    private val grid = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(148, 163, 184); strokeWidth = resources.displayMetrics.density }
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(71, 85, 105); textSize = 13 * resources.displayMetrics.scaledDensity; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD) }
    private data class Segment(val start: Int, val end: Int) { val count get() = end - start }
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val rows = max(1, visibleSegments().size); setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), (rows * 34 * resources.displayMetrics.density).toInt())
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas); val segments = visibleSegments(); val density = resources.displayMetrics.density
        if (segments.isEmpty()) { canvas.drawText("No Activity", 0f, 20 * density, label); return }
        val plotWidth = max(1f, width - 4 * density); val rowHeight = height / segments.size.toFloat()
        segments.forEachIndexed { row, segment ->
            val rowTop = row * rowHeight; val canvasTop = rowTop + 14 * density; val canvasHeight = max(13 * density, rowHeight - 15 * density); val baseline = canvasTop + canvasHeight * .58f; val cell = plotWidth / segment.count
            var boundary = segment.start
            while (boundary <= segment.end) { val x = ((boundary - segment.start) * cell).coerceIn(0f, max(0f, plotWidth - 22 * density)); canvas.drawText(String.format("%02d", boundary / 60), x, rowTop + 13 * density, label); boundary += 60 }
            val baselinePaint = Paint(grid).apply { color = Color.argb(34, 100, 116, 139); strokeWidth = .5f * density }; canvas.drawLine(0f, baseline, plotWidth, baseline, baselinePaint)
            var tick = 0
            while (tick <= segment.count) { val absolute = segment.start + tick; val hour = absolute % 60 == 0; val halfHour = absolute % 30 == 0; val length = if (hour) canvasHeight else if (halfHour) canvasHeight * .58f else canvasHeight * .32f; grid.alpha = if (hour) 107 else if (halfHour) 71 else 43; grid.strokeWidth = (if (hour) .8f else .5f) * density; val x = tick * cell; canvas.drawLine(x, baseline - length / 2, x, baseline + length / 2, grid); tick += 5 }
            var runStart = -1
            for (offset in 0..segment.count) { val index = segment.start + offset; val isActive = offset < segment.count && index < minutes.size && minutes[index]; if (isActive && runStart < 0) runStart = offset; if (!isActive && runStart >= 0) { val end = offset - 1; if (end > runStart) canvas.drawLine((runStart + .5f) * cell, baseline, (end + .5f) * cell, baseline, Paint(active).apply { strokeWidth = 1.4f * density; strokeCap = Paint.Cap.ROUND }); runStart = -1 } }
            repeat(segment.count) { offset -> val index = segment.start + offset; val isActive = index < minutes.size && minutes[index]; val radius = (if (isActive) .72f else .42f) * density; canvas.drawCircle((offset + .5f) * cell, baseline, radius, if (isActive) active else inactive) }
        }
        grid.alpha = 255
    }
    private fun visibleSegments(): List<Segment> { val count = minOf(minutes.size, 1440); val result = mutableListOf<Segment>(); var cursor = 0; while (cursor < count) { val first = (cursor until count).firstOrNull { minutes[it] } ?: break; val start = first / 60 * 60; val end = minOf(start + 180, 1440); result += Segment(start, end); cursor = end }; return result }
}

class AndroidUsageLineChartView(context: Context) : View(context) {
    var points: List<AndroidDailyUsagePoint> = emptyList(); set(value) { field = value; invalidate() }
    var period: String = "day"; set(value) { field = value; invalidate() }
    private val palette = intArrayOf(Color.rgb(15,118,110), Color.rgb(37,99,235), Color.rgb(234,88,12), Color.rgb(147,51,234), Color.rgb(190,24,93), Color.rgb(22,163,74), Color.rgb(71,85,105))
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(71,85,105); textSize = 11 * resources.displayMetrics.scaledDensity }
    private val grid = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(220,228,236); strokeWidth = resources.displayMetrics.density }
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) { setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), (420 * resources.displayMetrics.density).toInt()) }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas); if (points.isEmpty()) { canvas.drawText("No report data for this range", 20f, 40f, text); return }
        val dates = points.map { it.date }.distinct().sorted(); val series = points.groupBy { it.deviceID }.values.sortedWith(compareByDescending<List<AndroidDailyUsagePoint>> { it.first().aggregate }.thenBy { it.first().displayName })
        val left = 58 * resources.displayMetrics.density; val right = 12 * resources.displayMetrics.density; val top = 78 * resources.displayMetrics.density; val bottom = 46 * resources.displayMetrics.density; val plotWidth = width - left - right; val plotHeight = height - top - bottom
        val maxMinutes = max(60, points.maxOf { it.minutes }); val yMax = ceil(maxMinutes / 60.0).toInt() * 60
        repeat(5) { tick -> val value = yMax * tick / 4; val y = top + plotHeight - plotHeight * tick / 4f; canvas.drawLine(left, y, left + plotWidth, y, grid); canvas.drawText("${value / 60}h${value % 60}", 2f, y + 4, text) }
        val every = max(1, ceil(dates.size / 6.0).toInt()); dates.forEachIndexed { index, date -> if (index % every == 0 || index == dates.lastIndex) { val label = when (period) { "week" -> { val wf = java.time.temporal.WeekFields.ISO; String.format("%02dW%02d", date.get(wf.weekBasedYear()) % 100, date.get(wf.weekOfWeekBasedYear())) }; "month" -> String.format("%02d-%02d", date.year % 100, date.monthValue); else -> date.toString().substring(5) }; canvas.drawText(label, x(index, dates.size, left, plotWidth) - 18, top + plotHeight + 22, text) } }
        series.forEachIndexed { seriesIndex, values ->
            val color = palette[seriesIndex % palette.size]; val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; strokeWidth = (if (values.first().aggregate) 3 else 2) * resources.displayMetrics.density; style = Paint.Style.STROKE }; val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }; val byDate = values.associateBy { it.date }; var previous: PointF? = null
            dates.forEachIndexed { index, date -> val point = byDate[date]; if (point == null) { previous = null } else { val current = PointF(x(index, dates.size, left, plotWidth), top + plotHeight - point.minutes * plotHeight / yMax); previous?.let { canvas.drawLine(it.x, it.y, current.x, current.y, paint) }; canvas.drawCircle(current.x, current.y, 3.5f * resources.displayMetrics.density, dot); previous = current } }
            val legendX = left + (seriesIndex % 2) * (plotWidth / 2); val legendY = 20f + (seriesIndex / 2) * 24 * resources.displayMetrics.density; canvas.drawCircle(legendX, legendY, 4f * resources.displayMetrics.density, dot); canvas.drawText(values.first().displayName, legendX + 10 * resources.displayMetrics.density, legendY + 4, text)
        }
    }
    private fun x(index: Int, count: Int, left: Float, width: Float) = left + if (count == 1) width / 2 else index * width / (count - 1)
}

class AndroidTrackingLineChartView(context: Context) : View(context) {
    var rows: List<WeeklyRankingRow> = emptyList(); set(value) { field = value; requestLayout(); invalidate() }
    var metric: String = "Total tokens"; set(value) { field = value; invalidate() }
    private val palette = intArrayOf(Color.rgb(15,118,110), Color.rgb(37,99,235), Color.rgb(234,88,12), Color.rgb(147,51,234), Color.rgb(190,24,93), Color.rgb(22,163,74), Color.rgb(71,85,105), Color.rgb(8,145,178), Color.rgb(202,138,4), Color.rgb(79,70,229))
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(71,85,105); textSize = 10 * resources.displayMetrics.scaledDensity }
    private val grid = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(220,228,236); strokeWidth = resources.displayMetrics.density }
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) { val density = resources.displayMetrics.density; val viewport = MeasureSpec.getSize(widthMeasureSpec); val chartWidth = max(viewport, ((rows.map { it.weekStart }.distinct().size * 32 + 72) * density).toInt()); val requested = if (viewport < 600 * density) 650 else 520; setMeasuredDimension(chartWidth, (requested * density).toInt()) }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas); if (rows.isEmpty()) { canvas.drawText(context.getString(R.string.weekly_data_after_sync), 20f, 45f, text); return }
        val weeks = rows.map { it.weekStart }.distinct().sorted(); val series = rows.groupBy { it.model }.entries.sortedBy { it.value.firstOrNull()?.rank ?: 99 }.take(10); val density = resources.displayMetrics.density; val oneColumnLegend = this.width < 600 * density; val legendColumns = if (oneColumnLegend) 1 else 2; val legendRows = ceil(series.size / legendColumns.toDouble()).toInt(); val legendHeight = legendRows * 25 * density
        val left = 62 * density; val right = 10 * density; val top = 18 * density; val bottom = 42 * density + legendHeight; val width = this.width - left - right; val height = max(80 * density, this.height - top - bottom)
        fun value(row: WeeklyRankingRow): Double? = when(metric) { "Rank" -> row.rank.toDouble(); "Input tokens" -> if (row.hasTokenBreakdown) row.promptTokens.toDouble() else null; "Output tokens" -> if (row.hasTokenBreakdown) row.completionTokens.toDouble() else null; "Input price / M" -> row.promptPrice?.times(1_000_000); "Output price / M" -> row.completionPrice?.times(1_000_000); "Estimated Revenue" -> row.revenue; else -> row.totalTokens.toDouble() }
        val available = rows.mapNotNull(::value); if (available.isEmpty()) { canvas.drawText(context.getString(R.string.metric_not_published), 20f, 45f, text); return }
        val maxValue = max(1.0, available.max()); repeat(5) { tick -> val y = top + height - height * tick / 4f; canvas.drawLine(left, y, left + width, y, grid); canvas.drawText(android.text.format.Formatter.formatShortFileSize(context, (maxValue * tick / 4).toLong()).replace("B", ""), 1f, y + 4, text) }
        val keyIndices = linkedSetOf(0, weeks.lastIndex).apply { weeks.indices.filterTo(this) { index -> val wf = java.time.temporal.WeekFields.ISO; weeks[index].get(wf.weekOfWeekBasedYear()) == 1 }; if (size < 3 && weeks.size > 2) add(weeks.lastIndex / 2) }
        keyIndices.sorted().forEach { index -> val week = weeks[index]; val wf = java.time.temporal.WeekFields.ISO; val label = String.format("%04d-W%02d", week.get(wf.weekBasedYear()), week.get(wf.weekOfWeekBasedYear())); canvas.drawText(label, left + (if (weeks.size == 1) width/2 else index * width/(weeks.size-1)) - 27 * density, top + height + 22 * density, text) }
        val clip = canvas.clipBounds
        val firstVisibleWeek = if (weeks.size <= 1) 0 else ((clip.left - left) * (weeks.size - 1) / width).toInt().coerceIn(0, weeks.lastIndex)
        val lastVisibleWeek = if (weeks.size <= 1) 0 else ((clip.right - left) * (weeks.size - 1) / width).toInt().coerceIn(0, weeks.lastIndex)
        val drawFrom = (firstVisibleWeek - 1).coerceAtLeast(0)
        series.forEachIndexed { index, entry -> val color = palette[index % palette.size]; val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color=color; strokeWidth=2*density; style=Paint.Style.STROKE }; val dot=Paint(Paint.ANTI_ALIAS_FLAG).apply{this.color=color}; val values=entry.value.associateBy{it.weekStart}; var prior: PointF?=null; for (wi in drawFrom..lastVisibleWeek) { val week=weeks[wi]; val row=values[week]; val measured=row?.let(::value); if(measured==null){prior=null}else{ val point=PointF(left+(if(weeks.size==1) width/2 else wi*width/(weeks.size-1)), (top+height-measured*height/maxValue).toFloat()); prior?.let{canvas.drawLine(it.x,it.y,point.x,point.y,line)}; canvas.drawCircle(point.x,point.y,3*density,dot); prior=point } }; val column=index%legendColumns; val row=index/legendColumns; val lx=left+column*width/legendColumns; val ly=top+height+48*density+row*25*density; canvas.drawCircle(lx,ly,3*density,dot); canvas.drawText(entry.key.take(if(oneColumnLegend) 42 else 24),lx+8*density,ly+4,text) }
    }
}
