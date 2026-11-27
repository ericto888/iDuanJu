package app.iduanju.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.iduanju.IdjApp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * WebDAV multi-device sync (1:1 parity with iOS `WebDAVSync.swift`).
 *
 * Syncs `sync.idjbackup` (cross-platform iOS <-> Android smart-merge snapshot) containing watch progress,
 * favorites, installed plugins + scripts/storage, subscriptions, MacCMS sites, TVBox configs, Legado sources,
 * novels & manga. Credentials stay in private prefs (password encrypted via Android Keystore) and are never exported.
 */
class WebDAVSync(private val ctx: Context) {
    private val sp = ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private var lastAutoAt = 0L

    var serverURL by mutableStateOf(sp.getString(KEY_URL, "") ?: "")
    var username by mutableStateOf(sp.getString(KEY_USER, "") ?: "")
    var password by mutableStateOf(loadPassword())
    var remoteFolder by mutableStateOf(sp.getString(KEY_FOLDER, "iDuanJu") ?: "iDuanJu")
    var autoSync by mutableStateOf(sp.getBoolean(KEY_AUTO, false))
    var lastSyncAt by mutableLongStateOf(sp.getLong(KEY_LAST_AT, 0L))
        private set
    var lastStatus by mutableStateOf(sp.getString(KEY_LAST_STATUS, null))
        private set
    var busy by mutableStateOf<String?>(null)
        private set

    val isConfigured: Boolean
        get() = serverURL.trim().isNotEmpty() && username.trim().isNotEmpty() && password.isNotEmpty()

    val statusBadge: String?
        get() {
            if (!isConfigured) return null
            busy?.let { return it }
            if (lastSyncAt > 0L) {
                val rel = relativeTime(lastSyncAt)
                return if (autoSync) "自动 · $rel" else rel
            }
            return if (autoSync) "已开启自动" else "已配置"
        }

    fun saveConfig() {
        serverURL = serverURL.trim()
        username = username.trim()
        remoteFolder = cleanFolder(remoteFolder)
        sp.edit()
            .putString(KEY_URL, serverURL)
            .putString(KEY_USER, username)
            .putString(KEY_FOLDER, remoteFolder)
            .putBoolean(KEY_AUTO, autoSync)
            .apply()
        savePassword(password)
    }

    fun clearConfig() {
        serverURL = ""
        username = ""
        password = ""
        remoteFolder = "iDuanJu"
        autoSync = false
        lastSyncAt = 0L
        lastStatus = null
        sp.edit().clear().apply()
    }

    class SyncException(message: String) : Exception(message)

    data class Target(
        val baseUrl: HttpUrl,
        val folderSegments: List<String>,
        val folder: String,
        val folderUrl: HttpUrl,
        val fileUrl: HttpUrl,
        val authHeader: String,
    )

    suspend fun testConnection(): String {
        saveConfig()
        val target = makeTarget()
        busy = "测试中…"
        return try {
            val code = withContext(Dispatchers.IO) { probeAndEnsureFolder(target) }
            val msg = if (code == 201) "连接成功，已自动创建目录 /${target.folder}/" else "WebDAV 连接正常"
            recordStatus(msg, stampDate = false)
            msg
        } finally {
            busy = null
        }
    }

    /** Two-way smart-merge sync: pull remote snapshot & smart-merge locally, then upload merged snapshot. */
    suspend fun syncNow(): String {
        saveConfig()
        val target = makeTarget()
        if (busy != null) return "同步进行中"
        busy = "同步中…"
        return try {
            withContext(Dispatchers.IO) { probeAndEnsureFolder(target) }

            var mergedRemote = false
            val remoteData = withContext(Dispatchers.IO) { getFile(target) }
            if (remoteData != null && AppBackup.isBackupData(remoteData)) {
                AppBackup.restore(ctx, remoteData)
                mergedRemote = true
            }

            val localData = AppBackup.createBackupData(ctx)
            withContext(Dispatchers.IO) { putFile(target, localData) }

            val app = IdjApp.instance
            val msg = (if (mergedRemote) "双向合并完成" else "首次上传完成") +
                " · 插件 ${app.plugins.plugins.size} · 进度 ${app.library.history.size} · 收藏 ${app.library.favorites.size}"
            recordStatus(msg, stampDate = true)
            msg
        } finally {
            busy = null
        }
    }

    suspend fun pushOnly(): String {
        saveConfig()
        val target = makeTarget()
        if (busy != null) return "同步进行中"
        busy = "上传中…"
        return try {
            withContext(Dispatchers.IO) { probeAndEnsureFolder(target) }
            val data = AppBackup.createBackupData(ctx)
            withContext(Dispatchers.IO) { putFile(target, data) }
            val kb = maxOf(1, data.size / 1024)
            val msg = "已上传到云端（$kb KB）"
            recordStatus(msg, stampDate = true)
            msg
        } finally {
            busy = null
        }
    }

    suspend fun pullOnly(): String {
        saveConfig()
        val target = makeTarget()
        if (busy != null) return "同步进行中"
        busy = "拉取中…"
        return try {
            val data = withContext(Dispatchers.IO) { getFile(target) }
                ?: throw SyncException("云端尚无同步文件，请先点击「立即双向同步」或「仅上传」")
            val summary = AppBackup.restore(ctx, data)
            val msg = "云端拉取成功 · ${summary.toastText}"
            recordStatus(msg, stampDate = true)
            msg
        } finally {
            busy = null
        }
    }

    suspend fun autoSyncIfNeeded(minIntervalMs: Long = 90_000L) {
        if (!autoSync || !isConfigured || busy != null) return
        val now = System.currentTimeMillis()
        if (now - lastAutoAt < minIntervalMs) return
        lastAutoAt = now
        runCatching { syncNow() }
    }

    private fun recordStatus(msg: String, stampDate: Boolean) {
        lastStatus = msg
        val ed = sp.edit().putString(KEY_LAST_STATUS, msg)
        if (stampDate) {
            val now = System.currentTimeMillis()
            lastSyncAt = now
            ed.putLong(KEY_LAST_AT, now)
        }
        ed.apply()
    }

    private fun makeTarget(): Target {
        if (!isConfigured) throw SyncException("请先填写 WebDAV 服务器地址、账号和应用密码")
        return buildTarget(serverURL, remoteFolder, username, password)
    }

    // ── Password storage (Android Keystore AES-GCM, fallback Base64) ────────────────────────────────────

    private fun getOrCreateKey(): SecretKey? = runCatching {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(KEYSTORE_ALIAS, null) as? SecretKey) ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(KEYSTORE_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            generateKey()
        }
    }.getOrNull()

    private fun savePassword(raw: String) {
        if (raw.isEmpty()) {
            sp.edit().remove(KEY_PASS_ENC).remove(KEY_PASS_IV).remove(KEY_PASS_FALLBACK).apply()
            return
        }
        val key = getOrCreateKey()
        if (key != null) {
            val enc = runCatching {
                val c = Cipher.getInstance("AES/GCM/NoPadding")
                c.init(Cipher.ENCRYPT_MODE, key)
                val ct = c.doFinal(raw.toByteArray(Charsets.UTF_8))
                Base64.encodeToString(ct, Base64.NO_WRAP) to Base64.encodeToString(c.iv, Base64.NO_WRAP)
            }.getOrNull()
            if (enc != null) {
                sp.edit().putString(KEY_PASS_ENC, enc.first).putString(KEY_PASS_IV, enc.second).remove(KEY_PASS_FALLBACK).apply()
                return
            }
        }
        sp.edit().putString(KEY_PASS_FALLBACK, Base64.encodeToString(raw.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)).apply()
    }

    private fun loadPassword(): String {
        val enc = sp.getString(KEY_PASS_ENC, null)
        val iv = sp.getString(KEY_PASS_IV, null)
        if (enc != null && iv != null) {
            val key = getOrCreateKey()
            if (key != null) {
                runCatching {
                    val c = Cipher.getInstance("AES/GCM/NoPadding")
                    c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, Base64.decode(iv, Base64.DEFAULT)))
                    return String(c.doFinal(Base64.decode(enc, Base64.DEFAULT)), Charsets.UTF_8)
                }
            }
        }
        val fb = sp.getString(KEY_PASS_FALLBACK, null) ?: return ""
        return runCatching { String(Base64.decode(fb, Base64.DEFAULT), Charsets.UTF_8) }.getOrDefault("")
    }

    companion object {
        const val SYNC_FILE_NAME = "sync.idjbackup"
        private const val PREFS_NAME = "webdav"
        private const val KEY_URL = "stv.webdav.url"
        private const val KEY_USER = "stv.webdav.user"
        private const val KEY_FOLDER = "stv.webdav.folder"
        private const val KEY_AUTO = "stv.webdav.auto"
        private const val KEY_LAST_AT = "stv.webdav.lastAt"
        private const val KEY_LAST_STATUS = "stv.webdav.lastStatus"
        private const val KEY_PASS_ENC = "stv.webdav.passEnc"
        private const val KEY_PASS_IV = "stv.webdav.passIv"
        private const val KEY_PASS_FALLBACK = "stv.webdav.passFb"
        private const val KEYSTORE_ALIAS = "iduanju_webdav_aes"

        private val http = OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(45, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .followRedirects(false)
            .followSslRedirects(false)
            .build()

        fun cleanFolder(raw: String): String {
            val parts = raw.trim().trim('/').split('/').map { it.trim() }.filter { it.isNotEmpty() && it != "." && it != ".." }
            return if (parts.isEmpty()) "iDuanJu" else parts.joinToString("/")
        }

        fun buildTarget(serverURL: String, folder: String, username: String, password: String): Target {
            var normalized = serverURL.trim()
            if (!normalized.endsWith("/")) normalized += "/"
            val base = normalized.toHttpUrlOrNull()
            if (base == null || (base.scheme != "https" && base.scheme != "http") || base.host.isEmpty()) {
                throw SyncException("WebDAV 地址格式无效（需以 http:// 或 https:// 开头）")
            }
            val cleaned = cleanFolder(folder)
            val segs = cleaned.split('/')
            val folderBuilder = base.newBuilder()
            for (seg in segs) folderBuilder.addPathSegment(seg)
            folderBuilder.addPathSegment("") // trailing slash for collection URL
            val folderUrl = folderBuilder.build()

            val fileBuilder = base.newBuilder()
            for (seg in segs) fileBuilder.addPathSegment(seg)
            fileBuilder.addPathSegment(SYNC_FILE_NAME)
            val fileUrl = fileBuilder.build()

            val token = Base64.encodeToString("$username:$password".toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
            return Target(base, segs, cleaned, folderUrl, fileUrl, "Basic $token")
        }

        private fun relativeTime(ms: Long): String {
            val diffSec = ((System.currentTimeMillis() - ms) / 1000L).coerceAtLeast(0L)
            return when {
                diffSec < 60 -> "刚刚"
                diffSec < 3600 -> "${diffSec / 60} 分钟前"
                diffSec < 86400 -> "${diffSec / 3600} 小时前"
                else -> "${diffSec / 86400} 天前"
            }
        }

        /** Executes a WebDAV HTTP request preserving Basic Auth ONLY across same-host redirects. */
        private fun executeSameHost(
            url: HttpUrl,
            method: String,
            auth: String,
            bodyBytes: ByteArray? = null,
            headers: Map<String, String> = emptyMap(),
        ): Pair<Int, ByteArray> {
            var currentUrl = url
            var sendAuth = true
            val mediaType = "application/octet-stream".toMediaType()
            for (hop in 0..5) {
                val rb = Request.Builder()
                    .url(currentUrl)
                    .header("User-Agent", "iDuanJu-WebDAV/1.6")
                if (sendAuth) rb.header("Authorization", auth)
                headers.forEach { (k, v) -> rb.header(k, v) }
                val body = when {
                    bodyBytes != null -> bodyBytes.toRequestBody(mediaType)
                    method == "PUT" || method == "POST" || method == "MKCOL" -> ByteArray(0).toRequestBody(null)
                    else -> null
                }
                rb.method(method, body)
                http.newCall(rb.build()).execute().use { resp ->
                    val code = resp.code
                    val loc = resp.header("Location")
                    if (code in listOf(301, 302, 303, 307, 308) && loc != null && hop < 5) {
                        val next = currentUrl.resolve(loc) ?: throw SyncException("WebDAV 跳转地址无效")
                        sendAuth = next.host.equals(url.host, ignoreCase = true)
                        currentUrl = next
                    } else {
                        return code to (resp.body?.bytes() ?: ByteArray(0))
                    }
                }
            }
            throw SyncException("WebDAV 重定向次数过多")
        }

        private fun probeAndEnsureFolder(t: Target): Int {
            val (code, _) = executeSameHost(t.folderUrl, "PROPFIND", t.authHeader, headers = mapOf("Depth" to "0"))
            if (code == 401 || code == 403) throw SyncException("WebDAV 鉴权失败（$code），请检查账号与应用专用密码")
            if (code in 200..299) return code

            var cur = t.baseUrl
            var lastCode = code
            for (seg in t.folderSegments) {
                cur = cur.newBuilder().addPathSegment(seg).addPathSegment("").build()
                val (mkCode, _) = executeSameHost(cur, "MKCOL", t.authHeader)
                lastCode = mkCode
                if (mkCode == 401 || mkCode == 403) throw SyncException("WebDAV 鉴权失败（$mkCode），请检查账号与应用专用密码")
                if (mkCode !in 200..299 && mkCode != 405 && mkCode != 301 && mkCode != 302) {
                    throw SyncException("WebDAV 创建目录失败（HTTP $mkCode）")
                }
            }
            return lastCode
        }

        private fun getFile(t: Target): ByteArray? {
            val (code, bytes) = executeSameHost(t.fileUrl, "GET", t.authHeader)
            if (code == 401 || code == 403) throw SyncException("WebDAV 鉴权失败（$code），请检查账号与应用专用密码")
            if (code == 404) return null
            if (code !in 200..299) throw SyncException("读取云端同步文件失败（HTTP $code）")
            return bytes
        }

        private fun putFile(t: Target, data: ByteArray) {
            val (code, _) = executeSameHost(t.fileUrl, "PUT", t.authHeader, bodyBytes = data, headers = mapOf("Content-Type" to "application/octet-stream"))
            if (code == 401 || code == 403) throw SyncException("WebDAV 鉴权失败（$code），请检查账号与应用专用密码")
            if (code !in 200..299) throw SyncException("写入云端同步文件失败（HTTP $code）")
        }
    }
}
