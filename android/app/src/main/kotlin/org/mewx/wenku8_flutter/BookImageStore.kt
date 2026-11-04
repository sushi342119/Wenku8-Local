package org.mewx.wenku8_flutter

import android.content.ContentValues
import android.content.Context
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

/** Keep original encoded pixels; exporting never recompresses a book image. */
internal object BookImageStore {
    data class Image(val bytes: ByteArray, val mime: String, val name: String)
    fun renderedImage(bytes: ByteArray?, name: String?): Image {
        require(QuoteCardImage.valid(bytes)) { "图片格式或大小无效" }
        return Image(bytes!!, "image/png", QuoteCardImage.fileName(name))
    }
    fun image(bytes: ByteArray?, name: String?): Image {
        require(bytes != null && bytes.size in 16..8 * 1024 * 1024) { "图片大小无效" }
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        val extension = when (options.outMimeType) {
            "image/jpeg" -> "jpg"
            "image/png" -> "png"
            "image/webp" -> "webp"
            "image/gif" -> "gif"
            else -> throw IllegalArgumentException("不支持此图片格式")
        }
        require(options.outWidth > 0 && options.outHeight > 0 && options.outWidth.toLong() * options.outHeight <= 80_000_000) { "图片尺寸无效" }
        val stem = (name ?: "文库插图").replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "-").take(96).ifBlank { "文库插图" }
        return Image(bytes, options.outMimeType, "$stem.$extension")
    }

    fun save(context: Context, image: Image) {
        val resolver = context.contentResolver
        // Before scoped storage, a granted WRITE_EXTERNAL_STORAGE permission
        // allows a normal Pictures file. A unique file never replaces an image.
        val legacyFile = if (Build.VERSION.SDK_INT < 29) {
            @Suppress("DEPRECATION")
            val directory = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "Wenku8")
            check(directory.isDirectory || directory.mkdirs()) { "无法创建相册目录" }
            val extension = image.name.substringAfterLast('.', "png")
            File.createTempFile(image.name.substringBeforeLast('.').take(80).padEnd(3, '-'), ".$extension", directory)
        } else null
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, image.name)
            put(MediaStore.Images.Media.MIME_TYPE, image.mime)
            if (Build.VERSION.SDK_INT >= 29) {
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Wenku8")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            } else {
                @Suppress("DEPRECATION")
                put(MediaStore.Images.Media.DATA, checkNotNull(legacyFile).absolutePath)
            }
        }
        try {
            commitGalleryImage(
                create = {
                    resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                        ?: throw IllegalStateException("无法创建图片")
                },
                write = { uri ->
                    resolver.openOutputStream(uri)?.use { it.write(image.bytes); it.flush() }
                        ?: throw IllegalStateException("无法保存图片")
                },
                publish = { uri ->
                    val complete = ContentValues().apply {
                        put(MediaStore.Images.Media.SIZE, image.bytes.size)
                        if (Build.VERSION.SDK_INT >= 29) put(MediaStore.Images.Media.IS_PENDING, 0)
                    }
                    check(resolver.update(uri, complete, null, null) == 1) { "图片尚未保存完成" }
                },
                rollback = { uri -> resolver.delete(uri, null, null) },
            )
        } catch (error: Exception) {
            legacyFile?.delete()
            throw error
        }
    }
}
