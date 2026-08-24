package io.familyfinance.notifier

import org.json.JSONObject

data class NormalizedEvent(
    val eventId: String,
    val occurredAt: String,
    val eventType: String,
    val amount: String,
    val currency: String,
    val direction: String,
    val sourceApp: String,
    val merchantKey: String? = null,
    val accountAlias: String? = null,
    val confidence: Double? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("event_id", eventId)
        put("occurred_at", occurredAt)
        put("event_type", eventType)
        put("amount", amount)
        put("currency", currency)
        put("direction", direction)
        put("source_app", sourceApp)
        merchantKey?.let { put("merchant_key", it) }
        accountAlias?.let { put("account_alias", it) }
        confidence?.let { put("confidence", it) }
    }
}
