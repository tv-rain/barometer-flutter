package com.tvrain.barometer_flutter

import android.content.res.AssetManager
import java.io.ByteArrayOutputStream

/**
 * Reads the trusted local document (`barometer-trust/1`) that the facade's `NewClient` takes:
 * the local policy and the configuration and context approvals, as strict JSON.
 *
 * The document comes only from the application package, as the asset [ASSET]. It is never
 * fetched, and never taken from Dart, method-channel arguments, task data or a network reply.
 * This reader checks only the size bound; the facade decodes and validates the content and
 * rejects an invalid document as `trust_invalid`.
 */
internal object TrustDocument {
    /** The asset path of the document in the application package. */
    const val ASSET = "barometer/trust.json"

    /** The facade's size bound for the document. */
    const val MAX_BYTES = 1 shl 20

    /** Returns the document bytes of [asset], or throws if it is missing or too large. */
    fun read(assets: AssetManager, asset: String = ASSET): ByteArray =
        readAsset(assets, asset, MAX_BYTES) ?: throw AdapterUnavailableException()

    /**
     * Returns the issuer of embedded tasks named by [document], or null when there is none.
     *
     * It is the one issuer of the policy that has no trusted key. An issuer with a key can
     * sign remote packages; a keyless issuer can only be reached through an embedded delivery,
     * so it is the document's embedded issuer. Zero or several keyless issuers leave the
     * association undefined, and embedded tasks are then not installed. Call this only with a
     * document the facade has accepted, which has already been validated in full. The document is
     * read with [StrictJson], so it can only select the members the facade selected.
     */
    fun embeddedIssuer(document: ByteArray): String? = try {
        val root = StrictJson.decode(document, StrictJson.TRUST_DOCUMENT) as? Map<*, *>
        val policy = root?.get("policy") as? Map<*, *>
        val keys = policy?.get("keys") as? List<*>
        val issuers = policy?.get("issuers") as? List<*>
        if (keys == null || issuers == null) {
            null
        } else {
            val keyed = keys.map { issuerId(it) ?: return null }.toSet()
            val all = issuers.map { issuerId(it) ?: return null }
            all.filter { it !in keyed }.toSet().singleOrNull()
        }
    } catch (e: StrictJsonException) {
        null
    }

    private fun issuerId(entry: Any?): String? = (entry as? Map<*, *>)?.get("issuer_id") as? String
}

/**
 * Returns the bytes of the application asset [path], or null if it is missing, unreadable,
 * empty or larger than [max] bytes. It stops reading once more than [max] bytes have arrived.
 */
internal fun readAsset(assets: AssetManager, path: String, max: Int): ByteArray? = try {
    assets.open(path).use { input ->
        val out = ByteArrayOutputStream()
        val buf = ByteArray(8192)
        while (out.size() <= max) {
            val n = input.read(buf)
            if (n < 0) break
            out.write(buf, 0, n)
        }
        out.toByteArray().takeIf { it.isNotEmpty() && it.size <= max }
    }
} catch (e: java.io.IOException) {
    null
}
