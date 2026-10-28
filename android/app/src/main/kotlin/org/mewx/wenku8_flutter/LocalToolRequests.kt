package org.mewx.wenku8_flutter

import io.flutter.plugin.common.MethodChannel
import java.util.IdentityHashMap
import java.util.concurrent.Future
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Owns every asynchronous channel reply across picker, executor and detach.
 * All terminal callbacks use the same removal gate, so late work cannot reply twice. */
internal class LocalToolRequests(private val post: (() -> Unit) -> Unit) {
    private data class Pending(
        val result: MethodChannel.Result,
        var timer: ScheduledFuture<*>? = null,
        var work: Future<*>? = null,
    )
    private val pending = IdentityHashMap<MethodChannel.Result, Pending>()
    private val timers = ScheduledThreadPoolExecutor(1).apply { removeOnCancelPolicy = true }
    @Volatile var closed = false
        private set

    @Synchronized fun begin(result: MethodChannel.Result, timeoutMs: Long? = null): Boolean {
        if (closed) {
            result.error("closed", "Activity closed", null)
            return false
        }
        val call = Pending(result)
        pending[result] = call
        if (timeoutMs != null) deadline(result, timeoutMs)
        return true
    }

    @Synchronized fun deadline(result: MethodChannel.Result, timeoutMs: Long) {
        val call = pending[result] ?: return
        call.timer?.cancel(false)
        call.timer = timers.schedule(
            { error(result, "timeout", "Local file operation timed out; please retry") },
            timeoutMs, TimeUnit.MILLISECONDS,
        )
    }

    @Synchronized fun track(result: MethodChannel.Result, work: Future<*>) {
        val call = pending[result]
        if (call == null) work.cancel(true) else call.work = work
    }

    @Synchronized fun active(result: MethodChannel.Result) = pending.containsKey(result)

    fun complete(result: MethodChannel.Result, action: () -> Unit): Boolean {
        val call = synchronized(this) { pending.remove(result) } ?: return false
        call.timer?.cancel(false)
        action()
        return true
    }

    fun success(result: MethodChannel.Result, value: Any?) = post {
        complete(result) { result.success(value) }
    }

    fun error(result: MethodChannel.Result, code: String, message: String) = post {
        val call = synchronized(this) { pending.remove(result) }
        if (call != null) {
            call.timer?.cancel(false)
            call.work?.cancel(true)
            result.error(code, message, null)
        }
    }

    fun close() {
        val calls = synchronized(this) {
            if (closed) return
            closed = true
            pending.values.toList().also { pending.clear() }
        }
        timers.shutdownNow()
        // Invoked on the platform thread by Activity detach.
        for (call in calls) {
            call.timer?.cancel(false)
            call.work?.cancel(true)
            call.result.error("closed", "Activity closed", null)
        }
    }
}
