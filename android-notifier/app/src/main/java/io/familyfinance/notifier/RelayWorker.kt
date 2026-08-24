package io.familyfinance.notifier

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters

class RelayWorker(
    appContext: Context,
    params: WorkerParameters,
) : Worker(appContext, params) {
    override fun doWork(): Result {
        val store = EventStore(applicationContext)
        val events = store.readBatch(100)
        if (events.isEmpty()) return Result.success()

        val token = try {
            DriveRelay.accessToken(applicationContext)
        } catch (_: Exception) {
            return Result.retry()
        }
        if (token.isNullOrBlank()) {
            applicationContext.getSharedPreferences("relay-state", Context.MODE_PRIVATE)
                .edit()
                .putBoolean("drive_auth_required", true)
                .apply()
            return Result.retry()
        }

        return try {
            val (batchId, payload) = DriveRelay.buildBatch(store.deviceId(), events)
            if (!DriveRelay.upload(token, batchId, payload)) return Result.retry()
            val ids = events.mapNotNull { it.optString("event_id").takeIf(String::isNotBlank) }.toSet()
            store.acknowledge(ids)
            applicationContext.getSharedPreferences("relay-state", Context.MODE_PRIVATE)
                .edit()
                .putBoolean("drive_auth_required", false)
                .putLong("last_upload_at", System.currentTimeMillis())
                .apply()
            if (store.pendingCount() > 0) RelayScheduler.enqueueNow(applicationContext)
            Result.success()
        } catch (_: Exception) {
            Result.retry()
        }
    }
}
