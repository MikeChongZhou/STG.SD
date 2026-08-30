package com.timbertrail.stg

import android.content.Context
import android.graphics.*
import android.view.View
import java.time.LocalDate
import kotlin.math.ceil
import kotlin.math.max

data class AndroidDayReport(val deviceID: String, val displayName: String, val minutes: BooleanArray, val usedMinutes: Int, val aggregate: Boolean)
data class AndroidDailyUsagePoint(val date: LocalDate, val deviceID: String, val displayName: String, val minutes: Int, val aggregate: Boolean)

class AndroidMinuteBitmapView(context: Context) : View(context) {
    var minutes: BooleanArray = BooleanArray(1440); set(value) { field = value; invalidate() }
    private val active = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(15, 118, 110) }
    private val inactive = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(226, 232, 240) }
    private val grid = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(148, 163, 184); strokeWidth = resources.displayMetrics.density }
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(71, 85, 105); textSize = 10 * resources.displayMetrics.scaledDensity }
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) { setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), (150 * resources.displayMetrics.density).toInt()) }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas); val left = 48 * resources.displayMetrics.density; val plotWidth = max(1f, width - left - 8); val rowHeight = height / 4f
        repeat(4) { row ->
            val top = row * rowHeight + 14; val bottom = (row + 1) * rowHeight - 5; canvas.drawText(String.format("%02d–%02d", row * 6, (row + 1) * 6), 0f, top + 10, label); canvas.drawRect(left, top, left + plotWidth, bottom, inactive)
            val cell = plotWidth / 360f; repeat(360) { offset -> val index = row * 360 + offset; if (index < minutes.size && minutes[index]) canvas.drawRect(left + offset * cell, top, left + (offset + 1) * cell, bottom, active) }
            repeat(7) { hour -> val x = left + hour * plotWidth / 6f; canvas.drawLine(x, top - 3, x, bottom, grid); if (hour < 6) canvas.drawText(String.format("%02d", row * 6 + hour), x + 2, top - 4, label) }
        }
    }
}

class AndroidUsageLineChartView(context: Context) : View(context) {
    var points: List<AndroidDailyUsagePoint> = emptyList(); set(value) { field = value; invalidate() }
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
        val every = max(1, ceil(dates.size / 6.0).toInt()); dates.forEachIndexed { index, date -> if (index % every == 0 || index == dates.lastIndex) canvas.drawText(date.toString().substring(5), x(index, dates.size, left, plotWidth) - 18, top + plotHeight + 22, text) }
        series.forEachIndexed { seriesIndex, values ->
            val color = palette[seriesIndex % palette.size]; val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; strokeWidth = (if (values.first().aggregate) 3 else 2) * resources.displayMetrics.density; style = Paint.Style.STROKE }; val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }; val byDate = values.associateBy { it.date }; var previous: PointF? = null
            dates.forEachIndexed { index, date -> val point = byDate[date]; if (point == null) { previous = null } else { val current = PointF(x(index, dates.size, left, plotWidth), top + plotHeight - point.minutes * plotHeight / yMax); previous?.let { canvas.drawLine(it.x, it.y, current.x, current.y, paint) }; canvas.drawCircle(current.x, current.y, 3.5f * resources.displayMetrics.density, dot); previous = current } }
            val legendX = left + (seriesIndex % 2) * (plotWidth / 2); val legendY = 20f + (seriesIndex / 2) * 24 * resources.displayMetrics.density; canvas.drawCircle(legendX, legendY, 4f * resources.displayMetrics.density, dot); canvas.drawText(values.first().displayName, legendX + 10 * resources.displayMetrics.density, legendY + 4, text)
        }
    }
    private fun x(index: Int, count: Int, left: Float, width: Float) = left + if (count == 1) width / 2 else index * width / (count - 1)
}

class AndroidTrackingLineChartView(context: Context) : View(context) {
    var rows: List<WeeklyRankingRow> = emptyList(); set(value) { field = value; invalidate() }
    var metric: String = "Total tokens"; set(value) { field = value; invalidate() }
    private val palette = intArrayOf(Color.rgb(15,118,110), Color.rgb(37,99,235), Color.rgb(234,88,12), Color.rgb(147,51,234), Color.rgb(190,24,93), Color.rgb(22,163,74), Color.rgb(71,85,105), Color.rgb(8,145,178), Color.rgb(202,138,4), Color.rgb(79,70,229))
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(71,85,105); textSize = 10 * resources.displayMetrics.scaledDensity }
    private val grid = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(220,228,236); strokeWidth = resources.displayMetrics.density }
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) { setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), (430 * resources.displayMetrics.density).toInt()) }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas); if (rows.isEmpty()) { canvas.drawText("Weekly data will appear after a successful weekly sync action.", 20f, 45f, text); return }
        val weeks = rows.map { it.weekStart }.distinct().sorted(); val series = rows.groupBy { it.model }.entries.sortedBy { it.value.firstOrNull()?.rank ?: 99 }
        val left = 62 * resources.displayMetrics.density; val right = 10 * resources.displayMetrics.density; val top = 92 * resources.displayMetrics.density; val bottom = 42 * resources.displayMetrics.density; val width = this.width - left - right; val height = this.height - top - bottom
        fun value(row: WeeklyRankingRow): Double? = when(metric) { "Rank" -> row.rank.toDouble(); "Input tokens" -> if (row.hasTokenBreakdown) row.promptTokens.toDouble() else null; "Output tokens" -> if (row.hasTokenBreakdown) row.completionTokens.toDouble() else null; "Input price / M" -> row.promptPrice?.times(1_000_000); "Output price / M" -> row.completionPrice?.times(1_000_000); "Revenue" -> row.revenue; else -> row.totalTokens.toDouble() }
        val available = rows.mapNotNull(::value); if (available.isEmpty()) { canvas.drawText("This metric is not published in the OpenRouter historical dataset", 20f, 45f, text); return }
        val maxValue = max(1.0, available.max()); repeat(5) { tick -> val y = top + height - height * tick / 4f; canvas.drawLine(left, y, left + width, y, grid); canvas.drawText(android.text.format.Formatter.formatShortFileSize(context, (maxValue * tick / 4).toLong()).replace("B", ""), 1f, y + 4, text) }
        weeks.forEachIndexed { index, week -> if (index % max(1, ceil(weeks.size / 5.0).toInt()) == 0 || index == weeks.lastIndex) canvas.drawText(week.toString().substring(5), left + (if (weeks.size == 1) width/2 else index * width/(weeks.size-1)) - 15, top + height + 20, text) }
        series.take(10).forEachIndexed { index, entry -> val color = palette[index % palette.size]; val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color=color; strokeWidth=2*resources.displayMetrics.density; style=Paint.Style.STROKE }; val dot=Paint(Paint.ANTI_ALIAS_FLAG).apply{this.color=color}; val values=entry.value.associateBy{it.weekStart}; var prior: PointF?=null; weeks.forEachIndexed { wi, week -> val row=values[week]; val measured=row?.let(::value); if(measured==null){prior=null}else{ val point=PointF(left+(if(weeks.size==1) width/2 else wi*width/(weeks.size-1)), (top+height-measured*height/maxValue).toFloat()); prior?.let{canvas.drawLine(it.x,it.y,point.x,point.y,line)}; canvas.drawCircle(point.x,point.y,3*resources.displayMetrics.density,dot); prior=point } }; val lx=left+(index%2)*width/2; val ly=18f+(index/2)*18*resources.displayMetrics.density; canvas.drawCircle(lx,ly,3*resources.displayMetrics.density,dot); canvas.drawText(entry.key.take(34),lx+8*resources.displayMetrics.density,ly+4,text) }
    }
}
