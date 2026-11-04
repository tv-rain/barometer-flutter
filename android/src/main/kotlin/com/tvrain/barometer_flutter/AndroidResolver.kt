package com.tvrain.barometer_flutter

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.util.concurrent.ExecutionException
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Ordinary per-name platform lookup for the facade's `SystemResolver` port, through
 * [InetAddress.getAllByName]. The lookup runs on one of a few daemon threads and the caller
 * waits at most its `timeoutMillis`; a lookup still running at the deadline is abandoned, and
 * its answer is discarded. Any lookup failure, including an unknown name, is an error, which
 * the facade records as DNS-01 `resolver_error`: before API 29 the platform does not tell a
 * missing name apart from a resolver failure. An answer with no address of the requested
 * family is empty. Addresses are returned in canonical text without zone.
 */
internal class AndroidResolver(
    private val lookup: (String) -> Array<InetAddress> = InetAddress::getAllByName,
) {
    private val workers = ThreadPoolExecutor(
        0, MAX_LOOKUPS, 30, TimeUnit.SECONDS, SynchronousQueue(),
    ) { r -> Thread(r, "barometer-resolver").apply { isDaemon = true } }

    fun lookupNetIP(network: String, host: String, timeoutMillis: Long): List<String> {
        val want = when (network) {
            "ip" -> null
            "ip4" -> Inet4Address::class.java
            "ip6" -> Inet6Address::class.java
            else -> throw AdapterUnavailableException()
        }
        val name = host.removeSuffix(".")
        if (name.isEmpty() || timeoutMillis < 1 || isLiteral(name)) throw AdapterUnavailableException()
        val answer = try {
            workers.submit<Array<InetAddress>> { lookup(name) }.get(timeoutMillis, TimeUnit.MILLISECONDS)
        } catch (e: ExecutionException) {
            throw AdapterUnavailableException()
        } catch (e: TimeoutException) {
            throw AdapterUnavailableException()
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            throw AdapterUnavailableException()
        }
        return answer
            .filter { want == null || want.isInstance(it) }
            .filter { it !is Inet6Address || it.scopeId == 0 }
            .map { canonical(it) }
            .distinct()
    }

    companion object {
        private const val MAX_LOOKUPS = 4

        /** A literal would be returned without any lookup, so it is not a name to resolve. */
        private fun isLiteral(name: String) =
            name.contains(':') || name.all { it.isDigit() || it == '.' }

        /** Canonical address text: dotted IPv4, or RFC 5952 IPv6. */
        fun canonical(address: InetAddress): String {
            if (address is Inet4Address) return address.hostAddress!!
            return canonicalIPv6(address.address)
        }

        fun canonicalIPv6(bytes: ByteArray): String {
            require(bytes.size == 16)
            val groups = IntArray(8) { ((bytes[2 * it].toInt() and 0xff) shl 8) or (bytes[2 * it + 1].toInt() and 0xff) }
            var bestStart = -1
            var bestLen = 0
            var i = 0
            while (i < 8) {
                if (groups[i] == 0) {
                    var j = i
                    while (j < 8 && groups[j] == 0) j++
                    if (j - i > bestLen) {
                        bestStart = i
                        bestLen = j - i
                    }
                    i = j
                } else {
                    i++
                }
            }
            if (bestLen < 2) bestStart = -1
            val out = StringBuilder()
            i = 0
            while (i < 8) {
                if (i == bestStart) {
                    out.append("::")
                    i += bestLen
                    continue
                }
                if (out.isNotEmpty() && !out.endsWith(":")) out.append(':')
                out.append(Integer.toHexString(groups[i]))
                i++
            }
            return out.toString()
        }
    }
}
