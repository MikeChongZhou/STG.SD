package com.timbertrail.stg

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File
import java.time.Instant

class DiagnosticLog private constructor(private val context: Context) {
    private val directory = File(context.filesDir, "Diagnostics").apply { mkdirs() }
    private val file = File(directory, "stg-test.log")

    @Synchronized fun record(category: String, message: String) {
        runCatching {
            if (file.length() >= 1_024 * 1_024) {
                val bytes = file.readBytes(); file.writeBytes(bytes.copyOfRange(minOf(800 * 1_024, bytes.size), bytes.size))
            }
            file.appendText("${Instant.now()} [$category] $message\n")
        }
    }

    @Synchronized fun shareIntent(): Intent {
        record("diagnostics", "test log export requested")
        val shareDirectory = File(context.cacheDir, "diagnostics-share").apply { mkdirs() }
        val exported = File(shareDirectory, "stg-test-log.txt")
        exported.outputStream().use { output -> file.takeIf(File::exists)?.inputStream()?.use { it.copyTo(output) } }
        file.writeText(""); File(directory, "stg-test.previous.log").delete()
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", exported)
        return Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    companion object {
        @Volatile private var instance: DiagnosticLog? = null
        fun get(context: Context): DiagnosticLog = instance ?: synchronized(this) { instance ?: DiagnosticLog(context.applicationContext).also { instance = it } }
    }
}
