package org.mewx.wenku8_flutter

/** Exception classes and source coordinates only; never messages or arguments. */
internal fun nativeErrorDetails(error: Throwable): Map<String, Any> {
    val frames = error.stackTrace.asSequence().filter {
        it.className.startsWith("org.mewx.wenku8_flutter.") && it.lineNumber > 0 &&
            it.className.matches(Regex("[A-Za-z0-9_.$]+")) &&
            it.methodName.matches(Regex("[A-Za-z0-9_<>$]+")) &&
            it.fileName.orEmpty().matches(Regex("[A-Za-z0-9_]+\\.(kt|java)"))
    }.take(4).map { "android:${it.className}.${it.methodName}/${it.fileName}:${it.lineNumber}" }.toList()
    return buildMap {
        put("nativeType", error.javaClass.simpleName)
        error.cause?.let { put("nativeCause", it.javaClass.simpleName) }
        put("nativeTrace", frames)
    }
}
