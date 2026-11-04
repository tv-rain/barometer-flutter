package com.tvrain.barometer_flutter

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
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
)

/**
 * The basic Android `Network` adapter: coarse access state and access-network generation from
 * [ConnectivityManager], and a single-shot change watch.
 *
 * The generation starts at 1 and increases whenever the default network or its coarse state
 * (type, IPv4, IPv6) differs from the last one observed, either by a network callback or by
 * [access]. Capability updates that leave the coarse state unchanged, such as signal strength,
 * do not change it. VPN, validation and captive-portal signals are not reported yet and are
 * always `unknown`.
 *
 * The callback is registered on construction and removed by [close]; construct it only when a
 * client is created. Requires `ACCESS_NETWORK_STATE`.
 */
internal class AndroidNetwork(context: Context) : Closeable {
    private val connectivity =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val lock = Any()
    private val dispatcher: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "barometer-network").apply { isDaemon = true }
    }
    private val watches = HashMap<Long, Watch>()
    private var nextWatchId = 0L
    private var generation = 1L
    private var last: Coarse? = null
    private var closed = false

    private class Watch(val generation: Long, val observer: () -> Unit) {
        val active = AtomicBoolean(true)
    }

    /** The default network and its coarse state; the network handle never leaves this class. */
    private data class Coarse(val network: Any?, val type: String, val ipv4: String, val ipv6: String)

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = refresh()
        override fun onLost(network: Network) = refresh()
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = refresh()
        override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) = refresh()
    }

    init {
        if (Build.VERSION.SDK_INT >= 24) {
            connectivity.registerDefaultNetworkCallback(callback)
        } else {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            connectivity.registerNetworkCallback(request, callback)
        }
        synchronized(lock) { last = coarse() }
    }

    /** Returns the current coarse access state. */
    fun access(): AccessSnapshot {
        val now = coarse()
        val gen = observe(now)
        return AccessSnapshot(gen, now.type, UNKNOWN, now.ipv4, now.ipv6, UNKNOWN, UNKNOWN)
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
        val network = connectivity.activeNetwork ?: return Coarse(null, UNKNOWN, NO, NO)
        val caps = connectivity.getNetworkCapabilities(network)
        val lp = connectivity.getLinkProperties(network)
        val type = when {
            caps == null -> UNKNOWN
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> WIFI
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> CELLULAR
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> ETHERNET
            else -> OTHER
        }
        return families(network, type, lp)
    }

    /**
     * Before API 23 there is no active-network handle: the active network is the connected one
     * of the active type, and its families are unknown unless exactly one such network exists.
     */
    @Suppress("DEPRECATION")
    private fun coarseLegacy(): Coarse {
        val info = connectivity.activeNetworkInfo
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
        val network = matching.singleOrNull() ?: return Coarse(info.type, type, UNKNOWN, UNKNOWN)
        return families(network, type, connectivity.getLinkProperties(network))
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

        /** Any text the facade does not accept is unknown; this one is used on purpose. */
        const val UNKNOWN = "unknown"

        private fun yesNo(b: Boolean) = if (b) YES else NO
    }
}
