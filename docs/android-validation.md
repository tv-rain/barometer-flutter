# Android Validation Record

This record lists where the Android native glue was run and what each run covered, following the validation plan of [decision 0014](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0014-gomobile-facade-and-platform-matrix.md#validation-plan). It is evidence for the recorded inputs only. It does not establish conformance, safety, field behavior or support for any platform version, and Barometer Draft `0.1.0` status is unchanged.

No measurement result, outcome, device serial, account, network name or address is recorded. The instrumented tests check the lifecycle and result shape and never print a result.

## Library Under Test

The `Barometer.aar.build-info.txt` written by `scripts/build-native.sh android` at the current pin:

```text
artifact: Barometer.aar
targets: android/arm64,android/amd64
commit: c49695c9406d64d34d247de827ae2b0343634640
go: go1.26.0
gomobile: v0.0.0-20260821190718-4776eadac327
ndk: 29.0.14206865
android-api: 21 (native), 35 (Java bootclasspath)
javac: javac 17.0.18
slices:
  jni/arm64-v8a/libgojni.so
  jni/x86_64/libgojni.so
status: compiled only; not a release, not platform support
```

The API 35 row and the trust-store probes below were recorded with a library built at the earlier pin `52789565c85f9d14d7b2ce1d5e42f85b11cea753`, whose build-info differs from the one above only in the `commit` line.

## Instrumented Tests at the Current Pin

Run on 2026-11-05 from `example/android` with `./gradlew :barometer_flutter:connectedDebugAndroidTest` after a clean build, with the library above. The `arm64-v8a` `libgojni.so` packaged in the test APK is byte-identical to the one in the built AAR after `llvm-strip --strip-unneeded`, which is what the Android Gradle plugin applies. The tests are `AdapterDeviceTest` (6 tests) and `RecordStoreDeviceTest` (7 tests), described below. No test or glue code changed for this run, and the trust-store probe was not repeated.

| Target | Model | OS | ABI | Instrumented tests |
|---|---|---|---|---|
| Emulator, `system-images;android-21;default;arm64-v8a` | Android SDK built for arm64 | Android 5.0.2 (API 21) | `arm64-v8a` | 13 of 13 passed |
| Emulator, `system-images;android-24;default;arm64-v8a` | Android SDK built for arm64 | Android 7.0 (API 24) | `arm64-v8a` | 13 of 13 passed |

As before, these runs use the plugin's own test APK, not a Flutter application.

## Method Channel

Run on 2026-11-05 from `example/android` with `./gradlew :barometer_flutter:connectedDebugAndroidTest` and the library above, after the Dart API and the Android channel host were added. Besides the 13 tests above, `ChannelDeviceTest` (4 tests) drives `BarometerHost`, the channel handler, against the facade with the test package's trusted local document: no client before `initialize`, the lifecycle through the channel, native installation of an embedded asset and of a remote package with admission by Go, and refusal of trust inputs as channel arguments. It contacts no network.

| Target | Model | OS | ABI | Instrumented tests |
|---|---|---|---|---|
| Emulator, `system-images;android-21;default;arm64-v8a` | Android SDK built for arm64 | Android 5.0.2 (API 21) | `arm64-v8a` | 17 of 17 passed |
| Emulator, `system-images;android-24;default;arm64-v8a` | Android SDK built for arm64 | Android 7.0 (API 24) | `arm64-v8a` | 17 of 17 passed |
| Emulator, `system-images;android-35;default;arm64-v8a` | Android SDK built for arm64 | Android 15 (API 35) | `arm64-v8a` | 17 of 17 passed |

These runs use the plugin's own test APK; the channel host is called directly, not through a Flutter engine.

## DEV-725: Adapters, TCP-01 and DNS-01

Run on 2026-11-04 from `example/android` with `./gradlew :barometer_flutter:connectedDebugAndroidTest`, which runs the plugin's instrumented tests: `AdapterDeviceTest` (6 tests) and `RecordStoreDeviceTest` (7 tests, from DEV-724). `AdapterDeviceTest` initializes a facade client with the Android adapters, the state store and a synthetic trusted local document, runs TCP-01 to `1.1.1.1:443` and DNS-01 for `example.org` through the platform resolver, each through `StartRun`, `NextBundle` and `AcknowledgeBundle`, and checks that the coarse access state holds only the fixed values and that no result retains the target.

The trust-store check ran a Go probe built from Go 1.26.0 for `android/arm64` and run with `adb shell`. It loads `x509.SystemCertPool`, verifies every certificate found in the platform store directories against it, and checks that a leaf issued by a synthetic CA generated at run time is rejected as an unknown authority, while the same leaf verifies against that CA alone. The probe is not part of either repository.

| Target | Model | OS | ABI | Instrumented tests | Trust-store probe |
|---|---|---|---|---|---|
| Emulator, `system-images;android-21;default;arm64-v8a` | Android SDK built for arm64 | Android 5.0.2 (API 21) | `arm64-v8a` | 13 of 13 passed at `5278956`; superseded by the run above | System store found (all certificates verify); synthetic CA rejected |
| Emulator, `system-images;android-24;default;arm64-v8a` | Android SDK built for arm64 | Android 7.0 (API 24) | `arm64-v8a` | 13 of 13 passed at `5278956`; superseded by the run above | System store found; synthetic CA rejected |
| Emulator, `system-images;android-35;default;arm64-v8a` | Android SDK built for arm64 | Android 15 (API 35) | `arm64-v8a` | 13 of 13 passed at `5278956` | System store found, and every certificate in the updatable store `/apex/com.android.conscrypt/cacerts` verifies; synthetic CA rejected |
| Physical device | Not run | | | | |

No project-owned physical device was available for this run, so the `arm64-v8a` device row of the validation plan is open.

The API 21 run covers the native library alone: it runs the plugin's own test APK, not a Flutter application, which cannot run below API 24. The API 24 and API 35 runs use the same test APK; no Flutter application calls the adapters yet.

## Observed Behavior and Gaps

- **Trust store.** Go 1.26 loads `/system/etc/security/cacerts` and, on Android, also `/data/misc/keychain/certs-added`, the user-installed CA directory. Android 7 and later do not trust user-installed CAs for applications by default, so Go's pool may be wider than the application's platform policy. Go does not read the updatable store `/apex/com.android.conscrypt/cacerts` of API 34 and later; on the API 35 emulator the two stores held the same certificates, which an updated device need not. The probe ran as the shell user, not inside the application sandbox, and no user CA was installed. Handling of user-installed roots is open for M3 (DEV-708).
- **Probe build on API 21.** A probe linked by Go's internal linker (`CGO_ENABLED=0`) crashed at start on the API 21 emulator; one built with the NDK `aarch64-linux-android21-clang` ran. The gomobile library is built with the NDK and loaded on API 21 in the instrumented tests.
- **Network on API 21 to 22.** The platform has no active-network handle there. The adapter reads IPv4 and IPv6 from the single connected network of the active type and reports them `unknown` otherwise, which fails closed for TCP-01.
- **Resolver.** An unknown name is reported as `resolver_error`, never `no_data`, because the platform does not separate it from a resolver failure before API 29. A lookup abandoned at its deadline keeps its worker thread until the platform returns.
- **Not covered.** A physical device, VPN, validation and suspension signals, the network-change matrix, lifecycle and cancellation on devices, protected linkage keys (M3, DEV-708), the Dart API and the umbrella build (DEV-706), and x86_64 emulators.
