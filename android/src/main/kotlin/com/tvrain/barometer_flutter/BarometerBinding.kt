package com.tvrain.barometer_flutter

import barometermobile.Barometermobile
import barometermobile.RecordValue
import barometermobile.Records
import barometermobile.StringList

/**
 * The only file that names gomobile-generated classes: the `barometermobile` facade.
 *
 * The classes come from the standalone `Barometer.aar` or, in an umbrella build, from the
 * umbrella artifact. Naming a class at compile time neither loads the native library nor
 * runs Go code; constructing a facade value does.
 */
internal object BarometerBinding {
    val clientClass: Class<*> = barometermobile.Client::class.java

    /** The facade `Records` callback backed by [store]. */
    fun records(store: RecordStore): Records = StoreRecords(store)
}

/**
 * Adapts [RecordStore] to the facade callback. Every failure surfaces as the store's
 * detail-free exception, which the facade reports as unavailable.
 */
private class StoreRecords(private val store: RecordStore) : Records {
    override fun get(key: String, timeoutMillis: Long): RecordValue? =
        store.get(key, timeoutMillis)?.let { Barometermobile.newRecordValue(it) }

    override fun put(key: String, value: ByteArray?, timeoutMillis: Long) =
        store.put(key, value ?: ByteArray(0), timeoutMillis)

    override fun delete(key: String, timeoutMillis: Long) = store.delete(key, timeoutMillis)

    override fun list(cls: Long, timeoutMillis: Long): StringList {
        val keys = store.list(cls, timeoutMillis)
        val list = Barometermobile.newStringList()
        keys.forEach { list.add(it) }
        return list
    }
}
