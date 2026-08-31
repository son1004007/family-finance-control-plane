package io.familyfinance.notifier

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class NotificationNormalizerTest {
    @Test
    fun `separates debit amount from post transaction balance`() {
        val event = NotificationNormalizer.normalize(
            sourceApp = "com.kakaobank.channel",
            notificationKey = "synthetic-debit-1",
            postTime = 1_725_000_000_000L,
            title = "출금 12,000원",
            text = "거래 후 잔액 345,678원",
        )

        assertNotNull(event)
        assertEquals("account_debit", event!!.eventType)
        assertEquals("12000", event.amount)
        assertEquals("345678", event.balanceAfter)
        assertEquals("debit", event.direction)
        assertEquals("kakaobank", event.providerKey)
    }

    @Test
    fun `action amount wins even when balance appears first`() {
        val event = NotificationNormalizer.normalize(
            sourceApp = "com.kbankwith.smartbank",
            notificationKey = "synthetic-debit-2",
            postTime = 1_725_000_100_000L,
            title = "거래 알림",
            text = "잔액 900,000원\n25,000원 출금",
        )

        assertNotNull(event)
        assertEquals("25000", event!!.amount)
        assertEquals("900000", event.balanceAfter)
        assertEquals("account_debit", event.eventType)
    }

    @Test
    fun `bank notification referencing wallet charge stays account debit`() {
        val event = NotificationNormalizer.normalize(
            sourceApp = "com.kakaobank.channel",
            notificationKey = "synthetic-wallet-funding-bank-side",
            postTime = 1_725_000_150_000L,
            title = "쿠페이 충전",
            text = "50,000원 출금\n잔액 650,000원",
        )

        assertNotNull(event)
        assertEquals("account_debit", event!!.eventType)
        assertEquals("50000", event.amount)
        assertEquals("650000", event.balanceAfter)
        assertEquals("debit", event.direction)
        assertEquals("kakaobank", event.providerKey)
        assertEquals("coupang", event.merchantKey)
    }

    @Test
    fun `classifies wallet charge as wallet credit without counting balance as spend`() {
        val event = NotificationNormalizer.normalize(
            sourceApp = "com.coupang.mobile",
            notificationKey = "synthetic-wallet-charge",
            postTime = 1_725_000_200_000L,
            title = "쿠페이 알림",
            text = "쿠페이 충전 50,000원\n잔액 74,000원",
        )

        assertNotNull(event)
        assertEquals("wallet_charge", event!!.eventType)
        assertEquals("50000", event.amount)
        assertEquals("74000", event.balanceAfter)
        assertEquals("credit", event.direction)
        assertEquals("coupang", event.providerKey)
        assertEquals("coupang", event.merchantKey)
    }

    @Test
    fun `wallet merchant purchase remains debit expense candidate`() {
        val event = NotificationNormalizer.normalize(
            sourceApp = "com.coupang.mobile",
            notificationKey = "synthetic-wallet-purchase",
            postTime = 1_725_000_250_000L,
            title = "쿠페이 결제",
            text = "결제 17,500원\n잔액 56,500원",
        )

        assertNotNull(event)
        assertEquals("wallet_purchase", event!!.eventType)
        assertEquals("17500", event.amount)
        assertEquals("56500", event.balanceAfter)
        assertEquals("debit", event.direction)
    }

    @Test
    fun `classifies refund as credit`() {
        val event = NotificationNormalizer.normalize(
            sourceApp = "com.coupang.mobile",
            notificationKey = "synthetic-wallet-refund",
            postTime = 1_725_000_300_000L,
            title = "쿠페이 환불",
            text = "환불 8,900원\n잔액 82,900원",
        )

        assertNotNull(event)
        assertEquals("wallet_refund", event!!.eventType)
        assertEquals("8900", event.amount)
        assertEquals("82900", event.balanceAfter)
        assertEquals("credit", event.direction)
    }
}
