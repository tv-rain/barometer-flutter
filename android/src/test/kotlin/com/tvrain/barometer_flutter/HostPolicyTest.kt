package com.tvrain.barometer_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

/** Host tests of the host policy adapter's generation gate, with synthetic documents only. */
class HostPolicyTest {
    private fun document(generation: Any, owner: String = "a") =
        "{\"format\":\"barometer-trust/1\",\"policy\":{\"generation\":$generation,\"owner\":\"$owner\"}}".toByteArray()

    private fun rejected(policy: HostPolicy, next: HostPolicy.Document, active: HostPolicy.Document?, code: String = "policy_rejected") {
        try {
            policy.check(next, active)
            fail("accepted generation ${next.generation}")
        } catch (e: PolicyException) {
            assertEquals(code, e.message)
        }
    }

    @Test
    fun generationIsAPositiveInteger() {
        assertEquals(2L, HostPolicy.generation(document(2)))
        assertEquals(9_007_199_254_740_993L, HostPolicy.generation(document("9007199254740993")))
        for (bad in listOf("0", "-1", "2.0", "\"2\"", "null", "true")) assertNull(bad, HostPolicy.generation(document(bad)))
        assertNull(HostPolicy.generation("{}".toByteArray()))
        assertNull(HostPolicy.generation("not json".toByteArray()))
        assertNull(HostPolicy.generation("[]".toByteArray()))
    }

    @Test
    fun unreadableDocumentsAreTrustInvalid() {
        for (source in listOf<() -> ByteArray>({ throw AdapterUnavailableException() }, { document("1.5") })) {
            try {
                HostPolicy(source).read()
                fail("read an unusable document")
            } catch (e: PolicyException) {
                assertEquals("trust_invalid", e.message)
            }
        }
    }

    @Test
    fun onlyAStrictlyGreaterGenerationReplaces() {
        var bytes = document(2)
        val policy = HostPolicy { bytes }
        val two = policy.read()
        policy.check(two, null)
        policy.activated(two)

        bytes = document(1)
        rejected(policy, policy.read(), two)
        rejected(policy, policy.read(), null)
        bytes = document(2, owner = "b")
        rejected(policy, policy.read(), two)
        rejected(policy, policy.read(), null)

        // The same bytes reopen after close; while a client is open they are no replacement.
        bytes = document(2)
        policy.check(policy.read(), null)

        bytes = document(3)
        val three = policy.read()
        policy.check(three, two)
        policy.activated(three)
        bytes = document(2)
        rejected(policy, policy.read(), three)
        rejected(policy, policy.read(), null)
        // Activating a lower document never lowers the floor.
        policy.activated(two)
        rejected(policy, two, null)
        policy.check(three, null)
    }
}
