package com.tvrain.barometer_flutter

import android.os.BatteryManager
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Host tests of the adapters' pure rules, with synthetic values only. */
class AdapterTest {
    private fun assertUnavailable(block: () -> Unit) {
        try {
            block()
            fail("expected an error")
        } catch (e: AdapterUnavailableException) {
            assertEquals("adapter unavailable", e.message)
        }
    }

    @Test
    fun clockIsTrustedOnlyWithAutomaticTime() {
        assertEquals(1_700_000_000_000L, AndroidClock.trusted(1, 1_700_000_000_000L))
        assertUnavailable { AndroidClock.trusted(0, 1_700_000_000_000L) }
        assertUnavailable { AndroidClock.trusted(1, 0) }
        assertUnavailable { AndroidClock.trusted(1, -5) }
        assertUnavailable { AndroidClock({ throw SecurityException("synthetic") }, { 1L }).nowUnixMillis() }
    }

    @Test
    fun consentIsAbsent() {
        assertEquals("absent", AndroidConsent().status())
    }

    @Test
    fun batteryMapsToCoarseKnownValues() {
        assertEquals(BatterySnapshot(80, true, true, true),
            AndroidDevice.snapshot(80, 100, BatteryManager.BATTERY_STATUS_CHARGING))
        assertEquals(BatterySnapshot(50, true, false, true),
            AndroidDevice.snapshot(100, 200, BatteryManager.BATTERY_STATUS_DISCHARGING))
        assertEquals(BatterySnapshot(100, true, true, true),
            AndroidDevice.snapshot(100, 100, BatteryManager.BATTERY_STATUS_FULL))
        assertEquals(BatterySnapshot(0, false, false, false),
            AndroidDevice.snapshot(-1, -1, BatteryManager.BATTERY_STATUS_UNKNOWN))
        assertEquals(BatterySnapshot(0, false, false, true),
            AndroidDevice.snapshot(120, 100, BatteryManager.BATTERY_STATUS_NOT_CHARGING))
    }

    @Test
    fun ipv6IsCanonical() {
        fun v6(text: String) = AndroidResolver.canonicalIPv6(InetAddress.getByName(text).address)
        assertEquals("2001:db8::1", v6("2001:0db8:0:0:0:0:0:1"))
        assertEquals("2001:db8:0:1:1:1:1:1", v6("2001:db8:0:1:1:1:1:1"))
        assertEquals("2001:db8::1:0:0:1", v6("2001:db8:0:0:1:0:0:1"))
        assertEquals("::", v6("::"))
        assertEquals("::1", v6("::1"))
        assertEquals("fe80::", v6("fe80:0:0:0:0:0:0:0"))
        assertEquals("2001:db8:aaaa:bbbb:cccc:dddd:eeee:1", v6("2001:db8:aaaa:bbbb:cccc:dddd:eeee:0001"))
    }

    private val answer = arrayOf(
        InetAddress.getByAddress("example.test", byteArrayOf(192.toByte(), 0, 2, 7)),
        InetAddress.getByAddress("example.test", InetAddress.getByName("2001:db8::7").address),
    )

    @Test
    fun resolverFiltersByFamilyAndStripsTheRootDot() {
        val names = mutableListOf<String>()
        val r = AndroidResolver({ names.add(it); answer })
        assertEquals(listOf("192.0.2.7", "2001:db8::7"), r.lookupNetIP("ip", "example.test.", 1000))
        assertEquals(listOf("192.0.2.7"), r.lookupNetIP("ip4", "example.test.", 1000))
        assertEquals(listOf("2001:db8::7"), r.lookupNetIP("ip6", "example.test.", 1000))
        assertEquals(listOf("example.test", "example.test", "example.test"), names)
        val v4only = AndroidResolver({ arrayOf(answer[0]) })
        assertEquals(emptyList<String>(), v4only.lookupNetIP("ip6", "example.test.", 1000))
    }

    @Test
    fun resolverFailuresAreErrors() {
        val r = AndroidResolver({ throw UnknownHostException("synthetic") })
        assertUnavailable { r.lookupNetIP("ip4", "example.test.", 1000) }
        val ok = AndroidResolver({ answer })
        assertUnavailable { ok.lookupNetIP("tcp", "example.test.", 1000) }
        assertUnavailable { ok.lookupNetIP("ip", ".", 1000) }
        assertUnavailable { ok.lookupNetIP("ip", "192.0.2.7", 1000) }
        assertUnavailable { ok.lookupNetIP("ip", "2001:db8::7", 1000) }
        assertUnavailable { ok.lookupNetIP("ip", "example.test.", 0) }
    }

    @Test
    fun resolverStopsWaitingAtTheDeadline() {
        val release = CountDownLatch(1)
        val r = AndroidResolver({ release.await(); answer })
        val start = System.nanoTime()
        assertUnavailable { r.lookupNetIP("ip", "example.test.", 100) }
        val tookMillis = (System.nanoTime() - start) / 1_000_000
        release.countDown()
        assertTrue("waited $tookMillis ms", tookMillis in 90..1000)
    }
}
