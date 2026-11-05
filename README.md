# Barometer Flutter

`barometer_flutter` is the planned public Flutter plugin for Barometer, an embeddable library for privacy-preserving measurement of internet censorship and circumvention effectiveness from mobile devices. The core is [`barometer-go`](https://github.com/tv-rain/barometer-go), bound to Android and iOS with gomobile.

## Current Status

The plugin builds for Android and iOS and links the native Barometer library. It has a public Dart API, [`BarometerClient`](#dart-api), and a method channel that drives the facade client with the platform adapters and state store on Android and on iOS. The example application does not run a measurement yet. Nothing runs at plugin registration or application launch. The package is not published (`publish_to: none`); publication is planned with the Phase 5 release.

A successful build establishes compiler and linker compatibility for the recorded inputs only. It does not establish loading or execution on a device, emulator or simulator, conformance, safety, or support for any platform version. Barometer Draft `0.1.0` status is unchanged.

## Platform Constraints

| Setting | Value |
|---|---|
| Dart SDK | `^3.8.1` |
| Android | minSdk 21, compileSdk 35 |
| iOS | 15.0 |

These follow the supported platform matrix of [decision 0014](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0014-gomobile-facade-and-platform-matrix.md#supported-platform-matrix). Being inside the matrix is a target, not a support claim. The matrix's Android API 21 applies to the native library and to non-Flutter hosts. A Flutter application cannot run below API 24: Flutter 3.47.8 sets 24 as the default application minSdk, warns below 24 and fails the build below 23. The plugin keeps minSdk 21 only to match the native library it packages, so it adds no constraint of its own.

## Dart API

```dart
final client = BarometerClient();          // no native work
await client.initialize({});               // creates the native client
final task = await client.admitTask(embeddedTask('tcp-check'));
final run = await client.startRun(task);
final state = await client.runState(run); // {'state': 'active'} or {'state': 'terminal'}
final bundle = await client.nextBundle();  // Bundle? with id and exact bytes
if (bundle != null) await client.acknowledgeBundle(bundle.id);
await client.close();
```

| Call | Result | Facade call |
|---|---|---|
| `BarometerClient()` | | None: construction makes no channel call, loads no library and opens no storage |
| `initialize(Map config)` | | Creates the record store and facade client if there is none, then `Initialize` with the configuration as JSON text |
| `admitTask(TaskSource)` | `TaskHandle` | `InstallEmbeddedTask` or `InstallRemoteTask`, then `AdmitTask` |
| `startRun(TaskHandle)` | `RunHandle` | `StartRun` |
| `runState(RunHandle)` | `Map`: `{'state': 'active'}` or `{'state': 'terminal'}` | `RunState` |
| `cancelRun(RunHandle)` | | `CancelRun` |
| `nextBundle()` | `Bundle?` | `NextBundle`; null when none is pending |
| `acknowledgeBundle(String id)` | | `AcknowledgeBundle` |
| `setProxy(Map)` / `clearProxy()` | | `SetProxy` with the map as JSON text / `ClearProxy` |
| `clearMeasurementData()` | | `ClearMeasurementData` |
| `close()` | | `Close`, then closes the record store; succeeds without a client |

Task sources:

- `embeddedTask(name)`: the task shipped with the application as `barometer/tasks/<name>.json`: on Android the asset of that path (`src/main/assets/barometer/tasks/` of the application module), on iOS the resource of that path in the application bundle (a `barometer` folder reference in the Runner target). Native code reads it and installs it with the embedded issuer of the trusted local document. A name is 1 to 64 lowercase ASCII letters, digits, `_` and `-`, starting with a letter or digit, so it cannot leave that directory.
- `installRemoteTask(Uint8List signedPackage)`: a signed remote task package, passed unchanged. Native code installs it as a remote delivery record and admits it; Go verifies the signature against the issuer keys of the trusted local policy ([decision 0011](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0011-library-verified-signed-remote-tasks.md)). Each admission installs a new single-use record.

The embedded issuer is the one issuer of the trusted local document's policy that has no trusted key. An issuer with a key can sign remote packages, while a keyless issuer can only be reached through an embedded delivery. If the policy has no keyless issuer or more than one, embedded tasks are not installed and `admitTask` fails with `delivery_unavailable`.

`TaskHandle` and `RunHandle` are opaque and valid for one client generation. A `Bundle` carries its `id` and the exact UTF-8 JSON `bytes` Barometer stored; transport the bytes unchanged. `toJson()` decodes them.

A failure throws `BarometerException(code)`. The code is the facade's code string, such as `not_initialized`, `already_initialized`, `handle_unavailable`, `run_not_due`, `bundle_unavailable`, `clearing_incomplete` or an admission class such as `task_source_unauthenticated`, and carries no other detail. The native layer raises some of these codes itself, and adds two of its own, `invalid_arguments` and `native_error`:

| Code | Raised when |
|---|---|
| `not_initialized` | A call other than `initialize` or `close` is made while no native client exists |
| `trust_invalid` | `initialize` cannot read the trusted local document `barometer/trust.json` from the Android assets or the iOS application bundle, or the facade rejects it |
| `storage_unavailable` | `initialize` cannot open the record store, for example because another owner holds it, or `close` cannot close it |
| `delivery_unavailable` | The embedded task file is missing, unreadable, empty or larger than 131,072 bytes, or the document names no unique embedded issuer |
| `client_closed` | A call arrives after the Flutter engine detached the plugin |
| `invalid_arguments` | A channel call has malformed arguments, or a configuration map holds a value that is not JSON. The Dart API sends no malformed call |
| `native_error` | An unexpected native failure, or a bundle without an identifier. Its detail is not forwarded |

`initialize` keeps the client it created when it fails, so the host can retry it, or recover with `clearMeasurementData` after `clearing_incomplete`. `clearMeasurementData` needs a native client, so call `initialize` first; it fails with `not_initialized` otherwise. A `close` that fails keeps the client so that it can be retried. The native client belongs to the Flutter engine: every `BarometerClient` of one engine drives the same native client, and detaching the engine closes it.

## Channel Contract

The method channel is `com.tvrain.barometer_flutter/client` with Flutter's standard method codec. Every argument is JSON text, an opaque handle, a bundle identifier, an embedded task name or signed package bytes. None is a trust input: no call installs a local policy, approval, trust root, issuer association or adapter, and the issuer of an embedded task and the trusted local document come only from the application package.

| Method | Arguments | Result |
|---|---|---|
| `initialize` | `{config: String}` | null |
| `admitTask` | `{source: 'embedded', name: String}` or `{source: 'remote', package: Uint8List}` | task handle `String` |
| `startRun` | `{task: String}` | run handle `String` |
| `runState` | `{run: String}` | `{state: String}` |
| `cancelRun` | `{run: String}` | null |
| `nextBundle` | none | bundle bytes `Uint8List`, or null |
| `acknowledgeBundle` | `{id: String}` | null |
| `setProxy` | `{proxy: String}` | null |
| `clearProxy`, `clearMeasurementData`, `close` | none | null |

The native handler accepts an argument map only when its keys are exactly those listed, rejects anything else with `invalid_arguments`, and reports any other method as not implemented. JSON texts are bounded to 65,536 characters, handles and identifiers to 256 and packages to 131,072 bytes; the facade applies its own, smaller bounds. Errors are `PlatformException`s whose code is the error code above, with no message or details.

On Android, `BarometerFlutterPlugin` only registers the handler. Each call runs on one of at most four worker threads, never on the UI thread, and its answer is posted to the main looper. The record store is the plugin's `default` scope.

On iOS, `BarometerFlutterPlugin.swift` likewise only registers the handler, and `BarometerHost.swift` implements the same contract with the same arguments, results and error codes. Each call runs on an operation queue of at most four concurrent operations, never on the main thread, and its answer is delivered on the main queue. The record store is the `default` scope under Application Support, and detaching the engine closes the client.

Changing the Dart API or this contract is a reviewed public-API change.

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

## Apple State Storage

The Apple backend of the `Records` port (`RecordStore.swift`) has the same semantics as the Android one: one file per record, temporary-file-and-rename writes, arrival-order calls on one serial queue bounded by `timeoutMillis`, withdrawal of calls still queued at their deadline or at close, refusal of other puts while a clearing marker is stored, one owner per scope (an in-process registry and a `flock` that also refuses other processes) and failure instead of blocking on the main thread. Records live under the application's own `Library/Application Support/barometer/<scope>/records`, never in a shared or app-group container, and the `barometer`, scope and records directories are marked `isExcludedFromBackup`, so they stay out of iCloud and device backups. Files keep the platform's default data-protection class. A key the store does not hold reaches the facade as `BarometermobileNewAbsentRecordValue()`, because Swift cannot return nil from the generated throwing `get`. Durability across power loss or a full disk, OS or device clearing and reinstallation are not yet validated.

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

No adapter reads an address, network name, operator, subscriber, account or device identifier into a value it returns. The linkage key store is not installed, so linkage is disabled. The trusted local document is read only from the application asset `barometer/trust.json` by `TrustDocument`; it is never taken from Dart. The method-channel host creates the client at `initialize` (see [Channel Contract](#channel-contract)). Validation evidence is in [docs/android-validation.md](docs/android-validation.md).

## Apple Adapters

The same callbacks have Apple backends in Swift over Foundation, UIKit and the Network framework; `BarometerBinding.newClient(store:trust:)` wraps them in the facade protocols with a `RecordStore` and creates the client. It starts an `NWPathMonitor` and does nothing else; close the returned client before the store. Facade calls must not be made on the main thread; the method-channel host creates the client at `initialize` and makes every facade call on its worker queue (see [Channel Contract](#channel-contract)).

| Port | Apple source | Values |
|---|---|---|
| `Clock` | `Date()` (`CLOCK_REALTIME`) | Used as trusted time when positive; a time that is not positive is unavailable, with no fallback. Manual time cannot be detected (see below) |
| `Consent` | None yet | Always `absent`, so a measurement that requires consent never runs |
| `Device` | `UIDevice` battery level and state, read on the main queue with battery monitoring turned on for the reading and then restored | Battery percentage and charging, each only when known; unknown if the main queue does not answer within the deadline |
| `TimeZone` | `TimeZone.current` | IANA identifier |
| `Network` | `NWPathMonitor` | Type `wifi`, `cellular`, `ethernet` or `other`; IPv4 and IPv6 `yes` or `no` from the path or, where the path does not report them, from the primary interface's non-link-local addresses; VPN, validation and captive portal `unknown`. The generation changes only when these values, the primary interface or the gateways change. CoreTelephony is not used |
| `SystemResolver` | `getaddrinfo` on its own thread, at most four at once | Canonical addresses of the requested family; any failure, including an unknown name, is an error |

As on Android, no adapter returns an address, network name, interface name, operator, subscriber, account or device identifier, the linkage key store is not installed, and the trusted local document is read only from the application bundle resource `barometer/trust.json` by `TrustDocument`. Validation evidence is in [docs/apple-validation.md](docs/apple-validation.md).

Known limitation: iOS has no public API that reports whether the clock is set automatically ("Set Automatically"), so manual time cannot be detected and the system wall clock is used as trusted time whenever it is positive. This is weaker than the Android adapter, which reports the clock unavailable unless automatic time is on. A user-set or otherwise wrong clock is therefore accepted, which leaves the residual risk of [a wrong or manipulated device clock](https://github.com/tv-rain/barometer-spec/blob/main/library/task-trust.md#residual-risks) named by the specification: expiry, key validity and retention decisions are made against that clock.

## Build and Validate

Requires Flutter with Dart 3.8.1 or later; CI uses Flutter 3.47.8. iOS builds also need CocoaPods.

```sh
bash scripts/build-native.sh android
bash scripts/build-native.sh apple
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
cd example
flutter test
flutter build apk --debug
flutter build ios --debug --no-codesign
flutter build ios --debug --simulator
cd android
./gradlew :barometer_flutter:testDebugUnitTest
./gradlew :barometer_flutter:connectedDebugAndroidTest   # needs a running emulator or device
```

The Swift store, adapter and channel XCTests run in `example/ios` on a simulator after the iOS simulator build, and a script checks the store's atomicity under process kill. CI does not run them. The channel tests contact no network. The adapter tests contact `1.1.1.1:443` and resolve `example.org` once each:

```sh
cd example/ios
xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination 'platform=iOS Simulator,id=<udid>' -only-testing:RunnerTests -parallel-testing-enabled NO -collect-test-diagnostics never
cd ../..
bash scripts/ios-record-store-kill-test.sh <udid>
```

CI runs the same steps on `ubuntu-24.04` for Android and `macos-15` for iOS, except the instrumented tests, which need an emulator or device.

## Repository Boundaries

This repository owns the Flutter API, the native Kotlin and Swift glue and the plugin packaging. Library behavior is defined by the public [`barometer-spec`](https://github.com/tv-rain/barometer-spec) and implemented in `barometer-go`. Cross-project decisions live in the [Barometer coordination repository](https://github.com/tv-rain/barometer).

## License

The code and documentation are distributed under the [MIT License](LICENSE). The Barometer name and logo are covered by the [trademark notice](TRADEMARKS.md).
