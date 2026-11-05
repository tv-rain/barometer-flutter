// Umbrella mode only. Includes the barometermobile facade header of the host-supplied
// umbrella framework, named by BAROMETER_UMBRELLA_MODULE, so that BarometerBinding.swift
// imports the facade without naming the host's module. The include resolves to that
// framework's own module, and `export *` re-exports it.
#ifndef BAROMETER_UMBRELLA_MODULE
#error "BAROMETER_UMBRELLA_MODULE is not defined; set BAROMETER_FLUTTER_UMBRELLA_MODULE for pod install"
#endif
#define BAROMETER_UMBRELLA_STRING_(x) #x
#define BAROMETER_UMBRELLA_STRING(x) BAROMETER_UMBRELLA_STRING_(x)
#include BAROMETER_UMBRELLA_STRING(BAROMETER_UMBRELLA_MODULE/Barometermobile.objc.h)
