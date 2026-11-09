# Android Validation Record

This record lists where the Android native glue was run and what each run covered, following the validation plan of [decision 0014](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0014-gomobile-facade-and-platform-matrix.md#validation-plan). It is evidence for the recorded inputs only. It does not establish conformance, safety, field behavior or support for any platform version, and Barometer Draft `0.1.0` status is unchanged.

No measurement result, outcome, device serial, account, network name or address is recorded. The instrumented tests check the lifecycle and result shape and never print a result.

## Library Under Test

The `Barometer.aar.build-info.txt` written by `scripts/build-native.sh android` at the current pin:

```text
artifact: Barometer.aar
targets: android/arm64,android/amd64
commit: d7a5440ef35accc89a16a3074c586fa3d9f0308a
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

The sections after [Trust Roots Inside the Application](#trust-roots-inside-the-application) were recorded with libraries built at the earlier pins `c49695c9406d64d34d247de827ae2b0343634640` and, where they say so, `52789565c85f9d14d7b2ce1d5e42f85b11cea753`, whose build-info differs from the one above only in the `commit` line.

## Instrumented Tests at the Current Pin

Run on 2026-11-09 from `example/android` with `./gradlew :barometer_flutter:connectedDebugAndroidTest` and the library above, built locally by `scripts/build-native.sh android`. The tests are `AdapterDeviceTest` (6 tests), `RecordStoreDeviceTest` (7), `ChannelDeviceTest` (4), described below, and `TrustRootDeviceTest` (1) in its default `platform` scenario, described in the next section.

| Target | Model | OS | ABI | Instrumented tests |
|---|---|---|---|---|
| Emulator, `system-images;android-24;default;arm64-v8a` | Android SDK built for arm64 | Android 7.0 (API 24) | `arm64-v8a` | 18 of 18 passed |
| Emulator, `system-images;android-35;default;arm64-v8a` | Android SDK built for arm64 | Android 15 (API 35) | `arm64-v8a` | 18 of 18 passed |

The API 21 emulator did not run at this pin; its last run is the 17-test row of [Method Channel](#method-channel). These runs use the plugin's own test APK, not a Flutter application.

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
- **Not covered.** Any physical device (see above); VPN, validation and suspension signals, the network-change matrix, lifecycle and cancellation, and protected linkage keys, which are M3 work; the Dart API on API 21 to 34, and the umbrella build. The `x86_64` slice has run only the example's integration test in CI.
