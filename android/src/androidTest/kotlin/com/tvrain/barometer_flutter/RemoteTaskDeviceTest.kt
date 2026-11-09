package com.tvrain.barometer_flutter

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Signed remote task acceptance in the native library through the channel host: a package
 * signed with a synthetic Ed25519 key of the trusted local policy is installed with
 * `InstallRemoteTask` and admitted, and packages signed with a wrong key, with altered task
 * bytes or under an expired key are rejected as `task_source_unauthenticated`. The keys derive
 * from fixed public test seeds. Only admission runs; nothing contacts the network.
 */
@RunWith(AndroidJUnit4::class)
class RemoteTaskDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val now = System.currentTimeMillis()
    private val trusted = TestSigner("remote-key-1", DeviceTestDocuments.REMOTE_ISSUER, 0x31)
    private val expired = TestSigner("remote-key-expired", DeviceTestDocuments.REMOTE_ISSUER, 0x32)
    private lateinit var host: BarometerHost
    private lateinit var channel: ChannelCaller

    private fun scopeDir() = File(context.noBackupFilesDir, "barometer/${RecordStore.DEFAULT_SCOPE}")

    @Before
    fun setUp() {
        scopeDir().deleteRecursively()
        val base = DeviceTestDocuments.trustDocument("TCP-01", DeviceTestDocuments.TCP_TUPLE)
        val document = DeviceTestDocuments.withRemoteIssuer(
            base,
            trusted.key(now - 3_600_000L, now + 86_400_000L),
            expired.key(now - 7_200_000L, now - 3_600_000L),
        )
        host = BarometerHost(context, HostPolicy { document })
        channel = ChannelCaller(host)
        assertNull(channel.initialize("{}"))
    }

    @After
    fun tearDown() {
        channel.code("close")
        host.detach()
        scopeDir().deleteRecursively()
    }

    private fun task(id: String) = DeviceTestDocuments.runTask(id, "TCP-01", DeviceTestDocuments.TCP_INPUT).toByteArray()

    @Test
    fun signerMatchesTheRfc8032Vector() {
        // RFC 8032 section 7.1, test 1: the empty message.
        val seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        val signer = TestSigner("rfc", "rfc", seed)
        assertArrayEquals(hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"), signer.publicKey)
        assertArrayEquals(
            hex(
                "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
            ),
            signer.signature(ByteArray(0)),
        )
    }

    @Test
    fun aSignedPackageIsAcceptedAndForgeriesAreRejected() {
        val issued = now - 60_000L
        val accepted = channel.admitRemote(trusted.sign(task("remote-accepted"), issued))
        assertNull(accepted.code)
        assertTrue((accepted.value as String).isNotEmpty())

        // The same key ID and issuer with another seed: the signature does not verify.
        val impostor = TestSigner(trusted.keyId, trusted.issuerId, 0x77)
        assertEquals("task_source_unauthenticated", channel.admitRemote(impostor.sign(task("remote-wrong-key"), issued)).code)

        // Task bytes changed after signing.
        val altered = trusted.sign(task("remote-altered"), issued) { bytes ->
            JSONObject(String(bytes)).put("task_id", "remote-altered-2").toString().toByteArray()
        }
        assertEquals("task_source_unauthenticated", channel.admitRemote(altered).code)

        // A key whose validity ended an hour ago, for a package issued while it was valid.
        val late = expired.sign(task("remote-expired-key"), now - 5_400_000L)
        assertEquals("task_source_unauthenticated", channel.admitRemote(late).code)

        // The accepted package admits again as an exact redelivery.
        assertNull(channel.admitRemote(trusted.sign(task("remote-accepted"), issued)).code)
    }

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }
}
