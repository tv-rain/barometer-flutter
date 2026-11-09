package com.tvrain.barometer_flutter

import android.util.Base64
import java.math.BigInteger
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import org.json.JSONObject

/**
 * Builds synthetic signed remote task packages for the instrumented tests. Each key derives
 * from a fixed public test seed (byte `i` of the seed is `label xor i`, as in the Go test kit),
 * so it is not a deployment key and confers no authority outside these tests.
 *
 * Signing is the RFC 8032 Ed25519 reference algorithm over [BigInteger]: slow and not
 * constant-time, which is acceptable only for public test seeds. Verification is the native
 * library's; nothing here verifies.
 */
internal class TestSigner(val keyId: String, val issuerId: String, seed: ByteArray) {
    /** A signer whose seed derives from the one-byte [label]. */
    constructor(keyId: String, issuerId: String, label: Int) :
        this(keyId, issuerId, ByteArray(32) { (label xor it).toByte() })

    private val expanded = MessageDigest.getInstance("SHA-512").digest(seed)
    private val scalar = clamp(expanded.copyOfRange(0, 32))
    private val prefix = expanded.copyOfRange(32, 64)

    /** The 32-byte public key. */
    val publicKey: ByteArray = Ed25519.encode(Ed25519.multiply(scalar, Ed25519.BASE))

    /** The trusted key record of the policy, valid from [notBefore] to [notAfter] (Unix millis). */
    fun key(notBefore: Long, notAfter: Long): JSONObject = JSONObject()
        .put("key_id", keyId).put("issuer_id", issuerId)
        .put("public_key", Base64.encodeToString(publicKey, Base64.NO_WRAP))
        .put("not_before", utc(notBefore)).put("not_after", utc(notAfter))

    /** The raw Ed25519 signature of [message]. */
    fun signature(message: ByteArray): ByteArray = Ed25519.sign(scalar, prefix, publicKey, message)

    /** A package of [task] issued at [issuedAt]; [alter] changes the task member after signing. */
    fun sign(task: ByteArray, issuedAt: Long, alter: (ByteArray) -> ByteArray = { it }): ByteArray {
        val issued = utc(issuedAt)
        val signature = Ed25519.sign(scalar, prefix, publicKey, message(keyId, issuerId, issued, task))
        return JSONObject()
            .put("issuer_id", issuerId).put("key_id", keyId).put("issued_at", issued)
            .put("task", url(alter(task))).put("signature", url(signature))
            .toString().toByteArray()
    }

    companion object {
        fun utc(millis: Long): String =
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
                .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
                .format(Date(millis))

        private fun url(b: ByteArray) = Base64.encodeToString(b, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

        private fun clamp(b: ByteArray): BigInteger {
            val a = Ed25519.littleEndian(b)
            return a.andNot(BigInteger.valueOf(7)).clearBit(255).setBit(254)
        }

        /** M of the signed-task message construction: each part prefixed by its 4-byte length. */
        fun message(keyId: String, issuerId: String, issuedAt: String, task: ByteArray): ByteArray {
            val parts = listOf("barometer-signed-task-v1".toByteArray(), keyId.toByteArray(), issuerId.toByteArray(), issuedAt.toByteArray(), task)
            val out = ByteBuffer.allocate(parts.sumOf { 4 + it.size })
            parts.forEach { out.putInt(it.size).put(it) }
            return out.array()
        }
    }
}

/** RFC 8032 section 6 Ed25519 arithmetic in extended coordinates. */
internal object Ed25519 {
    private val P: BigInteger = BigInteger.ONE.shiftLeft(255).subtract(BigInteger.valueOf(19))
    private val Q: BigInteger = BigInteger.ONE.shiftLeft(252).add(BigInteger("27742317777372353535851937790883648493"))
    private val D: BigInteger = BigInteger.valueOf(-121665).multiply(BigInteger.valueOf(121666).modInverse(P)).mod(P)
    private val TWO = BigInteger.valueOf(2)

    class Point(val x: BigInteger, val y: BigInteger, val z: BigInteger, val t: BigInteger)

    val BASE: Point = run {
        val x = BigInteger("15112221349535400772501151409588531511454012693041857206046113283949847762202")
        val y = BigInteger("46316835694926478169428394003475163141307993866256225615783033603165251855960")
        Point(x, y, BigInteger.ONE, x.multiply(y).mod(P))
    }

    private fun add(a: Point, b: Point): Point {
        val aa = a.y.subtract(a.x).multiply(b.y.subtract(b.x)).mod(P)
        val bb = a.y.add(a.x).multiply(b.y.add(b.x)).mod(P)
        val cc = TWO.multiply(a.t).multiply(b.t).multiply(D).mod(P)
        val dd = TWO.multiply(a.z).multiply(b.z).mod(P)
        val e = bb.subtract(aa)
        val f = dd.subtract(cc)
        val g = dd.add(cc)
        val h = bb.add(aa)
        return Point(e.multiply(f).mod(P), g.multiply(h).mod(P), f.multiply(g).mod(P), e.multiply(h).mod(P))
    }

    fun multiply(s: BigInteger, point: Point): Point {
        var q = Point(BigInteger.ZERO, BigInteger.ONE, BigInteger.ONE, BigInteger.ZERO)
        var p = point
        var k = s
        while (k.signum() > 0) {
            if (k.testBit(0)) q = add(q, p)
            p = add(p, p)
            k = k.shiftRight(1)
        }
        return q
    }

    fun encode(point: Point): ByteArray {
        val zi = point.z.modInverse(P)
        val x = point.x.multiply(zi).mod(P)
        val y = point.y.multiply(zi).mod(P)
        return toLittleEndian(if (x.testBit(0)) y.setBit(255) else y)
    }

    fun littleEndian(b: ByteArray): BigInteger = BigInteger(1, b.reversedArray())

    private fun toLittleEndian(n: BigInteger): ByteArray {
        // Big-endian magnitude without a sign byte, reversed into 32 little-endian bytes.
        val big = n.toByteArray().dropWhile { it == 0.toByte() }.toByteArray()
        return ByteArray(32).also { out -> big.reversedArray().copyInto(out) }
    }

    private fun sha512(vararg parts: ByteArray): BigInteger {
        val md = MessageDigest.getInstance("SHA-512")
        parts.forEach { md.update(it) }
        return littleEndian(md.digest())
    }

    /** The signature of [message] under the expanded secret [scalar] and [prefix]. */
    fun sign(scalar: BigInteger, prefix: ByteArray, publicKey: ByteArray, message: ByteArray): ByteArray {
        val r = sha512(prefix, message).mod(Q)
        val rs = encode(multiply(r, BASE))
        val h = sha512(rs, publicKey, message).mod(Q)
        val s = r.add(h.multiply(scalar)).mod(Q)
        return rs + toLittleEndian(s)
    }
}
