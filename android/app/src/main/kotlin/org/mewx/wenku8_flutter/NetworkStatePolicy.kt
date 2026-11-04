package org.mewx.wenku8_flutter

internal object NetworkStatePolicy {
    fun classify(internet: Boolean?, validated: Boolean, blocked: Boolean = false): String = when {
        blocked -> "offline"
        internet == null -> "checking"
        !internet -> "offline"
        validated -> "online"
        else -> "checking"
    }
}
