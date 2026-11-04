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
    fun read(assets: AssetManager, asset: String = ASSET): ByteArray {
        val bytes = try {
            assets.open(asset).use { input ->
                val out = ByteArrayOutputStream()
                val buf = ByteArray(8192)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    if (out.size() > MAX_BYTES) throw AdapterUnavailableException()
                }
                out.toByteArray()
            }
        } catch (e: java.io.IOException) {
            throw AdapterUnavailableException()
        }
        if (bytes.isEmpty()) throw AdapterUnavailableException()
        return bytes
    }
}
