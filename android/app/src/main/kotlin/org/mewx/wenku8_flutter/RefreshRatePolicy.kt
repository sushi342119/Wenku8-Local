package org.mewx.wenku8_flutter

/** Resolution-preserving selection, without assuming a particular panel rate. */
internal object RefreshRatePolicy {
    data class Mode(val id: Int, val width: Int, val height: Int, val rate: Float)
    data class Preference(val modeId: Int, val rate: Float)

    fun select(sdk: Int, current: Mode, modes: List<Mode>): Preference? {
        val fastest = modes.asSequence()
            .filter { it.width == current.width && it.height == current.height }
            .filter { it.rate.isFinite() && it.rate > 0f }
            .maxWithOrNull(compareBy<Mode> { it.rate }.thenBy { it.id == current.id })
            ?: return null
        // Before API 34 a rate-only window preference applies to the DEFAULT
        // resolution, which need not be the resolution the user has selected.
        return Preference(if (sdk >= 34) 0 else fastest.id, fastest.rate)
    }
}

/** One vote per live surface/rate, not one vote per layout or rendered frame. */
internal class SurfaceRateVote {
    private var applied: Float? = null
    fun apply(rate: Float, valid: Boolean, submit: (Float) -> Unit): Boolean {
        if (!valid) { applied = null; return false }
        if (applied == rate) return false
        submit(rate)
        applied = rate
        return true
    }
    fun invalidate() { applied = null }
}
