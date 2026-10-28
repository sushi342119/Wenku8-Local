package org.mewx.wenku8_flutter

import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.FutureTask
import java.util.concurrent.atomic.AtomicInteger

class LocalToolRequestsTest {
    private class Reply : MethodChannel.Result {
        val done = CountDownLatch(1)
        val count = AtomicInteger()
        @Volatile var code: String? = null
        override fun success(result: Any?) { count.incrementAndGet(); done.countDown() }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            code = errorCode
            count.incrementAndGet()
            done.countDown()
        }
        override fun notImplemented() { count.incrementAndGet(); done.countDown() }
    }

    @Test fun activityDetachFailsRunningQueuedAndPickerRequestsExactlyOnce() {
        val requests = LocalToolRequests { it() }
        val executor = Executors.newSingleThreadExecutor()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val running = Reply()
        val queued = Reply()
        val fontPicker = Reply()
        try {
            assertTrue(requests.begin(running, 10000))
            assertTrue(requests.begin(queued, 10000))
            assertTrue(requests.begin(fontPicker))
            executor.execute {
                entered.countDown()
                release.await()
                requests.success(running, "late result")
            }
            executor.execute { requests.success(queued, "queued result") }
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            // The close operation used by LocalTools on Activity detach must
            // settle requests even when executor work cannot currently finish.
            requests.close()
            for (reply in listOf(running, queued, fontPicker)) {
                assertTrue(reply.done.await(1, TimeUnit.SECONDS))
                assertEquals("closed", reply.code)
            }
            release.countDown()
            executor.shutdown()
            assertTrue(executor.awaitTermination(1, TimeUnit.SECONDS))
            requests.success(fontPicker, "late picker result")
            requests.close()
            for (reply in listOf(running, queued, fontPicker)) assertEquals(1, reply.count.get())
            val detached = Reply()
            assertFalse(requests.begin(detached))
            assertEquals("closed", detached.code)
        } finally {
            release.countDown()
            executor.shutdownNow()
            requests.close()
        }
    }

    @Test fun blockedDirectoryOrReadTimesOutWithoutWaitingForExecutor() {
        val requests = LocalToolRequests { it() }
        try {
            val query = Reply()
            val read = Reply()
            requests.begin(query, 30)
            requests.begin(read, 30)
            val work = FutureTask<Unit> { }
            requests.track(query, work)
            for (reply in listOf(query, read)) {
                assertTrue(reply.done.await(1, TimeUnit.SECONDS))
                assertEquals("timeout", reply.code)
                assertFalse(requests.active(reply))
                requests.success(reply, "late provider completion")
                requests.error(reply, "local", "late provider error")
                assertEquals(1, reply.count.get())
            }
            assertTrue(work.isCancelled)
        } finally { requests.close() }
    }

    @Test fun queuedUiCompletionAfterDetachCannotReplyTwice() {
        val posts = mutableListOf<() -> Unit>()
        val requests = LocalToolRequests { posts.add(it) }
        val reply = Reply()
        requests.begin(reply)
        requests.success(reply, "ready before detach")
        requests.close()
        posts.forEach { it() }
        assertEquals("closed", reply.code)
        assertEquals(1, reply.count.get())
    }
}
