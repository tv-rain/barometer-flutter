package com.tvrain.barometer_flutter

import android.content.res.AssetManager
import java.io.ByteArrayOutputStream
import org.json.JSONException
import org.json.JSONObject

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
     * document the facade has accepted, which has already been validated in full.
     */
    fun embeddedIssuer(document: ByteArray): String? = try {
        val policy = JSONObject(String(document, Charsets.UTF_8)).getJSONObject("policy")
        val keyed = HashSet<String>()
        val keys = policy.getJSONArray("keys")
        for (i in 0 until keys.length()) keyed.add(keys.getJSONObject(i).getString("issuer_id"))
        val issuers = policy.getJSONArray("issuers")
        val keyless = (0 until issuers.length())
            .map { issuers.getJSONObject(it).getString("issuer_id") }
            .filter { it !in keyed }
            .toSet()
        keyless.singleOrNull()
    } catch (e: JSONException) {
        null
    }
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
