package org.mewx.wenku8_flutter

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File

internal class BookArchiveImport(private val root: File) {
    var documents: BookMarkupImport? = null

    companion object {
        const val MAX_ARCHIVE = 512L * 1024 * 1024
        private val supportedPattern = Regex(
            "\\.(txt|epub|mobi|azw|azw3|prc|fb2|pdf|docx?|rtf|html?|xhtml|md|markdown|zip)$",
            RegexOption.IGNORE_CASE,
        )

        fun supported(name: String): Boolean = supportedPattern.containsMatchIn(name.trim())

        fun limit(name: String): Long = when (name.substringAfterLast('.', "").lowercase()) {
            "zip", "epub", "pdf", "docx" -> MAX_ARCHIVE
            "mobi", "azw", "azw3", "prc" -> 256L * 1024 * 1024
            "html", "htm", "xhtml", "md", "markdown" -> 32L * 1024 * 1024
            else -> 128L * 1024 * 1024
        }
    }

    fun prepare(name: String, source: File): List<Map<String, String?>> =
        prepare(name, BookDocumentInput(source))

    fun prepare(name: String, source: BookDocumentInput): List<Map<String, String?>> {
        val cleanName = name.replace('\\', '/').substringAfterLast('/').trim().ifEmpty { "未命名书籍.txt" }
        val ext = cleanName.substringAfterLast('.', "").lowercase()
        require(supported(cleanName)) { "请选择支持的电子书或文档" }
        require(source.length() in 1..limit(cleanName)) { "文件为空或超过此格式的导入大小限制" }
        return when (ext) {
            "zip" -> prepareZip(source)
            "txt", "epub" -> {
                val staged = stageInput(source, ext)
                listOf(mapOf("name" to cleanName, "path" to staged.path, "error" to null))
            }
            else -> {
                val converter = documents ?: BookMarkupImport(root)
                try {
                    val converted = converter.convert(cleanName, source)
                    val epubName = "${cleanName.substringBeforeLast('.', cleanName)}.epub"
                    listOf(mapOf("name" to epubName, "path" to converted.path, "error" to null))
                } catch (error: Exception) {
                    listOf(mapOf("name" to cleanName, "path" to null, "error" to bookImportMessage(error)))
                }
            }
        }
    }

    private fun stageInput(source: BookDocumentInput, ext: String): File {
        source.file?.let { existing ->
            if (existing.parentFile?.canonicalFile == root.canonicalFile) return existing
        }
        val target = File.createTempFile("import-", ".source", root)
        try {
            source.inputStream().use { input ->
                target.outputStream().use { output -> input.copyTo(output, 65536) }
            }
            return target
        } catch (error: Exception) {
            target.delete()
            throw error
        }
    }

    private fun prepareZip(source: BookDocumentInput): List<Map<String, String?>> {
        val results = mutableListOf<Map<String, String?>>()
        source.zip().use { zip ->
            val candidates = zip.entries.filter { entry ->
                !entry.isDirectory &&
                    !entry.name.startsWith("__MACOSX/") &&
                    !entry.name.substringAfterLast('/').startsWith(".") &&
                    supported(entry.name) &&
                    !entry.name.endsWith(".zip", ignoreCase = true)
            }
            require(candidates.isNotEmpty()) { "压缩包中没有可导入的书籍或文档" }
            require(candidates.size <= 256) { "单次最多从压缩包导入 256 本书" }
            zip.readEntries(candidates) { entry, stream ->
                val entryName = entry.name.replace('\\', '/').substringAfterLast('/')
                var temp: File? = null
                try {
                    val staged = File.createTempFile("import-", ".source", root)
                    temp = staged
                    val max = limit(entryName)
                    var total = 0L
                    staged.outputStream().use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            val read = stream.read(buffer)
                            if (read < 0) break
                            total += read
                            require(total <= max) { "文件超过 ${max / (1024 * 1024)} MiB 大小限制" }
                            output.write(buffer, 0, read)
                        }
                    }
                    val ext = entryName.substringAfterLast('.', "").lowercase()
                    if (ext == "txt" || ext == "epub") {
                        results += mapOf("name" to entryName, "path" to staged.path, "error" to null)
                        temp = null
                    } else {
                        val prepared = prepare(entryName, BookDocumentInput(staged))
                        staged.delete()
                        temp = null
                        results.addAll(prepared)
                    }
                } catch (error: Exception) {
                    temp?.delete()
                    results += mapOf("name" to entryName, "path" to null, "error" to bookImportMessage(error))
                }
            }
        }
        return results
    }
}

internal class BookMarkupImport(
    private val root: File,
    private val pdfReader: ((String, BookDocumentInput) -> File)? = null,
) {
    fun convert(name: String, source: BookDocumentInput): File {
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext == "pdf" && pdfReader != null) {
            return pdfReader.invoke(name, source)
        }
        val title = name.substringBeforeLast('.', name).ifBlank { "导入文档" }
        val work = File.createTempFile("epub-work-", "", root).apply {
            delete()
            mkdirs()
        }
        val output = File.createTempFile("import-", ".source", root)
        try {
            val writer = BookEpubWriter(work, title)
            when (ext) {
                "docx" -> convertDocx(source, writer)
                "fb2" -> convertXmlText(source, writer)
                "html", "htm", "xhtml" -> convertHtml(source, writer)
                "rtf" -> convertRtf(source, writer)
                else -> convertPlainText(source, writer)
            }
            writer.write(output)
            return output
        } catch (error: Exception) {
            output.delete()
            throw error
        } finally {
            work.deleteRecursively()
        }
    }

    private fun readDecodedText(source: BookDocumentInput): String {
        val bytes = source.inputStream().use { it.readBytes() }
        return try {
            BookTextDecoder.decode(bytes, "auto")
        } catch (_: Exception) {
            String(bytes, Charsets.UTF_8)
        }
    }

    private fun convertPlainText(source: BookDocumentInput, writer: BookEpubWriter) {
        val text = readDecodedText(source)
        for (line in text.lineSequence()) {
            val trimmed = line.trim()
            if (trimmed.isEmpty()) continue
            if (trimmed.startsWith("#")) {
                writer.heading(trimmed.trimStart('#', ' ').ifEmpty { writer.title })
            } else {
                writer.text(trimmed)
            }
        }
    }

    private fun convertHtml(source: BookDocumentInput, writer: BookEpubWriter) {
        val raw = readDecodedText(source)
        val withoutScripts = raw
            .replace(Regex("(?is)<(script|style)\\b[^>]*>.*?</\\1>"), "")
            .replace(Regex("(?i)<(br|p|/p|div|/div|h[1-6]|/h[1-6]|li|/li)\\b[^>]*>"), "\n")
            .replace(Regex("<[^>]+>"), "")
            .replace("&nbsp;", " ")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&amp;", "&")
            .replace("&quot;", "\"")
        for (line in withoutScripts.lineSequence()) {
            val trimmed = line.trim()
            if (trimmed.isNotEmpty()) writer.text(trimmed)
        }
    }

    private fun convertRtf(source: BookDocumentInput, writer: BookEpubWriter) {
        val raw = readDecodedText(source)
        val stripped = raw
            .replace(Regex("\\\\par\\b\\s*"), "\n")
            .replace(Regex("\\\\[a-zA-Z]+-?\\d*\\s?"), "")
            .replace(Regex("[{}]"), "")
        for (line in stripped.lineSequence()) {
            val trimmed = line.trim()
            if (trimmed.isNotEmpty()) writer.text(trimmed)
        }
    }

    private fun convertXmlText(source: BookDocumentInput, writer: BookEpubWriter) {
        val text = readDecodedText(source)
        try {
            val parser = XmlPullParserFactory.newInstance().newPullParser()
            parser.setInput(text.reader())
            val paragraph = StringBuilder()
            var inParagraph = false
            var event = parser.eventType
            while (event != XmlPullParser.END_DOCUMENT) {
                when (event) {
                    XmlPullParser.START_TAG -> {
                        if (parser.name.equals("p", ignoreCase = true) || parser.name.equals("title", ignoreCase = true)) {
                            inParagraph = true
                            paragraph.setLength(0)
                        }
                    }
                    XmlPullParser.TEXT -> if (inParagraph) paragraph.append(parser.text)
                    XmlPullParser.END_TAG -> {
                        if (parser.name.equals("title", ignoreCase = true)) {
                            val heading = paragraph.toString().trim()
                            if (heading.isNotEmpty()) writer.heading(heading)
                            inParagraph = false
                        } else if (parser.name.equals("p", ignoreCase = true)) {
                            val line = paragraph.toString().trim()
                            if (line.isNotEmpty()) writer.text(line)
                            inParagraph = false
                        }
                    }
                }
                event = parser.next()
            }
        } catch (_: Exception) {
            convertHtml(source, writer)
        }
    }

    private fun convertDocx(source: BookDocumentInput, writer: BookEpubWriter) {
        source.zip().use { zip ->
            val docEntry = zip.getEntry("word/document.xml")
                ?: error("DOCX 文档缺少正文内容")
            zip.getInputStream(docEntry).use { stream ->
                val parser = XmlPullParserFactory.newInstance().newPullParser()
                parser.setInput(stream, "UTF-8")
                val paragraph = StringBuilder()
                var inText = false
                var event = parser.eventType
                while (event != XmlPullParser.END_DOCUMENT) {
                    when (event) {
                        XmlPullParser.START_TAG -> {
                            val local = parser.name.substringAfterLast(':')
                            if (local == "p") paragraph.setLength(0)
                            if (local == "t") inText = true
                        }
                        XmlPullParser.TEXT -> if (inText) paragraph.append(parser.text)
                        XmlPullParser.END_TAG -> {
                            val local = parser.name.substringAfterLast(':')
                            if (local == "t") inText = false
                            if (local == "p") {
                                val line = paragraph.toString().trim()
                                if (line.isNotEmpty()) writer.text(line)
                                paragraph.setLength(0)
                            }
                        }
                    }
                    event = parser.next()
                }
            }
        }
    }
}

internal class BookPdfImport(
    private val activity: Activity,
    private val root: File,
) {
    fun read(name: String, source: BookDocumentInput): File {
        val title = name.substringBeforeLast('.', name).ifBlank { "PDF 文档" }
        val work = File.createTempFile("pdf-work-", "", root).apply {
            delete()
            mkdirs()
        }
        val output = File.createTempFile("import-", ".source", root)
        var tempPdf: File? = null
        try {
            val pdfFile = source.file ?: File.createTempFile("pdf-src-", ".pdf", work).also { target ->
                tempPdf = target
                source.inputStream().use { input ->
                    target.outputStream().use { out -> input.copyTo(out, 65536) }
                }
            }
            val writer = BookEpubWriter(work, title)
            ParcelFileDescriptor.open(pdfFile, ParcelFileDescriptor.MODE_READ_ONLY).use { pfd ->
                PdfRenderer(pfd).use { renderer ->
                    require(renderer.pageCount > 0) { "PDF 文档没有可阅读的页面" }
                    val limit = minOf(renderer.pageCount, 2000)
                    for (index in 0 until limit) {
                        renderer.openPage(index).use { page ->
                            val width = page.width.coerceIn(360, 1440)
                            val height = (page.height.toLong() * width / maxOf(1, page.width)).toInt().coerceIn(360, 2560)
                            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                            try {
                                Canvas(bitmap).drawColor(Color.WHITE)
                                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                val png = ByteArrayOutputStream()
                                bitmap.compress(Bitmap.CompressFormat.PNG, 100, png)
                                val key = "page-$index"
                                writer.resource(key, "image/png", ByteArrayInputStream(png.toByteArray()))
                                if (index == 0) writer.cover = key
                                writer.heading("第 ${index + 1} 页")
                                writer.image(key)
                            } finally {
                                bitmap.recycle()
                            }
                        }
                    }
                }
            }
            writer.write(output)
            return output
        } catch (error: Exception) {
            output.delete()
            throw error
        } finally {
            tempPdf?.delete()
            work.deleteRecursively()
        }
    }
}
