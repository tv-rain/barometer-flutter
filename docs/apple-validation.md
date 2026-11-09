# Apple Validation Record

This record lists where the Apple native glue was run and what each run covered, following the validation plan of [decision 0014](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0014-gomobile-facade-and-platform-matrix.md#validation-plan). It is evidence for the recorded inputs only. It does not establish conformance, safety, field behavior or support for any platform version, and Barometer Draft `0.1.0` status is unchanged.

No measurement result, outcome, device identifier, account, network name or address is recorded. The XCTests check the lifecycle and result shape and never print a result.

## Library Under Test

The `Barometer.xcframework.build-info.txt` written by `scripts/build-native.sh apple` at the current pin, used by [Signals, Lifecycle and Linkage Keys](#signals-lifecycle-and-linkage-keys):

```text
artifact: Barometer.xcframework
targets: ios,iossimulator
commit: 7f5d7de7ada4709c1b2a4fdebbb4fb9b013ef918
go: go1.26.0
gomobile: v0.0.0-20260821190718-4776eadac327
xcode: Xcode 27.0 Build version 27A266a
iphoneos-sdk: 27.0
iphonesimulator-sdk: 27.0
ios-deployment-target: 15.0
slices:
  ios-arm64
  ios-arm64_x86_64-simulator
status: compiled only; not a release, not platform support
```

The earlier sections ran with the library built at commit `c49695c`, with otherwise the same build-info:

```text
artifact: Barometer.xcframework
targets: ios,iossimulator
commit: c49695c9406d64d34d247de827ae2b0343634640
go: go1.26.0
gomobile: v0.0.0-20260821190718-4776eadac327
xcode: Xcode 27.0 Build version 27A266a
iphoneos-sdk: 27.0
iphonesimulator-sdk: 27.0
ios-deployment-target: 15.0
slices:
  ios-arm64
  ios-arm64_x86_64-simulator
status: compiled only; not a release, not platform support
```

## Signals, Lifecycle and Linkage Keys

Run on 2026-11-09 on an Apple silicon host with Xcode 27.0 and Flutter 3.47.6, with the library at the current pin, on simulators created for the run and deleted afterwards. The XCTests ran from `example/ios` with the command of the next section after `flutter build ios --debug --simulator`. New in this run:

- `LifecycleTests` (7 tests): the VPN mapping from the primary interface type, every signal change (VPN, path state, suspension) advancing the generation and firing a watch while an unchanged state does not, the access state holding only fixed values; through the channel host with a fake background-task source, a started run holding a background task until it is cancelled, a background-task expiry during an active attempt (the attempt ends as `platform_suspended` or `cancelled_by_host` within ten seconds, the task ends within the two-second bound, and the next run begins a new task with the network active), and an engine detach during an active attempt (later calls answer `client_closed`, the scope is released within ten seconds, the attempt is recorded as `cancelled_by_host`); and the clear-data host rows with rotating linkage: with an acknowledged and a pending bundle and an active attempt, `clearMeasurementData` returns within ten seconds, invalidates the run handle, deletes every record, the Keychain key and the sentinel, is repeatable, and creates no key on the next initialization; an interrupted deletion (a directory in place of the sentinel) is `clearing_incomplete`, initialization is refused until a later clear completes it.
- `LinkageKeysTests` (6 tests): derivation creates a 32-byte key stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and not synchronizable, whose HMAC matches CryptoKit's, and a sentinel excluded from backup; deletion removes both and creates nothing; the sentinel truth table (a key without the sentinel, a missing key, an invalid key) replaces the key on the next derivation; an interrupted deletion fails and a later one completes; deadline bounds and close.
- `ReinstallTests` (2 phases, skipped unless `scripts/ios-reinstall-check.sh` drives them).

Active attempts wait on a loopback proxy that never answers; the linked runs contact `1.1.1.1:443`. The access state on the simulator reported VPN `not_detected` and suspension `active`; validation and captive portal are always `unknown`.

| Target | Model | OS | Architecture | XCTests | Reinstall check | Control |
|---|---|---|---|---|---|---|
| Simulator, current runtime `iOS 27.0 (24A434)` | iPhone 17 | iOS 27.0 | `arm64` | 55 run, 51 passed, 4 skipped | Passed | Failed as expected |
| Simulator, oldest installed runtime `iOS 18.4 (22E238)` | iPhone 16 | iOS 18.4 | `arm64` | 55 run, 51 passed, 4 skipped | Passed | Failed as expected |

The four skipped tests are the two process-kill helpers and the two reinstall phases. The reinstall check seeds records, a pending bundle, the Keychain key and the sentinel, uninstalls the example application with `simctl uninstall` and reinstalls it through the next test run: no Barometer file was present, initializing created no key, and the first derivation used a new key. On both runtimes the earlier Keychain item survived the uninstall and was deleted before use because the sentinel was gone. The control run, without the uninstall, failed on the surviving files, the pending bundle and the reused key. The example integration test (`barometer_flow_test.dart`) passed 1 of 1 on the iOS 27.0 simulator with the plugin's background task around each run.

## Adapters, TCP-01 and DNS-01

Run on 2026-11-05 on an Apple silicon host with Xcode 27.0, from `example/ios` with `xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination 'platform=iOS Simulator,id=<udid>' -only-testing:RunnerTests -parallel-testing-enabled NO -collect-test-diagnostics never`, after `flutter build ios --debug --simulator`. It runs `AdapterTests` (7 tests), `RecordStoreTests` (16 tests), `RecordStoreKillTests` (2 process-kill helpers, skipped unless `scripts/ios-record-store-kill-test.sh` drives them) and `RunnerTests` (1 test). `AdapterTests` initializes a facade client with the Apple adapters, the state store and a synthetic trusted local document, runs TCP-01 to `1.1.1.1:443` and DNS-01 for `example.org` through `getaddrinfo`, each through `StartRun`, `NextBundle` and `AcknowledgeBundle` called off the main thread, checks that the coarse access state holds only the fixed values and that no result retains the target, and checks that the bundled `barometer/trust.json` initializes a client and an invalid document is rejected as `trust_invalid`.

The trust-store check ran a Go probe built from Go 1.26.0 for `ios/arm64` against the iPhoneSimulator 27.0 SDK (deployment target 15.0) and run with `xcrun simctl spawn`. It loads `x509.SystemCertPool`, verifies a leaf issued by a synthetic CA generated at run time against Go's default roots and against the system pool, verifies the same leaf against that CA alone, and completes one TLS handshake to `example.org:443` with Go's default roots. On simulators created for the check and deleted afterwards, it then added the synthetic CA with `xcrun simctl keychain <udid> add-root-cert` and verified the leaf again. The probe is not part of either repository.

| Target | Model | OS | Architecture | XCTests | Trust-store probe |
|---|---|---|---|---|---|
| Simulator, current runtime `iOS 27.0 (24A434)` | iPhone 17 | iOS 27.0 | `arm64` | 24 of 24 run passed, 2 skipped | `SystemCertPool` loads; synthetic CA rejected by both; public server verifies; after `add-root-cert` the synthetic leaf verifies |
| Simulator, oldest installed runtime `iOS 18.4 (22E238)` | iPhone 16 | iOS 18.4 | `arm64` | 24 of 24 run passed, 2 skipped | Same as iOS 27.0 |
| Simulator, iOS 15 runtime | Not run | | | | |
| Simulator, `x86_64` | Not run | | | | |
| Physical device, connected by USB | iPhone 13 | iOS 27.0.1 | `arm64` | 24 of 24 run passed, 2 skipped | Not run |

The validation plan's minimum is an iOS 15 simulator runtime. None is installed on this host and it was not downloaded: the host's oldest runnable runtime is iOS 18.4, so the iOS 15 to 18.3 range has no simulator evidence. The `x86_64` simulator slice was built but not run, because the host is Apple silicon. The physical-device row ran the same XCTests from `example/ios` on 2026-11-05 with the same library build-info, after `flutter build ios --debug --no-codesign`, with `-destination 'platform=iOS,id=<udid>'` and Xcode automatic signing under a development team passed on the `xcodebuild` command line; no team, identity, profile or device identifier is committed. The trust-store probe was not run on the device, so the iOS 15 to 26 range has no device evidence either.

## Method Channel

Run on 2026-11-05 on the same host and library build, with the same command, on the iOS 27.0 iPhone 17 simulator. `ChannelTests` (14 tests) checks the Swift channel contract (exact argument keys, bounds counted in UTF-16 code units as Dart and Kotlin count them, embedded task names, rejection of trust inputs and unknown methods), the error-code filter, the embedded issuer of the trusted local document, and the host against the facade: nothing is created before `initialize`, the lifecycle runs through the channel with the facade's codes, the synthetic expired task is installed from the test bundle's `barometer/tasks/expired.json` with the embedded issuer and fails a later admission step, an unsigned remote package is refused as `task_source_unauthenticated`, a missing trusted local document is `trust_invalid` and a detached host answers `client_closed`. Every answer arrives on the main thread and no store call runs on it. The tests contact no network. The full `RunnerTests` run was 40 tests, 38 passed and 2 skipped (the process-kill helpers). The example application, run on the same simulator with a temporary Dart entry point that was not committed, answered `nextBundle` with `not_initialized`, `initialize` with `trust_invalid` (the example bundles no trusted local document), an embedded task name outside the task directory with `invalid_arguments`, and `close` with success, so Dart reaches the Swift handler. `flutter build ios --debug --simulator` and `flutter build ios --debug --no-codesign` succeeded. No device, older runtime or `x86_64` simulator ran the channel tests.

## Example Application From Dart

Run on 2026-11-05 from `example` with `flutter test integration_test -d <udid>`, Flutter 3.47.6 and Xcode 27.0 on an Apple silicon host, with the library above. `barometer_flow_test.dart` (1 test) launches the example, checks that nothing has run, presses **Run tcp-01** and **Run dns-01**, and checks that each run reaches `terminal` through `runState` polling from Dart, that its bundle holds one result with execution state `completed` and observation type `tcp_connect` or `dns_query` from platform `ios`, and that no bundle is pending after the acknowledgement. The trusted local document and tasks are the example's synthetic files, written into the application bundle by the Runner's **Generate Barometer Resources** build phase. TCP-01 contacts `1.1.1.1:443` once and DNS-01 resolves `example.org` once.

| Target | Model | OS | Architecture | Mode | Integration test |
|---|---|---|---|---|---|
| Simulator, runtime `iOS 26.5 (23F77)` | iPhone 17 Pro | iOS 26.5 | `arm64` | Standalone | 1 of 1 passed |
| CI simulator on `macos-15`, runtime `iOS 26.2` | iPhone 16 | iOS 26.2 | `arm64` | Standalone | 1 of 1 passed |
| Physical device, connected by USB | iPhone 13 (`iPhone14,5`) | iOS 27.0.1 (24A446) | `arm64` | Standalone | 1 of 1 passed |
| Physical device, connected by USB | iPhone 13 (`iPhone14,5`) | iOS 27.0.1 (24A446) | `arm64` | Umbrella | 1 of 1 passed |

The CI row ran with Flutter 3.47.8 and the runner's Xcode (reported as 16.4), with a library built in the same job by `scripts/build-native.sh apple` at the same pin; the manually started device build workflow runs it on the `iPhone <number>` simulator of the newest installed iOS runtime. An earlier CI attempt on an iPhone SE (3rd generation) simulator of the same runtime built the example and then made no progress for 19 minutes before it was cancelled; the step now has a 25-minute limit and logs verbosely. This is the first measurement run through the method channel on iOS, and the first run of the plugin inside the Flutter application with Dart driving it. No older runtime or `x86_64` simulator ran it.

The physical-device rows ran on 2026-11-05 with Flutter 3.47.6 and Xcode 27.0 on an Apple silicon host, with Xcode automatic signing under a development team passed only at build time (`FLUTTER_XCODE_DEVELOPMENT_TEAM`); no team, identity, profile or device identifier is committed. They are debug builds, so the integration test drives the application through the Dart VM service over USB. The `iproxy` that Flutter 3.47.6 bundles for that connection is an `x86_64` binary and needs Rosetta on Apple silicon; the runs used an `arm64` build of the same tool from libusbmuxd 2.1.1 in its place.

- **Standalone.** `flutter test integration_test -d <device>` with the library above.
- **Umbrella.** The example in umbrella mode (`BAROMETER_FLUTTER_UMBRELLA_MODULE` set, `pod install`, static pods) against an umbrella XCFramework that binds `barometermobile` together with two other Go packages in one `gomobile bind`, from a clean `build/ios`. The test ran with `flutter drive --keep-app-running` and a driver file that calls `integrationDriver()` and was not committed, because `flutter test integration_test` uninstalls the application after the run. In the built application the Go runtime is linked once, into the Runner binary, and the bundle contains no `Barometer` or `barometer_flutter` dynamic framework. The umbrella artifact's build information:

```text
artifact: umbrella XCFramework (ios-arm64, ios-arm64_x86_64-simulator)
barometermobile: commit c49695c9406d64d34d247de827ae2b0343634640
go: go1.26.2
gomobile: golang.org/x/mobile v0.0.0-20260820023541-8e8303b9da6c
flags: -trimpath -iosversion=15.0 -ldflags='-s -w'
xcode: Xcode 27.0 Build version 27A266a
status: local build for validation only; not a release, not platform support
```

The umbrella artifact's own check reported no skipped `barometermobile` exports and no build-host paths in its libraries.

## Observed Behavior and Gaps

- **Trust store.** On iOS, Go 1.26 does not read certificate files: `SystemCertPool` returns a platform-backed pool, and verification against it or against Go's default roots is delegated to the Security framework (`SecTrustEvaluateWithError`). A root added to the simulator's trust store with `simctl keychain add-root-cert` is then accepted, so Go's system roots are the iOS trust store, including roots installed into it. The device's handling of user- or profile-installed roots, which requires the user to enable full trust in Settings, is not yet observed. The rejection of the synthetic CA arrives as an untyped error, not `x509.UnknownAuthorityError`; Barometer's TLS normalization classifies any verification error other than a name mismatch or expiry as `certificate_untrusted`, so the class is unchanged. `simctl keychain reset` did not remove the added root within the same simulator boot; the simulators were deleted instead.
- **Clock (known limitation).** Manual time cannot be detected on iOS: there is no public API that reports the "Set Automatically" setting. The adapter uses `Date()` (`CLOCK_REALTIME`) as trusted time whenever it is positive and reports a time that is not positive as unavailable, with no fallback. This is weaker than the Android adapter's `AUTO_TIME` check, and it leaves the residual risk of [a wrong or manipulated device clock](https://github.com/tv-rain/barometer-spec/blob/main/library/task-trust.md#residual-risks) named by the specification. The simulator runs did not exercise a manually set clock.
- **Network.** On the simulator `NWPath.supportsIPv4` and `supportsIPv6` were false on a satisfied Wi-Fi path, so the adapter also reads the address families of the path's primary interface, ignoring link-local and loopback addresses. The interface name, its addresses and the gateways are compared inside the adapter only. On the simulator the path reflects the host's network. A VPN cannot be configured on a simulator, so `detected` is checked only through the mapping; a real tunnel, a split tunnel and network changes on a device are not yet observed. iOS has no public validation or captive-portal source, so both are always `unknown`.
- **Suspension.** Suspension is reported only when the plugin's background task for an active run expires. The simulator runs replace the system's background-task source with a test double; a real expiry on a device is not yet observed.
- **Keychain.** On the simulator a Keychain item survives uninstalling the application, as on devices, so the sentinel is what keeps an earlier key from being used. The item uses the application's default access group; another application or extension reading it, iCloud Keychain, backup and restore and device migration are not yet tested.
- **Device.** The simulator does not model a battery; the tests check the mapping with fixed inputs and that a reading restores the monitoring setting.
- **Resolver.** An unknown name is reported as `resolver_error`, never `no_data`, as on Android. A lookup abandoned at its deadline keeps its thread and one of the four lookup slots until `getaddrinfo` returns.
- **Not covered.** Devices other than one iPhone 13 on iOS 27.0.1, the trust-store probe on a device, the iOS 15 to 18.3 runtimes, `x86_64` simulators, VPN, suspension and network changes on devices, lifecycle and cancellation on devices, linkage keys on devices and their backup, restore and migration behavior, the method channel and Dart API on devices other than the iPhone 13 integration-test runs, and the native XCTests in umbrella mode.
