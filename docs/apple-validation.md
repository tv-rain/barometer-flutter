# Apple Validation Record

This record lists where the Apple native glue was run and what each run covered, following the validation plan of [decision 0014](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0014-gomobile-facade-and-platform-matrix.md#validation-plan). It is evidence for the recorded inputs only. It does not establish conformance, safety, field behavior or support for any platform version, and Barometer Draft `0.1.0` status is unchanged.

No measurement result, outcome, device identifier, account, network name or address is recorded. The XCTests check the lifecycle and result shape and never print a result.

## Library Under Test

The `Barometer.xcframework.build-info.txt` written by `scripts/build-native.sh apple` at the current pin, used by [Durability, Storage Full and the Nine Measurements](#durability-storage-full-and-the-nine-measurements), [Trust Store on the Device](#trust-store-on-the-device), [Oldest Runtime and `x86_64` Simulator](#oldest-runtime-and-x86_64-simulator), [Host Policy, Proxy and Signed Remote Tasks](#host-policy-proxy-and-signed-remote-tasks) and [Signals, Lifecycle and Linkage Keys](#signals-lifecycle-and-linkage-keys):

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

## Durability, Storage Full and the Nine Measurements

Run on 2026-11-09 on an Apple silicon host with Xcode 27.0 and Flutter 3.47.6, with the library at the current pin, on the project iPhone 13 (`iPhone14,5`) on iOS 27.2 (24B119), connected by USB, and on iOS 27.0 (24A434) iPhone 17 simulators created for the runs and deleted afterwards. The device runs used Xcode automatic signing under a development team passed only on the command line; no team, identity, profile or device identifier is committed. The application was installed over the existing one and never uninstalled, and the device was not restarted.

**XCTests on the device.** The full `RunnerTests` suite, including the tests of [Signals, Lifecycle and Linkage Keys](#signals-lifecycle-and-linkage-keys) and [Host Policy, Proxy and Signed Remote Tasks](#host-policy-proxy-and-signed-remote-tasks), ran from `example/ios` with `xcodebuild test -destination 'platform=iOS,id=<udid>'` after `flutter build ios --debug --no-codesign`: 71 tests, 62 passed and 9 skipped (the trust test without its environment, the process-kill helpers, the two durability phases, the two reinstall phases, the storage-full test and the network-change test, each run only by its script or with its environment). `LinkageKeysTests` and the clear-data rows of `LifecycleTests` therefore ran against the device's Keychain. `LocalPolicyTests` first failed on the device: the phone reports a known battery level and charging state that meet the test's constraint, so its run with the production device source started, and the test read that run's cancelled bundle in place of the next one. The test now completes and acknowledges that run, and passes on the device and on simulators, where the reading is unknown.

**Durability and process kill.** `bash scripts/ios-record-store-kill-test.sh <udid> 5` with the signing settings as `xcodebuild` arguments. Five rounds of `RecordStoreKillTests`: a test process replacing a record of the largest size with alternating values is killed with `SIGKILL` mid-write, and the next process finds either the earlier or the new value, never a mixture, the record written before the loop unchanged and no temporary file. Then `DurabilityTests`, the iOS counterpart of Android's `DurabilityDeviceTest`: a test process runs a one-time task and a repeating task (at most two runs, six hours apart) to completion on the proxy path through a loopback proxy that answers CONNECT without contacting the target, keeps their bundle pending, checks that a task reusing the one-time task's identifier with other content is rejected as `task_id_conflict`, starts a third attempt on a proxy that never answers and kills itself with `SIGKILL` while that attempt is active. The next process finds the same oldest pending bundle, byte for byte by SHA-256, both completed tasks `run_not_due` when admitted again as exact redeliveries, the conflicting task still `task_id_conflict` and the Keychain key present; `clearMeasurementData` then removes every record, the key and the sentinel. Both passed on the iPhone. A process kill stands in for power loss here and is not power-loss evidence: the device was not restarted, and power loss stays a deferred device check.

**Storage full.** `bash scripts/ios-storage-full-check.sh "iPhone 17" com.apple.CoreSimulator.SimRuntime.iOS-27-0 512m` creates a simulator and mounts a 512 MiB APFS disk image in place of the directory that holds its applications' data containers, so the test application's container is on a volume that the test can fill while the simulator's system data and Keychain stay on the host, as an application fills its own storage on a device. `StorageFullTests` stores a completed run's records, a pending bundle, the Keychain key and the sentinel (that run contacts `1.1.1.1:443` directly, so that linkage derives the key), admits a second task, and fills the volume with a filler file until a new 4 KiB file no longer fits. On the full volume a new task is rejected as `task_trust_unavailable`, the admitted task returns `run_not_due`, the stored record files are unchanged and no temporary file is left behind. `clearMeasurementData`, still on the full volume, returns within 10 seconds and leaves no record, no Keychain key and no sentinel. The check passed in three of three runs.

Earlier attempts placed the simulator's whole device directory on the image. There, without a reserve, clearing failed with `clearing_incomplete` because the clearing marker could not be stored; with a reserve it still failed in some runs, either because the space the reserve released was taken by the simulator's own processes before the marker was written, or because the Keychain, which shared the full volume, could not delete the key; in every such run clearing completed once the filler was removed. The record store now keeps a reserve file of 256 KiB per scope, released and committed before a clearing marker is stored ([Apple State Storage](../README.md#apple-state-storage)), and the check fills only the application's containers.

**The nine measurements from Dart.** `example/integration_test/measurements_test.dart` runs TCP-01, DNS-01, DNS-03, DNS-04, TLS-01, HTTP-01, NET-01, NET-03 and NET-05 from Dart through `BarometerClient`, each as a synthetic one-time embedded task from `example/barometer-fixtures/` ([README](../README.md#measurement-fixtures)). `scripts/ios-measurement-fixtures.sh start` served the fixtures of `scripts/measurement_fixtures.py` on the host's own stable global IPv6 address, answering only peers of the host's on-link prefix, and the build phase wrote that address into the tasks in place of `8.8.8.8`; the address is not recorded. On the simulator, which shares the host's network, the run's CA was added to the simulator's trust store, and the test checked for each task one result with execution state `completed` from platform `ios`, no pending bundle after the acknowledgement, and the observation types and outcomes of the [Android record](android-validation.md#durability-full-disk-and-the-nine-measurements), except NET-05: iOS reports network validation as `unknown`, so NET-05 stops before its first step with `inconclusive`. The outcomes are those of synthetic fixtures, not measurement data, and no result was printed or recorded.

On the iPhone the same nine tasks ran from Dart, but the fixtures were not reachable: every connection to the host's address failed (TCP-01 `address_unreachable`, DNS-01 `resolver_error`, the others failing at their first connection), while public IPv6 destinations were reachable from the same application. A probe connection from the test application to the host's address waited with "Network is down", which is consistent with iOS refusing the example the local network, for which it asks the user's permission; that permission was not given, and the CA was not installed on the device. The device runs therefore checked each task's lifecycle and result shape only (`BAROMETER_FIXTURE_CHECK=shape`): one result with execution state `completed` from platform `ios` and no pending bundle after the acknowledgement. They were profile builds launched with `devicectl` and read back from the application's container, because a debug run waited for Xcode to prepare the device's debug symbols, which did not fit on the host's disk.

| Target | Build | Fixtures | Nine measurements from Dart |
|---|---|---|---|
| Simulator, iOS 27.0 (24A434), iPhone 17 | Standalone (the library above) | Reached; CA trusted | 1 of 1 passed: all nine outcomes as expected |
| Simulator, iOS 27.0 (24A434), iPhone 17 | Umbrella (below) | Reached; CA trusted | 1 of 1 passed: all nine outcomes as expected |
| iPhone 13 (`iPhone14,5`), iOS 27.2 (24B119) | Standalone, profile | Not reached (local network not allowed) | 1 of 1 passed, lifecycle and result shape only |
| iPhone 13 (`iPhone14,5`), iOS 27.2 (24B119) | Umbrella, profile | Not reached (local network not allowed) | 1 of 1 passed, lifecycle and result shape only |

In umbrella mode the example linked the facade once, into the Runner binary, and its bundle held no `Barometer` or `barometer_flutter` dynamic framework. The umbrella XCFramework was built locally from the CircumRain umbrella's `barometer-integration` branch (`b4e7560`) with `make bind-ios`, after `go get` raised its `barometer-go` requirement to the pin above; the raise was not committed there. Its own check (`make check-barometer-ios`) reported no skipped `barometermobile` exports and no build-host paths in its two libraries. Its build information:

```text
artifact: umbrella XCFramework (ios-arm64, ios-arm64_x86_64-simulator)
binds: circum-rain-lib, circum-rain-config, barometermobile
barometermobile: commit 7f5d7de7ada4709c1b2a4fdebbb4fb9b013ef918
go: go1.26.2
gomobile: golang.org/x/mobile v0.0.0-20260820023541-8e8303b9da6c
flags: -trimpath -iosversion=15.0 -ldflags='-s -w'
xcode: Xcode 27.0 Build version 27A266a
status: local build for validation only; not a release, not platform support
```

**Network changes on the device.** `NetworkChangeDeviceTests` ran on the iPhone with `TEST_RUNNER_BAROMETER_NETWORK_CHANGE_TEST=10800,300` while a person switched the phone's Wi-Fi off and on. It reads the `Network` adapter's coarse access state every 250 ms and keeps one proxy-path TCP-01 attempt active on a loopback proxy that never answers. It observed three states, in this order:

| Access generation | Network type | VPN | IPv4 | IPv6 |
|---|---|---|---|---|
| +0 (start) | `wifi` | `not_detected` | `yes` | `yes` |
| +1 (Wi-Fi off) | `cellular` | `not_detected` | `yes` | `no` |
| +2 (Wi-Fi on) | `wifi` | `not_detected` | `yes` | `yes` |

Then Xcode lost the test process ("An error occurred while communicating with a remote process") and the run ended with exit code 65. The test's own assertions (that the generation advanced and that an attempt active across a change ended with `network_changed`) therefore did not run on the device, and airplane mode and a VPN were not exercised. The cause of the lost connection is not confirmed. The run was not repeated; the remaining check is deferred in [Deferred Device Checks](https://github.com/tv-rain/barometer/blob/main/docs/device-checks.md#ios-checks). A five-second run with no change, before it, failed as expected: no network change, and its attempts ended `incomplete` with `proxy_connect_failed`.

## Trust Store on the Device

Run on 2026-11-09 on an Apple silicon host with Xcode 27.0 and Flutter 3.47.6, with the library at the current pin, from `example/ios` with `bash scripts/ios-trust-root-check.sh` after `flutter build ios --debug --simulator` or `--no-codesign`. `TrustRootDeviceTests` (1 test, skipped unless the script runs it) checks Go's trust roots inside the application process through the facade, as Android's `TrustRootDeviceTest` does: one client runs TLS-01 directly to `8.8.8.8:443` with server name `dns.google`, verified with Go's system roots (the facade leaves the roots unset on Apple platforms), and then on the proxy path through a loopback CONNECT proxy in the test process that never contacts the target and answers the handshake with a leaf for `dns.google` issued by a synthetic CA. Only the reported `certificate_validation` is checked and no result is printed.

The script generates the synthetic CA (valid for two days), the leaf and a configuration profile that installs the CA in a directory outside the repository, and passes the leaf and its key to the test through the environment, so no key is committed. On the device the profile was installed from Safari and full trust was switched in Settings > General > About > Certificate Trust Settings by hand. The profile was removed after the runs and the generated material deleted. The device rows used Xcode automatic signing under a development team passed only on the `xcodebuild` command line; no team, identity, profile or device identifier is committed.

| Target | Model | OS | Synthetic CA | Public server (direct) | Synthetic leaf (intercepted) |
|---|---|---|---|---|---|
| Simulator, runtime `iOS 27.0 (24A434)` | iPhone 17 | iOS 27.0 | Not installed | `trusted` | `untrusted` |
| Physical device, connected by USB | iPhone 13 (`iPhone14,5`) | iOS 27.2 (24B119) | Not installed | `trusted` | `untrusted` |
| Physical device, connected by USB | iPhone 13 (`iPhone14,5`) | iOS 27.2 (24B119) | Profile installed, full trust off | `trusted` | `untrusted` |
| Physical device, connected by USB | iPhone 13 (`iPhone14,5`) | iOS 27.2 (24B119) | Profile installed, full trust on | `trusted` | `trusted` |
| Physical device, connected by USB | iPhone 13 (`iPhone14,5`) | iOS 27.2 (24B119) | Profile removed | `trusted` | `untrusted` |

As controls, the test expecting `trusted` failed on the device without the profile, and passed on a simulator after `xcrun simctl keychain <udid> add-root-cert` added the CA; that simulator was created for the run and deleted. The full `RunnerTests` run on a new iOS 27.0 simulator was 67 tests, 62 passed and 5 skipped (the trust test without its environment, the two process-kill helpers and the two reinstall phases). The device had been updated to iOS 27.2 since the earlier device rows, which ran on iOS 27.0.1.

## Oldest Runtime and `x86_64` Simulator

Run on 2026-11-09 on an Apple silicon host with Xcode 27.0 and Flutter 3.47.6, with the library at the current pin, on a simulator created for the run and deleted afterwards. The aim was the validation plan's iOS 15 minimum, or the oldest runtime the host could download and run, and the `x86_64` simulator slice.

**Runtime downloads.** `xcodebuild -downloadPlatform iOS -buildVersion <version>` answered "not available for download" for every requested version older than iOS 26: 15.0, 15.2, 15.4, 15.5, 16.0, 16.2, 16.4, 17.0, 17.2, 17.4, 17.5, 18.0, 18.1, 18.2, 18.3, 18.3.1, 18.4, 18.5 and 18.6, and for two older build numbers. iOS 26.0, 26.2 and 26.4 were offered, and those downloads were cancelled because they are newer than runtimes already installed. Xcode 27 therefore offers no runtime older than iOS 26, and the oldest runnable runtime on the host remains the installed `iOS 18.4 (22E238)`. iOS 15.0 to 18.3 have no simulator evidence; a runtime image for them would have to come from another source and be added with `xcrun simctl runtime add`, which this run did not do.

**Oldest runtime.** The XCTests ran with the command of [Adapters, TCP-01 and DNS-01](#adapters-tcp-01-and-dns-01) after `flutter build ios --debug --simulator`, and the example integration test with `flutter test integration_test -d <udid>`, as in [Example Application From Dart](#example-application-from-dart).

**`x86_64`.** The installed iOS 18.4 and 18.6 runtimes are universal (`x86_64` and `arm64`); iOS 26.5 and 27.0 are `arm64` only. The example built for testing for the `x86_64` simulator with `xcodebuild build-for-testing -workspace Runner.xcworkspace -scheme Runner -destination 'generic/platform=iOS Simulator' ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO`: the Runner, `RunnerTests`, Flutter, the Dart application and the plugin framework, which links the library's `ios-arm64_x86_64-simulator` slice, were all single-architecture `x86_64` binaries. None of it could run. Rosetta for macOS is not installed on the host, so an `x86_64` process is refused with "Bad CPU type in executable"; `xcodebuild -showdestinations` lists the iOS 18.4 simulator only as `arch:arm64`, `xcodebuild test` and `test-without-building` with `arch=x86_64` found no matching destination, and the `x86_64` application installed on the simulator but its launch was denied. Installing Rosetta needs a system software installation with license acceptance on the host, which this run did not do. No CI runner was used (CI coverage of the XCTests is separate work).

| Target | Model | OS | Architecture | XCTests | Integration test |
|---|---|---|---|---|---|
| Simulator, oldest runnable runtime `iOS 18.4 (22E238)` | iPhone 16 | iOS 18.4 | `arm64` | 66 run, 62 passed, 4 skipped | 1 of 1 passed |
| Simulator, iOS 15 to 18.3 runtimes | Not run: no runtime older than iOS 26 is offered for download by Xcode 27 | | | | |
| Simulator, iOS 18.4, `arch=x86_64` | Not run: built, not runnable without Rosetta on the host | | `x86_64` | Built for testing; no destination | Not run |

The four skipped XCTests are the two process-kill helpers and the two reinstall phases. The integration run also loaded `measurements_test.dart`, which is skipped without the Android measurement fixtures, so the run reported 1 passed and 1 skipped. No test failed and no Barometer code changed.

## Host Policy, Proxy and Signed Remote Tasks

Run on 2026-11-09 on an Apple silicon host with Xcode 27.0 and Flutter 3.47.6, with the library at the current pin, on simulators created for the run and deleted afterwards. The XCTests ran from `example/ios` with the command of [Adapters, TCP-01 and DNS-01](#adapters-tcp-01-and-dns-01) after `flutter build ios --debug --simulator`. New in this run:

- `HostPolicyTests` (5 tests). The generation gate: only a positive JSON integer is a generation, an unreadable document or one without such a generation is `trust_invalid`, and after generation 2 is activated a lower generation or the same generation with other bytes is `policy_rejected` with or without an open client, while the same bytes reopen after close and activating a lower document never lowers the floor. The host rows of `CC-TRUST-LOCAL-POLICY-LIFECYCLE-RUNTIME` through the channel host and the host policy adapter, with a fake background-task source: generation 2 is active with a run of a signed remote task waiting on a loopback proxy that never answers and a second admitted task. A generation-1 document, a generation-2 document with other content, an invalid generation-3 document and an incomplete generation-4 one return `policy_rejected`, `policy_rejected`, `trust_invalid` and `trust_invalid`, and the run stays `active` after each. A valid generation-3 document that removes the registration replaces the client at `initialize`: both task handles and the run handle return `handle_unavailable`, the run's background task ends, its only result is `cancelled_by_host`, the earlier package and a new one are rejected as `target_not_registered`, and the proxy sees no further connection. Generation 2 is then rejected again, both while generation 3 is active and, after `close`, for a new channel host of the same process, which activates generation 3 and then a generation-4 document that restores the registration and admits a new package. The release-review input: with a document whose `release_reviewed_tasks` lists one embedded one-time task without `not_after` by issuer and digest, that task is admitted from the test bundle and an unlisted one is `task_schema_invalid`; under a document without the listing the listed task is `task_schema_invalid` too.
- `LocalPolicyTests` (2 tests). With the trusted document's `device` member (minimum 50 percent, charging only) and the production `Device` adapter, the simulator reports battery level and charging as unknown and `startRun` returns `run_not_due`. With battery states set through the port's source, `startRun` returns `run_not_due` at 80 percent on battery, at 40 percent charging and with an unknown level while charging, and the run completes at 80 percent charging; without the member a run completes at 40 percent on battery. With a `network_context` member that lists only the direct path, a proxy-path TCP-01 attempt completes with egress `unavailable` and one that requires `country_code` is `not_run` with `network_context_unavailable`, and the proxy receives no CONNECT for the configured context endpoint; without the member the same configuration sends one there.
- `ProxyTests` (2 tests), through the facade: `setProxy` with a loopback proxy that answers CONNECT without contacting the target carries a proxy-path TCP-01 attempt to `completed`; an unapproved connection code, a missing port and port 0 return `proxy_rejected` and the previous proxy carries the next attempt; after `clearProxy`, repeated, a proxy-path attempt is `not_run` and reaches no proxy; `setProxy` works again after clearing. With an attempt waiting on the never-answering proxy and the record store held by the test, `setProxy` and `clearProxy` each return `cleanup_incomplete` after the two-second cleanup bound, a further `clearProxy` returns `cleanup_incomplete`, no replacement proxy is contacted, and the client closes once the store is released.
- `RemoteTaskTests` (2 tests): the test signer derives the RFC 8032 test 1 public key, against which the published signature verifies; a package signed with a synthetic key of the policy, derived from a fixed public test seed, is installed with `InstallRemoteTask` and admitted through the channel host, and the same bytes admit again as an exact redelivery; a package signed with another seed under the same key ID, one whose task bytes were changed after signing and one signed with a key whose validity ended an hour earlier are each rejected as `task_source_unauthenticated`.

| Target | Model | OS | Architecture | XCTests |
|---|---|---|---|---|
| Simulator, current runtime `iOS 27.0 (24A434)` | iPhone 17 | iOS 27.0 | `arm64` | 66 run, 62 passed, 4 skipped |
| Simulator, oldest installed runtime `iOS 18.4 (22E238)` | iPhone 16 | iOS 18.4 | `arm64` | 66 run, 62 passed, 4 skipped |

The four skipped tests are the two process-kill helpers and the two reinstall phases. The new tests contact no network: tasks run only on the proxy path through loopback proxies in the test process, which never open a connection onward, and the context endpoint `https://9.9.9.9/network-context` is only named in a CONNECT to such a proxy. The keys are synthetic and no deployment key or real proxy is used. CryptoKit randomizes its Ed25519 signatures, so the signer is checked by its public key and a published signature rather than by reproducing the RFC signature. Policy replacement is in-process only and, because a bundle does not change while its process runs, is reached in these tests through a test document source; the generation floor is not persisted, so the rollback check across application releases rests on App Store versioning and Go's replay records, which these runs do not exercise. Battery constraints that the simulator cannot report were exercised through the port's source, not through the simulator. No device ran these tests.

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
| Simulator, iOS 15 to 18.3 runtimes | Not run: not offered for download by Xcode 27 ([details](#oldest-runtime-and-x86_64-simulator)) | | | | |
| Simulator, `x86_64` | Built, not run: no Rosetta on the host ([details](#oldest-runtime-and-x86_64-simulator)) | | | | |
| Physical device, connected by USB | iPhone 13 | iOS 27.0.1 | `arm64` | 24 of 24 run passed, 2 skipped | Not run; see [Trust Store on the Device](#trust-store-on-the-device) |

The validation plan's minimum is an iOS 15 simulator runtime. Xcode 27 offers no runtime older than iOS 26 for download, so the host's oldest runnable runtime is iOS 18.4 and the iOS 15 to 18.3 range has no simulator evidence. The `x86_64` simulator slice builds and links but was not run, because the Apple silicon host has no Rosetta; see [Oldest Runtime and `x86_64` Simulator](#oldest-runtime-and-x86_64-simulator). The physical-device row ran the same XCTests from `example/ios` on 2026-11-05 with the same library build-info, after `flutter build ios --debug --no-codesign`, with `-destination 'platform=iOS,id=<udid>'` and Xcode automatic signing under a development team passed on the `xcodebuild` command line; no team, identity, profile or device identifier is committed. The trust-store probe was not run on the device; the device's trust store was checked later in the application process ([Trust Store on the Device](#trust-store-on-the-device)). The iOS 15 to 26 range has no device evidence.

## Method Channel

Run on 2026-11-05 on the same host and library build, with the same command, on the iOS 27.0 iPhone 17 simulator. `ChannelTests` (14 tests) checks the Swift channel contract (exact argument keys, bounds counted in UTF-16 code units as Dart and Kotlin count them, embedded task names, rejection of trust inputs and unknown methods), the error-code filter, the embedded issuer of the trusted local document, and the host against the facade: nothing is created before `initialize`, the lifecycle runs through the channel with the facade's codes, the synthetic expired task is installed from the test bundle's `barometer/tasks/expired.json` with the embedded issuer and fails a later admission step, an unsigned remote package is refused as `task_source_unauthenticated`, a missing trusted local document is `trust_invalid` and a detached host answers `client_closed`. Every answer arrives on the main thread and no store call runs on it. The tests contact no network. The full `RunnerTests` run was 40 tests, 38 passed and 2 skipped (the process-kill helpers). The example application, run on the same simulator with a temporary Dart entry point that was not committed, answered `nextBundle` with `not_initialized`, `initialize` with `trust_invalid` (the example bundles no trusted local document), an embedded task name outside the task directory with `invalid_arguments`, and `close` with success, so Dart reaches the Swift handler. `flutter build ios --debug --simulator` and `flutter build ios --debug --no-codesign` succeeded. No device or `x86_64` simulator ran the channel tests; they ran on iOS 18.4 as part of the later full `RunnerTests` runs.

## Example Application From Dart

Run on 2026-11-05 from `example` with `flutter test integration_test -d <udid>`, Flutter 3.47.6 and Xcode 27.0 on an Apple silicon host, with the library above. `barometer_flow_test.dart` (1 test) launches the example, checks that nothing has run, presses **Run tcp-01** and **Run dns-01**, and checks that each run reaches `terminal` through `runState` polling from Dart, that its bundle holds one result with execution state `completed` and observation type `tcp_connect` or `dns_query` from platform `ios`, and that no bundle is pending after the acknowledgement. The trusted local document and tasks are the example's synthetic files, written into the application bundle by the Runner's **Generate Barometer Resources** build phase. TCP-01 contacts `1.1.1.1:443` once and DNS-01 resolves `example.org` once.

| Target | Model | OS | Architecture | Mode | Integration test |
|---|---|---|---|---|---|
| Simulator, runtime `iOS 26.5 (23F77)` | iPhone 17 Pro | iOS 26.5 | `arm64` | Standalone | 1 of 1 passed |
| Simulator, oldest runnable runtime `iOS 18.4 (22E238)` | iPhone 16 | iOS 18.4 | `arm64` | Standalone | 1 of 1 passed |
| CI simulator on `macos-15`, runtime `iOS 26.2` | iPhone 16 | iOS 26.2 | `arm64` | Standalone | 1 of 1 passed |
| Physical device, connected by USB | iPhone 13 (`iPhone14,5`) | iOS 27.0.1 (24A446) | `arm64` | Standalone | 1 of 1 passed |
| Physical device, connected by USB | iPhone 13 (`iPhone14,5`) | iOS 27.0.1 (24A446) | `arm64` | Umbrella | 1 of 1 passed |

The CI row ran with Flutter 3.47.8 and the runner's Xcode (reported as 16.4), with a library built in the same job by `scripts/build-native.sh apple` at the same pin; the manually started device build workflow runs it on the `iPhone <number>` simulator of the newest installed iOS runtime. An earlier CI attempt on an iPhone SE (3rd generation) simulator of the same runtime built the example and then made no progress for 19 minutes before it was cancelled; the step now has a 25-minute limit and logs verbosely. This is the first measurement run through the method channel on iOS, and the first run of the plugin inside the Flutter application with Dart driving it. The iOS 18.4 row ran on 2026-11-09 with the library at the current pin ([Oldest Runtime and `x86_64` Simulator](#oldest-runtime-and-x86_64-simulator)); no `x86_64` simulator ran it.

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

- **Trust store.** On iOS, Go 1.26 does not read certificate files: `SystemCertPool` returns a platform-backed pool, and verification against it or against Go's default roots is delegated to the Security framework (`SecTrustEvaluateWithError`). A root added to the simulator's trust store with `simctl keychain add-root-cert` is then accepted, so Go's system roots are the iOS trust store, including roots installed into it. On the iPhone 13 the same holds for a root installed by a configuration profile: it is rejected while full trust for it is off in Settings and accepted once full trust is on, as the platform verifier treats it for every application ([Trust Store on the Device](#trust-store-on-the-device)). Unlike Android, where [decision 0016](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0016-android-trust-root-set.md) excludes user-installed CAs, a root that the user or a profile installs and fully trusts is therefore trusted by Barometer on iOS; whether Apple platforms should narrow this is an open decision. The rejection of the synthetic CA arrives as an untyped error, not `x509.UnknownAuthorityError`; Barometer's TLS normalization classifies any verification error other than a name mismatch or expiry as `certificate_untrusted`, so the class is unchanged. `simctl keychain reset` did not remove the added root within the same simulator boot; the simulators were deleted instead.
- **Clock (known limitation).** Manual time cannot be detected on iOS: there is no public API that reports the "Set Automatically" setting. The adapter uses `Date()` (`CLOCK_REALTIME`) as trusted time whenever it is positive and reports a time that is not positive as unavailable, with no fallback. This is weaker than the Android adapter's `AUTO_TIME` check, and it leaves the residual risk of [a wrong or manipulated device clock](https://github.com/tv-rain/barometer-spec/blob/main/library/task-trust.md#residual-risks) named by the specification. The simulator runs did not exercise a manually set clock.
- **Network.** On the simulator `NWPath.supportsIPv4` and `supportsIPv6` were false on a satisfied Wi-Fi path, so the adapter also reads the address families of the path's primary interface, ignoring link-local and loopback addresses. The interface name, its addresses and the gateways are compared inside the adapter only. On the simulator the path reflects the host's network. A VPN cannot be configured on a simulator, so `detected` is checked only through the mapping; a real tunnel, a split tunnel and network changes on a device are not yet observed. iOS has no public validation or captive-portal source, so both are always `unknown`.
- **Suspension.** Suspension is reported only when the plugin's background task for an active run expires. The simulator runs replace the system's background-task source with a test double; a real expiry on a device is not yet observed.
- **Keychain.** On the simulator a Keychain item survives uninstalling the application, as on devices, so the sentinel is what keeps an earlier key from being used. The item uses the application's default access group; another application or extension reading it, iCloud Keychain, backup and restore and device migration are not yet tested.
- **Device.** The simulator does not model a battery; the tests check the mapping with fixed inputs and that a reading restores the monitoring setting.
- **Resolver.** An unknown name is reported as `resolver_error`, never `no_data`, as on Android. A lookup abandoned at its deadline keeps its thread and one of the four lookup slots until `getaddrinfo` returns.
- **Not covered.** Devices other than one iPhone 13 on iOS 27.0.1 and 27.2, a root installed by a mobile device management profile or one trusted without a profile, the iOS 15 to 18.3 runtimes (not offered for download by Xcode 27), `x86_64` simulators (built, not run without Rosetta), VPN, suspension and network changes on devices, lifecycle and cancellation on devices, linkage keys on devices and their backup, restore and migration behavior, the method channel and Dart API on devices other than the iPhone 13 integration-test runs, and the native XCTests in umbrella mode.
