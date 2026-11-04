package com.tvrain.barometer_flutter

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.provider.Settings

/**
 * Reported for every adapter failure. Like [RecordStoreException] it carries no detail: the
 * facade maps any native error to "unavailable" or "unsatisfied", and its text never crosses.
 */
internal class AdapterUnavailableException : Exception("adapter unavailable")

/**
 * Trusted wall-clock time for the facade's `Clock` port.
 *
 * Android has no trusted wall-clock API before API 33, so the wall clock counts as trusted
 * only while automatic time (`Settings.Global.AUTO_TIME`) is on, meaning the platform sets it
 * from the network. With manual time, an unreadable setting or a time that is not positive
 * the clock is unavailable; there is no fallback.
 */
internal class AndroidClock(
    private val autoTime: () -> Int,
    private val wallClock: () -> Long = System::currentTimeMillis,
) {
    constructor(resolver: ContentResolver) : this({
        Settings.Global.getInt(resolver, Settings.Global.AUTO_TIME, 0)
    })

    fun nowUnixMillis(): Long = trusted(runCatching(autoTime).getOrDefault(0), wallClock())

    companion object {
        fun trusted(autoTime: Int, now: Long): Long {
            if (autoTime != 1 || now <= 0) throw AdapterUnavailableException()
            return now
        }
    }
}

/**
 * Consent status for the facade's `Consent` port. No host consent source exists yet, so the
 * status is always `absent`: a measurement that requires consent never runs. The query carries
 * no task value and the answer no user, account, device or consent-record identifier.
 */
internal class AndroidConsent {
    fun status(): String = ABSENT

    companion object {
        const val ABSENT = "absent"
    }
}

/** Coarse battery and charging state, each with a known flag. */
internal data class BatterySnapshot(
    val percent: Long,
    val percentKnown: Boolean,
    val charging: Boolean,
    val chargingKnown: Boolean,
)

/**
 * Coarse battery and charging state for the facade's `Device` port, read from the sticky
 * `ACTION_BATTERY_CHANGED` broadcast. Only the level, scale and status extras are read.
 */
internal class AndroidDevice(private val context: Context) {
    fun state(): BatterySnapshot {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: return UNKNOWN
        return snapshot(
            intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1),
            intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1),
            intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1),
        )
    }

    companion object {
        private val UNKNOWN = BatterySnapshot(0, false, false, false)

        fun snapshot(level: Int, scale: Int, status: Int): BatterySnapshot {
            val percentKnown = level in 0..scale && scale > 0
            val percent = if (percentKnown) level * 100L / scale else 0L
            val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL
            val chargingKnown = charging ||
                status == BatteryManager.BATTERY_STATUS_DISCHARGING ||
                status == BatteryManager.BATTERY_STATUS_NOT_CHARGING
            return BatterySnapshot(percent, percentKnown, charging, chargingKnown)
        }
    }
}

/** The device's IANA time-zone identifier for the facade's `TimeZone` port. */
internal class AndroidTimeZone {
    fun identifier(): String {
        val id = java.util.TimeZone.getDefault().id
        if (id.isNullOrEmpty()) throw AdapterUnavailableException()
        return id
    }
}
