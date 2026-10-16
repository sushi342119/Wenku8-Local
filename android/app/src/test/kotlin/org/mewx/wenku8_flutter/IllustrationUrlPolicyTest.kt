package org.mewx.wenku8_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class IllustrationUrlPolicyTest {
    @Test fun originalAndCurrentImageHostsAreAccepted() {
        for (host in listOf("pic.wenku8.cn", "pic.wenku8.com", "img.wenku8.net", "pic.777743.xyz")) {
            assertEquals(host, IllustrationUrlPolicy.parse("https://$host/a.jpg").host)
        }
    }

    @Test fun originalSiteRedirectsStayOnHttpsAndTrustedHosts() {
        val source = IllustrationUrlPolicy.parse("https://pic.wenku8.cn/pictures/1/a.jpg")
        val cdn = IllustrationUrlPolicy.redirect(source, "http://pic.777743.xyz/pictures/1/a.jpg")
        assertEquals("https://pic.777743.xyz/pictures/1/a.jpg", cdn.toString())
        assertEquals("https://pic.777743.xyz/1/a.jpg", IllustrationUrlPolicy.redirect(cdn, "/1/a.jpg").toString())
        assertEquals("https://pic.777743.xyz/a%2Fb.jpg?key=%2F%2B", IllustrationUrlPolicy.redirect(cdn,
            "http://pic.777743.xyz:80/a%2Fb.jpg?key=%2F%2B").toString())
    }

    @Test fun redirectsCannotEscapeToUntrustedOrLocalAddresses() {
        val source = IllustrationUrlPolicy.parse("https://pic.wenku8.com/a.jpg")
        for (target in listOf("https://example.org/a", "http://127.0.0.1/a", "file:///tmp/a",
            "https://pic.wenku8.cn.evil.test/a", "https://pic.777743.xyz.evil.test/a",
            "https://wenku8.com@evil.test/a", "https://user@pic.wenku8.com/a", "https://pic.wenku8.com:8080/a")) {
            assertThrows(IllegalArgumentException::class.java) {
                IllustrationUrlPolicy.redirect(source, target)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            IllustrationUrlPolicy.parse("http://pic.wenku8.com/a.jpg")
        }
    }
}
