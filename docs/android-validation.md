# Android Validation Record

This record lists where the Android native glue was run and what each run covered, following the validation plan of [decision 0014](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0014-gomobile-facade-and-platform-matrix.md#validation-plan). It is evidence for the recorded inputs only. It does not establish conformance, safety, field behavior or support for any platform version, and Barometer Draft `0.1.0` status is unchanged.

No measurement result, outcome, device serial, account, network name or address is recorded. The instrumented tests check the lifecycle and result shape and never print a result.

## Library Under Test

The `Barometer.aar.build-info.txt` written by `scripts/build-native.sh android` at the current pin:

```text
artifact: Barometer.aar
targets: android/arm64,android/amd64
commit: 7f5d7de7ada4709c1b2a4fdebbb4fb9b013ef918
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

[Signals, Lifecycle and Linkage Keys](#signals-lifecycle-and-linkage-keys) was recorded with this library. [Trust Roots Inside the Application](#trust-roots-inside-the-application) was recorded at the earlier pin `d7a5440ef35accc89a16a3074c586fa3d9f0308a`, and the sections after it at `c49695c9406d64d34d247de827ae2b0343634640` and, where they say so, `52789565c85f9d14d7b2ce1d5e42f85b11cea753`; their build-info differs from the one above only in the `commit` line.

## Signals, Lifecycle and Linkage Keys

Run on 2026-11-09 from `example/android` with `./gradlew :barometer_flutter:connectedDebugAndroidTest` and the library above, built locally by `scripts/build-native.sh android`, on emulators started headless (`-no-window`). The 37 tests are the 18 of the earlier run (`AdapterDeviceTest`, `RecordStoreDeviceTest`, `ChannelDeviceTest`, `TrustRootDeviceTest` in its `platform` scenario) and these:

- `NetworkSignalDeviceTest` (5): the VPN, validation, captive-portal and suspension values at rest for the API level; a test VPN service up and down (a VPN for the test application over the synthetic prefix `198.18.0.0/24`, granted through `appops` from API 22 and through the system dialog on API 21); airplane mode on and off (from API 30; earlier levels through the script below); Wi-Fi off and on; and device idle forced with `dumpsys deviceidle enable` and `force-idle` on battery, then undone. Each change must advance the generation, fire a pending watch and keep every value one of the fixed ones.
- `LinkageKeysDeviceTest` (7): Keystore derivation (32 bytes, repeatable, a non-exportable key created on first use with its sentinel), a key without the sentinel replaced before use, a missing key created when needed, deletion of key and sentinel that is idempotent and creates nothing, a deletion that fails and completes later, nothing after close, and no key store before API 23.
- `ClearDataDeviceTest` (3), the native rows of the clear-data contract through the facade with the production adapters: with rotating linkage, an acknowledged and a pending bundle and an attempt waiting on a loopback proxy that never answers, `clearMeasurementData` returns within 10 seconds, ends the attempt, deletes every record, the key and the sentinel, can be repeated, and creates no key when the client is initialized again; a deletion blocked by a directory in place of the sentinel returns `clearing_incomplete`, blocks `initialize` and is completed by a later clear; and closing a client during an attempt records it as `cancelled_by_host`.
- `LifecycleDeviceTest` (2): detaching the channel host closes the client and releases the storage scope, after which calls return `client_closed`; and a process killed by `Process.killProcess` while its attempt waits on the proxy leaves a scope that the next process opens, initializes and clears.
- `ClearStorageDeviceTest` (2), skipped here and run by `scripts/android-clear-storage-check.sh`.

| Target | Build fingerprint | OS | ABI | Instrumented tests | Skipped (not applicable) |
|---|---|---|---|---|---|
| Emulator, `system-images;android-21;default;arm64-v8a` | `generic_arm64/sdk_phone_arm64/generic_arm64:5.0.2/LSY66K/8789838:eng/test-keys` | Android 5.0.2 (API 21) | `arm64-v8a` | 25 passed, 12 skipped | Key store tests (6), interrupted clear, device idle, Wi-Fi (no Wi-Fi in the image), airplane mode, the two script phases |
| Emulator, `system-images;android-24;default;arm64-v8a` | `Android/sdk_phone_arm64/generic_arm64:7.0/NYC/8695085:userdebug/test-keys` | Android 7.0 (API 24) | `arm64-v8a` | 32 passed, 5 skipped | No-key-store check, Wi-Fi (no Wi-Fi in the image), airplane mode, the two script phases |
| Emulator, `system-images;android-35;default;arm64-v8a` | `Android/sdk_phone64_arm64/emu64a:15/AE3A.240806.019/12368160:userdebug/test-keys` | Android 15 (API 35) | `arm64-v8a` | 34 passed, 3 skipped | No-key-store check, the two script phases |

`ClearDataDeviceTest` and `ClearStorageDeviceTest` run TCP-01 to `1.1.1.1:443`; the other new tests contact no network. Observed values:

- At rest, VPN was `not_detected` on every level; validation `yes`, captive portal `no` and suspension `active` on API 24 and 35, and all three `unknown` on API 21.
- With the test VPN up, API 24 and 35 reported `detected` as the application's default network although it routes only the synthetic prefix; API 21 reported `detected` or `unknown`, both accepted by the test.
- Forced device idle reported `suspended` on API 24 and 35 and `active` after it was undone. The emulator images ship with deep idle disabled; the test enables it and restores the setting.
- Airplane mode removed the default network (type `unknown`, IPv4 `no`, VPN `unknown`) and the original type returned after it was switched off. Wi-Fi off moved the API 35 default network off Wi-Fi, and it returned validated.
- After `clearMeasurementData`, run handles return `not_initialized`, because clearing ends the generation.

Host scripts, run against each emulator with the same library:

| Script | API 21 | API 24 | API 35 |
|---|---|---|---|
| `scripts/android-airplane-check.sh`: `airplaneModeRemovesTheNetworkAndRestoresIt` while the host switches airplane mode on 8 seconds after the start and off 15 seconds later (as root through `su` before API 30, `cmd connectivity airplane-mode` from API 30) | Passed | Passed | Passed |
| `scripts/android-clear-storage-check.sh`: seed records, a pending bundle, the key and the sentinel with linkage on, `pm clear` the test application as Settings "Clear storage" does, then check that no Barometer file or key survived and that initializing creates no key | Passed (no key before API 23) | Passed | Passed |
| `scripts/android-clear-storage-check.sh --control`: the same without `pm clear`; the verification must fail | Failed as expected | Failed as expected | Failed as expected |

The example's integration test (`flutter test integration_test -d <emulator>` in `example`, Flutter 3.47.6) passed on the API 35 emulator with this library. Its trusted local document now lists the two embedded tasks as release-reviewed by the digests of the bytes the build wrote, which this pin requires for an embedded task without `not_after`.

The instrumentation's shell user cannot switch airplane mode before API 30, or run `su`, so those levels need the host script. On API 21 the platform remembers VPN consent by package name: after a reinstall, which changes the test application's user ID, it reports the permission as granted but does not establish the VPN until the emulator restarts, so the API 21 row was run on a freshly started emulator. These are emulator runs: real radios, vendor power management and hardware-backed keys remain the deferred device checks AD-05, AD-06 and AD-08 of the [deferred device checks](https://github.com/tv-rain/barometer/blob/main/docs/device-checks.md). Uninstall and reinstall, backup and restore and device-to-device migration of the key were not run.

## Trust Roots Inside the Application

The library uses the Android trust-root set of [decision 0016](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0016-android-trust-root-set.md): the updatable store `/apex/com.android.conscrypt/cacerts` when it yields a certificate, otherwise the system store `/system/etc/security/cacerts`, never a user-installed CA, and no TLS-dependent test without a root set. `TrustRootDeviceTest` checks it in the test application's process through the facade. Each run initializes one client with a loopback proxy and runs TLS-01 twice: directly to `8.8.8.8:443` with server name `dns.google`, whose chain reaches the GlobalSign Root CA present in the API 24 and API 35 stores, and on the proxy path through a CONNECT proxy in the test process that never contacts the target and answers the handshake with a leaf for the same name issued by a synthetic test CA (`android/src/androidTest/assets/barometer/trust-roots/`, no private key of the CA is kept). Only the reported `certificate_validation` is checked.

`scripts/android-trust-scenario.sh` prepares each scenario on the emulator as root and `reset` undoes it; the test reads the scenario from the instrumentation argument `trustScenario`:

```sh
bash scripts/android-trust-scenario.sh user-ca
cd example/android && ./gradlew :barometer_flutter:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.tvrain.barometer_flutter.TrustRootDeviceTest \
  -Pandroid.testInstrumentationRunnerArguments.trustScenario=user-ca
bash scripts/android-trust-scenario.sh reset
```

| Scenario | Emulator state | Expected direct, intercepted | API 24 | API 35 |
|---|---|---|---|---|
| `platform` | Stores unchanged | `trusted`, `untrusted`: the system store is found and the synthetic CA is rejected | Passed | Passed |
| `user-ca` | Synthetic CA installed in the user store `/data/misc/user/0/cacerts-added` and in `/data/misc/keychain/certs-added`, which Go's own loader reads | `trusted`, `untrusted`: the user-installed CA is rejected | Passed | Passed |
| `updatable-only` | The updatable store, as applications see it, holds only the synthetic CA | `untrusted`, `trusted`: the root set follows the updatable store | Not applicable (no updatable store) | Passed |
| `system-only` | The system store, as applications see it, holds only the synthetic CA | API 24: `untrusted`, `trusted` (the system store is the root set); API 35: `trusted`, `untrusted` (the system store is not read while the updatable store yields certificates) | Passed | Passed |

Run on 2026-11-09 with the library above on the emulators of the previous table; build fingerprints `Android/sdk_phone_arm64/generic_arm64:7.0/NYC/8695085:userdebug/test-keys` and `Android/sdk_phone64_arm64/emu64a:15/AE3A.240806.019/12368160:userdebug/test-keys`. A store is replaced by a bind mount, labeled like the store, in the zygote mount namespaces, so the application sees it while the system and APEX images stay unchanged; on API 24, which has no `nsenter`, the mount is made in the shell's namespace and propagates to the zygote. As a control, the `updatable-only` state on API 35 run with the `platform` expectations failed on the direct handshake. No result was printed or recorded.

This is emulator evidence. A device whose Conscrypt module was updated, so that the two stores differ by more than this substitution, is check AD-04 of the [deferred device checks](https://github.com/tv-rain/barometer/blob/main/docs/device-checks.md). The direct case depends on `8.8.8.8` serving a chain to a root in the image's store; the GlobalSign cross-signature it relies on expires in January 2028.

## Method Channel

Run on 2026-11-05 from `example/android` with `./gradlew :barometer_flutter:connectedDebugAndroidTest` and the library above, after the Dart API and the Android channel host were added. Besides the 13 tests above, `ChannelDeviceTest` (4 tests) drives `BarometerHost`, the channel handler, against the facade with the test package's trusted local document: no client before `initialize`, the lifecycle through the channel, native installation of an embedded asset and of a remote package with admission by Go, and refusal of trust inputs as channel arguments. It contacts no network.

| Target | Model | OS | ABI | Instrumented tests |
|---|---|---|---|---|
| Emulator, `system-images;android-21;default;arm64-v8a` | Android SDK built for arm64 | Android 5.0.2 (API 21) | `arm64-v8a` | 17 of 17 passed |
| Emulator, `system-images;android-24;default;arm64-v8a` | Android SDK built for arm64 | Android 7.0 (API 24) | `arm64-v8a` | 17 of 17 passed |
| Emulator, `system-images;android-35;default;arm64-v8a` | Android SDK built for arm64 | Android 15 (API 35) | `arm64-v8a` | 17 of 17 passed |

These runs use the plugin's own test APK; the channel host is called directly, not through a Flutter engine.

## Example Application From Dart

Run on 2026-11-05 from `example` with `flutter test integration_test -d <device>` and Flutter 3.47.6 on an Apple silicon host, with the library above. `barometer_flow_test.dart` (1 test) launches the example, checks that nothing has run, presses **Run tcp-01** and **Run dns-01**, and checks that each run reaches `terminal` through `runState` polling from Dart, that its bundle holds one result with execution state `completed` and observation type `tcp_connect` or `dns_query` from platform `android`, and that no bundle is pending after the acknowledgement. The trusted local document and tasks are the example's synthetic files, generated into the APK's assets by the build. TCP-01 contacts `1.1.1.1:443` once and DNS-01 resolves `example.org` once. A second press of **Run tcp-01** in the same build, tried once and not committed, admitted the task as a redelivery whose run ended without a new bundle.

| Target | Model | OS | ABI | Integration test |
|---|---|---|---|---|
| Emulator, `system-images;android-35;default;arm64-v8a` | Android SDK built for arm64 | Android 15 (API 35) | `arm64-v8a` | 1 of 1 passed |
| CI emulator on `ubuntu-24.04`, `system-images;android-35;default;x86_64` | Emulator AVD created by `reactivecircus/android-emulator-runner` | Android 15 (API 35) | `x86_64` | 1 of 1 passed |

The CI row ran with Flutter 3.47.8 and a library built in the same job by `scripts/build-native.sh android` at the same pin; the manually started device build workflow runs it. This is the first run of the plugin inside a Flutter application on Android: the Dart API, the method channel, the native host, the adapters and the facade together. No API 24 emulator ran it, because the host was out of disk space.

## DEV-725: Adapters, TCP-01 and DNS-01

Run on 2026-11-04 from `example/android` with `./gradlew :barometer_flutter:connectedDebugAndroidTest`, which runs the plugin's instrumented tests: `AdapterDeviceTest` (6 tests) and `RecordStoreDeviceTest` (7 tests, from DEV-724). `AdapterDeviceTest` initializes a facade client with the Android adapters, the state store and a synthetic trusted local document, runs TCP-01 to `1.1.1.1:443` and DNS-01 for `example.org` through the platform resolver, each through `StartRun`, `NextBundle` and `AcknowledgeBundle`, and checks that the coarse access state holds only the fixed values and that no result retains the target.

The trust-store check ran a Go probe built from Go 1.26.0 for `android/arm64` and run with `adb shell`. It loads `x509.SystemCertPool`, verifies every certificate found in the platform store directories against it, and checks that a leaf issued by a synthetic CA generated at run time is rejected as an unknown authority, while the same leaf verifies against that CA alone. The probe is not part of either repository.

| Target | Model | OS | ABI | Instrumented tests | Trust-store probe |
|---|---|---|---|---|---|
| Emulator, `system-images;android-21;default;arm64-v8a` | Android SDK built for arm64 | Android 5.0.2 (API 21) | `arm64-v8a` | 13 of 13 passed at `5278956`; superseded by the run above | System store found (all certificates verify); synthetic CA rejected |
| Emulator, `system-images;android-24;default;arm64-v8a` | Android SDK built for arm64 | Android 7.0 (API 24) | `arm64-v8a` | 13 of 13 passed at `5278956`; superseded by the run above | System store found; synthetic CA rejected |
| Emulator, `system-images;android-35;default;arm64-v8a` | Android SDK built for arm64 | Android 15 (API 35) | `arm64-v8a` | 13 of 13 passed at `5278956` | System store found, and every certificate in the updatable store `/apex/com.android.conscrypt/cacerts` verifies; synthetic CA rejected |

The project has no Android physical device, so Android evidence comes from emulators only, and emulator evidence is not device evidence. Device runs of these checks, and the checks only a device can answer (transitions between real radios, vendor power management, power loss and hardware-backed keys), wait until a project-owned device is available. The device evidence so far is on iOS, in [the Apple validation record](apple-validation.md).

The API 21 run covers the native library alone: it runs the plugin's own test APK, not a Flutter application, which cannot run below API 24. The API 24 and API 35 runs use the same test APK; no Flutter application calls the adapters yet.

## Observed Behavior and Gaps

- **Trust store.** Go's own Android loader reads `/system/etc/security/cacerts` and the user-installed CA directory `/data/misc/keychain/certs-added`, and never the updatable store of API 34 and later. The library no longer uses it on Android: it loads the root set of decision 0016, checked in the application process above. User-disabled system CAs are not consulted, and a device with an updated Conscrypt module has not been tested.
- **Probe build on API 21.** A probe linked by Go's internal linker (`CGO_ENABLED=0`) crashed at start on the API 21 emulator; one built with the NDK `aarch64-linux-android21-clang` ran. The gomobile library is built with the NDK and loaded on API 21 in the instrumented tests.
- **Network on API 21 to 22.** The platform has no active-network handle there. The adapter reads IPv4 and IPv6 from the single connected network of the active type and reports them `unknown` otherwise, which fails closed for TCP-01.
- **Resolver.** An unknown name is reported as `resolver_error`, never `no_data`, because the platform does not separate it from a resolver failure before API 29. A lookup abandoned at its deadline keeps its worker thread until the platform returns.
- **Not covered.** Any physical device (see above); uninstall and reinstall, backup and restore and device-to-device migration of linkage keys; the Dart API on API 21 to 34, and the umbrella build. The `x86_64` slice has run only the example's integration test in CI. The VPN, validation, captive-portal and suspension signals, lifecycle and cancellation and the protected linkage keys ran on emulators only ([Signals, Lifecycle and Linkage Keys](#signals-lifecycle-and-linkage-keys)).
