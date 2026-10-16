package org.mewx.wenku8_flutter

import java.net.URI
import java.net.URL
import java.util.Locale

/** The original site's image hosts and its verified image-only CDN. */
internal object IllustrationUrlPolicy {
    private fun checked(uri: URI): URL {
        val host = uri.host?.lowercase(Locale.ROOT) ?: error("Missing image host")
        require(uri.scheme.equals("https", ignoreCase = true) && uri.userInfo == null &&
            uri.port in setOf(-1, 443) &&
            (listOf("wenku8.com", "wenku8.net", "wenku8.cn").any {
                host == it || host.endsWith(".$it")
            } || host == "pic.777743.xyz")) { "Unsupported image address" }
        return uri.toURL()
    }

    fun parse(raw: String): URL = checked(URI(raw))

    /** Recheck every hop, upgrading the site's historical HTTP redirects. */
    fun redirect(from: URL, location: String): URL {
        val next = from.toURI().resolve(location)
        require(next.scheme.equals("http", ignoreCase = true) ||
            next.scheme.equals("https", ignoreCase = true))
        require(next.port in setOf(-1, 80, 443))
        val authority = requireNotNull(next.rawAuthority).let {
            if (next.port == 80) it.removeSuffix(":80") else it
        }
        // Keep percent-escaped paths and query signatures byte-for-byte.
        // URI's decoded path constructor would turn an encoded slash into '/'.
        val secure = "https://$authority${next.rawPath.orEmpty()}" +
            (next.rawQuery?.let { "?$it" } ?: "") +
            (next.rawFragment?.let { "#$it" } ?: "")
        return checked(URI(secure))
    }
}
