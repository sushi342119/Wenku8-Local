package org.mewx.wenku8_flutter

/** An album entry becomes successful only after its full bytes are published. */
internal fun <T> commitGalleryImage(
    create: () -> T,
    write: (T) -> Unit,
    publish: (T) -> Unit,
    rollback: (T) -> Unit,
): T {
    val asset = create()
    try {
        write(asset)
        publish(asset)
        return asset
    } catch (error: Exception) {
        try { rollback(asset) } catch (cleanup: Exception) { error.addSuppressed(cleanup) }
        throw error
    }
}
