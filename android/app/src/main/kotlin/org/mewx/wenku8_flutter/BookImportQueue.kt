package org.mewx.wenku8_flutter

import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.UUID

/** One selected original at a time, without keeping a batch of copied books. */
internal class BookImportQueue<T>(
    private val root: File,
    private val copy: (T, File, Long) -> Unit,
) {
    private data class Selection<T>(val source: T, val name: String, val limit: Long)
    private val selections = mutableMapOf<String, Selection<T>>()
    private var active: File? = null

    @Synchronized fun select(source: T, name: String, limit: Long): Map<String, String> {
        val token = UUID.randomUUID().toString()
        selections[token] = Selection(source, name, limit)
        return mapOf("name" to name, "token" to token)
    }

    @Synchronized fun stage(token: String): Map<String, String> {
        val selection = selections[token] ?: error("所选文件授权已结束，请重新选择这本书")
        check(active?.exists() != true) { "请等待当前书籍导入完成后重试" }
        val target = File.createTempFile("import-", ".source", root)
        try {
            copy(selection.source, target, selection.limit)
            active = target
            return mapOf("name" to selection.name, "path" to target.path)
        } catch (error: Exception) {
            target.delete()
            File(target.path + ".part").delete()
            throw error
        }
    }

    @Synchronized fun release(tokens: Iterable<String>) { tokens.forEach(selections::remove) }
}

/** Engine-owned, not Activity-owned: rotation/recreation must not revoke the
 * remaining selections or delete a file the Dart importer is still reading. */
internal class BookDocumentImportSession<T>(parent: File, copy: (T, File, Long) -> Unit) {
    private val work = lazy { BookImportWorkspace(parent) }
    val root get() = work.value.root
    val initialized get() = work.isInitialized()
    val queue by lazy { BookImportQueue(root, copy) }
    fun close() {
        // Do not race in-flight Dart I/O during engine teardown. A subsequent
        // session removes this abandoned workspace before making new copies.
        if (work.isInitialized()) work.value.abandon()
    }
}

/** Outside cacheDir so Android cannot evict a book halfway through importing.
 * Old interrupted work is removed on the next session, never durable books. */
internal class BookImportWorkspace(parent: File) : AutoCloseable {
    val root: File = synchronized(owned) {
        check(parent.isDirectory || parent.mkdirs()) { "无法创建导入目录，请检查剩余空间" }
        parent.listFiles()?.filter { it.isDirectory && it.name.startsWith("session-") && it.path !in owned }
            ?.forEach { check(it.deleteRecursively()) { "清理上次导入的临时文件失败，请重试" } }
        File(parent, "session-${UUID.randomUUID()}").also {
            check(it.mkdir()) { "无法创建导入目录，请检查剩余空间" }
            owned.add(it.path)
        }
    }

    override fun close() { synchronized(owned) {
        root.deleteRecursively()
        owned.remove(root.path)
    } }

    fun abandon() { synchronized(owned) { owned.remove(root.path) } }

    companion object { private val owned = mutableSetOf<String>() }
}

internal fun bookImportMessage(error: Exception): String {
    val messages = generateSequence<Throwable>(error) { it.cause }.mapNotNull { it.message }.joinToString(" ")
    return when {
        messages.contains("ENOSPC", true) || messages.contains("No space left", true) ->
            "存储空间不足，请清理空间后重新导入；已导入的书籍会保留"
        error is SecurityException -> "所选文件的读取授权已失效，请重新选择文件"
        error is FileNotFoundException -> "无法读取所选文件，请确认原文件仍存在且已下载到本机，再重新选择"
        error is IOException -> "文件读取或保存失败，请检查原文件与剩余空间后重试"
        else -> error.message ?: "无法读取所选文件"
    }
}
