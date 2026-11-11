# Proxy Host Integration

This document maps the host-integration requirements of the proxy contract to the plugin's Dart API, method channel and Android and Apple native glue. It answers the four checklist questions of the review case `RV-CC-PROXY-HOST-INTEGRATION` in the [`barometer-go` cross-cutting plan](https://github.com/tv-rain/barometer-go/blob/main/docs/cross-cutting-requirements.md#cc-proxy-host-integration) for the code at this revision. It is the implementer's mapping, not that review: the review needs a mobile binding reviewer independent of the binding implementer, and it has not been held. It does not establish conformance, platform support or field behavior.

Requirements, at public revision [`dc51b6d`](https://github.com/tv-rain/barometer-spec/blob/dc51b6d52abb414cdfd71930f442b80408f36f00/library/proxy.md#host-integration):

- **REQ-PROXY-0002.** The host may provide the proxy at initialization and replace or clear it while the application runs; the binding accepts only ordinary serializable values and requires no native callbacks, interfaces, sockets or complex objects.
- **REQ-PROXY-0003.** Method names may follow binding conventions; initialization, atomic replacement and clearing have semantics equivalent to the core contract.
- **REQ-PROXY-0004.** The egress-classification endpoints are configured separately at the same initialization and are not properties of the proxy object.
- **REQ-PROXY-0014.** The host keeps the previous local proxy available until `setProxy` or `clearProxy` returns.

## Method Mapping

Every layer passes the proxy as JSON text, and only the Go core parses it. The plugin adds no proxy state, validation, resolution or retry of its own.

| Operation | Dart (`BarometerClient`) | Channel method and arguments | Android glue | Apple glue | `barometermobile` facade and Go core |
|---|---|---|---|---|---|
| Initialization with a proxy | `initialize(Map config)`, with the proxy object as the `proxy` member | `initialize`, `{config: String}` | `BarometerHost.kt` opens the record store and facade client, then `Client.initialize(String)` | `BarometerHost.swift` likewise, then `BarometerClient.initialize(_:)` in `BarometerBinding.swift` | `Client.Initialize(configJSON string) error` |
| Atomic replacement | `setProxy(Map proxy)` | `setProxy`, `{proxy: String}` | `Client.setProxy(String)` | `BarometerClient.setProxy(_:)` | `Client.SetProxy(proxyJSON string) error` |
| Clearing | `clearProxy()` | `clearProxy`, no arguments | `Client.clearProxy()` | `BarometerClient.clearProxy()` | `Client.ClearProxy() error` |

Dart encodes each map with `jsonEncode` ([Strict JSON](../README.md#strict-json)). The Kotlin and Swift channel contracts (`ChannelContract.kt`, `ChannelContract.swift`) accept an argument map only with exactly the listed keys, bound JSON text to 65,536 characters and reject anything else with `invalid_arguments` before any facade call. The native hosts run the facade call on a worker, never on the UI or main thread, and answer on the main thread. The Go names are those of the facade's documented surface (`barometer-go` `docs/public-api.md`), whose signatures `barometer-go` checks in `TestPublicSurfaceMatchesDocumentedSignatures` and `TestFacadeSurfaceIsTheReviewedBindingSurface`.

## Checklist Answers

1. **Only ordinary serializable values.** Yes, on every layer. Dart takes a `Map<String, Object?>` and sends a `String`; a value `jsonEncode` cannot encode fails in Dart with `invalid_arguments` and makes no call. The channel carries only that `String`. The Android and Apple glue pass the same `String` to the facade, whose proxy methods take a string or nothing. The proxy object has exactly the fields `host`, `port` and `connection_code` (REQ-PROXY-0005); the Go core rejects any other member, including an endpoint field, as `proxy_rejected`.
2. **No native callbacks, interfaces, sockets or complex objects.** Yes. No Dart call or channel method takes a callback, listener, socket, file descriptor or platform object, and the plugin registers none for the proxy. The host runs its own local proxy service and gives Barometer only its address, port and connection code. The native adapters the facade needs (network, resolver, device, linkage keys) are Barometer-owned glue that the plugin creates; the host supplies none of them.
3. **Initialization, atomic replacement and clearing with equivalent semantics.** Yes, by delegation: each Dart call is exactly one facade call with the same text, and the native glue returns the facade's outcome unchanged. The Go core validates the whole replacement before any change, returns `proxy_rejected` and keeps the previous configuration on invalid input; otherwise it stops admission on the previous generation, cancels and drains its attempts within the cleanup bound, installs the replacement or clears the proxy atomically, and returns only after the previous generation is no longer in use (REQ-PROXY-0008, REQ-PROXY-0013). `clearProxy` may be repeated. A proxy-path task without a proxy is `not_run`; a direct task is unaffected and never falls back. The atomicity itself is the Go core's (`barometer-go` `proxy.go`): the plugin may run `setProxy` and `clearProxy` concurrently with other calls on up to four workers, and while a change is in progress the core answers other lifecycle calls, admission and new starts with `transition_in_progress` instead of mixing generations.
4. **Egress-classification endpoints configured separately at initialization.** Yes. The endpoints are the top-level `network_context` member of the `initialize` configuration, next to `proxy`, never a member of the proxy object: `setProxy` with a proxy object carrying `primary_endpoint` returns `proxy_rejected`. Replacing or clearing the proxy leaves the configured endpoints unchanged, which the Go core asserts in `TestProxyHostConfigurationStaysSeparate`; the glue cannot change them, because it forwards the text unchanged. The endpoints must also be approved by the trusted local document, as must the proxy's connection code ([Android Host Policy](../README.md#android-host-policy), [Apple Host Policy](../README.md#apple-host-policy)).

## Error Codes

`setProxy` and `clearProxy` throw `BarometerException(code)` with:

| Code | Raised when |
|---|---|
| `proxy_rejected` | The replacement is not a valid proxy object (an unknown member, a missing or out-of-range `port`, a non-loopback `host`), or the trusted local document does not approve its `connection_code`. The previous proxy stays configured |
| `cleanup_incomplete` | The previous generation's work did not end within the cleanup bound. Nothing is installed and the client is blocked: later calls return `cleanup_incomplete` until it is closed or cleared |
| `transition_in_progress` | Another lifecycle change, such as a proxy change or `initialize`, is in progress |
| `not_initialized`, `client_closed`, `invalid_arguments`, `native_error` | As for every call ([Dart API](../README.md#dart-api)) |

Both proxy codes are facade errors whose message is only the code, so the Android and Apple hosts forward them as the `PlatformException` code with no message or details, and Dart turns that into `BarometerException(code)`.

## Host Guidance

- Keep the previous local proxy listening until `setProxy` or `clearProxy` returns, whether it succeeds or fails (REQ-PROXY-0014). Barometer may still be draining tunnels through it until then. Only after the call returns may the host stop it or move it to another port. After `proxy_rejected` the previous proxy is still configured and in use, so keep it running.
- After `cleanup_incomplete`, recover with `close` and a new `initialize`, or with `clearMeasurementData`. Keep the previous local proxy available until then.
- Choose a `connection_code` that names a coarse connection-path category, stable across endpoint renewal, never an account, key, server address, session or installation identifier (REQ-PROXY-0009), and list it in the trusted local document's approvals.
- The proxy listens on loopback only: `host` is a loopback IP address or `localhost`, and Barometer rejects any other host (REQ-PROXY-0007).
- Choose the egress-classification endpoints, review them for privacy, approve them in the trusted local document and pass them in `network_context` at `initialize`. On the proxy path Barometer contacts only an explicit-IP endpoint, through the same proxy generation as the measurement; a hostname endpoint is unavailable there ([decision 0013](https://github.com/tv-rain/barometer/blob/main/docs/decisions/0013-explicit-ip-only-proxy-connect.md)).

## Evidence

| Check | Where | What it shows |
|---|---|---|
| Dart: `the remaining calls send their arguments` | `test/barometer_client_test.dart` | `setProxy` sends only `{proxy: String}` with the map's JSON; `clearProxy` sends no arguments |
| Dart: `proxy codes reach Dart unchanged` | `test/barometer_client_test.dart` | `proxy_rejected` and `cleanup_incomplete` from the channel become `BarometerException` with the same code for both calls |
| Kotlin host tests and Swift `ChannelTests` | `ChannelContractTest.kt`, `ChannelTests.swift` | The channel accepts only the listed argument keys, and only checked facade codes cross |
| Android `ProxyDeviceTest` (3 tests), Apple `ProxyTests` (3 tests) | `android/src/androidTest`, `example/ios/RunnerTests` | Through the facade: a proxy carries an attempt; an unapproved code, a missing port and port 0 are `proxy_rejected` and keep the previous proxy; clearing, repeated, leaves proxy-path runs `not_run`; a generation that cannot drain is `cleanup_incomplete` and blocks the client. Through the channel host: `proxy_rejected` for an unapproved code, a proxy object with `primary_endpoint` and a missing port, with the initial proxy kept; `cleanup_incomplete` from `setProxy` and `clearProxy` while the host's record store is held; `close` afterwards |
| Go: `TestProxyHostConfigurationStaysSeparate`, `TestCcProxyConfigurationValidation`, `TestProxyLifecycleSerialization`, `TestProxyCleanupIncomplete` | `barometer-go` | Separation of the context endpoints, validation before change, serialization of changes and the cleanup bound in the core |

The runs are recorded in [the Android validation record](android-validation.md#proxy-host-integration) and [the Apple validation record](apple-validation.md#proxy-host-integration).

## Limits

- The independent review `RV-CC-PROXY-HOST-INTEGRATION` is open; `CC-PROXY-HOST-INTEGRATION` stays planned in `barometer-go`.
- Replacement atomicity under concurrent readers is evidenced in the Go core only. The native tests check the outcome of each call, not interleavings.
- No physical device ran these checks; emulator and simulator runs only.
