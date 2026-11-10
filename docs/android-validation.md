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

[Strict JSON](#strict-json), [Reinstall and Backup](#reinstall-and-backup), [Durability, Full Disk and the Nine Measurements](#durability-full-disk-and-the-nine-measurements), [Host Policy, Proxy and Signed Remote Tasks](#host-policy-proxy-and-signed-remote-tasks) and [Signals, Lifecycle and Linkage Keys](#signals-lifecycle-and-linkage-keys) were recorded with this library. [Trust Roots Inside the Application](#trust-roots-inside-the-application) was recorded at the earlier pin `d7a5440ef35accc89a16a3074c586fa3d9f0308a`, and the sections after it at `c49695c9406d64d34d247de827ae2b0343634640` and, where they say so, `52789565c85f9d14d7b2ce1d5e42f85b11cea753`; their build-info differs from the one above only in the `commit` line.

## Strict JSON

Run on 2026-11-10 from `example/android` with `./gradlew :barometer_flutter:connectedDebugAndroidTest` limited to `StrictJsonDeviceTest`, `ChannelDeviceTest` and `PolicyReplacementDeviceTest`, with the library above, on the API 24 and API 35 emulators of [Reinstall and Backup](#reinstall-and-backup) started headless. All 8 tests passed on each. `StrictJsonDeviceTest` (3 tests) builds a synthetic trusted document and changes `policy.generation` or another member: an escaped spelling of the name and the largest generation 2^63-1 are read by the host and accepted by the facade with the same value; equal, conflicting and escaped-equivalent duplicate names, a case variant in place of the name, a duplicate `format`, `-0`, `0`, a negative, `2.0`, `2e0`, `0.2e1`, a quoted value, 2^63 and 2^64+1, a byte-order mark, a trailing value, a lone surrogate escape, a raw control character, invalid UTF-8 and nesting past depth 10 are read as no generation by the host and rejected by the facade through `BarometerBinding.newClient`. A case-variant `Generation` next to `generation` is not read and the facade rejects the document. The embedded issuer is read through an escaped name and value and agrees with the facade; a repeated `issuer_id` yields none and the facade rejects the document. Through the channel host, each rejected document makes `initialize` return `trust_invalid`, `admitTask` and `nextBundle` return `not_initialized` and creates no record store; with escaped spellings of the generation and the issuer, the synthetic expired task gets the same admission code as with the plain document, past delivery binding and provenance. Host tests: `./gradlew :barometer_flutter:testDebugUnitTest` passed, including `StrictJsonTest` (6 tests). The example's integration test passed on the API 24 emulator, reading real bundles through the strict Dart reader.

## Reinstall and Backup

Run on 2026-11-09 with the library above on emulators started headless (`-no-window`, cold boot). `ReinstallBackupDeviceTest` and `scripts/android-reinstall-backup-check.sh` ([README](../README.md#build-and-validate)) check the linkage key, its sentinel and the records of the plugin's test application, which targets API 35 and allows backup by default. The seed runs TCP-01 to `1.1.1.1:443` once with rotating linkage, which leaves records, a pending bundle, the Keystore key and the sentinel, and writes a control file in the backed-up files directory; it reports the SHA-256 of the key's HMAC of a fixed synthetic message, which the host passes to the verification and does not keep. The verification checks that the control file is present after a restore and absent after a reinstall, that no Barometer file is present under the `no_backup` directory and no key under the scope's alias, that initializing with linkage on finds no pending bundle and creates no key, and that the first derivation gives another HMAC than the seed's key, so the earlier key is not used again. No result or derived value was printed or recorded.

| Target | Build fingerprint | OS | ABI |
|---|---|---|---|
| Emulator, `system-images;android-21;default;arm64-v8a` | `generic_arm64/sdk_phone_arm64/generic_arm64:5.0.2/LSY66K/8789838:eng/test-keys` | Android 5.0.2 (API 21) | `arm64-v8a` |
| Emulator, `system-images;android-24;default;arm64-v8a` | `Android/sdk_phone_arm64/generic_arm64:7.0/NYC/8695085:userdebug/test-keys` | Android 7.0 (API 24) | `arm64-v8a` |
| Emulator, `system-images;android-35;default;arm64-v8a` | `Android/sdk_phone64_arm64/emu64a:15/AE3A.240806.019/12368160:userdebug/test-keys` | Android 15 (API 35) | `arm64-v8a` |

| Check | API 24 | API 35 |
|---|---|---|
| `reinstall`: `adb uninstall` and `adb install` between seed and verification | Passed | Passed |
| `reinstall --control`: the same without the reinstall; the verification must fail | Failed as expected | Failed as expected |
| `adb-backup`: `adb backup -noapk` of the application, confirmed on the emulator's screen; the archive lists `_manifest`, `r/app_dxmaker_cache` and `f/backup-control`, and nothing from the `no_backup` directory | Passed | Passed |
| `adb-backup`, restore into a fresh installation: uninstall, install, `adb restore` | Passed | Passed |
| `adb-backup`, restore into the existing installation after a new seed: the restore cleared the application's data, the `no_backup` directory and the Keystore key with it, before restoring the control file | Passed | Passed |
| `bmgr`: `bmgr backupnow` through `com.android.localtransport/.LocalTransport`; the transport's copy, read as root, lists the same three entries; uninstall, install with automatic restore off, `bmgr restore <token> <package>` | Not available: the image has no backup transport | Passed |

The backups held the control file and no record, sentinel, reserve, lock or other Barometer file: the record store and the sentinel live under `Context.getNoBackupFilesDir()`, which Android leaves out of both full-data backup paths, and Keystore keys are not part of any backup. A restored application therefore found neither a key nor a sentinel, and its first derivation created a new key. A Keystore key present without its sentinel, which no path here produced, is replaced before use (`LinkageKeysDeviceTest.aKeyWithoutTheSentinelIsReplacedBeforeUse`). No backup exclusion had to be added. API 21 has no linkage key, so the script refuses it; its records use the same `no_backup` directory.

**API 21 rerun.** `./gradlew :barometer_flutter:connectedDebugAndroidTest` from `example/android` on the API 21 emulator, freshly started: 48 tests, 34 passed, 14 skipped, none failed. The passing ones include `AdapterDeviceTest` (6), `RecordStoreDeviceTest` (7), `ChannelDeviceTest` (4), `TrustRootDeviceTest` in its `platform` scenario, `NetworkSignalDeviceTest` (at rest and the test VPN), `ClearDataDeviceTest` (2), `LifecycleDeviceTest` (2), `LocalPolicyDeviceTest` (2), `PolicyReplacementDeviceTest`, `ProxyDeviceTest` (2), `RemoteTaskDeviceTest` (2), `DurabilityDeviceTest` and `StorageFullDeviceTest`. Skipped, because they cannot run on API 21:

- `LinkageKeysDeviceTest`, 6 of 7 tests, and `ClearDataDeviceTest.anInterruptedClearIsIncompleteUntilCompleted`: Android Keystore holds no HMAC key before API 23; `noKeyStoreBeforeApi23` passed.
- `NetworkSignalDeviceTest.deviceIdleIsSuspension`: no device idle before API 23.
- `NetworkSignalDeviceTest.wifiOffAndOnChangesTheDefaultNetwork`: the image has no Wi-Fi.
- `NetworkSignalDeviceTest.airplaneModeRemovesTheNetworkAndRestoresIt`: the shell user cannot switch airplane mode before API 30; the host script below ran it.
- `ClearStorageDeviceTest` (2) and `ReinstallBackupDeviceTest` (2): phases that only the host scripts run.

On the same emulator `scripts/android-airplane-check.sh` and `scripts/android-clear-storage-check.sh` passed and `scripts/android-clear-storage-check.sh --control` failed as expected. `TrustRootDeviceTest` was run in its `platform` scenario only, as on API 24 before; the other trust scenarios were not run on API 21.

These are emulator runs. Device-to-device migration, a vendor backup transport and hardware-backed keys remain the deferred device checks AD-07 and AD-08 of the [deferred device checks](https://github.com/tv-rain/barometer/blob/main/docs/device-checks.md).

## Durability, Full Disk and the Nine Measurements

Run on 2026-11-09 with the library above, Flutter 3.47.6 and emulators started headless (`-no-window`). These rows are the emulator coverage of the deferred device checks AD-06, AD-07 and AD-09 of the [deferred device checks](https://github.com/tv-rain/barometer/blob/main/docs/device-checks.md); a physical device, power loss and vendor power management remain open there.

| Target | Build fingerprint | OS | ABI |
|---|---|---|---|
| Emulator, `system-images;android-24;default;arm64-v8a` | `Android/sdk_phone_arm64/generic_arm64:7.0/NYC/8695085:userdebug/test-keys` | Android 7.0 (API 24) | `arm64-v8a` |
| Emulator, `system-images;android-35;default;arm64-v8a` | `Android/sdk_phone64_arm64/emu64a:15/AE3A.240806.019/12368160:userdebug/test-keys` | Android 15 (API 35) | `arm64-v8a` |

**Durability and process kill.** `DurabilityDeviceTest` binds `DurabilityService` in its own process. The service runs a one-time task and a repeating task (at most two runs, six hours apart) to completion through a loopback proxy that answers CONNECT without contacting the target, keeps their bundle pending, checks that a task reusing the one-time task's identifier with other content is rejected as `task_id_conflict`, and starts a third attempt that waits on a proxy that never answers. The test kills the process with `Process.killProcess` during that attempt. The next process opens the scope and finds the same oldest pending bundle, byte for byte by SHA-256; both completed tasks, admitted again as exact redeliveries, return `run_not_due`, because the run ledger kept their runs; and the conflicting task is still rejected as `task_id_conflict`, because the replay record kept the identifier. `clearMeasurementData` then removes every record and the sentinel. A kill during a write is `RecordStoreDeviceTest.writesAreAtomicUnderProcessKillAndSurviveRestart`: a process that replaces a record of the largest size with alternating values is killed mid-write, and the next process finds either the earlier or the new value, never a mixture, and the record written before the loop unchanged.

**Full disk.** `StorageFullDeviceTest` stores a completed run's records, a pending bundle and, from API 23, the linkage key and sentinel, admits a second task, and then fills the emulator's data partition: a filler file in the test application's files directory takes the free space with `posix_fallocate` in shrinking extents, without writing them, and single-byte appends fill the last block until `ENOSPC`, so the partition reports zero bytes available to the application. On the full partition a new task is rejected as `task_trust_unavailable`, because its replay record cannot be stored; the admitted task returns `run_not_due`, because its run cannot be reserved in the ledger; the stored record files and the pending bundle are unchanged and no temporary file is left behind. `clearMeasurementData`, still on the full partition, returns within 10 seconds and leaves no record, no Keystore key and no sentinel. The first run of this test found clearing failing with `clearing_incomplete` on a full partition, because the clearing marker could not be stored; the record store now keeps a 64 KiB reserve file per scope that a clearing-marker put releases first ([Android State Storage](../README.md#android-state-storage)).

**Instrumented suite.** `./gradlew :barometer_flutter:connectedDebugAndroidTest` from `example/android`, 46 tests: on API 24, 41 passed and 5 skipped; on API 35, 43 passed and 3 skipped, with the skips listed in [Host Policy, Proxy and Signed Remote Tasks](#host-policy-proxy-and-signed-remote-tasks). `DurabilityDeviceTest`, `StorageFullDeviceTest` and `RecordStoreDeviceTest` (9 tests) also passed on both emulators in umbrella mode, with the umbrella AAR below in place of the plugin's library.

**The nine measurements from Dart.** `example/integration_test/measurements_test.dart` runs TCP-01, DNS-01, DNS-03, DNS-04, TLS-01, HTTP-01, NET-01, NET-03 and NET-05 from Dart through `BarometerClient`, each as a synthetic one-time embedded task from `example/barometer-fixtures/`, against host fixtures prepared by `scripts/android-measurement-fixtures.sh start` ([README](../README.md#measurement-fixtures)). Every task names only `8.8.8.8` or `fixture.example.org` bootstrapped to it; the emulator's packet filter sends that traffic to `scripts/measurement_fixtures.py` on the host and rejects any other packet for the address, and a CA generated for the run is the emulator's only trust root (the system store on API 24, the updatable store on API 35). The test checks, for each task, one result with execution state `completed` from platform `android`, no pending bundle after the acknowledgement, and the observation types and outcome below. The outcomes are those of synthetic fixtures, not measurement data, and no result was printed or recorded.

| Task | Observation types | Outcome |
|---|---|---|
| TCP-01 to `8.8.8.8:443` | `tcp_connect` | `connected` |
| DNS-01, direct UDP to `8.8.8.8:53`, `example.org` A | `dns_query` | `resolved` |
| DNS-03, `https://fixture.example.org/dns-query` bootstrapped to `8.8.8.8` | `tcp_connect`, `tls_handshake`, `http_exchange`, `dns_query` | `response` |
| DNS-04, `fixture.example.org:853` bootstrapped to `8.8.8.8` | `tcp_connect`, `tls_handshake`, `dns_query` | `response` |
| TLS-01 to `8.8.8.8:443`, server name `fixture.example.org` | `tcp_connect`, `tls_handshake` | `handshake_succeeded` |
| HTTP-01, `https://8.8.8.8/fixture`, expected status 200 | `tcp_connect`, `tls_handshake`, `http_exchange` | `expected_response` |
| NET-01 | none | `snapshot` |
| NET-03, `http://8.8.8.8/generate_204`, expected status 204 | `tcp_connect`, `http_exchange` | `validated` |
| NET-05, a profile of DNS-01 (direct TCP), TCP-01, TLS-01 and HTTP-01 steps against the same fixtures | none at the top level | `completed` |

| Build | API 24 | API 35 |
|---|---|---|
| Standalone (the library above) | 1 of 1 passed | 1 of 1 passed |
| Umbrella (the AAR below) | 1 of 1 passed | 1 of 1 passed |

As a control, the standalone run on API 24 with the fixture listeners stopped and the redirect in place failed at the first task with `connection_refused`. In umbrella mode the example APK holds one `libgojni.so` per ABI, the umbrella's, and the CircumRain and `barometermobile` classes together. The umbrella AAR was built locally from the CircumRain umbrella's `barometer-integration` branch (`b4e7560`) with `make bind-android`, after `go get` raised its `barometer-go` requirement to the pin above; the raise changed no other module version, and the change was not committed there. Its build information:

```text
artifact: umbrella AAR (android/arm, android/arm64, android/386, android/amd64)
binds: circum-rain-lib, circum-rain-config, barometermobile
barometermobile: commit 7f5d7de7ada4709c1b2a4fdebbb4fb9b013ef918
go: go1.26.9
gomobile: golang.org/x/mobile v0.0.0-20260820023541-8e8303b9da6c
flags: -trimpath -androidapi 21 -ldflags='-s -w'
ndk: 29.0.14206865
status: local build for validation only; not a release, not platform support
```

The umbrella's own check (`make check-barometer-android`) reported no skipped `barometermobile` exports and no build-host paths in its four libraries. API 21 was not run: a Flutter application cannot run below API 24, and the native durability rows did not change there.

## Host Policy, Proxy and Signed Remote Tasks

Run on 2026-11-09 from `example/android` with `./gradlew :barometer_flutter:connectedDebugAndroidTest` and the library above, on the API 24 and API 35 emulators of the next section's table, started headless. The full suite of 44 tests ran on each; these are the 7 new ones:

- `PolicyReplacementDeviceTest` (1), the host rows of `CC-TRUST-LOCAL-POLICY-LIFECYCLE-RUNTIME` through the channel host and the host policy adapter. Generation 2 is active with a run of a signed remote task waiting on a loopback proxy that never answers and a second admitted task. A generation-1 document, a generation-2 document with other content, an invalid generation-3 document and an incomplete generation-4 one return `policy_rejected`, `policy_rejected`, `trust_invalid` and `trust_invalid`, and the run stays `active` after each. A valid generation-3 document that removes the registration replaces the client at `initialize`: both task handles and the run handle return `handle_unavailable`, the run's only result is `cancelled_by_host`, the earlier package and a new one are rejected as `target_not_registered`, and the proxy sees no further connection. Generation 2 is then rejected again, both while generation 3 is active and, after `close`, for a new channel host of the same process, which activates generation 3 and then a generation-4 document that restores the registration and admits a new package.
- `LocalPolicyDeviceTest` (2): with the trusted document's `device` member (minimum 50 percent, charging only), `startRun` returns `run_not_due` at 80 percent on battery and at 40 percent charging, and the run completes at 80 percent charging; without the member a run completes at 40 percent on battery. The battery state is set with `dumpsys battery` and reset afterwards. With a `network_context` member that lists only the direct path, a proxy-path TCP-01 attempt completes with egress `unavailable` and one that requires `country_code` is `not_run` with `network_context_unavailable`, and the proxy receives no CONNECT for the configured context endpoint; without the member the same configuration sends one there.
- `ProxyDeviceTest` (2), through the facade: `setProxy` with a loopback proxy that answers CONNECT without contacting the target carries a proxy-path TCP-01 attempt to `completed`; an unapproved connection code, a missing port and port 0 return `proxy_rejected` and the previous proxy carries the next attempt; after `clearProxy`, repeated, a proxy-path attempt is `not_run` and reaches no proxy; `setProxy` works again after clearing. With an attempt waiting on the never-answering proxy and the record store held by the test, `setProxy` and `clearProxy` each return `cleanup_incomplete` after the two-second cleanup bound, a further `clearProxy` returns `cleanup_incomplete`, no replacement proxy is contacted, and the client closes once the store is released.
- `RemoteTaskDeviceTest` (2): the test signer reproduces RFC 8032 test 1; a package signed with a synthetic key of the policy, derived from a fixed public test seed, is installed with `InstallRemoteTask` and admitted, and admits again as an exact redelivery; a package signed with another seed under the same key ID, one whose task bytes were changed after signing and one signed with a key whose validity ended an hour earlier are each rejected as `task_source_unauthenticated`.

| Target | Build fingerprint | OS | ABI | Instrumented tests | Skipped (not applicable) |
|---|---|---|---|---|---|
| Emulator, `system-images;android-24;default;arm64-v8a` | `Android/sdk_phone_arm64/generic_arm64:7.0/NYC/8695085:userdebug/test-keys` | Android 7.0 (API 24) | `arm64-v8a` | 39 passed, 5 skipped | No-key-store check, Wi-Fi (no Wi-Fi in the image), airplane mode, the two script phases |
| Emulator, `system-images;android-35;default;arm64-v8a` | `Android/sdk_phone64_arm64/emu64a:15/AE3A.240806.019/12368160:userdebug/test-keys` | Android 15 (API 35) | `arm64-v8a` | 41 passed, 3 skipped | No-key-store check, the two script phases |

The seven new tests passed again in a second run on both emulators. On API 35 `NetworkSignalDeviceTest.wifiOffAndOnChangesTheDefaultNetwork` first failed twice in an emulator that had run the suite before, because Wi-Fi did not return as the default network within the test's wait, and passed after a cold boot of the emulator; the run in the table is from that boot. A test that needs an attempt to stay active now waits until the access network has kept one generation for five seconds, so a connectivity change of an earlier test cannot end the attempt with `network_changed`. The example's integration test passed on the API 35 emulator with Flutter 3.47.6.

The new tests contact no network: tasks run only on the proxy path through loopback proxies in the test process, which never open a connection onward, and the context endpoint `https://9.9.9.9/network-context` is only named in a CONNECT to such a proxy. The keys are synthetic, no deployment key or real proxy is used, and API 21 was not run for this change. Policy replacement is in-process only: the generation floor is not persisted, so the rollback check across application releases rests on Android's version-code rule and Go's replay records, which these runs do not exercise.

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

The instrumentation's shell user cannot switch airplane mode before API 30, or run `su`, so those levels need the host script. On API 21 the platform remembers VPN consent by package name: after a reinstall, which changes the test application's user ID, it reports the permission as granted but does not establish the VPN until the emulator restarts, so the API 21 row was run on a freshly started emulator. These are emulator runs: real radios, vendor power management and hardware-backed keys remain the deferred device checks AD-05, AD-06 and AD-08 of the [deferred device checks](https://github.com/tv-rain/barometer/blob/main/docs/device-checks.md). Uninstall and reinstall and backup and restore of the key were run later ([Reinstall and Backup](#reinstall-and-backup)); device-to-device migration was not run.

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
| CI emulator on `ubuntu-24.04`, `system-images;android-35;default;x86_64`, umbrella mode | Emulator AVD created by `reactivecircus/android-emulator-runner` | Android 15 (API 35) | `x86_64` | 1 of 1 passed |
| CI emulator on `ubuntu-24.04`, `system-images;android-24;default;x86_64` | Emulator AVD created by `reactivecircus/android-emulator-runner` | Android 7.0 (API 24) | `x86_64` | 1 of 1 passed |
| CI emulator on `ubuntu-24.04`, `system-images;android-24;default;x86_64`, umbrella mode | Emulator AVD created by `reactivecircus/android-emulator-runner` | Android 7.0 (API 24) | `x86_64` | 1 of 1 passed |

The CI rows ran with Flutter 3.47.8 and a library built in the same job by `scripts/build-native.sh android` at the same pin, in the manually started device build workflow, which runs them on every start ([run of 2026-11-10](https://github.com/tv-rain/barometer-flutter/actions/runs/42843366272)). Each runs `barometer_flow_test.dart` once through `scripts/integration-test.sh`, which stops a run that has not finished within 15 minutes and prints the Flutter tool's log, the host's `adb` processes, the emulator's processes, logcat and the `adb` server log.

**Stalled installation on API 24.** Two earlier runs of the workflow ([one](https://github.com/tv-rain/barometer-flutter/actions/runs/42806009928), [two](https://github.com/tv-rain/barometer-flutter/actions/runs/42822665126)) stalled on the API 24 emulator while `flutter test` installed the application in umbrella mode, right after the standalone run on the same emulator had passed: one for 30 minutes until the step's limit, one until a ten-minute bound. A probe repeated the standalone and umbrella runs five times each on one API 24 emulator ([run](https://github.com/tv-rain/barometer-flutter/actions/runs/42833833730)); two umbrella runs stalled and the diagnostics showed the same state both times. The tool's `adb install -t -r` of the 169 MB debug APK was still running on the host; on the emulator, `installd` had reserved space for the package (`free_cache(169340722)`), the package manager logged nothing further, and a `cmd` process waited in a binder call. `adb` streams the APK into `cmd package install` on API 24 and later, and that transfer had stopped part way and never resumed. A second probe repeated the same ten runs with an `adb` that adds `--no-streaming` to `install`, which pushes the APK to the emulator and then installs it from there ([run](https://github.com/tv-rain/barometer-flutter/actions/runs/42839741689)): all ten passed, each installation in about 4.5 seconds. Raw `adb install` and uninstall of both APKs, 12 times in a row without running the application, had not stalled ([run](https://github.com/tv-rain/barometer-flutter/actions/runs/42826343634)); why the streamed transfer stops only after a test run, only on API 24 and so far only for the umbrella build, is not known. `scripts/integration-test.sh` therefore runs `flutter test` with a view of the Android SDK whose `adb` adds `--no-streaming` to `install`; the tool has no option for it.

The umbrella rows set `barometerUmbrellaArtifact` to the standalone library's local Maven publication, which binds the same facade: they exercise the plugin's umbrella dependency path, not an umbrella artifact that binds other Go packages, which ran only locally ([Durability, Full Disk and the Nine Measurements](#durability-full-disk-and-the-nine-measurements)). This is the first run of the plugin inside a Flutter application on Android: the Dart API, the method channel, the native host, the adapters and the facade together. The plugin's instrumented tests and host scripts run only locally.

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
- **Not covered.** Any physical device (see above); power loss; device-to-device migration of linkage keys and a vendor backup transport (uninstall and reinstall and backup and restore through `adb` and the local transport ran on emulators, [Reinstall and Backup](#reinstall-and-backup)); the Dart API on API 21 to 23 and 25 to 34 (a Flutter application cannot run below API 24); the instrumented tests and host scripts in CI. The umbrella build ran on API 24 and 35 emulators only ([Durability, Full Disk and the Nine Measurements](#durability-full-disk-and-the-nine-measurements)). The `x86_64` slice has run only the example's integration test, in CI at API 24 and API 35. The VPN, validation, captive-portal and suspension signals, lifecycle and cancellation and the protected linkage keys ran on emulators only ([Signals, Lifecycle and Linkage Keys](#signals-lifecycle-and-linkage-keys)).
