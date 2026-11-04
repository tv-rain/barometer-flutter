# Barometer Flutter

`barometer_flutter` is the planned public Flutter plugin for Barometer, an embeddable library for privacy-preserving measurement of internet censorship and circumvention effectiveness from mobile devices. The core is [`barometer-go`](https://github.com/tv-rain/barometer-go), bound to Android and iOS with gomobile.

## Current Status

This repository is a skeleton. The plugin builds for Android and iOS and links the native Barometer library, but it has no Dart API, opens no platform channel and calls no Barometer code at registration or launch. The Android native adapters and state store exist and are exercised by instrumented tests only; the Dart API, the iOS adapters and the wiring between them arrive later in Phase 3 milestone M2. The package is not published (`publish_to: none`); publication is planned with the Phase 5 release.

A successful build establishes compiler and linker compatibility for the recorded inputs only. It does not establish loading or execution on a device, emulator or simulator, conformance, safety, or support for any platform version. Barometer Draft `0.1.0` status is unchanged.

## Platform Constraints

| Setting | Value |
|---|---|
| Dart SDK | `^3.8.1` |
| Android | minSdk 21, compileSdk 35 |
| iOS | 15.0 |

These follow the supported platform matrix of [decision 0014](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0014-gomobile-facade-and-platform-matrix.md#supported-platform-matrix). Being inside the matrix is a target, not a support claim. The matrix's Android API 21 applies to the native library and to non-Flutter hosts. A Flutter application cannot run below API 24: Flutter 3.47.6 sets 24 as the default application minSdk, warns below 24 and fails the build below 23. The plugin keeps minSdk 21 only to match the native library it packages, so it adds no constraint of its own.

## Native Library

The plugin does not track native binaries in Git. `scripts/build-native.sh` fetches `barometer-go` at the commit in `scripts/barometer-go.revision`, runs its `make mobile-android` or `make mobile-apple`, and writes the result where the plugin expects it:

| Target | Output | Consumed by |
|---|---|---|
| `android` | `android/libs/Barometer.aar` | `android/build.gradle.kts` |
| `apple` | `ios/Frameworks/Barometer.xcframework` | `ios/barometer_flutter.podspec` |

Each output has a `.build-info.txt` file that records the `barometer-go` commit and toolchain versions. The prerequisites are those of the [`barometer-go` native build](https://github.com/tv-rain/barometer-go/blob/main/docs/mobile-build.md): Go 1.26, and JDK 17, Android SDK platform 35 and NDK `28.2.13676358` for Android, or full Xcode for Apple.

To build from a local `barometer-go` checkout instead, set `BAROMETER_GO_DIR`. A local build embeds the checkout path in the library's Go build information, so do not share it outside the team.

The Kotlin and Swift sources name gomobile-generated classes only in `BarometerBinding.kt` and `BarometerBinding.swift`. They name the `barometermobile` facade ([decision 0014](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0014-gomobile-facade-and-platform-matrix.md)), for example `barometermobile.Records` and `BarometermobileClient`. In the TV Rain application's umbrella build, the generated classes come from the umbrella artifact instead of the standalone library.

## Android State Storage

The Android backend of the facade's `Records` port (`RecordStore.kt`) keeps the replay records, run ledger, pending bundles and clearing marker of one storage scope as one file per record under the application's `no_backup` directory (`Context.getNoBackupFilesDir()`), which Android excludes from cloud backup and device-to-device transfer. The plugin therefore adds no backup rules to the host application's manifest. A put writes a temporary file and renames it over the record, so a process kill leaves the earlier or the new value. All calls run in arrival order on one worker thread and wait at most their `timeoutMillis`; a call still queued at its deadline never runs, a running one finishes before any later call, and the caller gets an error in both cases. The facade hands a store's calls over one at a time in the order Go issues them, and never one whose deadline has passed, so arrival order is issue order and a write abandoned before a clear cannot arrive after it. While a clearing marker is stored, other puts are refused. A scope has one owner across threads and processes, and calls on the UI thread fail instead of blocking it. Durability across power loss or a full disk, OS or device clearing and reinstallation are not yet validated.

## Android Adapters

The remaining facade callbacks that `Initialize`, TCP-01 and DNS-01 need have Android backends in plain Kotlin over the Android SDK; `BarometerBinding.newClient(context, store, trust)` wraps them in the facade interfaces with a `RecordStore` and creates the client. It registers a network callback and does nothing else; close the returned client before the store.

| Port | Android source | Values |
|---|---|---|
| `Clock` | `System.currentTimeMillis()` while `Settings.Global.AUTO_TIME` is on | Unavailable with manual time; no fallback |
| `Consent` | None yet | Always `absent`, so a measurement that requires consent never runs |
| `Device` | Sticky `ACTION_BATTERY_CHANGED` broadcast | Battery percentage and charging, each only when known |
| `TimeZone` | `java.util.TimeZone.getDefault()` | IANA identifier |
| `Network` | `ConnectivityManager` default network | Type `wifi`, `cellular`, `ethernet` or `other`; IPv4 and IPv6 `yes` or `no` from the link's address families; VPN, validation and captive portal `unknown`. The generation changes only when the default network or these values change |
| `SystemResolver` | `InetAddress.getAllByName` on a worker thread | Canonical addresses of the requested family; any failure, including an unknown name, is an error |

No adapter reads an address, network name, operator, subscriber, account or device identifier into a value it returns. The linkage key store is not installed, so linkage is disabled. The trusted local document is read only from the application asset `barometer/trust.json` by `TrustDocument`; it is never taken from Dart. Wiring the client into the plugin and the Dart API is later work. Validation evidence is in [docs/android-validation.md](docs/android-validation.md).

## Build and Validate

Requires Flutter with Dart 3.8.1 or later; CI uses Flutter 3.47.6. iOS builds also need CocoaPods.

```sh
bash scripts/build-native.sh android
bash scripts/build-native.sh apple
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
cd example
flutter test
flutter build apk --debug
flutter build ios --debug --no-codesign
flutter build ios --debug --simulator
cd android
./gradlew :barometer_flutter:testDebugUnitTest
./gradlew :barometer_flutter:connectedDebugAndroidTest   # needs a running emulator or device
```

CI runs the same steps on `ubuntu-24.04` for Android and `macos-15` for iOS.

## Repository Boundaries

This repository owns the Flutter API, the native Kotlin and Swift glue and the plugin packaging. Library behavior is defined by the public [`barometer-spec`](https://github.com/tv-rain/barometer-spec) and implemented in `barometer-go`. Cross-project decisions live in the [Barometer coordination repository](https://github.com/tv-rain/barometer).

## License

The code and documentation are distributed under the [MIT License](LICENSE). The Barometer name and logo are covered by the [trademark notice](TRADEMARKS.md).
