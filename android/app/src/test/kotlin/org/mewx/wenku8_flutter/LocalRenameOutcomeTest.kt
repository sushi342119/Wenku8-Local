package org.mewx.wenku8_flutter

import local.saf.localRenameOutcome
import org.junit.Assert.*
import org.junit.Test

class LocalRenameOutcomeTest {
    @Test fun exactNameAndChangedUriAreConfirmed() {
        var name = "书.txt"
        val result = localRenameOutcome("old", "书 ✦古风.txt", { name }) { _, next ->
            name = next
            "new"
        }
        assertEquals(true, result["renamed"])
        assertEquals("new", result["fileUri"])
        assertEquals("书 ✦古风.txt", result["fileName"])
    }

    @Test fun deniedRenameLeavesOldName() {
        val result = localRenameOutcome("old", "书 ✦古风.txt", { "书.txt" }) { _, _ ->
            throw SecurityException("只读")
        }
        assertEquals(false, result["renamed"])
        assertEquals("permission", result["code"])
        assertEquals("书.txt", result["fileName"])
    }

    @Test fun nullResultIsFailure() {
        val result = localRenameOutcome("old", "新.txt", { "书.txt" }) { _, _ -> null }
        assertEquals(false, result["renamed"])
        assertEquals("unsupported", result["code"])
    }

    @Test fun unknownOriginalNameDoesNotAttemptRename() {
        var calls = 0
        val result = localRenameOutcome("old", "新.txt", { null }) { _, _ -> calls++; "new" }
        assertEquals(0, calls)
        assertEquals(false, result["renamed"])
    }

    @Test fun providerAdjustedNameRollsBackAndReturnsRestoredUri() {
        var name = "书.txt"
        var calls = 0
        val result = localRenameOutcome("old", "书 ✦古风.txt", { name }) { _, next ->
            calls++
            name = if (calls == 1) "被提供方改写.txt" else next
            "uri-$calls"
        }
        assertEquals(2, calls)
        assertEquals("书.txt", name)
        assertEquals(false, result["renamed"])
        assertEquals("uri-2", result["fileUri"])
        assertEquals("书.txt", result["fileName"])
    }

    @Test fun failedConfirmationRollsBack() {
        var calls = 0
        var name = "书.txt"
        val result = localRenameOutcome("old", "新.txt", {
            if (calls == 1) throw IllegalStateException("查询失败")
            name
        }) { _, next -> calls++; name = next; "uri-$calls" }
        assertEquals(false, result["renamed"])
        assertEquals("书.txt", name)
        assertEquals("uri-2", result["fileUri"])
    }

    @Test fun staleCachedNameCannotOverwriteExternalFilenameTags() {
        var calls = 0
        val result = localRenameOutcome("old", "书 ✦旧标签.txt", { "书 ✦外部标签.txt" }, "书.txt") { _, _ ->
            calls++
            "new"
        }
        assertEquals(0, calls)
        assertEquals(false, result["renamed"])
        assertEquals("书 ✦外部标签.txt", result["fileName"])
    }

    @Test fun failedRollbackIsExplicitAndKeepsKnownActualLocation() {
        var calls = 0
        var name = "书.txt"
        val result = localRenameOutcome("old", "新.txt", { name }) { _, _ ->
            calls++
            if (calls == 2) throw SecurityException("拒绝回滚")
            name = "错误.txt"
            "new"
        }
        assertEquals(false, result["renamed"])
        assertEquals("new", result["fileUri"])
        assertEquals("错误.txt", result["fileName"])
        assertTrue(result["message"].toString().contains("回滚未完成"))
    }
}
