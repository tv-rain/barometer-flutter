# Barometer Flutter

`barometer_flutter` is the planned public Flutter plugin for Barometer, an embeddable library for privacy-preserving measurement of internet censorship and circumvention effectiveness from mobile devices. The core is [`barometer-go`](https://github.com/tv-rain/barometer-go), bound to Android and iOS with gomobile.

## Current Status

This repository is a skeleton. The plugin builds for Android and iOS and links the native Barometer library, but it has no Dart API, opens no platform channel and calls no Barometer code. The Dart API and the native adapters arrive in Phase 3 milestone M2. The package is not published (`publish_to: none`); publication is planned with the Phase 5 release.

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

The Kotlin and Swift sources name gomobile-generated classes only in `BarometerBinding.kt` and `BarometerBinding.swift`. Today these are the root package's default names (`barometer.Client`, `BarometerClient`). When `barometer-go` adds the `barometermobile` facade, these files change to the facade's names. In the TV Rain application's umbrella build, the generated classes come from the umbrella artifact instead of the standalone library.

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
```

CI runs the same steps on `ubuntu-24.04` for Android and `macos-15` for iOS.

## Repository Boundaries

This repository owns the Flutter API, the native Kotlin and Swift glue and the plugin packaging. Library behavior is defined by the public [`barometer-spec`](https://github.com/tv-rain/barometer-spec) and implemented in `barometer-go`. Cross-project decisions live in the [Barometer coordination repository](https://github.com/tv-rain/barometer).

## License

The code and documentation are distributed under the [MIT License](LICENSE). The Barometer name and logo are covered by the [trademark notice](TRADEMARKS.md).
