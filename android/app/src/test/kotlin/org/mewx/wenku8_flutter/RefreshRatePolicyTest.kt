package org.mewx.wenku8_flutter

import org.junit.Assert.*
import org.junit.Test

class RefreshRatePolicyTest {
    private fun mode(id: Int, rate: Float, width: Int = 1080, height: Int = 2400) =
        RefreshRatePolicy.Mode(id, width, height, rate)

    @Test fun selectsTheDeviceMaximumWithoutAssuming120() {
        for (max in listOf(60f, 90f, 120f, 144f, 165f)) {
            val p = RefreshRatePolicy.select(36, mode(1, 60f), listOf(mode(1, 60f), mode(2, max)))!!
            assertEquals(max, p.rate, 0f)
            assertEquals(0, p.modeId)
        }
    }

    @Test fun neverChangesResolutionToGetAHigherRate() {
        val p = RefreshRatePolicy.select(33, mode(1, 60f),
            listOf(mode(1, 60f), mode(2, 90f), mode(3, 144f, 1440, 3200)))!!
        assertEquals(2, p.modeId)
        assertEquals(90f, p.rate, 0f)
    }

    @Test fun legacyUsesSameSizeModeAndModernUsesRateOnly() {
        for (sdk in listOf(24, 29, 30, 31, 33, 34, 35, 36)) {
            val p = RefreshRatePolicy.select(sdk, mode(1, 60f), listOf(mode(1, 60f), mode(2, 119.88f)))!!
            assertEquals(if (sdk < 34) 2 else 0, p.modeId)
            assertEquals(119.88f, p.rate, 0f)
        }
    }

    @Test fun tiesKeepCurrentModeAndMalformedRatesAreIgnored() {
        val current = mode(2, 90f)
        assertEquals(2, RefreshRatePolicy.select(29, current,
            listOf(mode(3, 90f), current, mode(4, Float.NaN), mode(5, Float.POSITIVE_INFINITY), mode(6, -1f)))!!.modeId)
        assertNull(RefreshRatePolicy.select(36, current, emptyList()))
    }

    @Test fun repeatedLayoutsDoNotResubmitTheVote() {
        val vote = SurfaceRateVote()
        val submitted = mutableListOf<Float>()
        repeat(100) { vote.apply(120f, true) { submitted.add(it) } }
        vote.apply(90f, true) { submitted.add(it) }
        assertEquals(listOf(120f, 90f), submitted)
    }

    @Test fun recreationAndResumeReceiveFreshVotes() {
        val vote = SurfaceRateVote()
        val submitted = mutableListOf<Float>()
        vote.apply(120f, false) { submitted.add(it) }
        assertTrue(submitted.isEmpty())
        vote.apply(120f, true) { submitted.add(it) }
        vote.invalidate()
        vote.apply(120f, true) { submitted.add(it) }
        vote.apply(0f, true) { submitted.add(it) }
        vote.apply(120f, true) { submitted.add(it) }
        assertEquals(listOf(120f, 120f, 0f, 120f), submitted)
    }

    @Test fun failedSubmissionCanRetryOnNextLifecycleEvent() {
        val vote = SurfaceRateVote()
        try { vote.apply(120f, true) { throw IllegalStateException() } } catch (_: IllegalStateException) { }
        val submitted = mutableListOf<Float>()
        assertTrue(vote.apply(120f, true) { submitted.add(it) })
        assertEquals(listOf(120f), submitted)
    }
}
