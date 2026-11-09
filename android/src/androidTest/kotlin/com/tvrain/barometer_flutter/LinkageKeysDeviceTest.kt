package com.tvrain.barometer_flutter

import android.content.Context
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.KeyStore
import javax.crypto.SecretKey
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * [AndroidLinkageKeys] against Android Keystore: derivation, the reinstall sentinel, orphaned
 * keys, deletion and its failure. The derived values are compared with each other only and
 * never printed.
 */
@RunWith(AndroidJUnit4::class)
class LinkageKeysDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val scopeDir = File(context.noBackupFilesDir, "barometer/$SCOPE")
    private val alias = AndroidLinkageKeys.alias(scopeDir)
    private val sentinel = AndroidLinkageKeys.sentinel(scopeDir)
    private var keys: AndroidLinkageKeys? = null

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    @Before
    fun setUp() {
        scopeDir.deleteRecursively()
        if (Build.VERSION.SDK_INT >= 23) keyStore().deleteEntry(alias)
        keys = AndroidLinkageKeys.open(scopeDir)
    }

    @After
    fun tearDown() {
        keys?.let {
            runCatching { it.delete(5_000) }
            it.close()
        }
        scopeDir.deleteRecursively()
    }

    private fun derive(message: String) = keys!!.deriveHmacSha256(message.toByteArray(), 5_000)

    @Test
    fun noKeyStoreBeforeApi23() {
        assumeTrue(Build.VERSION.SDK_INT < 23)
        assertNull(keys)
    }

    @Test
    fun derivationCreatesANonExportableKeyOnFirstUse() {
        assumeTrue(Build.VERSION.SDK_INT >= 23)
        assertFalse(keyStore().containsAlias(alias))
        assertFalse(sentinel.exists())
        val a = derive("message-a")
        assertEquals(32, a.size)
        assertTrue(sentinel.isFile)
        val key = keyStore().getKey(alias, null) as SecretKey
        assertNull("the key is exportable", key.encoded)
        assertArrayEquals(a, derive("message-a"))
        assertFalse(a.contentEquals(derive("message-b")))
    }

    @Test
    fun aKeyWithoutTheSentinelIsReplacedBeforeUse() {
        assumeTrue(Build.VERSION.SDK_INT >= 23)
        val a = derive("message")
        assertTrue(sentinel.delete())
        assertTrue(keyStore().containsAlias(alias))
        val b = derive("message")
        assertFalse("an orphaned key was used", a.contentEquals(b))
        assertTrue(sentinel.isFile)
        assertArrayEquals(b, derive("message"))
    }

    @Test
    fun aMissingKeyIsCreatedWhenNeeded() {
        assumeTrue(Build.VERSION.SDK_INT >= 23)
        val a = derive("message")
        keyStore().deleteEntry(alias)
        val b = derive("message")
        assertFalse(a.contentEquals(b))
        assertTrue(keyStore().containsAlias(alias))
    }

    @Test
    fun deletionRemovesKeyAndSentinelAndCreatesNothing() {
        assumeTrue(Build.VERSION.SDK_INT >= 23)
        val a = derive("message")
        keys!!.delete(5_000)
        assertFalse(keyStore().containsAlias(alias))
        assertFalse(sentinel.exists())
        keys!!.delete(5_000)
        assertFalse(keyStore().containsAlias(alias))
        assertFalse(sentinel.exists())
        assertFalse(a.contentEquals(derive("message")))
    }

    @Test
    fun anInterruptedDeletionFailsAndCompletesLater() {
        assumeTrue(Build.VERSION.SDK_INT >= 23)
        derive("message")
        // A directory in place of the sentinel cannot be deleted as a file.
        assertTrue(sentinel.delete())
        assertTrue(File(sentinel, "blocker").mkdirs())
        try {
            keys!!.delete(5_000)
            fail("an incomplete deletion succeeded")
        } catch (e: AdapterUnavailableException) {
        }
        assertFalse(keyStore().containsAlias(alias))
        assertTrue(sentinel.deleteRecursively())
        keys!!.delete(5_000)
        assertFalse(sentinel.exists())
    }

    @Test
    fun nothingRunsAfterClose() {
        assumeTrue(Build.VERSION.SDK_INT >= 23)
        keys!!.close()
        for (op in listOf({ derive("message") }, { keys!!.delete(5_000) })) {
            try {
                op()
                fail("a call ran after close")
            } catch (e: AdapterUnavailableException) {
            }
        }
        assertFalse(keyStore().containsAlias(alias))
        keys = null
    }

    companion object {
        private const val SCOPE = "linkage-keys-device-test"
    }
}
