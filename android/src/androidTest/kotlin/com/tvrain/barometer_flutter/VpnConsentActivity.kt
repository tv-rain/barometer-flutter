package com.tvrain.barometer_flutter

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle

/**
 * Test-only activity that asks for the VPN permission with the system dialog, which accepts
 * only a request from an activity. API 21 has no shell command that grants it.
 */
class VpnConsentActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val request = VpnService.prepare(this)
        if (request == null) finish() else startActivityForResult(request, 1)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        finish()
    }
}
