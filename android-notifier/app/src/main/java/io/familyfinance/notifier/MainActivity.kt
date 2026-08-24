package io.familyfinance.notifier

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import com.google.android.gms.auth.api.identity.Identity

class MainActivity : ComponentActivity() {
    private lateinit var status: TextView

    private val authorizationLauncher = registerForActivityResult(
        ActivityResultContracts.StartIntentSenderForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            runCatching {
                Identity.getAuthorizationClient(this)
                    .getAuthorizationResultFromIntent(result.data!!)
            }.onSuccess { authorization ->
                if (!authorization.accessToken.isNullOrBlank()) {
                    markDriveAuthorized()
                    RelayScheduler.enqueueNow(this)
                }
            }
        }
        refreshStatus()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        RelayScheduler.ensureSafetySchedule(this)
        setContentView(buildContent())
        refreshStatus()
    }

    override fun onResume() {
        super.onResume()
        if (::status.isInitialized) refreshStatus()
    }

    private fun buildContent(): LinearLayout {
        status = TextView(this).apply {
            textSize = 16f
            setPadding(32, 32, 32, 32)
        }
        val notificationAccess = Button(this).apply {
            text = "1. 알림 접근 허용"
            setOnClickListener {
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            }
        }
        val authorizeDrive = Button(this).apply {
            text = "2. 비공개 릴레이 승인"
            setOnClickListener { requestDriveAuthorization() }
        }
        val samsungBattery = Button(this).apply {
            text = "3. 절전 예외 설정"
            setOnClickListener { openSamsungNeverSleepingApps() }
        }
        val relayNow = Button(this).apply {
            text = "대기 이벤트 전송"
            setOnClickListener {
                RelayScheduler.enqueueNow(this@MainActivity)
                refreshStatus()
            }
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 48, 32, 48)
            addView(status)
            addView(notificationAccess)
            addView(authorizeDrive)
            addView(samsungBattery)
            addView(relayNow)
        }
    }

    private fun requestDriveAuthorization() {
        Identity.getAuthorizationClient(this)
            .authorize(DriveRelay.authorizationRequest())
            .addOnSuccessListener { result ->
                if (result.hasResolution()) {
                    val pendingIntent = result.pendingIntent ?: return@addOnSuccessListener
                    authorizationLauncher.launch(
                        IntentSenderRequest.Builder(pendingIntent.intentSender).build()
                    )
                } else if (!result.accessToken.isNullOrBlank()) {
                    markDriveAuthorized()
                    RelayScheduler.enqueueNow(this)
                    refreshStatus()
                }
            }
            .addOnFailureListener {
                getSharedPreferences("relay-state", MODE_PRIVATE)
                    .edit()
                    .putBoolean("drive_auth_required", true)
                    .apply()
                refreshStatus()
            }
    }

    private fun markDriveAuthorized() {
        getSharedPreferences("relay-state", MODE_PRIVATE)
            .edit()
            .putBoolean("drive_auth_required", false)
            .putBoolean("drive_authorized_once", true)
            .apply()
    }

    private fun openSamsungNeverSleepingApps() {
        val samsungIntent = Intent("com.samsung.android.sm.ACTION_OPEN_CHECKABLE_LISTACTIVITY").apply {
            setPackage("com.samsung.android.lool")
            putExtra("activity_type", 2)
        }
        if (samsungIntent.resolveActivity(packageManager) != null) {
            startActivity(samsungIntent)
        } else {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    private fun notificationAccessGranted(): Boolean =
        Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
            ?.contains(packageName) == true

    private fun refreshStatus() {
        val prefs = getSharedPreferences("relay-state", MODE_PRIVATE)
        val pending = EventStore(this).pendingCount()
        val notification = if (notificationAccessGranted()) "허용" else "필요"
        val drive = when {
            prefs.getBoolean("drive_auth_required", false) -> "재승인 필요"
            prefs.getBoolean("drive_authorized_once", false) -> "승인됨"
            else -> "승인 필요"
        }
        status.text = buildString {
            appendLine("Family Finance 알림 수집")
            appendLine("알림 접근: $notification")
            appendLine("비공개 릴레이: $drive")
            append("전송 대기: $pending 건")
        }
    }
}
