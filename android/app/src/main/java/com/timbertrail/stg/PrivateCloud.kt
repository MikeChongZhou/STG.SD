package com.timbertrail.stg

import android.content.Context
import android.net.Uri
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.URLEncoder
import java.net.UnknownHostException
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.util.UUID

internal object CloudConfiguration {
    const val microsoftClientID = "a4ff927c-e45a-413e-b5c3-45b026719171"
    const val googleClientID = "552360735383-030pcr7mduhf1d20kjslobh5dhacsg2o.apps.googleusercontent.com"
    const val googleCallbackScheme = "com.googleusercontent.apps.552360735383-030pcr7mduhf1d20kjslobh5dhacsg2o"
    const val googleRedirectURI = "$googleCallbackScheme:/oauth2redirect"
}

internal data class CloudCredential(
    val accessToken: String,
    val refreshToken: String,
    val expiresAt: Long,
    val accountLabel: String
) {
    fun json() = JSONObject().put("access_token", accessToken).put("refresh_token", refreshToken)
        .put("expires_at", expiresAt).put("account_label", accountLabel).toString()

    companion object {
        fun parse(value: String): CloudCredential? = runCatching {
            val json = JSONObject(value)
            CloudCredential(json.getString("access_token"), json.getString("refresh_token"), json.getLong("expires_at"), json.optString("account_label"))
        }.getOrNull()
    }
}

internal object PrivateCloudCredentials {
    private fun key(provider: String) = "private-cloud-$provider"
    fun load(context: Context, provider: String): CloudCredential? = CloudCredential.parse(SecureStore(context).get(key(provider)))
    fun save(context: Context, provider: String, credential: CloudCredential) = SecureStore(context).put(key(provider), credential.json())
    fun remove(context: Context, provider: String) = SecureStore(context).put(key(provider), "")
    fun isSignedIn(context: Context, provider: String) = provider != "off" && load(context, provider) != null
    fun account(context: Context, provider: String) = load(context, provider)?.accountLabel.orEmpty()

    fun saveGoogleRequest(context: Context, request: GoogleAuthorizationRequest) {
        SecureStore(context).put("google-oauth-request", JSONObject().put("state", request.state).put("verifier", request.verifier)
            .put("redirect_uri", request.redirectURI).put("created_at", Instant.now().epochSecond).toString())
    }
    fun loadGoogleRequest(context: Context): GoogleAuthorizationRequest? = runCatching {
        val json = JSONObject(SecureStore(context).get("google-oauth-request"))
        if (Instant.now().epochSecond - json.getLong("created_at") > 900) return@runCatching null
        GoogleAuthorizationRequest("", json.getString("state"), json.getString("verifier"), json.getString("redirect_uri"))
    }.getOrNull()
    fun clearGoogleRequest(context: Context) = SecureStore(context).put("google-oauth-request", "")
}

internal data class RemoteFile(val id: String, val name: String)

internal interface PrivateCloudDrive {
    var credential: CloudCredential
    fun list(): List<RemoteFile>
    fun upload(name: String, data: ByteArray, existingID: String? = null)
    fun download(id: String): ByteArray
    fun listFolder(folder: String): List<RemoteFile>
    fun uploadFolder(folder: String, name: String, data: ByteArray, existingID: String? = null)
    fun delete(id: String)
}

internal object PrivateCloudDriveFactory {
    fun fromStore(context: Context, provider: String): PrivateCloudDrive {
        val credential = PrivateCloudCredentials.load(context, provider) ?: error("Sign in to ${if (provider == "onedrive") "OneDrive" else "Google Drive"} in Settings first")
        return when (provider) {
            "onedrive" -> OneDriveCloudDrive(context, credential)
            "google" -> GoogleCloudDrive(context, credential)
            else -> error("Private cloud is not configured")
        }
    }
}

internal data class OneDriveDeviceCode(val deviceCode: String, val userCode: String, val verificationURL: String, val message: String, val expiresIn: Int, val interval: Int)

internal object OneDriveAuthorization {
    private const val scope = "offline_access User.Read Files.ReadWrite.AppFolder"
    fun requestCode(): OneDriveDeviceCode {
        val json = JSONObject(CloudHttp.form("https://login.microsoftonline.com/common/oauth2/v2.0/devicecode", mapOf("client_id" to CloudConfiguration.microsoftClientID, "scope" to scope)).decodeToString())
        return OneDriveDeviceCode(json.getString("device_code"), json.getString("user_code"), json.getString("verification_uri"), json.optString("message"), json.getInt("expires_in"), json.optInt("interval", 5))
    }

    fun waitForCredential(code: OneDriveDeviceCode): CloudCredential {
        val deadline = Instant.now().epochSecond + code.expiresIn
        var interval = maxOf(3, code.interval)
        while (Instant.now().epochSecond < deadline) {
            val response = CloudHttp.raw("POST", "https://login.microsoftonline.com/common/oauth2/v2.0/token", contentType = "application/x-www-form-urlencoded", body = CloudHttp.encodedForm(mapOf(
                "client_id" to CloudConfiguration.microsoftClientID,
                "grant_type" to "urn:ietf:params:oauth:grant-type:device_code",
                "device_code" to code.deviceCode
            )))
            if (response.status in 200..299) return tokenCredential(response.body, "")
            val error = runCatching { JSONObject(response.body.decodeToString()) }.getOrNull()
            when (error?.optString("error")) {
                "authorization_pending" -> Unit
                "slow_down" -> interval += 5
                else -> error(CloudHttp.errorMessage("Microsoft sign-in failed", response))
            }
            Thread.sleep(interval * 1000L)
        }
        error("Microsoft sign-in code expired")
    }

    internal fun refresh(refreshToken: String): CloudCredential {
        val data = CloudHttp.form("https://login.microsoftonline.com/common/oauth2/v2.0/token", mapOf("client_id" to CloudConfiguration.microsoftClientID, "grant_type" to "refresh_token", "refresh_token" to refreshToken, "scope" to scope))
        return tokenCredential(data, refreshToken)
    }

    private fun tokenCredential(data: ByteArray, fallback: String): CloudCredential {
        val json = JSONObject(data.decodeToString())
        val refresh = json.optString("refresh_token", fallback)
        check(refresh.isNotBlank()) { "Microsoft did not return an offline refresh token" }
        return CloudCredential(json.getString("access_token"), refresh, Instant.now().epochSecond + json.getLong("expires_in"), "Microsoft account")
    }
}

internal class OneDriveCloudDrive(private val context: Context, override var credential: CloudCredential) : PrivateCloudDrive {
    private var appRootReady = false

    fun account(): String {
        val json = JSONObject(graph("GET", "/v1.0/me?\$select=displayName,mail,userPrincipalName").decodeToString())
        return json.optString("mail").ifBlank { json.optString("userPrincipalName") }.ifBlank { json.optString("displayName", "Microsoft account") }
    }

    override fun list(): List<RemoteFile> {
        ensureAppRoot()
        return files(graph("GET", "/v1.0/me/drive/special/approot/children?\$select=id,name,lastModifiedDateTime"))
    }

    override fun upload(name: String, data: ByteArray, existingID: String?) {
        ensureAppRoot(); graph("PUT", "/v1.0/me/drive/special/approot:/${CloudHttp.path(name)}:/content", data, "application/octet-stream")
    }

    override fun download(id: String) = graph("GET", "/v1.0/me/drive/items/${CloudHttp.path(id)}/content")
    override fun listFolder(folder: String): List<RemoteFile> { val id = ensureFolder(folder); return files(graph("GET", "/v1.0/me/drive/items/${CloudHttp.path(id)}/children?\$select=id,name")) }
    override fun uploadFolder(folder: String, name: String, data: ByteArray, existingID: String?) { val id = ensureFolder(folder); graph("PUT", "/v1.0/me/drive/items/${CloudHttp.path(id)}:/${CloudHttp.path(name)}:/content", data, "application/octet-stream") }
    override fun delete(id: String) { graph("DELETE", "/v1.0/me/drive/items/${CloudHttp.path(id)}") }

    private fun ensureFolder(name: String): String {
        list().firstOrNull { it.name == name }?.let { return it.id }
        val body = JSONObject().put("name", name).put("folder", JSONObject()).put("@microsoft.graph.conflictBehavior", "replace").toString().encodeToByteArray()
        return JSONObject(graph("POST", "/v1.0/me/drive/special/approot/children", body, "application/json").decodeToString()).getString("id")
    }

    private fun ensureAppRoot() {
        if (appRootReady) return
        val delays = intArrayOf(1, 2, 4, 8)
        for (attempt in 0..delays.size) {
            try {
                graph("GET", "/v1.0/me/drive/special/approot?\$select=id,name,specialFolder")
                appRootReady = true; return
            } catch (error: Exception) {
                val message = error.message.orEmpty().lowercase()
                if (!("pending provisioning" in message || "servicenotavailable" in message || "http 503" in message)) throw error
                if (attempt == 0) runCatching { graph("GET", "/v1.0/me/drive?\$select=id,driveType") }
                if (attempt == delays.size) error("OneDrive is still preparing this account. Open OneDrive once with the same Microsoft account, wait for its Files page to load, then return to STG and sync again.")
                Thread.sleep(delays[attempt] * 1000L)
            }
        }
    }

    private fun graph(method: String, path: String, body: ByteArray? = null, contentType: String? = null): ByteArray {
        refreshIfNeeded()
        return CloudHttp.request(method, "https://graph.microsoft.com$path", mapOf("Authorization" to "Bearer ${credential.accessToken}"), contentType, body, "Microsoft Graph request failed")
    }

    private fun refreshIfNeeded() {
        if (credential.expiresAt > Instant.now().epochSecond + 120) return
        credential = OneDriveAuthorization.refresh(credential.refreshToken).copy(accountLabel = credential.accountLabel)
        PrivateCloudCredentials.save(context, "onedrive", credential)
    }

    private fun files(data: ByteArray): List<RemoteFile> {
        val values = JSONObject(data.decodeToString()).optJSONArray("value") ?: JSONArray()
        return (0 until values.length()).map { values.getJSONObject(it) }.map { RemoteFile(it.getString("id"), it.getString("name")) }
    }
}

internal data class GoogleAuthorizationRequest(val authorizationURL: String, val state: String, val verifier: String, val redirectURI: String)

internal object GoogleAuthorization {
    private const val scope = "openid email profile https://www.googleapis.com/auth/drive.appdata"
    fun begin(): GoogleAuthorizationRequest {
        val verifier = random(48); val challenge = Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        val state = random(24)
        val url = CloudHttp.url("https://accounts.google.com/o/oauth2/v2/auth", mapOf(
            "client_id" to CloudConfiguration.googleClientID, "redirect_uri" to CloudConfiguration.googleRedirectURI,
            "response_type" to "code", "scope" to scope, "code_challenge" to challenge, "code_challenge_method" to "S256",
            "state" to state, "access_type" to "offline", "prompt" to "consent", "include_granted_scopes" to "true"
        ))
        return GoogleAuthorizationRequest(url, state, verifier, CloudConfiguration.googleRedirectURI)
    }

    fun finish(callback: Uri, request: GoogleAuthorizationRequest): CloudCredential {
        callback.getQueryParameter("error")?.let { error("Google sign-in failed: $it") }
        check(callback.getQueryParameter("state") == request.state) { "Google sign-in state did not match" }
        val code = callback.getQueryParameter("code").orEmpty(); check(code.isNotBlank()) { "Google sign-in returned no authorization code" }
        val items = linkedMapOf("client_id" to CloudConfiguration.googleClientID, "code" to code, "code_verifier" to request.verifier, "grant_type" to "authorization_code", "redirect_uri" to request.redirectURI)
        if (BuildConfig.GOOGLE_CLIENT_SECRET.isNotBlank()) items["client_secret"] = BuildConfig.GOOGLE_CLIENT_SECRET
        return tokenCredential(CloudHttp.form("https://oauth2.googleapis.com/token", items), "")
    }

    internal fun refresh(refreshToken: String): CloudCredential {
        val items = linkedMapOf("client_id" to CloudConfiguration.googleClientID, "refresh_token" to refreshToken, "grant_type" to "refresh_token")
        if (BuildConfig.GOOGLE_CLIENT_SECRET.isNotBlank()) items["client_secret"] = BuildConfig.GOOGLE_CLIENT_SECRET
        return tokenCredential(CloudHttp.form("https://oauth2.googleapis.com/token", items), refreshToken)
    }

    private fun tokenCredential(data: ByteArray, fallback: String): CloudCredential {
        val json = JSONObject(data.decodeToString()); val refresh = json.optString("refresh_token", fallback)
        check(refresh.isNotBlank()) { "Google did not return an offline refresh token; revoke access and sign in again" }
        return CloudCredential(json.getString("access_token"), refresh, Instant.now().epochSecond + json.getLong("expires_in"), "Google account")
    }
    private fun random(count: Int): String { val bytes = ByteArray(count); SecureRandom().nextBytes(bytes); return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING) }
}

internal class GoogleCloudDrive(private val context: Context, override var credential: CloudCredential) : PrivateCloudDrive {
    fun account(): String {
        val json = JSONObject(authorized("GET", "https://openidconnect.googleapis.com/v1/userinfo").decodeToString())
        return json.optString("email").ifBlank { json.optString("name", "Google account") }
    }

    override fun list() = listFiles(null)
    override fun upload(name: String, data: ByteArray, existingID: String?) = uploadTo(name, data, existingID, "appDataFolder")
    override fun download(id: String) = authorized("GET", "https://www.googleapis.com/drive/v3/files/${CloudHttp.path(id)}?alt=media")
    override fun listFolder(folder: String) = listFiles(ensureFolder(folder))
    override fun uploadFolder(folder: String, name: String, data: ByteArray, existingID: String?) = uploadTo(name, data, existingID, ensureFolder(folder))
    override fun delete(id: String) { authorized("DELETE", "https://www.googleapis.com/drive/v3/files/${CloudHttp.path(id)}") }

    private fun listFiles(parent: String?): List<RemoteFile> {
        var query = "trashed = false"; if (parent != null) query += " and '$parent' in parents"
        val url = CloudHttp.url("https://www.googleapis.com/drive/v3/files", mapOf("spaces" to "appDataFolder", "fields" to "files(id,name)", "pageSize" to "1000", "q" to query))
        val files = JSONObject(authorized("GET", url).decodeToString()).optJSONArray("files") ?: JSONArray()
        return (0 until files.length()).map { files.getJSONObject(it) }.map { RemoteFile(it.getString("id"), it.getString("name")) }
    }

    private fun ensureFolder(name: String): String {
        list().firstOrNull { it.name == name }?.let { return it.id }
        val metadata = JSONObject().put("name", name).put("mimeType", "application/vnd.google-apps.folder").put("parents", JSONArray().put("appDataFolder")).toString().encodeToByteArray()
        return JSONObject(authorized("POST", "https://www.googleapis.com/drive/v3/files?fields=id,name", metadata, "application/json").decodeToString()).getString("id")
    }

    private fun uploadTo(name: String, data: ByteArray, existingID: String?, parent: String) {
        if (existingID != null) { authorized("PATCH", "https://www.googleapis.com/upload/drive/v3/files/${CloudHttp.path(existingID)}?uploadType=media", data, "application/octet-stream"); return }
        val boundary = "stg-${UUID.randomUUID()}"
        val metadata = JSONObject().put("name", name).put("parents", JSONArray().put(parent)).toString()
        val out = ByteArrayOutputStream(); out.write("--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n".toByteArray()); out.write("--$boundary\r\nContent-Type: application/octet-stream\r\n\r\n".toByteArray()); out.write(data); out.write("\r\n--$boundary--\r\n".toByteArray())
        authorized("POST", "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart", out.toByteArray(), "multipart/related; boundary=$boundary")
    }

    private fun authorized(method: String, url: String, body: ByteArray? = null, contentType: String? = null): ByteArray {
        refreshIfNeeded(); return CloudHttp.request(method, url, mapOf("Authorization" to "Bearer ${credential.accessToken}"), contentType, body, "Google Drive request failed")
    }
    private fun refreshIfNeeded() {
        if (credential.expiresAt > Instant.now().epochSecond + 120) return
        credential = GoogleAuthorization.refresh(credential.refreshToken).copy(accountLabel = credential.accountLabel)
        PrivateCloudCredentials.save(context, "google", credential)
    }
}

internal data class CloudHttpResponse(val status: Int, val body: ByteArray, val requestID: String?)

internal object CloudHttp {
    fun form(url: String, fields: Map<String, String>): ByteArray = request("POST", url, contentType = "application/x-www-form-urlencoded", body = encodedForm(fields), fallback = "OAuth request failed")
    fun encodedForm(fields: Map<String, String>) = fields.entries.joinToString("&") { "${query(it.key)}=${query(it.value)}" }.encodeToByteArray()
    fun url(base: String, fields: Map<String, String>) = base + "?" + fields.entries.joinToString("&") { "${query(it.key)}=${query(it.value)}" }
    fun path(value: String) = URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20")
    private fun query(value: String) = URLEncoder.encode(value, StandardCharsets.UTF_8.name())

    fun request(method: String, url: String, headers: Map<String, String> = emptyMap(), contentType: String? = null, body: ByteArray? = null, fallback: String): ByteArray {
        val response = raw(method, url, headers, contentType, body)
        if (response.status !in 200..299) error(errorMessage(fallback, response))
        return response.body
    }

    fun raw(method: String, url: String, headers: Map<String, String> = emptyMap(), contentType: String? = null, body: ByteArray? = null): CloudHttpResponse {
        val retryDelays = longArrayOf(500, 1_000, 2_000, 4_000)
        for (attempt in 0..retryDelays.size) {
            try { return rawOnce(method, url, headers, contentType, body) }
            catch (error: IOException) {
                val transient = error is UnknownHostException || error is ConnectException || error is SocketTimeoutException || error.message.orEmpty().contains("resolve host", ignoreCase = true)
                if (!transient || attempt == retryDelays.size) throw IOException("Network request failed after ${attempt + 1} attempts: ${error.message ?: error.javaClass.simpleName}", error)
                Thread.sleep(retryDelays[attempt])
            }
        }
        error("Network request failed")
    }

    private fun rawOnce(method: String, url: String, headers: Map<String, String>, contentType: String?, body: ByteArray?): CloudHttpResponse {
        val connection = URL(url).openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = method; connection.connectTimeout = 20_000; connection.readTimeout = 45_000; connection.instanceFollowRedirects = true
            connection.setRequestProperty("Accept", "application/json"); headers.forEach(connection::setRequestProperty)
            if (body != null) { connection.doOutput = true; contentType?.let { connection.setRequestProperty("Content-Type", it) }; connection.outputStream.use { it.write(body) } }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val data = stream?.use { it.readBytes() } ?: ByteArray(0)
            CloudHttpResponse(status, data, connection.getHeaderField("request-id"))
        } finally { connection.disconnect() }
    }

    fun errorMessage(fallback: String, response: CloudHttpResponse): String {
        val root = runCatching { JSONObject(response.body.decodeToString()) }.getOrNull()
        val nested = root?.optJSONObject("error")
        val code = nested?.optString("code").takeUnless { it.isNullOrBlank() } ?: root?.optString("error").takeUnless { it.isNullOrBlank() }
        val detail = nested?.optString("message").takeUnless { it.isNullOrBlank() } ?: root?.optString("error_description").takeUnless { it.isNullOrBlank() }
        return buildString { append(fallback); append(" (HTTP ${response.status}"); code?.let { append("; code=$it") }; response.requestID?.let { append("; request_id=$it") }; append(")"); detail?.let { append(": $it") } }
    }
}
