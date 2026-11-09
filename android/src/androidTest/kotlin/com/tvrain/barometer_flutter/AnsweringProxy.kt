package com.tvrain.barometer_flutter

import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import org.json.JSONObject

/**
 * A loopback CONNECT proxy that never contacts any target. It answers `200` to a CONNECT for
 * one of [open], then holds the tunnel until the client closes it, so a TCP-01 attempt on the
 * proxy path completes without leaving the device; any other CONNECT gets `502` and is closed.
 * It records every CONNECT target it receives.
 */
class AnsweringProxy(private val open: Set<String> = setOf("1.1.1.1:443")) : AutoCloseable {
    private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
    private val held = Collections.synchronizedList(mutableListOf<Socket>())
    val port: Int get() = server.localPort

    /** The CONNECT targets received, in order. */
    val targets: MutableList<String> = Collections.synchronizedList(mutableListOf<String>())

    private val worker = Thread {
        while (!server.isClosed) {
            val socket = runCatching { server.accept() }.getOrNull() ?: break
            held.add(socket)
            Thread { runCatching { serve(socket) } }.apply { isDaemon = true; start() }
        }
    }.apply { isDaemon = true; start() }

    private fun serve(socket: Socket) {
        socket.use {
            val header = ByteArrayOutputStream()
            val input = it.getInputStream()
            while (!header.toString("ISO-8859-1").endsWith("\r\n\r\n")) {
                val b = input.read()
                if (b < 0 || header.size() > 8192) return
                header.write(b)
            }
            val line = header.toString("ISO-8859-1").lineSequence().first().split(" ")
            if (line.size != 3 || line[0] != "CONNECT") return
            targets.add(line[1])
            val output = it.getOutputStream()
            if (line[1] !in open) {
                output.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".toByteArray())
                output.flush()
                return
            }
            output.write("HTTP/1.1 200 Connection established\r\n\r\n".toByteArray())
            output.flush()
            // The tunnel leads nowhere: discard what arrives until the client closes it.
            val sink = ByteArray(4096)
            while (input.read(sink) >= 0) {
            }
        }
    }

    /** The `proxy` member of a configuration for this proxy with [code]. */
    fun config(code: String = DeviceTestDocuments.CONNECTION_CODE): JSONObject =
        JSONObject().put("host", "127.0.0.1").put("port", port).put("connection_code", code)

    override fun close() {
        server.close()
        synchronized(held) { held.forEach { runCatching { it.close() } } }
        worker.join(5_000)
    }
}
