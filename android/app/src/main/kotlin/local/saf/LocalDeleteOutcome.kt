package local.saf

import java.io.FileNotFoundException
import java.io.IOException

/**
 * SAF 删除结果的保守映射：通用 SAF 接口不能仅凭 FileNotFoundException
 * 证明文件不存在，因此该异常返回“无法确认 / io_error”，保留本地记录；
 * 用户可选择“仅移出书库”，不再伪造 notFound:true。
 */
fun localDeleteOutcome(
    deleteDocument: () -> Boolean
): Map<String, Any?> {
    fun failure(
        code: String,
        outcome: String = "failed"
    ): Map<String, Any?> = mapOf(
        "deleted" to false,
        "outcome" to outcome,
        "code" to code,
        "message" to "无法完成文件操作，请重试"
    )

    return try {
        if (deleteDocument()) {
            mapOf(
                "deleted" to true,
                "outcome" to "deleted"
            )
        } else {
            failure("delete_rejected")
        }
    } catch (e: FileNotFoundException) {
        failure(
            code = "io_error",
            outcome = "unconfirmed"
        )
    } catch (e: SecurityException) {
        failure("permission")
    } catch (e: UnsupportedOperationException) {
        failure("unsupported")
    } catch (e: IllegalArgumentException) {
        failure("invalid_uri")
    } catch (e: IOException) {
        failure("io_error", outcome = "unconfirmed")
    } catch (e: Exception) {
        failure("unknown")
    }
}
