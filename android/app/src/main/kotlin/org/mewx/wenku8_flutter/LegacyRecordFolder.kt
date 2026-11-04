package org.mewx.wenku8_flutter

internal class LegacyRecordException(val code: String, message: String) : Exception(message)
internal data class LegacyRecordDocument(val id: String, val name: String, val directory: Boolean, val modified: Long)

/** Resolve only the two documented folder names, never crawl private data. */
internal object LegacyRecordFolder {
    val names = setOf("bookshelf_local.wk8", "read_saves.wk8", "read_saves_v1.wk8", "search_history.wk8")
    fun locate(root: List<LegacyRecordDocument>, children: (String) -> List<LegacyRecordDocument>): List<LegacyRecordDocument> {
        if (root.any { !it.directory && it.name in names }) return root
        root.firstOrNull { it.directory && it.name.equals("saves", true) }?.let { return children(it.id) }
        root.firstOrNull { it.directory && it.name.equals("wenku8", true) }?.let {
            val bookRoot = children(it.id)
            if (bookRoot.any { !it.directory && it.name in names }) return bookRoot
            bookRoot.firstOrNull { it.directory && it.name.equals("saves", true) }?.let { saves -> return children(saves.id) }
        }
        throw LegacyRecordException("legacy_empty", "未找到旧版记录，请选择含有 bookshelf_local.wk8 或 read_saves.wk8 的 saves 目录")
    }
}
