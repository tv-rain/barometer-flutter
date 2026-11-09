package com.tvrain.barometer_flutter

import android.content.Context
import android.os.Build
import android.os.Bundle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The linkage key, its sentinel and the records across uninstall and reinstall and across
 * backup and restore. `scripts/android-reinstall-backup-check.sh` runs [seed], uninstalls and
 * reinstalls the test application or backs it up and restores it, then runs [verify]. Both are
 * skipped unless the instrumentation argument `reinstallBackup` names them.
 *
 * [seed] runs TCP-01 to 1.1.1.1:443 once with rotating linkage, which leaves records, a pending
 * bundle, the Keystore key and the sentinel, and writes a control file in the backed-up files
 * directory. It reports `keyFingerprint`, the SHA-256 of the key's HMAC of a fixed synthetic
 * message, as an instrumentation status; no result and no derived value is printed. [verify]
 * checks that no Barometer file survived, that the control file is present after a restore and
 * absent after a reinstall, that initializing creates no key, and that the first derivation
 * gives another fingerprint than `previousKey`, so the earlier key is not used again.
 */
@RunWith(AndroidJUnit4::class)
class ReinstallBackupDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val arguments = InstrumentationRegistry.getArguments()
    private val phase = arguments.getString("reinstallBackup")
    private val scopeDir = File(context.noBackupFilesDir, "barometer/$SCOPE")
    private val alias = AndroidLinkageKeys.alias(scopeDir)
    private val control = File(context.filesDir, CONTROL)

    private fun keyExists(): Boolean =
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.containsAlias(alias)

    private fun trust() = DeviceTestDocuments.trustDocument(
        "TCP-01", DeviceTestDocuments.TCP_TUPLE, linkageScopes = listOf(DeviceTestDocuments.LINKAGE_SCOPE),
    )

    /** SHA-256 of the scope key's HMAC of a fixed message; creates the key if it is missing. */
    private fun keyFingerprint(): String {
        val keys = AndroidLinkageKeys.open(scopeDir)!!
        try {
            val mac = keys.deriveHmacSha256(MESSAGE, 5_000)
            return MessageDigest.getInstance("SHA-256").digest(mac).joinToString("") { "%02x".format(it) }
        } finally {
            keys.close()
        }
    }

    @Test
    fun seed() {
        assumeTrue(phase == "seed")
        assumeTrue("linkage keys need API 23", Build.VERSION.SDK_INT >= 23)
        scopeDir.deleteRecursively()
        if (keyExists()) KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(alias)
        val store = RecordStore.open(context, SCOPE)
        val owner = BarometerBinding.newClient(context, store, trust())
        try {
            val client = owner.facade
            client.initialize(DeviceTestDocuments.linkedConfig())
            val task = DeviceTestDocuments.runTask("reinstall-backup", "TCP-01", DeviceTestDocuments.TCP_INPUT)
            val run = client.startRun(client.admitTask(task, client.installEmbeddedTask(DeviceTestDocuments.ISSUER, task.toByteArray())))
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
            while (client.runState(run) != "terminal") {
                assertTrue(System.nanoTime() < deadline)
                Thread.sleep(10)
            }
            // The bundle stays pending.
            assertTrue(JSONObject(client.nextBundle()).has("bundle_id"))
        } finally {
            owner.close()
            store.close()
        }
        assertTrue(File(scopeDir, "records").list()!!.isNotEmpty())
        assertTrue("the run created no key", keyExists())
        assertTrue(AndroidLinkageKeys.sentinel(scopeDir).isFile)
        control.writeText("barometer-backup-control/1\n")
        val status = Bundle()
        status.putString("keyFingerprint", keyFingerprint())
        instrumentation.sendStatus(0, status)
    }

    @Test
    fun verify() {
        assumeTrue(phase == "verify-reinstall" || phase == "verify-restore")
        assumeTrue("linkage keys need API 23", Build.VERSION.SDK_INT >= 23)
        val previous = arguments.getString("previousKey")
        assertNotNull("no previousKey argument", previous)
        if (phase == "verify-restore") {
            assertTrue("the control file was not restored", control.isFile)
        } else {
            assertFalse("the control file survived the reinstall", control.exists())
        }
        assertFalse("Barometer files survived", File(context.noBackupFilesDir, "barometer").exists())
        // A reinstall or a restore into a fresh installation has no key; a key left without its
        // sentinel would be replaced before use, which the fingerprint check below covers.
        val keyBefore = keyExists()
        val store = RecordStore.open(context, SCOPE)
        val owner = BarometerBinding.newClient(context, store, trust())
        try {
            owner.facade.initialize(DeviceTestDocuments.linkedConfig())
            assertEquals("a pending bundle survived", "", owner.facade.nextBundle())
            assertEquals("a key was created before linkage needed one", keyBefore, keyExists())
        } finally {
            owner.close()
            store.close()
        }
        assertFalse("the earlier key survived", keyBefore)
        assertNotEquals("the earlier key was used again", previous, keyFingerprint())
        assertTrue(AndroidLinkageKeys.sentinel(scopeDir).isFile)
        val keys = AndroidLinkageKeys.open(scopeDir)!!
        try {
            keys.delete(5_000)
        } finally {
            keys.close()
        }
        scopeDir.deleteRecursively()
        control.delete()
    }

    companion object {
        private const val SCOPE = "reinstall-backup-test"
        private const val CONTROL = "backup-control"
        private val MESSAGE = "barometer-reinstall-backup-check".toByteArray()
    }
}
