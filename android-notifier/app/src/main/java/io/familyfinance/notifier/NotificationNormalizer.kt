package io.familyfinance.notifier

import java.security.MessageDigest
import java.time.Instant

object NotificationNormalizer {
    private val amountRegex = Regex("""([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s*원""")
    private val financeKeywords = listOf(
        "출금", "입금", "결제", "승인", "사용", "취소", "환불", "이체", "충전", "잔액",
    )
    private val creditKeywords = listOf("입금", "취소", "환불")
    private val debitKeywords = listOf("출금", "결제", "승인", "사용", "이체")

    fun normalize(
        sourceApp: String,
        notificationKey: String,
        postTime: Long,
        title: String,
        text: String,
    ): NormalizedEvent? {
        val combined = "$title\n$text"
        if (financeKeywords.none { combined.contains(it) }) return null

        val amountMatch = amountRegex.find(combined) ?: return null
        val amount = amountMatch.groupValues[1].replace(",", "")
        if (amount.isBlank()) return null

        val merchantKey = merchantKey(combined)
        val direction = when {
            creditKeywords.any { combined.contains(it) } -> "credit"
            debitKeywords.any { combined.contains(it) } -> "debit"
            else -> "unknown"
        }
        val eventType = when {
            combined.contains("충전") && merchantKey == "coupang" -> "wallet_charge"
            combined.contains("환불") && merchantKey == "coupang" -> "wallet_refund"
            combined.contains("취소") || combined.contains("환불") -> "card_refund"
            combined.contains("출금") || combined.contains("이체") -> "account_debit"
            combined.contains("입금") -> "account_credit"
            (combined.contains("결제") || combined.contains("승인") || combined.contains("사용")) && merchantKey == "coupang" -> "wallet_purchase"
            combined.contains("결제") || combined.contains("승인") || combined.contains("사용") -> "card_purchase"
            else -> "financial_notification"
        }
        val confidence = when (eventType) {
            "financial_notification" -> 0.55
            "wallet_charge", "wallet_refund", "wallet_purchase" -> 0.9
            else -> 0.8
        }
        val eventId = sha256("$sourceApp|$notificationKey|$postTime|$eventType|$amount")

        return NormalizedEvent(
            eventId = eventId,
            occurredAt = Instant.ofEpochMilli(postTime).toString(),
            eventType = eventType,
            amount = amount,
            currency = "KRW",
            direction = direction,
            sourceApp = sourceApp,
            merchantKey = merchantKey,
            confidence = confidence,
        )
    }

    private fun merchantKey(text: String): String? = when {
        text.contains("쿠페이", ignoreCase = true) || text.contains("쿠팡", ignoreCase = true) -> "coupang"
        text.contains("카카오페이", ignoreCase = true) -> "kakaopay"
        text.contains("네이버페이", ignoreCase = true) -> "naverpay"
        text.contains("토스", ignoreCase = true) -> "toss"
        else -> null
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
}
