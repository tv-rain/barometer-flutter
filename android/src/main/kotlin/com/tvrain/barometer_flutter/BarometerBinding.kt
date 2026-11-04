package com.tvrain.barometer_flutter

import android.content.Context
import barometermobile.AccessState
import barometermobile.Adapters
import barometermobile.Barometermobile
import barometermobile.Client
import barometermobile.Clock
import barometermobile.Consent
import barometermobile.Device
import barometermobile.DeviceState
import barometermobile.Network
import barometermobile.NetworkObserver
import barometermobile.RecordValue
import barometermobile.Records
import barometermobile.StringList
import barometermobile.SystemResolver
import barometermobile.TimeZone
import java.io.Closeable

/**
 * The only file that names gomobile-generated classes: the `barometermobile` facade.
 *
 * The classes come from the standalone `Barometer.aar` or, in an umbrella build, from the
 * umbrella artifact. Naming a class at compile time neither loads the native library nor
 * runs Go code; constructing a facade value does.
 */
internal object BarometerBinding {
    val clientClass: Class<*> = barometermobile.Client::class.java

    /** The facade `Records` callback backed by [store]. */
    fun records(store: RecordStore): Records = StoreRecords(store)

    /**
     * Creates a facade client with the Android adapters over [store] and the trusted local
     * document [trust], which must come from [TrustDocument]. It registers the network
     * callback and performs no other work; nothing is measured until the lifecycle calls.
     * The linkage key store is not installed, so linkage is disabled.
     */
    fun newClient(context: Context, store: RecordStore, trust: ByteArray): BarometerClient {
        val app = context.applicationContext
        val network = AndroidNetwork(app)
        try {
            val adapters = Adapters().apply {
                records = StoreRecords(store)
                clock = ClockCallback(AndroidClock(app.contentResolver))
                setNetwork(NetworkCallback(network))
                consent = ConsentCallback(AndroidConsent())
                device = DeviceCallback(AndroidDevice(app))
                timeZone = TimeZoneCallback(AndroidTimeZone())
                resolver = ResolverCallback(AndroidResolver())
            }
            return BarometerClient(Barometermobile.newClient(adapters, trust), network)
        } catch (e: Exception) {
            network.close()
            throw e
        }
    }
}

/**
 * A facade client and the adapter resources it owns. [close] closes the client, then removes
 * the network callback; close the record store after this.
 */
internal class BarometerClient(val facade: Client, private val network: AndroidNetwork) : Closeable {
    override fun close() {
        try {
            facade.close()
        } finally {
            network.close()
        }
    }
}

/**
 * Adapts [RecordStore] to the facade callback. Every failure surfaces as the store's
 * detail-free exception, which the facade reports as unavailable.
 */
private class StoreRecords(private val store: RecordStore) : Records {
    override fun get(key: String, timeoutMillis: Long): RecordValue? =
        store.get(key, timeoutMillis)?.let { Barometermobile.newRecordValue(it) }

    override fun put(key: String, value: ByteArray?, timeoutMillis: Long) =
        store.put(key, value ?: ByteArray(0), timeoutMillis)

    override fun delete(key: String, timeoutMillis: Long) = store.delete(key, timeoutMillis)

    override fun list(cls: Long, timeoutMillis: Long): StringList {
        val keys = store.list(cls, timeoutMillis)
        val list = Barometermobile.newStringList()
        keys.forEach { list.add(it) }
        return list
    }
}

private class ClockCallback(private val clock: AndroidClock) : Clock {
    override fun nowUnixMillis(timeoutMillis: Long): Long = clock.nowUnixMillis()
}

private class ConsentCallback(private val consent: AndroidConsent) : Consent {
    override fun status(timeoutMillis: Long): String = consent.status()
}

private class DeviceCallback(private val device: AndroidDevice) : Device {
    override fun state(timeoutMillis: Long): DeviceState {
        val s = device.state()
        return Barometermobile.newDeviceState(s.percent, s.percentKnown, s.charging, s.chargingKnown)
    }
}

private class TimeZoneCallback(private val zone: AndroidTimeZone) : TimeZone {
    override fun identifier(timeoutMillis: Long): String = zone.identifier()
}

private class ResolverCallback(private val resolver: AndroidResolver) : SystemResolver {
    override fun lookupNetIP(network: String, host: String, timeoutMillis: Long): StringList {
        val list = Barometermobile.newStringList()
        resolver.lookupNetIP(network, host, timeoutMillis).forEach { list.add(it) }
        return list
    }
}

private class NetworkCallback(private val network: AndroidNetwork) : Network {
    override fun access(timeoutMillis: Long): AccessState {
        val s = network.access()
        return Barometermobile.newAccessState(
            s.generation, s.networkType, s.vpn, s.ipv4, s.ipv6, s.validated, s.captivePortal,
        )
    }

    override fun watch(generation: Long, observer: NetworkObserver): Long =
        network.watch(generation) { observer.changed() }

    override fun stopWatch(watchID: Long) = network.stopWatch(watchID)
}
