package io.familyfinance.notifier

import java.security.MessageDigest
import java.time.Instant

object NotificationNormalizer {
    private val providerPackages = mapOf(
        "com.kakaobank.channel" to "kakaobank",
        "com.kbankwith.smartbank" to "kbank",
        "com.wooribank.smart.npib" to "wooribank",
        "com.coupang.mobile" to "coupang",
    )
    private val walletProviders = setOf("coupang")

    private val amountRegex = Regex("""([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s*원""")
    private val actionAmountRegexes = listOf(
        Regex("""(?:출금|입금|결제|승인|사용|취소|환불|이체|충전)(?:금액)?\s*[:：]?\s*([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s*원"""),
        Regex("""([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s*원\s*(?:출금|입금|결제|승인|사용|취소|환불|이체|충전)"""),
    )
    private val balanceRegex = Regex(
        """(?:거래\s*후\s*)?잔액\s*[:：]?\s*([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s*원?""",
    )
    private val financeKeywords = listOf(
        "출금", "입금", "결제", "승인", "사용", "취소", "환불", "이체", "충전", "잔액",
    )
    private val creditKeywords = listOf("입금", "취소", "환불")
    private val debitKeywords = listOf("출금", "결제", "승인", "사용", "이체", "충전")

    fun normalize(
        sourceApp: String,
        notificationKey: String,
        postTime: Long,
        title: String,
        text: String,
    ): NormalizedEvent? {
        val providerKey = providerPackages[sourceApp] ?: return null
        val combined = "$title\n$text"
        if (financeKeywords.none { combined.contains(it) }) return null

        val balanceMatch = balanceRegex.find(combined)
        val balanceAfter = balanceMatch?.groupValues?.get(1)?.replace(",", "")
        val amount = findTransactionAmount(combined, balanceMatch?.range) ?: return null

        val merchantKey = merchantKey(combined)
        val isWalletProvider = providerKey in walletProviders
        val eventType = when {
            isWalletProvider && combined.contains("충전") -> "wallet_charge"
            isWalletProvider && combined.contains("환불") -> "wallet_refund"
            !isWalletProvider && merchantKey != null && combined.contains("충전") -> "account_debit"
            combined.contains("취소") || combined.contains("환불") -> "card_refund"
            combined.contains("출금") || combined.contains("이체") -> "account_debit"
            combined.contains("입금") -> "account_credit"
            isWalletProvider && (combined.contains("결제") || combined.contains("승인") || combined.contains("사용")) -> "wallet_purchase"
            combined.contains("결제") || combined.contains("승인") || combined.contains("사용") -> "card_purchase"
            else -> "financial_notification"
        }
        val direction = when (eventType) {
            "account_credit", "card_refund", "wallet_charge", "wallet_refund" -> "credit"
            "account_debit", "card_purchase", "wallet_purchase" -> "debit"
            else -> when {
                creditKeywords.any { combined.contains(it) } -> "credit"
                debitKeywords.any { combined.contains(it) } -> "debit"
                else -> "unknown"
            }
        }
        val confidence = when (eventType) {
            "financial_notification" -> 0.55
            "wallet_charge", "wallet_refund", "wallet_purchase" -> 0.92
            else -> if (balanceAfter != null) 0.9 else 0.82
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
            providerKey = providerKey,
            merchantKey = merchantKey,
            balanceAfter = balanceAfter,
            confidence = confidence,
        )
    }

    private fun findTransactionAmount(text: String, balanceRange: IntRange?): String? {
        for (pattern in actionAmountRegexes) {
            val match = pattern.find(text) ?: continue
            val candidate = match.groupValues[1].replace(",", "")
            if (candidate.isNotBlank()) return candidate
        }
        return amountRegex.findAll(text)
            .firstOrNull { candidate -> balanceRange == null || candidate.range.intersect(balanceRange).isEmpty() }
            ?.groupValues
            ?.get(1)
            ?.replace(",", "")
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
