package org.mewx.wenku8_flutter

/** A provider's flag is an offer, not proof of a retained read grant. */
internal fun retainBookOpenReadGrant(
    persistableOffered: Boolean,
    hasPersistedRead: () -> Boolean,
    retainRead: () -> Unit,
): Boolean {
    if (hasPersistedRead()) return true
    if (persistableOffered) {
        try { retainRead() }
        catch (_: SecurityException) { /* The source remains temporary. */ }
    }
    return hasPersistedRead()
}
