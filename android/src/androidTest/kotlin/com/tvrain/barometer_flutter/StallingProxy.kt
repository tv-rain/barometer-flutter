package com.tvrain.barometer_flutter

import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject

/**
 * A loopback CONNECT proxy that never contacts the requested target and never answers: it
 * reads the request and holds the connection open, so an attempt on the proxy path stays
 * active until it is cancelled or its deadline passes.
 */
class StallingProxy : AutoCloseable {
    private val server = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
    private val held = Collections.synchronizedList(mutableListOf<Socket>())
    val port: Int get() = server.localPort

    /** CONNECT requests received. */
    val connects = AtomicInteger()

    private val worker = Thread {
        while (!server.isClosed) {
            val socket = runCatching { server.accept() }.getOrNull() ?: break
            held.add(socket)
            Thread { runCatching { readRequest(socket) } }.apply { isDaemon = true; start() }
        }
    }.apply { isDaemon = true; start() }

    private fun readRequest(socket: Socket) {
        val header = ByteArrayOutputStream()
        val input = socket.getInputStream()
        while (!header.toString("ISO-8859-1").endsWith("\r\n\r\n")) {
            val b = input.read()
            if (b < 0 || header.size() > 8192) return
            header.write(b)
        }
        if (header.toString("ISO-8859-1").startsWith("CONNECT ")) connects.incrementAndGet()
        // No answer: the socket stays open until the client gives up or the proxy closes.
    }

    /** The `proxy` member of an `Initialize` configuration for this proxy. */
    fun config(): JSONObject = JSONObject().put("host", "127.0.0.1").put("port", port)
        .put("connection_code", DeviceTestDocuments.CONNECTION_CODE)

    override fun close() {
        server.close()
        synchronized(held) { held.forEach { runCatching { it.close() } } }
        worker.join(5_000)
    }
}
