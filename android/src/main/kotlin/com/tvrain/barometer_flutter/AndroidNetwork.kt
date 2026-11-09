package com.tvrain.barometer_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.PowerManager
import java.io.Closeable
import java.net.Inet4Address
import java.net.Inet6Address
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Coarse access state for the facade's `Network` port. Every field is one of the fixed values
 * the facade accepts; nothing here is an address, name, SSID, BSSID, operator, subscriber,
 * interface or other identifier.
 */
internal data class AccessSnapshot(
    val generation: Long,
    val networkType: String,
    val vpn: String,
    val ipv4: String,
    val ipv6: String,
    val validated: String,
    val captivePortal: String,
    val suspended: String,
)

/**
 * The Android `Network` adapter: coarse access state and access-network generation from
 * [ConnectivityManager] and [PowerManager], and a single-shot change watch.
 *
 * The generation starts at 1 and increases whenever the default network or any reported value
 * differs from the last one observed, either by a network callback, a device-idle broadcast or
 * [access]. Capability updates that leave every value unchanged, such as signal strength, do
 * not change it. Every value is read from the default network of this application:
 *
 * - VPN: `detected` when the default network has the VPN transport, otherwise `not_detected`.
 *   Before API 23 there is no per-application default network: a VPN is `detected` when the
 *   active network is one, `not_detected` when no VPN network exists and `unknown` otherwise.
 * - Validation and captive portal: the `VALIDATED` and `CAPTIVE_PORTAL` capabilities from
 *   API 23, `unknown` before.
 * - Suspension: `suspended` when the operating system stops the application's network work,
 *   which is device idle (Doze) from API 23, a default network without `NOT_SUSPENDED` from
 *   API 28 or one reported blocked for this application from API 29; `active` when every source
 *   of the API level says otherwise; `unknown` before API 23 and while the blocked status of
 *   the default network is not yet known. Backgrounding alone is not suspension.
 *
 * Without a default network the VPN, validation and captive-portal values are `unknown`.
 * The callback and receiver are registered on construction and removed by [close]; construct
 * it only when a client is created. Requires `ACCESS_NETWORK_STATE`.
 */
internal class AndroidNetwork(context: Context) : Closeable {
    private val app = context.applicationContext
    private val connectivity =
        app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
    private val lock = Any()
    private val dispatcher: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "barometer-network").apply { isDaemon = true }
    }
    private val watches = HashMap<Long, Watch>()
    private var nextWatchId = 0L
    private var generation = 1L
    private var last: Coarse? = null
    private var closed = false

    /** The blocked status reported for each network (API 29 and later); guarded by [lock]. */
    private val blocked = HashMap<Network, Boolean>()

    private class Watch(val generation: Long, val observer: () -> Unit) {
        val active = AtomicBoolean(true)
    }

    /** The default network and its coarse state; the network handle never leaves this class. */
    private data class Coarse(
        val network: Any?,
        val type: String,
        val ipv4: String,
        val ipv6: String,
        val vpn: String = UNKNOWN,
        val validated: String = UNKNOWN,
        val captivePortal: String = UNKNOWN,
        val suspended: String = UNKNOWN,
    )

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = refresh()
        override fun onLost(network: Network) {
            synchronized(lock) { blocked.remove(network) }
            refresh()
        }

        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = refresh()
        override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) = refresh()

        // API 29 and later.
        override fun onBlockedStatusChanged(network: Network, isBlocked: Boolean) {
            synchronized(lock) { blocked[network] = isBlocked }
            refresh()
        }
    }

    /** Device-idle changes (API 23 and later); the refresh runs on the adapter's own thread. */
    private val idleReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            try {
                dispatcher.execute { refresh() }
            } catch (e: RejectedExecutionException) {
            }
        }
    }

    init {
        if (Build.VERSION.SDK_INT >= 24) {
            connectivity.registerDefaultNetworkCallback(callback)
        } else {
            // A request excludes VPN networks unless NOT_VPN is removed.
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            connectivity.registerNetworkCallback(request, callback)
        }
        if (Build.VERSION.SDK_INT >= 23) {
            val filter = IntentFilter(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            if (Build.VERSION.SDK_INT >= 33) {
                app.registerReceiver(idleReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                app.registerReceiver(idleReceiver, filter)
            }
        }
        synchronized(lock) { last = coarse() }
    }

    /** Returns the current coarse access state. */
    fun access(): AccessSnapshot {
        val now = coarse()
        val gen = observe(now)
        return AccessSnapshot(
            gen, now.type, now.vpn, now.ipv4, now.ipv6, now.validated, now.captivePortal, now.suspended,
        )
    }

    /**
     * Registers a single-shot watch: [observer] runs once, on this adapter's own thread, when
     * the generation differs from [generation], at once if it already does. Returns promptly.
     */
    fun watch(generation: Long, observer: () -> Unit): Long {
        if (generation < 0) throw AdapterUnavailableException()
        val due: Watch?
        val id: Long
        synchronized(lock) {
            if (closed) throw AdapterUnavailableException()
            id = ++nextWatchId
            val w = Watch(generation, observer)
            if (generation != this.generation) {
                due = w
            } else {
                watches[id] = w
                due = null
            }
        }
        due?.let { dispatch(it) }
        return id
    }

    /** Stops a watch; its observer never runs afterwards. Never blocks. */
    fun stopWatch(id: Long) {
        synchronized(lock) { watches.remove(id) }?.active?.set(false)
    }

    /** Removes the network callback and stops every watch. */
    override fun close() {
        val stopped: List<Watch>
        synchronized(lock) {
            if (closed) return
            closed = true
            stopped = watches.values.toList()
            watches.clear()
        }
        stopped.forEach { it.active.set(false) }
        runCatching { connectivity.unregisterNetworkCallback(callback) }
        if (Build.VERSION.SDK_INT >= 23) runCatching { app.unregisterReceiver(idleReceiver) }
        dispatcher.shutdownNow()
    }

    private fun refresh() {
        runCatching { observe(coarse()) }
    }

    /** Records [now], advancing the generation and firing due watches if it changed. */
    private fun observe(now: Coarse): Long {
        val due: List<Watch>
        val gen: Long
        synchronized(lock) {
            if (now != last) {
                last = now
                generation++
            }
            gen = generation
            due = watches.filterValues { it.generation != gen }.keys.map { watches.remove(it)!! }
        }
        due.forEach { dispatch(it) }
        return gen
    }

    private fun dispatch(w: Watch) {
        try {
            dispatcher.execute { if (w.active.compareAndSet(true, false)) w.observer() }
        } catch (e: RejectedExecutionException) {
            w.active.set(false)
        }
    }

    private fun coarse(): Coarse {
        if (Build.VERSION.SDK_INT < 23) return coarseLegacy()
        val idle = power.isDeviceIdleMode
        val network = connectivity.activeNetwork
            ?: return Coarse(null, UNKNOWN, NO, NO, suspended = if (idle) SUSPENDED else ACTIVE)
        val caps = connectivity.getNetworkCapabilities(network)
        val lp = connectivity.getLinkProperties(network)
        val type = when {
            caps == null -> UNKNOWN
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> WIFI
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> CELLULAR
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> ETHERNET
            else -> OTHER
        }
        val vpn = when {
            caps == null -> UNKNOWN
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> DETECTED
            else -> NOT_DETECTED
        }
        val validated = caps?.let { yesNo(it.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) } ?: UNKNOWN
        val portal = caps?.let { yesNo(it.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL)) } ?: UNKNOWN
        val notSuspended = if (Build.VERSION.SDK_INT >= 28 && caps != null) {
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED)
        } else {
            true
        }
        val isBlocked = if (Build.VERSION.SDK_INT >= 29) synchronized(lock) { blocked[network] } else false
        val suspended = when {
            idle || !notSuspended || isBlocked == true -> SUSPENDED
            isBlocked == null -> UNKNOWN
            else -> ACTIVE
        }
        return families(network, type, lp).copy(
            vpn = vpn, validated = validated, captivePortal = portal, suspended = suspended,
        )
    }

    /**
     * Before API 23 there is no active-network handle: the active network is the connected one
     * of the active type, and its families are unknown unless exactly one such network exists.
     * Validation, captive portal and suspension are not available.
     */
    @Suppress("DEPRECATION")
    private fun coarseLegacy(): Coarse {
        val info = connectivity.activeNetworkInfo
        val anyVpn = connectivity.allNetworks.any {
            connectivity.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }
        val vpn = when {
            info?.type == ConnectivityManager.TYPE_VPN -> DETECTED
            anyVpn -> UNKNOWN
            else -> NOT_DETECTED
        }
        if (info == null || !info.isConnected) return Coarse(null, UNKNOWN, NO, NO)
        val type = when (info.type) {
            ConnectivityManager.TYPE_WIFI -> WIFI
            ConnectivityManager.TYPE_MOBILE -> CELLULAR
            ConnectivityManager.TYPE_ETHERNET -> ETHERNET
            else -> OTHER
        }
        val matching = connectivity.allNetworks.filter { n ->
            connectivity.getNetworkInfo(n)?.let { it.type == info.type && it.isConnected } == true
        }
        val network = matching.singleOrNull()
            ?: return Coarse(info.type, type, UNKNOWN, UNKNOWN, vpn = vpn)
        return families(network, type, connectivity.getLinkProperties(network)).copy(vpn = vpn)
    }

    private fun families(network: Network, type: String, lp: LinkProperties?): Coarse {
        if (lp == null) return Coarse(network, type, UNKNOWN, UNKNOWN)
        val addresses = lp.linkAddresses.map { it.address }
        val ipv4 = addresses.any { it is Inet4Address }
        val ipv6 = addresses.any { it is Inet6Address && !it.isLinkLocalAddress && !it.isLoopbackAddress }
        return Coarse(network, type, yesNo(ipv4), yesNo(ipv6))
    }

    companion object {
        const val WIFI = "wifi"
        const val CELLULAR = "cellular"
        const val ETHERNET = "ethernet"
        const val OTHER = "other"
        const val YES = "yes"
        const val NO = "no"
        const val DETECTED = "detected"
        const val NOT_DETECTED = "not_detected"
        const val SUSPENDED = "suspended"
        const val ACTIVE = "active"

        /** Any text the facade does not accept is unknown; this one is used on purpose. */
        const val UNKNOWN = "unknown"

        private fun yesNo(b: Boolean) = if (b) YES else NO
    }
}
