# Apple Validation Record

This record lists where the Apple native glue was run and what each run covered, following the validation plan of [decision 0014](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0014-gomobile-facade-and-platform-matrix.md#validation-plan). It is evidence for the recorded inputs only. It does not establish conformance, safety, field behavior or support for any platform version, and Barometer Draft `0.1.0` status is unchanged.

No measurement result, outcome, device identifier, account, network name or address is recorded. The XCTests check the lifecycle and result shape and never print a result.

## Library Under Test

The `Barometer.xcframework.build-info.txt` written by `scripts/build-native.sh apple` at the pin:

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

## DEV-729: Adapters, TCP-01 and DNS-01

Run on 2026-11-05 on an Apple silicon host with Xcode 27.0, from `example/ios` with `xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination 'platform=iOS Simulator,id=<udid>' -only-testing:RunnerTests -parallel-testing-enabled NO -collect-test-diagnostics never`, after `flutter build ios --debug --simulator`. It runs `AdapterTests` (7 tests), `RecordStoreTests` (16 tests, from DEV-728), `RecordStoreKillTests` (2 process-kill helpers, skipped unless `scripts/ios-record-store-kill-test.sh` drives them) and `RunnerTests` (1 test). `AdapterTests` initializes a facade client with the Apple adapters, the state store and a synthetic trusted local document, runs TCP-01 to `1.1.1.1:443` and DNS-01 for `example.org` through `getaddrinfo`, each through `StartRun`, `NextBundle` and `AcknowledgeBundle` called off the main thread, checks that the coarse access state holds only the fixed values and that no result retains the target, and checks that the bundled `barometer/trust.json` initializes a client and an invalid document is rejected as `trust_invalid`.

The trust-store check ran a Go probe built from Go 1.26.0 for `ios/arm64` against the iPhoneSimulator 27.0 SDK (deployment target 15.0) and run with `xcrun simctl spawn`. It loads `x509.SystemCertPool`, verifies a leaf issued by a synthetic CA generated at run time against Go's default roots and against the system pool, verifies the same leaf against that CA alone, and completes one TLS handshake to `example.org:443` with Go's default roots. On simulators created for the check and deleted afterwards, it then added the synthetic CA with `xcrun simctl keychain <udid> add-root-cert` and verified the leaf again. The probe is not part of either repository.

| Target | Model | OS | Architecture | XCTests | Trust-store probe |
|---|---|---|---|---|---|
| Simulator, current runtime `iOS 27.0 (24A434)` | iPhone 17 | iOS 27.0 | `arm64` | 24 of 24 run passed, 2 skipped | `SystemCertPool` loads; synthetic CA rejected by both; public server verifies; after `add-root-cert` the synthetic leaf verifies |
| Simulator, oldest installed runtime `iOS 18.4 (22E238)` | iPhone 16 | iOS 18.4 | `arm64` | 24 of 24 run passed, 2 skipped | Same as iOS 27.0 |
| Simulator, iOS 15 runtime | Not run | | | | |
| Simulator, `x86_64` | Not run | | | | |
| Physical device | Not run | | | | |

The validation plan's minimum is an iOS 15 simulator runtime. None is installed on this host and it was not downloaded: the host's oldest runnable runtime is iOS 18.4, so the iOS 15 to 18.3 range has no simulator evidence. The `x86_64` simulator slice was built but not run, because the host is Apple silicon. Physical-device evidence is the next task.

## Observed Behavior and Gaps

- **Trust store.** On iOS, Go 1.26 does not read certificate files: `SystemCertPool` returns a platform-backed pool, and verification against it or against Go's default roots is delegated to the Security framework (`SecTrustEvaluateWithError`). A root added to the simulator's trust store with `simctl keychain add-root-cert` is then accepted, so Go's system roots are the iOS trust store, including roots installed into it. The device's handling of user- or profile-installed roots, which requires the user to enable full trust in Settings, is not yet observed. The rejection of the synthetic CA arrives as an untyped error, not `x509.UnknownAuthorityError`; Barometer's TLS normalization classifies any verification error other than a name mismatch or expiry as `certificate_untrusted`, so the class is unchanged. `simctl keychain reset` did not remove the added root within the same simulator boot; the simulators were deleted instead.
- **Clock (known limitation).** Manual time cannot be detected on iOS: there is no public API that reports the "Set Automatically" setting. The adapter uses `Date()` (`CLOCK_REALTIME`) as trusted time whenever it is positive and reports a time that is not positive as unavailable, with no fallback. This is weaker than the Android adapter's `AUTO_TIME` check, and it leaves the residual risk of [a wrong or manipulated device clock](https://github.com/tv-rain/barometer-spec/blob/main/library/task-trust.md#residual-risks) named by the specification. The simulator runs did not exercise a manually set clock.
- **Network.** On the simulator `NWPath.supportsIPv4` and `supportsIPv6` were false on a satisfied Wi-Fi path, so the adapter also reads the address families of the path's primary interface, ignoring link-local and loopback addresses. The interface name, its addresses and the gateways are compared inside the adapter only. On the simulator the path reflects the host's network.
- **Device.** The simulator does not model a battery; the tests check the mapping with fixed inputs and that a reading restores the monitoring setting.
- **Resolver.** An unknown name is reported as `resolver_error`, never `no_data`, as on Android. A lookup abandoned at its deadline keeps its thread and one of the four lookup slots until `getaddrinfo` returns.
- **Not covered.** A physical device, the iOS 15 to 18.3 runtimes, `x86_64` simulators, VPN, validation and suspension signals, the network-change matrix, lifecycle and cancellation on devices, protected linkage keys (M3, DEV-709), the Dart API and the umbrella build (DEV-706).
