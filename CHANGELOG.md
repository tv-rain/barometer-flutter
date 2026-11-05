# Changelog

All notable changes to `barometer_flutter` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). A version does not by itself establish implementation conformance, platform support, field validation, or support for a Draft Barometer specification.

## [Unreleased]

### Added

- Android capability and network adapters (DEV-725): Kotlin backends of the facade `Clock` (wall clock trusted only while automatic time is on, otherwise unavailable), `Consent` (always `absent` until a host consent source exists), `Device` (coarse battery and charging), `TimeZone` (IANA identifier), basic `Network` (coarse type and IPv4 and IPv6 availability with an access-network generation and a single-shot change watch; VPN, validation and captive portal stay `unknown`) and `SystemResolver` (`InetAddress` lookup bounded by the deadline). `BarometerBinding.newClient` assembles them with the state store, and `TrustDocument` reads the `barometer-trust/1` document from the application asset `barometer/trust.json`. The plugin manifest now requests `ACCESS_NETWORK_STATE`, which merges into host applications. Instrumented tests run TCP-01 and DNS-01 through the facade; [the Android validation record](docs/android-validation.md) lists the emulators and device that ran them. No Dart API change and no support claim.
- Android state-store backend (DEV-724): `RecordStore`, the Kotlin backend of the facade `Records` callback, stores one storage scope's records as files under the application's no-backup directory with atomic replacement, per-call deadlines, arrival-order execution that keeps abandoned writes behind later deletes and close, refusal of other puts while a clearing marker is stored, one owner per scope and no work on the UI thread. JVM unit tests and instrumented tests cover it. No Dart API change.
- Repository skeleton (DEV-715): a Flutter plugin for Android and iOS with no Dart API, an example application, a script that builds the native Barometer library from a pinned `barometer-go` commit, and CI that builds the example on both platforms. Android minSdk 21 and compileSdk 35, iOS 15.0, Dart `^3.8.1`. Nothing is published.

### Changed

- `scripts/barometer-go.revision` pins `barometer-go` `c49695c9406d64d34d247de827ae2b0343634640` (barometer-go PR #116). The facade's `Records.Get` now reports a known-absent key with the non-nil `newAbsentRecordValue()`, because Swift cannot return nil from the generated throwing method, and treats a nil return as unavailable. The `Records` adapter in `BarometerBinding.kt` returns the absent value for a key `RecordStore` does not hold, and `RecordStoreDeviceTest` expects it. `RecordStore` itself, Swift and Dart are unchanged.
- `scripts/barometer-go.revision` pins `barometer-go` `8f8d7c4a01159e654f58bd7d340cd6e4533069f2`. With it the facade hands `Records` and `LinkageKeyStore` callbacks to native code in the order Go issues them and never hands over a call past its deadline, so a write abandoned before a clear can no longer reach `RecordStore` after it; `StartRun` also fails closed once its lifecycle deadline has passed. The README and `RecordStore` documentation now say which side guarantees the order. No Kotlin, Swift or Dart behavior changes.
- `scripts/barometer-go.revision` pins `barometer-go` `52789565c85f9d14d7b2ce1d5e42f85b11cea753`, the merge of the `barometermobile` gomobile facade (DEV-723). The native library now exposes only the facade, so `BarometerBinding.kt` and `BarometerBinding.swift` name `barometermobile.Client` and `BarometermobileClient` (DEV-724).
