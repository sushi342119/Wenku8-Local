package org.mewx.wenku8_flutter

import java.io.File
import java.io.InputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Bounded chapters and disk-backed resources; no whole-book image byte array. */
internal class BookEpubWriter(private val work: File, var title: String) {
    var author = ""
    var cover: String? = null
    private val chapters = mutableListOf<Pair<String, File>>()
    private val references = linkedMapOf<String, Int>()
    private val resources = mutableMapOf<Int, Pair<String, File>>()
    private val body = StringBuilder()
    private var chapterTitle = title
    private var expanded = 0L
    companion object {
        fun escape(text: String) = text.replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace("\"", "&quot;")
    }
    fun heading(value: String) { flush(); chapterTitle = value.trim().take(2048).ifEmpty { title } }
    fun text(value: String) {
        if (value.isBlank()) return
        // A huge unstructured paragraph must not become one enormous Text layout.
        var at = 0
        while (at < value.length) {
            var end = minOf(at + 4000, value.length)
            if (end < value.length && value[end - 1].isHighSurrogate()) end--
            append("<p>${escape(value.substring(at, end))}</p>")
            at = end
        }
    }
    private fun append(value: String) {
        if (body.length + value.length > 200000) flush()
        body.append(value)
    }
    private fun reference(key: String) = references.getOrPut(key) { references.size }
    fun inlineResourceKey() = "inline-${references.size}"
    fun image(key: String, style: String = "") {
        append("<img src=\"resource:${reference(key)}\"${if (style.isEmpty()) "" else " style=\"${escape(style)}\""}/>")
    }
    fun resource(key: String, type: String, input: InputStream) {
        val ext = when (type.lowercase().substringBefore(';')) {
            "image/jpeg", "jpg", "jpeg" -> "jpg"
            "image/png", "png" -> "png"
            "image/gif", "gif" -> "gif"
            "image/webp", "webp" -> "webp"
            else -> return
        }
        val id = reference(key)
        if (resources.containsKey(id)) return
        val file = File(work, "resource-$id.$ext")
        var size = 0L
        try {
            file.outputStream().use { output ->
                val buffer = ByteArray(65536)
                while (true) {
                    val read = input.read(buffer); if (read < 0) break
                    size += read
                    require(size <= 8L * 1024 * 1024 && expanded + size <= 1024L * 1024 * 1024) {
                        "单张图片超过 8 MiB，或文档展开后超过 1 GiB"
                    }
                    output.write(buffer, 0, read)
                }
            }
            expanded += size
            resources[id] = ext to file
        } catch (error: Exception) { file.delete(); throw error }
    }
    private fun flush() {
        if (body.isEmpty()) return
        require(chapters.size < 10000) { "文档章节过多，请拆分后导入" }
        val file = File(work, "chapter-${chapters.size}.html")
        file.writeText(body.toString())
        expanded += file.length()
        require(expanded <= 1024L * 1024 * 1024) { "文档展开后超过 1 GiB" }
        chapters += chapterTitle to file
        body.setLength(0)
    }
    fun write(output: File) {
        flush()
        require(chapters.isNotEmpty()) { "文档中没有可阅读的正文" }
        ZipOutputStream(output.outputStream().buffered(65536)).use { zip ->
            fun entry(path: String, value: String) {
                zip.putNextEntry(ZipEntry(path).apply { time = 0 })
                zip.write(value.toByteArray(Charsets.UTF_8)); zip.closeEntry()
            }
            entry("mimetype", "application/epub+zip")
            entry("META-INF/container.xml", """<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""")
            val coverId = cover?.let { references[it] }
            val manifest = chapters.indices.joinToString("") { "<item id=\"c$it\" href=\"c$it.xhtml\" media-type=\"application/xhtml+xml\"/>" } +
                resources.entries.sortedBy { it.key }.joinToString("") { (id, item) ->
                    "<item id=\"i$id\" href=\"image-$id.${item.first}\" media-type=\"image/${if (item.first == "jpg") "jpeg" else item.first}\"${if (id == coverId) " properties=\"cover-image\"" else ""}/>"
                }
            entry("content.opf", """<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>${escape(title)}</dc:title><dc:creator>${escape(author)}</dc:creator></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>$manifest</manifest><spine>${chapters.indices.joinToString("") { "<itemref idref=\"c$it\"/>" }}</spine></package>""")
            entry("nav.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol>${chapters.mapIndexed { i, c -> "<li><a href=\"c$i.xhtml\">${escape(c.first)}</a></li>" }.joinToString("")}</ol></nav></body></html>""")
            for ((i, chapter) in chapters.withIndex()) {
                val html = chapter.second.readText().replace(Regex("resource:(\\d+)")) { match ->
                    val id = match.groupValues[1].toInt()
                    resources[id]?.let { "image-$id.${it.first}" } ?: ""
                }
                entry("c$i.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>$html</body></html>")
            }
            for ((id, item) in resources.toSortedMap()) {
                zip.putNextEntry(ZipEntry("image-$id.${item.first}").apply { time = 0 })
                item.second.inputStream().use { it.copyTo(zip, 65536) }; zip.closeEntry()
            }
        }
        require(output.length() <= BookArchiveImport.MAX_ARCHIVE) { "转换后的文档超过 512 MiB" }
    }
}
