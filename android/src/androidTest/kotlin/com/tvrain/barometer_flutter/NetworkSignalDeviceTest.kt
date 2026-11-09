package com.tvrain.barometer_flutter

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The VPN, validation, captive-portal and suspension signals of [AndroidNetwork] while the
 * emulator's state changes: a test VPN up and down, airplane mode, Wi-Fi off and on, and device
 * idle (Doze) forced through `dumpsys deviceidle`. Every change must advance the generation and
 * fire a pending watch, and every value must stay one of the fixed ones.
 *
 * These tests change the emulator's connectivity and power state through the shell and restore
 * it afterwards; run them on emulators only. They contact no network themselves.
 */
@RunWith(AndroidJUnit4::class)
class NetworkSignalDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var network: AndroidNetwork
    private val airplaneByHost = InstrumentationRegistry.getArguments().getString("airplaneByHost") == "true"

    @Before
    fun setUp() {
        network = AndroidNetwork(context)
    }

    @After
    fun tearDown() {
        network.close()
    }

    private fun assertFixed(s: AccessSnapshot) {
        assertTrue(s.networkType, s.networkType in setOf("wifi", "cellular", "ethernet", "other", "unknown"))
        assertTrue(s.vpn, s.vpn in setOf("detected", "not_detected", "unknown"))
        for (v in listOf(s.ipv4, s.ipv6, s.validated, s.captivePortal)) assertTrue(v, v in YES_NO_UNKNOWN)
        assertTrue(s.suspended, s.suspended in setOf("suspended", "active", "unknown"))
    }

    /** Registers a watch on the current generation; the latch opens when it fires. */
    private fun watchCurrent(): Pair<Long, CountDownLatch> {
        val gen = network.access().generation
        val latch = CountDownLatch(1)
        network.watch(gen) { latch.countDown() }
        return gen to latch
    }

    /** Waits until [condition] holds for the current reading and returns it. */
    private fun awaitAccess(what: String, seconds: Long = 30, condition: (AccessSnapshot) -> Boolean): AccessSnapshot {
        var last = network.access()
        assertTrue("$what: $last", DeviceShell.await(seconds) {
            last = network.access()
            assertFixed(last)
            condition(last)
        })
        return last
    }

    @Test
    fun signalsAtRestFollowTheApiLevel() {
        val s = awaitAccess("connected") { it.networkType != "unknown" }
        assertFixed(s)
        assertEquals("not_detected", s.vpn)
        if (Build.VERSION.SDK_INT >= 23) {
            assertEquals("yes", s.validated)
            assertEquals("no", s.captivePortal)
            assertEquals("active", awaitAccess("not suspended") { it.suspended != "unknown" }.suspended)
        } else {
            assertEquals("unknown", s.validated)
            assertEquals("unknown", s.captivePortal)
            assertEquals("unknown", s.suspended)
        }
    }

    @Test
    fun vpnUpAndDownAdvancesTheGeneration() {
        grantVpn()
        assertNull("VPN permission not granted", VpnService.prepare(context))
        awaitAccess("connected") { it.networkType != "unknown" && it.vpn == "not_detected" }
        val (before, latch) = watchCurrent()
        var restore: Pair<Long, CountDownLatch>? = null
        try {
            context.startService(Intent(context, TestVpnService::class.java))
            // API 21 remembers the consent by package name, so after a reinstall, which changes
            // the test application's user ID, it reports the permission granted but refuses to
            // establish the VPN until the emulator restarts.
            assertTrue("VPN was not established", DeviceShell.await(10) { TestVpnService.tunnel != null })
            // Before API 23 a VPN that may not apply to this application is unknown.
            val expected = if (Build.VERSION.SDK_INT >= 23) setOf("detected") else setOf("detected", "unknown")
            val up = awaitAccess("VPN detected") { it.vpn in expected }
            assertTrue(up.generation > before)
            assertTrue("watch did not fire", latch.await(5, TimeUnit.SECONDS))
            restore = watchCurrent()
        } finally {
            context.startService(Intent(context, TestVpnService::class.java).setAction(TestVpnService.ACTION_STOP))
        }
        val (upGen, downLatch) = restore!!
        val down = awaitAccess("VPN gone") { it.vpn == "not_detected" }
        assertTrue(down.generation > upGen)
        assertTrue("watch did not fire", downLatch.await(5, TimeUnit.SECONDS))
    }

    @Test
    fun airplaneModeRemovesTheNetworkAndRestoresIt() {
        assumeTrue(
            "before API 30 the instrumentation cannot switch airplane mode; " +
                "scripts/android-airplane-check.sh switches it from the host",
            Build.VERSION.SDK_INT >= 30 || airplaneByHost,
        )
        val connected = awaitAccess("connected") { it.networkType != "unknown" }
        val (before, latch) = watchCurrent()
        var restore: Pair<Long, CountDownLatch>? = null
        try {
            airplaneMode(true)
            val off = awaitAccess("no network", 60) { it.networkType == "unknown" }
            assertTrue(off.generation > before)
            assertEquals("unknown", off.vpn)
            assertEquals("no", off.ipv4)
            assertTrue("watch did not fire", latch.await(5, TimeUnit.SECONDS))
            restore = watchCurrent()
        } finally {
            airplaneMode(false)
        }
        val (offGen, onLatch) = restore!!
        val on = awaitAccess("network back", 90) { it.networkType == connected.networkType && it.ipv4 == connected.ipv4 }
        assertTrue(on.generation > offGen)
        assertTrue("watch did not fire", onLatch.await(5, TimeUnit.SECONDS))
    }

    @Test
    fun wifiOffAndOnChangesTheDefaultNetwork() {
        val connected = awaitAccess("connected") { it.networkType != "unknown" }
        assumeTrue("the default network is not Wi-Fi in this image", connected.networkType == "wifi")
        val (before, latch) = watchCurrent()
        var restore: Pair<Long, CountDownLatch>? = null
        try {
            DeviceShell.run("svc wifi disable")
            val off = awaitAccess("Wi-Fi gone") { it.networkType != "wifi" }
            assertTrue(off.generation > before)
            assertTrue("watch did not fire", latch.await(5, TimeUnit.SECONDS))
            restore = watchCurrent()
        } finally {
            DeviceShell.run("svc wifi enable")
        }
        val (offGen, onLatch) = restore!!
        val on = awaitAccess("Wi-Fi back", 60) { it.networkType == "wifi" && it.validated == "yes" }
        assertTrue(on.generation > offGen)
        assertTrue("watch did not fire", onLatch.await(5, TimeUnit.SECONDS))
    }

    @Test
    fun deviceIdleIsSuspension() {
        assumeTrue("device idle exists from API 23", Build.VERSION.SDK_INT >= 23)
        awaitAccess("active") { it.suspended == "active" }
        // Emulator images ship with deep idle disabled; it is enabled for the test and restored.
        val mode = if (Build.VERSION.SDK_INT >= 24) " deep" else ""
        val wasEnabled = DeviceShell.run("dumpsys deviceidle enabled$mode").trim() == "1"
        val (before, latch) = watchCurrent()
        var restore: Pair<Long, CountDownLatch>? = null
        try {
            DeviceShell.run("dumpsys battery unplug")
            DeviceShell.run("dumpsys deviceidle enable$mode")
            DeviceShell.run("dumpsys deviceidle force-idle")
            val idle = awaitAccess("suspended") { it.suspended == "suspended" }
            assertTrue(idle.generation > before)
            assertTrue("watch did not fire", latch.await(5, TimeUnit.SECONDS))
            restore = watchCurrent()
        } finally {
            DeviceShell.run("dumpsys deviceidle unforce")
            if (!wasEnabled) DeviceShell.run("dumpsys deviceidle disable$mode")
            DeviceShell.run("dumpsys battery reset")
        }
        val (idleGen, activeLatch) = restore!!
        val active = awaitAccess("active again", 60) { it.suspended == "active" }
        assertTrue(active.generation > idleGen)
        assertTrue("watch did not fire", activeLatch.await(5, TimeUnit.SECONDS))
    }

    /**
     * Grants this application the VPN permission: through `appops` from API 22, and on API 21,
     * which has no such operation, by confirming the system's VPN dialog, opened by
     * [VpnConsentActivity], through UiAutomation.
     */
    private fun grantVpn() {
        if (Build.VERSION.SDK_INT >= 22) {
            DeviceShell.run("appops set ${context.packageName} ACTIVATE_VPN allow")
            return
        }
        if (VpnService.prepare(context) == null) return
        context.startActivity(Intent(context, VpnConsentActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        fun click(id: String): Boolean {
            val node = automation.rootInActiveWindow?.findAccessibilityNodeInfosByViewId(id)?.firstOrNull()
            return node != null && node.isEnabled && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        }
        assertTrue("VPN dialog not confirmed", DeviceShell.await(10) { click("android:id/button1") })
        DeviceShell.await(10) { VpnService.prepare(context) == null }
    }

    /**
     * Switches airplane mode through the shell from API 30. With the instrumentation argument
     * `airplaneByHost`, `scripts/android-airplane-check.sh` switches it instead and this does
     * nothing.
     */
    private fun airplaneMode(on: Boolean) {
        if (airplaneByHost) return
        DeviceShell.run("cmd connectivity airplane-mode ${if (on) "enable" else "disable"}")
    }

    companion object {
        private val YES_NO_UNKNOWN = setOf("yes", "no", "unknown")
    }
}
