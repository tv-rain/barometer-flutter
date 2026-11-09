package com.tvrain.barometer_flutter

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor

/**
 * Test-only VPN for the network-signal tests. It routes only a reserved synthetic prefix for
 * this application, so other traffic keeps its path, and never reads the interface. The test
 * grants the VPN permission through the emulator shell (`appops set <package> ACTIVATE_VPN
 * allow`), so no consent dialog appears.
 */
class TestVpnService : VpnService() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stop()
            stopSelf()
            return START_NOT_STICKY
        }
        if (tunnel == null) {
            tunnel = Builder()
                .setSession("barometer-test")
                .addAddress("198.18.0.1", 32)
                .addRoute("198.18.0.0", 24)
                .addAllowedApplication(packageName)
                .establish()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stop()
        super.onDestroy()
    }

    override fun onRevoke() {
        stop()
        super.onRevoke()
    }

    private fun stop() {
        runCatching { tunnel?.close() }
        tunnel = null
    }

    companion object {
        const val ACTION_STOP = "com.tvrain.barometer_flutter.STOP_TEST_VPN"

        @Volatile
        var tunnel: ParcelFileDescriptor? = null
    }
}
