package org.mewx.wenku8_flutter

import android.content.Context
import android.graphics.BitmapFactory
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mewx.wenku8.api.TokenManager
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.zip.GZIPInputStream

/** Bounded I/O workers; guest content requests cannot mutate an account session. */
internal class Wenku8Bridge(context: Context, private val postToMain: (Runnable) -> Unit) : MethodChannel.MethodCallHandler {
    private val io = Executors.newFixedThreadPool(4)
    private val accounts = Executors.newSingleThreadExecutor()
    private val imageIo = Executors.newSingleThreadExecutor()
    private val store = AccountSessionStore(context)
    @Volatile private var sessionCookie: String? = null
    @Volatile private var sessionLoaded = false
    @Volatile private var sessionRevision = 0
    private val images = File(context.filesDir, "wenku8-illustrations-v1")
    private val imageLock = Any()
    private data class Response(val bytes: ByteArray, val cookie: String?)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf("request", "cover", "requestBytes", "accountRequest", "login", "hasSession", "clearSession", "illustration", "clearIllustrations", "encodeReview")) {
            result.notImplemented()
            return
        }
        val account = call.method in setOf("accountRequest", "login", "hasSession", "clearSession")
        val queuedRevision = sessionRevision
        (if (account) accounts else if (call.method in setOf("illustration", "clearIllustrations")) imageIo else io).execute {
            try {
                if (account && !sessionLoaded) {
                    sessionCookie = store.read()
                    sessionLoaded = true
                }
                val response: Any? = when (call.method) {
                    "hasSession" -> sessionCookie != null
                    "clearSession" -> {
                        store.write(null)
                        sessionCookie = null
                        sessionRevision++
                        null
                    }
                    "encodeReview" -> {
                        val text = call.argument<String>("text") ?: throw IllegalArgumentException("Missing text")
                        require(text.length <= 10000)
                        if (!charset("GBK").newEncoder().canEncode(text)) {
                            postToMain(Runnable { result.error("REVIEW_ENCODING", "Characters outside the review encoding", null) })
                            return@execute
                        }
                        Base64.encodeToString(URLEncoder.encode(text, "GBK").toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
                    }
                    "illustration" -> illustration(call.argument<String>("url") ?: "")
                    "clearIllustrations" -> synchronized(imageLock) {
                        check(!images.exists() || images.deleteRecursively())
                        null
                    }
                    else -> {
                        val action = if (call.method == "cover") {
                            val id = call.argument<Int>("aid") ?: 0
                            require(id > 0)
                            "action=book&do=cover&aid=$id"
                        } else call.argument<String>("action") ?: ""
                        require(action.isNotBlank() && action.length <= 60000)
                        if (call.method == "login") {
                            require(action.startsWith("action=login&") || action.startsWith("action=loginemail&"))
                            val reply = request(action, null)
                            val text = reply.bytes.toString(Charsets.UTF_8)
                            if (text.trim() == "1") {
                                val cookie = reply.cookie ?: throw IllegalStateException("Missing session")
                                store.write(cookie)
                                sessionCookie = cookie
                                sessionRevision++
                            }
                            text
                        } else if (call.method == "accountRequest") {
                            check(queuedRevision == sessionRevision) { "Session changed" }
                            val cookie = sessionCookie
                            if (cookie == null) "4" else {
                                val reply = request(action, cookie)
                                val text = reply.bytes.toString(Charsets.UTF_8)
                                if (reply.cookie != null && reply.cookie != cookie && text.trim() != "4") {
                                    store.write(reply.cookie)
                                    sessionCookie = reply.cookie
                                }
                                text
                            }
                        } else {
                            val reply = request(action, null)
                            if (call.method == "request") reply.bytes.toString(Charsets.UTF_8) else reply.bytes
                        }
                    }
                }
                postToMain(Runnable { result.success(response) })
            } catch (_: Exception) {
                // Never expose actions, credentials or cookie-bearing exceptions.
                postToMain(Runnable { result.error("LEGACY_API_ERROR", "Request or local storage failed", null) })
            } catch (_: LinkageError) {
                postToMain(Runnable { result.error("LEGACY_API_RUNTIME", "Legacy runtime unavailable", null) })
            }
        }
    }

    private fun request(action: String, cookie: String?): Response {
        val version = TokenManager.getMagicVersionCpp("1.30")
        val encoded = Base64.encodeToString(action.toByteArray(Charsets.UTF_8), Base64.DEFAULT).trim()
        val body = "&appver=$version&request=$encoded&timetoken=${System.currentTimeMillis()}"
        val connection = (URL("https://wenku8-relay.mewx.org/").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            setRequestProperty("Accept-Encoding", "gzip")
            setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
            cookie?.let { setRequestProperty("Cookie", "PHPSESSID=$it") }
            connectTimeout = 5000
            readTimeout = 10000
            doOutput = true
            instanceFollowRedirects = false
        }
        try {
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            check(connection.responseCode in 200..299)
            val session = connection.headerFields.entries
                .filter { it.key?.equals("Set-Cookie", ignoreCase = true) == true }
                .flatMap { it.value }.firstNotNullOfOrNull {
                    Regex("(?:^|[;,]\\s*)PHPSESSID=([A-Za-z0-9,-]{8,256})").find(it)?.groupValues?.get(1)
                }
            val stream = if (connection.contentEncoding?.contains("gzip", ignoreCase = true) == true) {
                GZIPInputStream(BufferedInputStream(connection.inputStream))
            } else connection.inputStream
            return Response(stream.use { readBounded(it, 8 * 1024 * 1024) }, session)
        } finally {
            connection.disconnect()
        }
    }

    private fun illustration(raw: String): ByteArray = synchronized(imageLock) {
        val url = IllustrationUrlPolicy.parse(raw)
        val name = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray()).joinToString("") { "%02x".format(it) }
        val file = File(images, name)
        if (file.isFile) {
            try {
                require(file.length() in 1..(8 * 1024 * 1024))
                val cached = file.readBytes()
                validateImage(cached)
                file.setLastModified(System.currentTimeMillis())
                return@synchronized cached
            } catch (_: Exception) { file.delete() }
        }
        val bytes = downloadIllustration(url)
            try {
                images.mkdirs()
                val temporary = File(images, "$name.part")
                temporary.writeBytes(bytes)
                check(temporary.renameTo(file))
                val cached = images.listFiles()?.filter { it.isFile } ?: emptyList()
                var size = cached.sumOf { it.length() }
                for (old in cached.sortedBy { it.lastModified() }) {
                    if (size <= 256L * 1024 * 1024) break
                    if (old != file) { val length = old.length(); if (old.delete()) size -= length }
                }
            } catch (_: Exception) { /* An online illustration survives a cache write error. */ }
        bytes
    }

    private fun downloadIllustration(source: URL): ByteArray {
        var url = source
        for (hop in 0..3) {
            val connection = (url.openConnection() as HttpURLConnection).apply {
                connectTimeout = 5000
                readTimeout = 12000
                instanceFollowRedirects = false
            }
            try {
                val status = connection.responseCode
                if (status in setOf(301, 302, 303, 307, 308)) {
                    check(hop < 3) { "Too many image redirects" }
                    val location = connection.getHeaderField("Location")
                    require(!location.isNullOrBlank())
                    url = IllustrationUrlPolicy.redirect(url, location)
                } else {
                    check(status in 200..299)
                    val bytes = connection.inputStream.use { readBounded(it, 8 * 1024 * 1024) }
                    validateImage(bytes)
                    return bytes
                }
            } finally {
                connection.disconnect()
            }
        }
        error("Image redirect limit")
    }

    private fun validateImage(bytes: ByteArray) {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0 &&
            bounds.outWidth.toLong() * bounds.outHeight <= 50_000_000L)
    }

    private fun readBounded(input: java.io.InputStream, limit: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size() + count <= limit)
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
    fun close() {
        io.shutdown()
        accounts.shutdown()
        imageIo.shutdown()
    }
}
