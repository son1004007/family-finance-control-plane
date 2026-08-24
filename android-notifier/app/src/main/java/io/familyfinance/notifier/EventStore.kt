package io.familyfinance.notifier

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.util.UUID

class EventStore(private val context: Context) {
    private val queueFile: File = File(context.filesDir, "pending-events.ndjson")
    private val prefs = context.getSharedPreferences("relay-state", Context.MODE_PRIVATE)

    fun deviceId(): String = synchronized(LOCK) {
        prefs.getString("device_id", null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString("device_id", it).apply()
        }
    }

    fun append(event: NormalizedEvent) = synchronized(LOCK) {
        queueFile.parentFile?.mkdirs()
        queueFile.appendText(event.toJson().toString() + "\n", Charsets.UTF_8)
    }

    fun readBatch(limit: Int = 100): List<JSONObject> = synchronized(LOCK) {
        if (!queueFile.isFile) return emptyList()
        queueFile.useLines { lines ->
            lines.filter { it.isNotBlank() }
                .take(limit)
                .map { JSONObject(it) }
                .toList()
        }
    }

    fun acknowledge(eventIds: Set<String>) = synchronized(LOCK) {
        if (!queueFile.isFile || eventIds.isEmpty()) return
        val remaining = queueFile.readLines(Charsets.UTF_8)
            .filter { line ->
                if (line.isBlank()) return@filter false
                val id = runCatching { JSONObject(line).optString("event_id") }.getOrDefault("")
                id !in eventIds
            }
        val temp = File(context.filesDir, "pending-events.ndjson.tmp")
        temp.writeText(
            remaining.joinToString(separator = "\n", postfix = if (remaining.isEmpty()) "" else "\n"),
            Charsets.UTF_8,
        )
        if (!temp.renameTo(queueFile)) {
            queueFile.writeText(temp.readText(Charsets.UTF_8), Charsets.UTF_8)
            temp.delete()
        }
    }

    fun pendingCount(): Int = synchronized(LOCK) {
        if (!queueFile.isFile) 0 else queueFile.useLines { lines -> lines.count { it.isNotBlank() } }
    }

    companion object {
        private val LOCK = Any()
    }
}
