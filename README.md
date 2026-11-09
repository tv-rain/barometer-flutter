# Barometer Flutter

`barometer_flutter` is the planned public Flutter plugin for Barometer, an embeddable library for privacy-preserving measurement of internet censorship and circumvention effectiveness from mobile devices. The core is [`barometer-go`](https://github.com/tv-rain/barometer-go), bound to Android and iOS with gomobile.

## Current Status

The plugin builds for Android and iOS and links the native Barometer library. It has a public Dart API, [`BarometerClient`](#dart-api), and a method channel that drives the facade client with the platform adapters and state store on Android and on iOS. The [example application](#example-application) runs synthetic embedded TCP-01 and DNS-01 tasks from Dart when a button is pressed. Nothing runs at plugin registration or application launch. The package is not published (`publish_to: none`); publication is planned with the Phase 5 release.

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
| `initialize(Map config)` | | Creates the record store and facade client if there is none, then `Initialize` with the configuration as JSON text. On Android it reads the trusted local document again and replaces the client when the document changed ([Android Host Policy](#android-host-policy)) |
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
| `trust_invalid` | `initialize` cannot read the trusted local document from the Android asset the host registered (by default `barometer/trust.json`) or from `barometer/trust.json` in the iOS application bundle, or the facade rejects it |
| `policy_rejected` | Android only: `initialize` finds a trusted local document that differs from the active one, or from the last one activated in the process, without a strictly greater `policy_generation` ([Android Host Policy](#android-host-policy)) |
| `storage_unavailable` | `initialize` cannot open the record store, for example because another owner holds it, or `close` cannot close it |
| `delivery_unavailable` | The embedded task file is missing, unreadable, empty or larger than 131,072 bytes, or the document names no unique embedded issuer |
| `client_closed` | A call arrives after the Flutter engine detached the plugin |
| `invalid_arguments` | A channel call has malformed arguments, or a configuration map holds a value that is not JSON. The Dart API sends no malformed call |
| `native_error` | An unexpected native failure, or a bundle without an identifier. Its detail is not forwarded |

`initialize` keeps the client it created when it fails, so the host can retry it, or recover with `clearMeasurementData` after `clearing_incomplete`. `clearMeasurementData` needs a native client, so call `initialize` first; it fails with `not_initialized` otherwise. A `close` that fails keeps the client so that it can be retried. The native client belongs to the Flutter engine: every `BarometerClient` of one engine drives the same native client, and detaching the engine closes it, which cancels its active runs (recorded as `cancelled_by_host`) within the lifecycle deadline and releases the storage scope. A host that offers a user-visible action promising to remove local data, such as "clear local data" or "reset privacy data", must call `clearMeasurementData` from it; Barometer does not infer account semantics. The example application has no such action.

## Example Application

The example in `example/` runs TCP-01 and DNS-01 from Dart through `BarometerClient` with synthetic configuration. Nothing runs at launch. Pressing **Run tcp-01** or **Run dns-01** initializes Barometer (or continues after `already_initialized`), admits the embedded task, starts a run, polls `runState` until it is terminal, reads the oldest pending bundle and acknowledges it (`example/lib/flow.dart`). The page shows the lifecycle steps and the result shape (result count, execution state, observation types, platform), never the measurement outcome. TCP-01 contacts `1.1.1.1:443` once and DNS-01 resolves `example.org` once.

The synthetic files live in `example/barometer/`:

| File | Content |
|---|---|
| `trust.json` | A `barometer-trust/1` document with one keyless issuer, `example-embedded-issuer`, permitted TCP-01 and DNS-01 at low risk on the direct path, without consent, against two registered targets: `1.1.1.1:443` over TCP and `example.org`, and listing the two tasks below as release-reviewed by their SHA-256 digests. No keys, approvals, endpoints or linkage |
| `tasks/tcp-01.json`, `tasks/dns-01.json` | One-run embedded tasks for those targets |

They contain no secret, participant endpoint or personal data. Both tasks are one-time embedded tasks without `not_after`: repeat mode `none` and `max_runs` 1, which Barometer admits under the embedded one-time exception of the registered limits. Barometer grants that exception only to a task that the trusted local document lists in `release_reviewed_tasks` by its embedded issuer and the SHA-256 digest of its exact bytes; any other embedded task without `not_after` is rejected as `task_schema_invalid`. The exception leaves two obligations with the host: release review fixes each such task to one run, and the host does not persist the task across application updates. The example ships its tasks in the application bundle and keeps no copy elsewhere. The files carry placeholders that the build fills: `__BUILD_STAMP__` in each task becomes the build time in Unix seconds, which is part of the task identifier so that a rebuilt task never conflicts with a retained replay record; in the trusted local document, `__EXPIRES_AT__` becomes the build time plus six days (the target registration expiry) and `__TASK_SHA256_<name>__` the digest of the written `tasks/<name>.json`, so the listing matches the exact bytes in the package. On Android the `barometerExampleAssets` Gradle task in `example/android/app/build.gradle.kts` writes them as generated assets; on iOS the **Generate Barometer Resources** build phase of the Runner target writes them into the application bundle. Because the target registrations expire, an example build is usable for six days. Each task runs once per build: pressing a button again admits the same task as a redelivery, whose run produces no new bundle, and the page reports `no bundle is pending`. A host application ships reviewed files instead; this generation exists only for the example.

`example/integration_test/barometer_flow_test.dart` presses both buttons and checks that each run ends terminal with one completed result of the expected observation type and no pending bundle after the acknowledgement. Run it on an emulator or simulator:

```sh
cd example
flutter test integration_test -d <device-id>
```

### Measurement Fixtures (Android)

`example/barometer-fixtures/` holds a second synthetic set for evidence runs only: a trusted local document and nine one-time embedded tasks, one for each registered measurement (TCP-01, DNS-01, DNS-03, DNS-04, TLS-01, HTTP-01, NET-01, NET-03 and NET-05), all on the direct path. Every remote target is the public literal `8.8.8.8` or the name `fixture.example.org` bootstrapped to it, and DNS queries ask for `example.org`. `scripts/android-measurement-fixtures.sh start` prepares one emulator for them: it generates a CA and a server certificate for `fixture.example.org` and `8.8.8.8` (the CA's private key is deleted once the certificate is issued), starts `scripts/measurement_fixtures.py` on the host's loopback interface (DNS over UDP and TCP, HTTP, HTTPS with a DNS-over-HTTPS endpoint, and DNS over TLS, all with fixed synthetic answers), makes the CA the emulator's only trust root through `scripts/android-trust-scenario.sh`, and adds packet-filter rules that send the emulator's TCP and UDP traffic for `8.8.8.8` on ports 53, 80, 443 and 853 to the host and reject any other traffic for that address, so no task contacts it. `stop` undoes all of it. The fixtures serve one emulator at a time. `example/integration_test/measurements_test.dart` then runs the nine tasks from Dart and checks each result's execution state, observation types and outcome; it is skipped unless the build carries the fixture set:

```sh
bash scripts/android-measurement-fixtures.sh start     # emulators only; needs adb root, openssl and python3
cd example
ORG_GRADLE_PROJECT_barometerExampleAssets=barometer-fixtures \
  flutter test integration_test/measurements_test.dart -d <emulator-id> \
  --dart-define=BAROMETER_MEASUREMENT_FIXTURES=true
cd .. && bash scripts/android-measurement-fixtures.sh stop
```

Add `ORG_GRADLE_PROJECT_barometerUmbrellaArtifact` and `ORG_GRADLE_PROJECT_barometerUmbrellaRepository` for the umbrella build. The fixture set is never part of an ordinary build: `barometerExampleAssets` accepts only `barometer` (the default) and `barometer-fixtures`.

## Channel Contract

The method channel is `com.tvrain.barometer_flutter/client` with Flutter's standard method codec. Every argument is JSON text, an opaque handle, a bundle identifier, an embedded task name or signed package bytes. None is a trust input: no call installs a local policy, approval, trust root, issuer association or adapter, and the issuer of an embedded task and the trusted local document come only from the application package.

TLS trust roots are chosen by the Go library, not by the host. On Android they are the platform's updatable or system CA store, never user-installed CAs, even when the application's network security configuration trusts them for its own traffic; without a loadable store, TLS-dependent tasks are rejected as `task_unsupported` ([decision 0016](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0016-android-trust-root-set.md)).

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

The Kotlin and Swift sources name gomobile-generated classes only in `BarometerBinding.kt` and `BarometerBinding.swift`. They name the `barometermobile` facade ([decision 0014](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0014-gomobile-facade-and-platform-matrix.md)), for example `barometermobile.Records` and `BarometermobileClient`.

## Standalone and Umbrella Modes

gomobile artifacts cannot be combined in one application: each carries its own copy of the gomobile runtime. An application that ships its own gomobile library binds `barometermobile` into that library instead, in one `gomobile bind` command with its own Go packages (an umbrella build, see [Umbrella Builds](https://github.com/tv-rain/barometer-go/blob/main/docs/mobile-build.md#umbrella-builds) for the build properties it must keep). The plugin builds in one of two modes:

| Mode | Native library | Selected by |
|---|---|---|
| Standalone (default) | The plugin's own `Barometer.aar` and `Barometer.xcframework`, built by `scripts/build-native.sh` | Nothing to set |
| Umbrella | The host application's umbrella artifact; the plugin ships no native library and no gomobile runtime | The Gradle property `barometerUmbrellaArtifact` on Android; the `Umbrella` subspec on iOS |

The Kotlin and Swift glue is the same in both modes. The facade's Java package `barometermobile` and Objective-C names `Barometermobile…` do not depend on the artifact, so only the iOS module import in `BarometerBinding.swift` is conditional. The umbrella artifact must bind the `barometermobile` package of the `barometer-go` commit the plugin was written for (`scripts/barometer-go.revision`); a facade from another commit may not match the glue.

**Android.** Set `barometerUmbrellaArtifact` to the Maven coordinates (`group:name:version`) of the umbrella AAR, for example in the application's `android/gradle.properties`. The plugin then compiles against it with `compileOnly`, uses it in its own unit and instrumented tests, and neither registers nor depends on its own library. The application declares the repository that serves the AAR for all projects and packages the AAR once, through its own dependency or another plugin's.

**iOS.** The plugin compiles against the umbrella framework that another pod of the application vendors, and the application binary links the facade once. Set two variables for `pod install`, for example at the top of `ios/Podfile`, and link pods statically:

```ruby
ENV['BAROMETER_FLUTTER_UMBRELLA_POD'] = '<pod that vendors the umbrella framework>'
ENV['BAROMETER_FLUTTER_UMBRELLA_MODULE'] = '<module name of the umbrella framework>'
# inside the application target:
use_frameworks! :linkage => :static
```

With them set, `Umbrella` becomes the podspec's default subspec, which is the one a Flutter application's Podfile installs. It depends on the named pod and imports the facade through `ios/barometer_flutter/Umbrella/`, a small Clang module that includes `<module>/Barometermobile.objc.h`, so the plugin source does not name the host's module. Run `pod install` again after changing the variables. Dynamic frameworks are not supported in umbrella mode, because the plugin framework would have to link the facade itself.

**Example.** The example builds in either mode. In umbrella mode it stands in for the host with a local Maven repository on Android and the local pod `example/ios/umbrella` on iOS:

```sh
cd example
# Android: the AAR at <repo>/<group path>/<name>/<version>/<name>-<version>.aar, with a POM
flutter build apk --debug -P barometerUmbrellaArtifact=<group:name:version> -P barometerUmbrellaRepository=<repo>
# iOS: copy or link the umbrella XCFramework into ios/umbrella/Frameworks/ (not tracked)
export BAROMETER_FLUTTER_UMBRELLA_MODULE=<module name of the umbrella framework>
(cd ios && pod install)
flutter build ios --debug --simulator
```

The Gradle properties can also be passed as `ORG_GRADLE_PROJECT_barometerUmbrellaArtifact` and `ORG_GRADLE_PROJECT_barometerUmbrellaRepository`, which `flutter test integration_test` also honors. Umbrella mode has been built and its integration test run locally on an Android emulator, an iOS simulator and an iPhone against an umbrella artifact that binds `barometermobile` with other Go packages, and the measurement integration test on API 24 and API 35 emulators. The device build workflow builds the example in umbrella mode with the standalone library standing in for the umbrella artifact, and runs tests in standalone mode only.

## Android State Storage

The Android backend of the facade's `Records` port (`RecordStore.kt`) keeps the replay records, run ledger, pending bundles and clearing marker of one storage scope as one file per record under the application's `no_backup` directory (`Context.getNoBackupFilesDir()`), which Android excludes from cloud backup and device-to-device transfer. The plugin therefore adds no backup rules to the host application's manifest. A put writes a temporary file and renames it over the record, so a process kill leaves the earlier or the new value, and a put that fails on a full disk leaves the earlier one. Each scope's directory also holds `clearing.reserve`, 64 KiB of zero bytes that a put of a clearing marker deletes first, so that clearing can store its marker and complete on a full disk; the reserve is allocated again when no marker is stored or the scope is opened, if space allows. All calls run in arrival order on one worker thread and wait at most their `timeoutMillis`; a call still queued at its deadline never runs, a running one finishes before any later call, and the caller gets an error in both cases. The facade hands a store's calls over one at a time in the order Go issues them, and never one whose deadline has passed, so arrival order is issue order and a write abandoned before a clear cannot arrive after it. While a clearing marker is stored, other puts are refused. A scope has one owner across threads and processes, and calls on the UI thread fail instead of blocking it. Operating-system data clearing ("Clear storage" in Settings) removes the scope with the rest of the application's data; `scripts/android-clear-storage-check.sh` checks it on an emulator. Process kill and a full data partition are checked on emulators ([Android validation record](docs/android-validation.md#durability-full-disk-and-the-nine-measurements)), and so are uninstall and reinstall and backup and restore, which bring back no record ([Reinstall and Backup](docs/android-validation.md#reinstall-and-backup)); durability across power loss is not yet validated.

## Android Linkage Keys

From API 23 the backend of the facade's `LinkageKeyStore` port (`AndroidLinkageKeys.kt`) keeps one HMAC-SHA-256 key per storage scope in Android Keystore, under the alias `barometer-linkage-<scope>`. The key is created on the first derivation, never leaves Keystore and is never exported; derivation runs inside it. No StrongBox or hardware backing is required, so a device without a secure element, and every emulator, holds a software-backed key. Before API 23 Android Keystore cannot hold an HMAC key, so the adapter is not installed and result linkage stays disabled; nothing falls back to a key in memory or in a file.

A reinstall sentinel, the non-secret file `linkage-sentinel` in the scope's directory under the `no_backup` directory, ties the key to the current state. It is written before a key is created. A key found without it, after an interrupted deletion or from any earlier state, is deleted before use and replaced only when a derivation needs one. Deletion removes the key, then the sentinel, and creates nothing, so `clearMeasurementData` deletes both and a new key appears only when linkage is next needed. Keystore keys are not backed up and the sentinel lives in the `no_backup` directory, so neither is restored to another installation. `scripts/android-reinstall-backup-check.sh` checks this on an emulator: after uninstall and reinstall, and after `adb backup` or `bmgr` through the local transport and a restore, no key, sentinel or record is present and the first derivation uses a new key. Calls run in arrival order on one worker thread with the same deadline and withdrawal rules as the record store, so a derivation abandoned before a deletion cannot recreate the key after it.

## Apple State Storage

The Apple backend of the `Records` port (`RecordStore.swift`) has the same semantics as the Android one: one file per record, temporary-file-and-rename writes, arrival-order calls on one serial queue bounded by `timeoutMillis`, withdrawal of calls still queued at their deadline or at close, refusal of other puts while a clearing marker is stored, one owner per scope (an in-process registry and a `flock` that also refuses other processes) and failure instead of blocking on the main thread. Records live under the application's own `Library/Application Support/barometer/<scope>/records`, never in a shared or app-group container, and the `barometer`, scope and records directories are marked `isExcludedFromBackup`, so they stay out of iCloud and device backups. Files keep the platform's default data-protection class. A key the store does not hold reaches the facade as `BarometermobileNewAbsentRecordValue()`, because Swift cannot return nil from the generated throwing `get`. Uninstalling the application removes the container and the records with it; `scripts/ios-reinstall-check.sh` checks on a simulator that no record survives an uninstall and reinstall. Durability across power loss or a full disk and backup and restore are not yet validated.

## Apple Linkage Keys

The Apple backend of the `LinkageKeyStore` port (`AppleLinkageKeys.swift`) keeps one random 32-byte HMAC-SHA-256 key per storage scope as a Keychain generic password of the service `barometer-linkage` whose account is the scope name. The item is stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so a run in the background can derive after the first unlock and the key never moves to another device through a backup, and with `kSecAttrSynchronizable` false, so iCloud Keychain does not copy it. No access group is named, so the item is in the application's default access group, which stays private to the application unless the host application shares its first keychain access group with other applications or extensions; a host that does so must not ship that configuration with Barometer. The Keychain cannot compute an HMAC with a stored secret, so the key is read into memory for each derivation and dropped afterwards. It is created on the first derivation; if it cannot be stored with these attributes the derivation fails and linkage with it, with no fallback to another store.

Keychain items survive uninstalling the application, so a reinstall sentinel, the non-secret file `linkage-sentinel` in the scope's directory under Application Support, excluded from backup, ties the key to the current installation. It is written before a key is created. A key found without it, after a reinstall, a restored container or an interrupted deletion, is deleted before use and replaced only when a derivation needs one; a key that is missing, not 32 bytes, or stored with other attributes is replaced the same way. Deletion removes the key, then the sentinel, and creates nothing, so `clearMeasurementData` deletes both and a new key appears only when linkage is next needed. `BarometerBinding.newClient` installs the store for the record store's scope. Calls run in arrival order on one serial queue with the same deadline and withdrawal rules as the record store, so a derivation abandoned before a deletion cannot recreate the key after it. `scripts/ios-reinstall-check.sh` checks on a simulator that after uninstall and reinstall no record is present and the first derivation uses a new key although the earlier Keychain item survived.

## Lifecycle on iOS

The channel host wraps active runs in a `UIApplication` background task: the first `startRun` begins one, and it ends once no started run is still active as far as the host knows (a run leaves that set when `runState` reports it `terminal`, when it is cancelled, and when the client is cleared or closed). When the task's expiration handler runs, the operating system is about to suspend the application: the host reports suspension to the `Network` adapter, which ends an active attempt as `platform_suspended` through the access-generation watch, cancels every run it tracks, so the attempt is recorded as `cancelled_by_host` if the suspension did not end it first, and ends the task within two seconds. The next `startRun` begins a new task and reports the network active again. Backgrounding alone is not suspension, and a run started while the system grants no background time runs without a task. An engine detach closes the client, which cancels active runs within the lifecycle deadline and releases the scope.

## Android Adapters

The remaining facade callbacks that `Initialize`, TCP-01 and DNS-01 need have Android backends in plain Kotlin over the Android SDK; `BarometerBinding.newClient(context, store, trust)` wraps them in the facade interfaces with a `RecordStore` and, from API 23, the linkage key store of the same scope, and creates the client. It registers a network callback and a device-idle receiver and does nothing else; close the returned client before the store.

| Port | Android source | Values |
|---|---|---|
| `Clock` | `System.currentTimeMillis()` while `Settings.Global.AUTO_TIME` is on | Unavailable with manual time; no fallback |
| `Consent` | None yet | Always `absent`, so a measurement that requires consent never runs |
| `Device` | Sticky `ACTION_BATTERY_CHANGED` broadcast | Battery percentage and charging, each only when known |
| `TimeZone` | `java.util.TimeZone.getDefault()` | IANA identifier |
| `Network` | `ConnectivityManager` default network of the application, `PowerManager` device idle | Type `wifi`, `cellular`, `ethernet` or `other`; IPv4 and IPv6 `yes` or `no` from the link's address families; VPN, validation, captive portal and suspension as below. The generation changes only when the default network or any of these values change |
| `LinkageKeyStore` | Android Keystore, API 23 and later | See [Android Linkage Keys](#android-linkage-keys) |
| `SystemResolver` | `InetAddress.getAllByName` on a worker thread | Canonical addresses of the requested family; any failure, including an unknown name, is an error |

The network signals come from the application's default network, so a VPN that excludes the application is not reported:

| Value | API 23 and later | API 21 and 22 |
|---|---|---|
| VPN | `detected` with the VPN transport, otherwise `not_detected` | `detected` when the active network is a VPN, `not_detected` when no VPN network exists, otherwise `unknown` |
| Validation, captive portal | `yes` or `no` from `NET_CAPABILITY_VALIDATED` and `NET_CAPABILITY_CAPTIVE_PORTAL` | `unknown` |
| Suspension | `suspended` in device idle (Doze), from API 28 on a network without `NET_CAPABILITY_NOT_SUSPENDED` and from API 29 on a network reported blocked for the application; otherwise `active`, or `unknown` on API 29 and later until the blocked status is reported | `unknown` |

Without a default network the VPN, validation and captive-portal values are `unknown`. Suspension means the operating system stops the application's network work; backgrounding alone is not suspension, because background work is the host's decision. An unknown suspension does not block a run.

No adapter reads an address, network name, operator, subscriber, account or device identifier into a value it returns, and the access state carries no identifier. The trusted local document reaches the client only through the host policy adapter below; it is never taken from Dart. The method-channel host creates the client at `initialize` (see [Channel Contract](#channel-contract)). Validation evidence is in [docs/android-validation.md](docs/android-validation.md).

## Android Host Policy

The host policy adapter (`HostPolicy.kt`) is the only source of the trusted local document on Android. It reads the application asset that the host registers from its own native code, before the engine registers the plugin, for example in `Application.onCreate`:

```kotlin
BarometerFlutterPlugin.setTrustAsset("barometer/trust.json") // the default
```

The path is relative to the application's assets and made of plain segments; anything else throws `IllegalArgumentException`. The asset ships in the application package, so the release signature authenticates it. Dart, channel arguments, tasks, collector replies, targets, proxies and context endpoints cannot supply or change it.

Every `initialize` reads the document again:

- The same bytes as the active document: nothing is replaced, and `initialize` returns `already_initialized` as before.
- Different bytes: a policy replacement, activated only by reinitialization. The document's `policy_generation` must be strictly greater than every generation activated in the process; a lower or equal one fails with `policy_rejected`. The facade then validates the document in full while the active client stays open; an invalid one fails with `trust_invalid`. Either failure leaves the active policy, its runs, handles and deliveries in place. Only then is the active client closed, which cancels its runs (recorded as `cancelled_by_host`) and invalidates its task and run handles and delivery records, and a new client over the same record store is initialized with this call's configuration. Tasks are admitted again through `admitTask`; one the new policy no longer permits is rejected there, for a removed registration as `target_not_registered`. If closing fails, the new client is discarded and the active one is kept so that `close` can be retried.
- With no client open, after `close` or in another engine of the process, the document must be the last one activated or have a greater generation.

The generation floor is kept in memory for the life of the process. It is not persisted: across releases, Android refuses to install a lower version code over an installed application, and Go rejects admission under a generation below the highest one of its retained replay records as `policy_rollback`. A debuggable build installed with a downgrade flag, or an application whose data was cleared, can start from an earlier packaged document.

The document's local restriction inputs apply on Android as in Go: `device` gates runs on the battery state the `Device` adapter reads (a run that does not meet it returns `run_not_due`), and `network_context` limits Network Context acquisition to the paths and configured endpoints it lists. `setProxy` and `clearProxy` return `proxy_rejected` for a configuration the trusted document does not approve or the facade cannot validate, leaving the previous proxy in place, and `cleanup_incomplete` when the previous proxy's work does not end within the cleanup bound, after which the client is blocked until `close`. Keep the previous local proxy available until `setProxy` or `clearProxy` returns. Signed remote packages are verified by the native library against the Ed25519 issuer keys of the active policy; the plugin holds no key. iOS still reads the fixed bundle resource and does not replace the policy.

## Apple Adapters

The same callbacks have Apple backends in Swift over Foundation, UIKit, the Network framework, Security and CryptoKit; `BarometerBinding.newClient(store:trust:)` wraps them in the facade protocols with a `RecordStore` and the linkage key store of the same scope, and creates the client. It starts an `NWPathMonitor` and does nothing else; close the returned client before the store. Facade calls must not be made on the main thread; the method-channel host creates the client at `initialize` and makes every facade call on its worker queue (see [Channel Contract](#channel-contract)).

| Port | Apple source | Values |
|---|---|---|
| `Clock` | `Date()` (`CLOCK_REALTIME`) | Used as trusted time when positive; a time that is not positive is unavailable, with no fallback. Manual time cannot be detected (see below) |
| `Consent` | None yet | Always `absent`, so a measurement that requires consent never runs |
| `Device` | `UIDevice` battery level and state, read on the main queue with battery monitoring turned on for the reading and then restored | Battery percentage and charging, each only when known; unknown if the main queue does not answer within the deadline |
| `TimeZone` | `TimeZone.current` | IANA identifier |
| `Network` | `NWPathMonitor`, the host's background-task expiry | Type `wifi`, `cellular`, `ethernet` or `other`; IPv4 and IPv6 `yes` or `no` from the path or, where the path does not report them, from the primary interface's non-link-local addresses; VPN, validation, captive portal and suspension as below. The generation changes only when these values, the primary interface or the gateways change. CoreTelephony is not used |
| `SystemResolver` | `getaddrinfo` on its own thread, at most four at once | Canonical addresses of the requested family; any failure, including an unknown name, is an error |
| `LinkageKeyStore` | Keychain and CryptoKit | See [Apple Linkage Keys](#apple-linkage-keys) |

| Signal | Value |
|---|---|
| VPN | `detected` when the primary interface of a satisfied path has the type `other`, which is how `NWPath` reports a tunnel interface; `not_detected` when it is Wi-Fi, cellular, wired Ethernet or loopback; `unknown` without a satisfied path. Only the interface type is read, so a tunnel that is not the default path (a split tunnel) is not detected |
| Validation, captive portal | Always `unknown`: iOS has no public source. `NWPath` does not report validation, and the captive-network state is visible only to a hotspot helper with a restricted entitlement |
| Suspension | `suspended` after a background task of an active run expired, until the next run starts; otherwise `active` (see [Lifecycle on iOS](#lifecycle-on-ios)) |

As on Android, no adapter returns an address, network name, interface name, operator, subscriber, account or device identifier. Unlike Android, the trusted local document is read only from the application bundle resource `barometer/trust.json` by `TrustDocument`. Validation evidence is in [docs/apple-validation.md](docs/apple-validation.md).

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
flutter test integration_test -d <device-id>   # needs a running emulator or simulator
flutter build apk --debug
flutter build ios --debug --no-codesign
flutter build ios --debug --simulator
cd android
./gradlew :barometer_flutter:testDebugUnitTest
./gradlew :barometer_flutter:connectedDebugAndroidTest   # needs a running emulator or device
```

The Android instrumented tests change the emulator's connectivity and power state through the shell (a test VPN, airplane mode from API 30, Wi-Fi, forced device idle, the reported battery level and charging state) and restore it; run them on emulators only. On API 21, run them on a freshly started emulator: it remembers the VPN consent by package name, and a reinstalled test application gets a new user ID, for which it refuses to establish the VPN. Three scripts cover what the instrumentation cannot do itself:

```sh
bash scripts/android-airplane-check.sh            # airplane mode switched from the host, every API level
bash scripts/android-clear-storage-check.sh       # "Clear storage" (pm clear) without calling Barometer
bash scripts/android-clear-storage-check.sh --control   # the same without clearing; must fail
bash scripts/android-reinstall-backup-check.sh reinstall [--control]   # uninstall and reinstall, API 23 and later
bash scripts/android-reinstall-backup-check.sh adb-backup   # adb backup and restore; accepts the confirmation screen
bash scripts/android-reinstall-backup-check.sh bmgr   # bmgr through the local transport, as root; exit 3 without one
```

On iOS the XCTests run from `example/ios` with `xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination 'platform=iOS Simulator,id=<udid>' -only-testing:RunnerTests` after `flutter build ios --debug --simulator`. Two scripts drive what a single test process cannot do, on simulators only:

```sh
bash scripts/ios-record-store-kill-test.sh <udid> [rounds]   # process kill during record writes
bash scripts/ios-reinstall-check.sh <udid> [--control]       # uninstall and reinstall; the control must fail
```

The Swift store, adapter and channel XCTests run in `example/ios` on a simulator after the iOS simulator build, and a script checks the store's atomicity under process kill. CI does not run them. The channel tests contact no network. The adapter tests contact `1.1.1.1:443` and resolve `example.org` once each:

```sh
cd example/ios
xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination 'platform=iOS Simulator,id=<udid>' -only-testing:RunnerTests -parallel-testing-enabled NO -collect-test-diagnostics never
cd ../..
bash scripts/ios-record-store-kill-test.sh <udid>
```

CI runs formatting, analysis and the Dart tests on every pull request and push to `main`. The native builds run in the separate device build workflow, which is started manually from the Actions tab when a change touches the native glue, the example, the build scripts or the `barometer-go` pin, and before an Epic closes. It runs the same steps on `ubuntu-24.04` for Android and `macos-15` for iOS, except the plugin's instrumented tests and XCTests, and runs the example's integration test on an API 35 `x86_64` Android emulator and on an iPhone simulator of the newest iOS runtime installed on the runner.

## Repository Boundaries

This repository owns the Flutter API, the native Kotlin and Swift glue and the plugin packaging. Library behavior is defined by the public [`barometer-spec`](https://github.com/tv-rain/barometer-spec) and implemented in `barometer-go`. Cross-project decisions live in the [Barometer coordination repository](https://github.com/tv-rain/barometer).

## License

The code and documentation are distributed under the [MIT License](LICENSE). The Barometer name and logo are covered by the [trademark notice](TRADEMARKS.md).
