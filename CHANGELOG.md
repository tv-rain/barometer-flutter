# Changelog

All notable changes to `barometer_flutter` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). A version does not by itself establish implementation conformance, platform support, field validation, or support for a Draft Barometer specification.

## [Unreleased]

### Added

- Android state-store backend (DEV-724): `RecordStore`, the Kotlin backend of the facade `Records` callback, stores one storage scope's records as files under the application's no-backup directory with atomic replacement, per-call deadlines, arrival-order execution that keeps abandoned writes behind later deletes and close, refusal of other puts while a clearing marker is stored, one owner per scope and no work on the UI thread. JVM unit tests and instrumented tests cover it. No Dart API change.
- Repository skeleton (DEV-715): a Flutter plugin for Android and iOS with no Dart API, an example application, a script that builds the native Barometer library from a pinned `barometer-go` commit, and CI that builds the example on both platforms. Android minSdk 21 and compileSdk 35, iOS 15.0, Dart `^3.8.1`. Nothing is published.

### Changed

- `scripts/barometer-go.revision` pins `barometer-go` `52789565c85f9d14d7b2ce1d5e42f85b11cea753`, the merge of the `barometermobile` gomobile facade (DEV-723). The native library now exposes only the facade, so `BarometerBinding.kt` and `BarometerBinding.swift` name `barometermobile.Client` and `BarometermobileClient` (DEV-724).
