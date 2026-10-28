package local.saf

/** A provider must confirm the exact display name; never assume a requested
 * name was used. On an unconfirmed or adjusted name, restore the old name. */
fun <U> localRenameOutcome(
    originalUri: U,
    newFileName: String,
    readName: (U) -> String?,
    expectedFileName: String? = null,
    rename: (U, String) -> U?,
): Map<String, Any?> {
    var currentUri = originalUri
    var currentName: String? = null
    var originalName: String? = null
    var renamed = false
    try {
        require(newFileName.isNotBlank() && !newFileName.contains('/') &&
            !newFileName.contains('\\') && !newFileName.contains('\u0000')) { "文件名不合法" }
        originalName = readName(originalUri)?.takeIf { it.isNotEmpty() }
            ?: throw IllegalStateException("无法确认原文件名，本次未改名")
        currentName = originalName
        check(expectedFileName == null || originalName == expectedFileName) {
            "源文件名已变化，请重新扫描后重试"
        }
        currentUri = rename(originalUri, newFileName)
            ?: throw UnsupportedOperationException("文件提供方拒绝重命名")
        renamed = true
        currentName = null
        currentName = readName(currentUri)
        check(currentName == newFileName) { "文件提供方未确认指定文件名" }
        return mapOf("renamed" to true, "fileUri" to currentUri.toString(), "fileName" to currentName)
    } catch (error: Exception) {
        var rollbackError: String? = null
        if (renamed && originalName != null) {
            try {
                currentUri = rename(currentUri, originalName)
                    ?: throw IllegalStateException("文件提供方拒绝恢复原文件名")
                currentName = null
                currentName = readName(currentUri)
                check(currentName == originalName) { "无法确认恢复后的文件名" }
            } catch (rollback: Exception) {
                rollbackError = rollback.message ?: "恢复原文件名失败"
            }
        }
        val code = when (error) {
            is SecurityException -> "permission"
            is UnsupportedOperationException -> "unsupported"
            else -> "rename_failed"
        }
        return mapOf(
            "renamed" to false,
            "code" to code,
            "message" to ((error.message ?: "文件改名失败") +
                (rollbackError?.let { "；回滚未完成：$it" } ?: "")),
            "fileUri" to currentUri.toString(),
            "fileName" to currentName,
        )
    }
}
