package com.tvrain.barometer_flutter

import java.security.MessageDigest

/** A host policy failure with a fixed code: `trust_invalid` or `policy_rejected`. */
internal class PolicyException(code: String) : Exception(code)

/**
 * The host policy adapter: the only path by which a trusted local document reaches the channel
 * host's facade client, and the gate a replacement document passes before the current one is
 * given up.
 *
 * The document comes from [source], which in production reads the application asset that the
 * host's native code registered ([BarometerFlutterPlugin.setTrustAsset]); the application
 * package authenticates it, because the asset ships signed with the release. It never comes
 * from Dart, method-channel arguments, task data, collector replies, targets, proxies or context
 * endpoints. The adapter reads the document at every `initialize`; a document that differs
 * from the active one is a replacement and is activated only by reinitialization, and only
 * when its `policy_generation` is strictly greater than every generation this adapter has
 * activated. A lower or equal generation fails closed with `policy_rejected` and leaves the
 * active policy, its runs and handles untouched; the facade validates the rest of the document
 * before the active client is closed.
 *
 * The generation floor lives in memory for the adapter's lifetime: one adapter serves every
 * engine of the process, so a later engine cannot activate an earlier generation either. It is
 * not persisted; across application releases, Android's refusal to install a lower version
 * code over an installed one keeps an earlier packaged policy out, and Go rejects admission
 * under a generation below its retained replay records as `policy_rollback`.
 */
internal class HostPolicy(private val source: () -> ByteArray) {
    /** One read of the trusted local document. */
    class Document(val bytes: ByteArray, val generation: Long) {
        private val digest: ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

        /** True when [other] has the same exact bytes. */
        fun sameAs(other: Document): Boolean = MessageDigest.isEqual(digest, other.digest)
    }

    private val lock = Any()
    private var highest: Document? = null

    /** Reads the current document, or throws `trust_invalid` when it is unreadable. */
    fun read(): Document {
        val bytes = try {
            source()
        } catch (e: Exception) {
            throw PolicyException(TRUST_INVALID)
        }
        return Document(bytes, generation(bytes) ?: throw PolicyException(TRUST_INVALID))
    }

    /**
     * Checks that [next] may become the active document after [active], the document of the
     * client still open, or after none. The same bytes as [active] are no replacement and are
     * not checked here. Throws `policy_rejected` otherwise unless [next] has a generation
     * strictly greater than every activated one, or, with no client open, is exactly the
     * highest activated document, as when a closed client is initialized again.
     */
    fun check(next: Document, active: Document?) = synchronized(lock) {
        val floor = highest ?: return@synchronized
        val reopened = active == null && next.sameAs(floor)
        if (next.generation <= floor.generation && !reopened) throw PolicyException(POLICY_REJECTED)
    }

    /** Records [document] as activated, raising the floor. */
    fun activated(document: Document) = synchronized(lock) {
        val floor = highest
        if (floor == null || document.generation > floor.generation) highest = document
    }

    companion object {
        const val TRUST_INVALID = "trust_invalid"
        const val POLICY_REJECTED = "policy_rejected"

        /**
         * The `policy.generation` of [document], or null when it is not a strict JSON object
         * with an integer generation in the facade's range 1 to 2^63-1. The document is read
         * with [StrictJson] under the facade's trusted-document bounds, so a repeated or
         * escaped-equivalent member name, an integer in another spelling (`-0`, `7.0`, `7e0`)
         * or out of range, invalid UTF-8 or a byte-order mark yields no generation, as the
         * facade selects none; an escaped spelling of `generation` is the same member. Unknown
         * members are left to the facade, which rejects them.
         */
        fun generation(document: ByteArray): Long? = try {
            val root = StrictJson.decode(document, StrictJson.TRUST_DOCUMENT) as? Map<*, *>
            val policy = root?.get("policy") as? Map<*, *>
            StrictJson.integer(policy?.get("generation"), 1, Long.MAX_VALUE)
        } catch (e: StrictJsonException) {
            null
        }
    }
}
