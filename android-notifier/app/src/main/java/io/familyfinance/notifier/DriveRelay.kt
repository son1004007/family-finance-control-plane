package io.familyfinance.notifier

import android.content.Context
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import com.google.android.gms.tasks.Tasks
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.UUID

object DriveRelay {
    const val SCOPE = "https://www.googleapis.com/auth/drive.appdata"
    private const val UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id"

    fun authorizationRequest(): AuthorizationRequest = AuthorizationRequest.builder()
        .setRequestedScopes(listOf(Scope(SCOPE)))
        .build()

    fun accessToken(context: Context): String? {
        val result = Tasks.await(
            Identity.getAuthorizationClient(context).authorize(authorizationRequest())
        )
        if (result.hasResolution()) return null
        return result.accessToken
    }

    fun buildBatch(deviceId: String, events: List<JSONObject>): Pair<String, ByteArray> {
        val batchId = UUID.randomUUID().toString()
        val document = JSONObject().apply {
            put("schema_version", 1)
            put("batch_id", batchId)
            put("device_id", deviceId)
            put("events", JSONArray(events))
        }
        return batchId to document.toString().toByteArray(StandardCharsets.UTF_8)
    }

    fun upload(accessToken: String, batchId: String, payload: ByteArray): Boolean {
        require(payload.size <= 512 * 1024) { "batch too large" }
        val boundary = "ff-${UUID.randomUUID()}"
        val fileName = "ff-notification-${System.currentTimeMillis()}-$batchId.json"
        val metadata = JSONObject().apply {
            put("name", fileName)
            put("parents", JSONArray().put("appDataFolder"))
            put("mimeType", "application/json")
        }.toString()

        val prefix = buildString {
            append("--$boundary\r\n")
            append("Content-Type: application/json; charset=UTF-8\r\n\r\n")
            append(metadata)
            append("\r\n--$boundary\r\n")
            append("Content-Type: application/json\r\n\r\n")
        }.toByteArray(StandardCharsets.UTF_8)
        val suffix = "\r\n--$boundary--\r\n".toByteArray(StandardCharsets.UTF_8)
        val totalLength = prefix.size + payload.size + suffix.size

        val connection = (URL(UPLOAD_URL).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 10_000
            readTimeout = 15_000
            doOutput = true
            setRequestProperty("Authorization", "Bearer $accessToken")
            setRequestProperty("Content-Type", "multipart/related; boundary=$boundary")
            setFixedLengthStreamingMode(totalLength)
        }
        return try {
            connection.outputStream.use { out ->
                out.write(prefix)
                out.write(payload)
                out.write(suffix)
            }
            connection.responseCode in 200..299
        } finally {
            connection.disconnect()
        }
    }
}
