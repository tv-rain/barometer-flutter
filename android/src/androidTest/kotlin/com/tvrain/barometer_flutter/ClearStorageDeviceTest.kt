package com.tvrain.barometer_flutter

import android.content.Context
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Operating-system data clearing ("Clear storage" in Settings) without calling Barometer.
 * `scripts/android-clear-storage-check.sh` runs [seed], clears the test application's data with
 * `pm clear`, which is what Settings does, then runs [verifyCleared]. Both are skipped unless
 * the instrumentation argument `clearStorage` names them. The seed runs TCP-01 to 1.1.1.1:443
 * once with rotating linkage; no result is printed.
 */
@RunWith(AndroidJUnit4::class)
class ClearStorageDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val phase = InstrumentationRegistry.getArguments().getString("clearStorage")
    private val scopeDir = File(context.noBackupFilesDir, "barometer/$SCOPE")
    private val alias = AndroidLinkageKeys.alias(scopeDir)

    private fun keyExists(): Boolean =
        Build.VERSION.SDK_INT >= 23 && KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.containsAlias(alias)

    private fun trust() = DeviceTestDocuments.trustDocument(
        "TCP-01", DeviceTestDocuments.TCP_TUPLE, linkageScopes = listOf(DeviceTestDocuments.LINKAGE_SCOPE),
    )

    @Test
    fun seed() {
        assumeTrue(phase == "seed")
        scopeDir.deleteRecursively()
        val store = RecordStore.open(context, SCOPE)
        val owner = BarometerBinding.newClient(context, store, trust())
        try {
            val client = owner.facade
            client.initialize(DeviceTestDocuments.linkedConfig())
            val task = DeviceTestDocuments.runTask("clear-storage", "TCP-01", DeviceTestDocuments.TCP_INPUT)
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
        assertEquals(Build.VERSION.SDK_INT >= 23, keyExists())
        assertEquals(Build.VERSION.SDK_INT >= 23, AndroidLinkageKeys.sentinel(scopeDir).isFile)
    }

    @Test
    fun verifyCleared() {
        assumeTrue(phase == "verify")
        assertFalse("Barometer files survived", File(context.noBackupFilesDir, "barometer").exists())
        assertFalse("the Keystore key survived", keyExists())
        val store = RecordStore.open(context, SCOPE)
        val owner = BarometerBinding.newClient(context, store, trust())
        try {
            owner.facade.initialize(DeviceTestDocuments.linkedConfig())
            assertEquals("", owner.facade.nextBundle())
            assertFalse("a key was created before linkage needed one", keyExists())
        } finally {
            owner.close()
            store.close()
        }
        scopeDir.deleteRecursively()
    }

    companion object {
        private const val SCOPE = "clear-storage-test"
    }
}
