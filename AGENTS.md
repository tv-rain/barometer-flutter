# Barometer Flutter Repository Instructions

## Scope

These instructions apply to the `barometer-flutter` repository. Follow the Barometer coordination repository's project-wide `AGENTS.md` as well when working from the coordinated workspace. If the two differ, this file controls repository-local details while accepted cross-project safety, privacy, architecture and workflow decisions continue to apply.

Before changing this repository, read `README.md`, the coordination repository's `docs/task-workflow.md` for tracked work, and [decision 0014](../docs/decisions/0014-gomobile-facade-and-platform-matrix.md) for the binding boundary and platform matrix.

## Repository Boundary

This repository owns the Flutter API, the Barometer-owned Kotlin and Swift glue, the example application and the plugin packaging. It does not own Go source, specifications or the native build itself: library behavior is defined by `barometer-spec` and implemented in `barometer-go`, and the native libraries are built by `barometer-go`'s build script through `scripts/build-native.sh`.

- Do not commit native binaries. `android/libs/` and `ios/Frameworks/` are build outputs.
- Change the `barometer-go` commit only by editing `scripts/barometer-go.revision`, and record the change in the changelog.
- Name gomobile-generated classes only in `BarometerBinding.kt` and `BarometerBinding.swift`, so the facade switch and the umbrella build change one place per platform.
- Keep the native glue dependent only on the generated binding classes, the Flutter embedding and platform SDKs. Do not depend on another gomobile library or ship a second copy of the gomobile runtime.

## Binding Boundary

- The Dart API carries only serializable lifecycle values. It has no call that installs a local policy, approval, trust root, issuer association or adapter, and method-channel arguments are never trust inputs.
- Trust inputs reach the facade only from reviewed, Barometer-owned native code.
- No Barometer work starts at plugin registration, construction or application launch.
- A change to the public Dart API, the channel contract or the native adapter surface is a reviewed public-API change.

## Safety and Privacy

Assume hostile networks, possible surveillance and participants in repressive environments. Do not add user, account, advertising, device, SIM, subscriber or other identifying data. Do not add analytics, crash reporting or other third-party SDKs. Never commit secrets, signing identities, participant data, measurement data, personal machine paths or temporary agent files.

Use precise, conservative language. A successful build is not loading, execution or platform support, and being inside the platform matrix is a target, not a support claim.

## Canonical Commands

Run from the repository root:

- `bash scripts/build-native.sh android|apple` builds the native library at the pinned commit.
- `dart format --output=none --set-exit-if-changed .` checks formatting.
- `flutter analyze` analyzes the plugin and example.
- `flutter test` in `example/` runs the example's widget test.
- `flutter build apk --debug`, `flutter build ios --debug --no-codesign` and `flutter build ios --debug --simulator` in `example/` build the example.

Run the platform builds on hosts with the corresponding prerequisites and report any validation that could not run. Before handoff, run `git diff --check`.
