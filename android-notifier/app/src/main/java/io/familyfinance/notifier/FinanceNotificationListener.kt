package io.familyfinance.notifier

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

class FinanceNotificationListener : NotificationListenerService() {
    override fun onListenerConnected() {
        super.onListenerConnected()
        RelayScheduler.ensureSafetySchedule(applicationContext)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null || sbn.packageName == packageName) return
        val extras = sbn.notification.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        if (title.isBlank() && text.isBlank()) return

        // Raw notification strings are intentionally short-lived locals only. The
        // persistent queue receives NormalizedEvent fields and never title/text.
        val event = NotificationNormalizer.normalize(
            sourceApp = sbn.packageName,
            notificationKey = sbn.key,
            postTime = sbn.postTime,
            title = title,
            text = text,
        ) ?: return

        EventStore(applicationContext).append(event)
        RelayScheduler.enqueueNow(applicationContext)
    }
}
