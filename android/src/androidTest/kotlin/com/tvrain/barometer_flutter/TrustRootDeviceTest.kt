package com.tvrain.barometer_flutter

import android.content.Context
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.KeyFactory
import java.security.KeyStore
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The trust-root set of the Go library inside the application process, through the facade.
 *
 * Each case runs TLS-01 twice on one client: directly to `8.8.8.8:443` with server name
 * `dns.google`, whose chain the platform stores of API 24 and later trust through the
 * GlobalSign Root CA cross-signature, and on the proxy path through a
 * loopback CONNECT proxy in this process that answers the handshake itself with a leaf for the
 * same name issued by the synthetic test CA in the test assets. Only the reported
 * `certificate_validation` is checked; no result is printed.
 *
 * The instrumentation argument `trustScenario` names the emulator state that
 * `scripts/android-trust-scenario.sh` prepared; without it the device is unchanged:
 *
 * - `platform`: the stores are untouched. The system store is found and the synthetic CA is
 *   rejected.
 * - `user-ca`: the synthetic CA is installed as a user CA. It is still rejected.
 * - `updatable-only` (API 34 and later): the updatable store holds only the synthetic CA. The
 *   synthetic leaf is trusted and the public one is not, so the root set follows that store.
 * - `system-only`: the system store holds only the synthetic CA. From API 34, where the updatable
 *   store exists, nothing changes; before it the system store is the root set.
 * - `no-store`: both stores are empty, so there is no root set. Only
 *   [testsThatVerifyCertificatesNeedARootSet] runs: through the channel host, every test that
 *   verifies a certificate is rejected as `task_unsupported`, while TCP-01 is still admitted.
 */
@RunWith(AndroidJUnit4::class)
class TrustRootDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val testAssets = InstrumentationRegistry.getInstrumentation().context.assets
    private val scenario =
        InstrumentationRegistry.getArguments().getString("trustScenario") ?: "platform"
    private val closeables = mutableListOf<AutoCloseable>()

    private fun scopeDir() = File(context.noBackupFilesDir, "barometer/$SCOPE")

    @Before
    fun setUp() {
        scopeDir().deleteRecursively()
    }

    @After
    fun tearDown() {
        closeables.asReversed().forEach { runCatching { it.close() } }
        scopeDir().deleteRecursively()
    }

    @Test
    fun rootSetFollowsThePlatformStores() {
        assumeTrue("no root set to follow", scenario != NO_STORE)
        val updatable = Build.VERSION.SDK_INT >= 34
        // Expected certificate_validation of the direct (public) and the intercepted
        // (synthetic CA) handshake.
        val (direct, intercepted) = when (scenario) {
            "platform", "user-ca" -> TRUSTED to UNTRUSTED
            "updatable-only" -> {
                assumeTrue("the updatable store exists from API 34", updatable)
                UNTRUSTED to TRUSTED
            }
            "system-only" -> if (updatable) TRUSTED to UNTRUSTED else UNTRUSTED to TRUSTED
            else -> throw IllegalArgumentException("unknown trustScenario")
        }

        val proxy = InterceptingProxy().also { closeables.add(it) }
        val tuple = JSONObject().put("address", ADDRESS).put("port", 443).put("scheme", "tls")
            .put("tls_server_name", SERVER_NAME)
        val store = RecordStore.open(context, SCOPE).also { closeables.add(it) }
        val trust = DeviceTestDocuments.trustDocument("TLS-01", tuple, listOf(CONNECTION_CODE))
        val owner = BarometerBinding.newClient(context, store, trust).also { closeables.add(it) }
        val client = owner.facade
        val proxyConfig = JSONObject().put("host", "127.0.0.1").put("port", proxy.port)
            .put("connection_code", CONNECTION_CODE)
        client.initialize(JSONObject().put("proxy", proxyConfig).toString())

        val input = JSONObject().put("ip_address", ADDRESS).put("port", 443).put("server_name", SERVER_NAME)
        assertEquals("direct", direct, validation(owner, DeviceTestDocuments.runTask("trust-direct", "TLS-01", input)))
        assertEquals(0, proxy.connects.get())
        assertEquals("intercepted", intercepted,
            validation(owner, DeviceTestDocuments.runTask("trust-proxy", "TLS-01", input, "proxy")))
        assertEquals(1, proxy.connects.get())
    }

    /**
     * Admission of the six tests that verify a certificate (TLS-01, HTTP-01, NET-03, DNS-04,
     * DNS-03 and NET-05) through the channel host, as signed remote packages of a synthetic
     * issuer permitted every test but the composite NET-05. Without a root set none of them is
     * registered, so each is `task_unsupported` (decision 0016, REQ-TRUST-0036); with one, each
     * gets past the test lookup to a later admission class. TCP-01 is admitted either way. Only admission runs.
     */
    @Test
    fun testsThatVerifyCertificatesNeedARootSet() {
        val now = System.currentTimeMillis()
        val signer = TestSigner("trust-key", DeviceTestDocuments.REMOTE_ISSUER, 0x51)
        val base = DeviceTestDocuments.trustDocument("TCP-01", DeviceTestDocuments.TCP_TUPLE)
        val all = DeviceTestDocuments.edit(base) { root ->
            val policy = root.getJSONObject("policy")
            val lists = listOf(policy.getJSONObject("permissions"), policy.getJSONArray("issuers").getJSONObject(0).getJSONObject("permissions"))
            for (permissions in lists) {
                TLS_TESTS.filter { it != "NET-05" }.forEach { permissions.getJSONArray("tests").put(JSONObject().put("id", it).put("version", "0.1.0")) }
            }
        }
        val document = DeviceTestDocuments.withRemoteIssuer(all, signer.key(now - 3_600_000L, now + 86_400_000L))
        val host = BarometerHost(context, HostPolicy { document })
        val channel = ChannelCaller(host)
        val defaultScope = File(context.noBackupFilesDir, "barometer/${RecordStore.DEFAULT_SCOPE}")
        defaultScope.deleteRecursively()
        try {
            assertEquals(null, channel.initialize("{}"))
            fun admit(id: String, test: String, input: JSONObject) = channel.admitRemote(
                signer.sign(DeviceTestDocuments.runTask(id, test, input).toByteArray(), now - 60_000L),
            )
            for (test in TLS_TESTS) {
                val code = admit("roots-${test.lowercase()}", test, JSONObject()).code
                if (scenario == NO_STORE) {
                    assertEquals(test, "task_unsupported", code)
                } else {
                    assertTrue("$test: $code", code != null && code != "task_unsupported")
                }
            }
            assertEquals(null, admit("roots-tcp-01", "TCP-01", DeviceTestDocuments.TCP_INPUT).code)
        } finally {
            channel.code("close")
            host.detach()
            defaultScope.deleteRecursively()
        }
    }

    /** Runs [task] and returns the certificate_validation of its TLS handshake observation. */
    private fun validation(owner: BarometerClient, task: String): String {
        val client = owner.facade
        val ref = client.installEmbeddedTask(DeviceTestDocuments.ISSUER, task.toByteArray())
        val run = client.startRun(client.admitTask(task, ref))
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60)
        while (client.runState(run) != "terminal") {
            assertTrue("run did not become terminal", System.nanoTime() < deadline)
            Thread.sleep(10)
        }
        val bundle = JSONObject(client.nextBundle())
        client.acknowledgeBundle(bundle.getString("bundle_id"))
        val result = bundle.getJSONArray("results").getJSONObject(0)
        val execution = result.getJSONObject("execution")
        assertEquals(execution.optString("reason"), "completed", execution.getString("state"))
        val observations = result.getJSONObject("measurement").getJSONArray("observations")
        for (i in 0 until observations.length()) {
            val o = observations.getJSONObject(i)
            if (o.getString("type") == "tls_handshake") {
                return o.getJSONObject("details").getString("certificate_validation")
            }
        }
        throw AssertionError("no TLS handshake observation")
    }

    /**
     * A loopback CONNECT proxy that never contacts the requested target: it accepts the tunnel
     * and answers the TLS handshake with the synthetic leaf and chain from the test assets.
     */
    private inner class InterceptingProxy : AutoCloseable {
        private val server = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val port: Int get() = server.localPort
        val connects = AtomicInteger()
        private val tls: SSLContext = run {
            val factory = CertificateFactory.getInstance("X.509")
            val chain = testAssets.open("$FIXTURES/leaf-chain.pem").use { factory.generateCertificates(it) }
                .toTypedArray<Certificate>()
            val key = KeyFactory.getInstance("EC")
                .generatePrivate(PKCS8EncodedKeySpec(testAssets.open("$FIXTURES/leaf-key.pk8").use { it.readBytes() }))
            val keys = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
                load(null)
                setKeyEntry("leaf", key, CharArray(0), chain)
            }
            val managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
                .apply { init(keys, CharArray(0)) }
            SSLContext.getInstance("TLS").apply { init(managers.keyManagers, null, null) }
        }
        private val worker = Thread {
            while (!server.isClosed) {
                val socket = runCatching { server.accept() }.getOrNull() ?: break
                runCatching { intercept(socket) }
                runCatching { socket.close() }
            }
        }.apply { isDaemon = true; start() }

        private fun intercept(socket: Socket) {
            socket.soTimeout = 20_000
            val header = ByteArrayOutputStream()
            val input = socket.getInputStream()
            while (!header.toString("ISO-8859-1").endsWith("\r\n\r\n")) {
                val b = input.read()
                if (b < 0 || header.size() > 8192) return
                header.write(b)
            }
            if (!header.toString("ISO-8859-1").startsWith("CONNECT $ADDRESS:443 ")) return
            connects.incrementAndGet()
            socket.getOutputStream().apply { write("HTTP/1.1 200 Connection established\r\n\r\n".toByteArray()); flush() }
            val tunnel = tls.socketFactory.createSocket(socket, "127.0.0.1", socket.port, true) as SSLSocket
            tunnel.useClientMode = false
            tunnel.use {
                it.startHandshake()
                it.inputStream.read()
            }
        }

        override fun close() {
            server.close()
            worker.join(5_000)
        }
    }

    companion object {
        private const val SCOPE = "trust-root-device-test"
        private const val FIXTURES = "barometer/trust-roots"
        private const val ADDRESS = "8.8.8.8"
        private const val SERVER_NAME = "dns.google"
        private const val CONNECTION_CODE = "synthetic_proxy"
        private const val TRUSTED = "trusted"
        private const val UNTRUSTED = "untrusted"
        private const val NO_STORE = "no-store"
        private val TLS_TESTS = listOf("TLS-01", "HTTP-01", "NET-03", "DNS-04", "DNS-03", "NET-05")
    }
}
