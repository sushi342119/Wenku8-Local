package org.mewx.wenku8_flutter

/** consume() is the Dart-ready handshake. A warm callback claims the request
 * before delivery, so an overlapping startup consume cannot open it twice. */
internal class ReadingWidgetOpenInbox {
    private var pending: String? = null
    private var ready = false
    private var ticket = 0L

    fun offer(destination: String?, notify: Boolean, deliver: (String, (Boolean) -> Unit) -> Unit): Boolean {
        if (destination != "statistics" && destination != "moments" && destination != "continue" && destination != "excerpts" && destination?.matches(Regex("configure:[0-9]{1,10}")) != true) return false
        ticket += 1
        val offeredTicket = ticket
        pending = destination
        if (!notify || !ready) return true
        pending = null
        deliver(destination) { accepted ->
            if (!accepted && ticket == offeredTicket) {
                pending = destination
                ready = false
            }
        }
        return true
    }

    fun consume(): String? {
        ready = true
        val destination = pending
        pending = null
        return destination
    }

    fun pause() { ready = false }
}
