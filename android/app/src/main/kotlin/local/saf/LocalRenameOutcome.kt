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
    var attempted = false
    try {
        require(newFileName.isNotBlank() && !newFileName.contains('/') &&
            !newFileName.contains('\\') && !newFileName.contains('\u0000')) { "文件名不合法" }
        originalName = readName(originalUri)?.takeIf { it.isNotEmpty() }
            ?: throw IllegalStateException("无法确认原文件名，本次未改名")
        currentName = originalName
        check(expectedFileName == null || originalName == expectedFileName) {
            "源文件名已变化，请重新扫描后重试"
        }
        attempted = true
        currentUri = rename(originalUri, newFileName)
            ?: throw UnsupportedOperationException("文件提供方拒绝重命名")
        renamed = true
        currentName = null
        currentName = readName(currentUri)
        check(currentName == newFileName) { "文件提供方未确认指定文件名" }
        return mapOf("renamed" to true, "fileUri" to currentUri.toString(), "fileName" to currentName)
    } catch (error: Exception) {
        var rollbackFailed = false
        if (attempted && !renamed) {
            currentName = try { readName(originalUri)?.takeIf { it.isNotBlank() } } catch (_: Exception) { null }
            if (currentName == null) {
                return mapOf("renamed" to false, "code" to "unconfirmed",
                    "message" to "无法确认改名结果，请重新扫描原文件夹", "fileUri" to null, "fileName" to null)
            }
            renamed = currentName != originalName
        }
        if (renamed && originalName != null) {
            try {
                currentUri = rename(currentUri, originalName)
                    ?: throw IllegalStateException("文件提供方拒绝恢复原文件名")
                currentName = null
                currentName = readName(currentUri)
                check(currentName == originalName) { "无法确认恢复后的文件名" }
            } catch (rollback: Exception) {
                rollbackFailed = true
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
            "message" to if (rollbackFailed) {
                "文件改名失败；回滚未完成，请重新扫描原文件夹"
            } else {
                "文件改名失败，请重试"
            },
            "fileUri" to currentUri.toString(),
            "fileName" to currentName,
        )
    }
}
