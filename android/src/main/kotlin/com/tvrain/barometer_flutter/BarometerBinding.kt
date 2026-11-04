package com.tvrain.barometer_flutter

/**
 * The only file that names gomobile-generated classes.
 *
 * The classes come from the standalone `Barometer.aar` or, in an umbrella build, from the
 * umbrella artifact. Naming the class at compile time neither loads the native library nor
 * runs Go code.
 */
internal object BarometerBinding {
    val clientClass: Class<*> = barometer.Client::class.java
}
