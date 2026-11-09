#!/usr/bin/env bash
# Checks the linkage key and the records across uninstall and reinstall on an iOS simulator.
# ReinstallTests.testReinstallSeed runs TCP-01 to 1.1.1.1:443 once with linkage on, which leaves
# records, a pending bundle, the Keychain key and the reinstall sentinel, and prints the key's
# fingerprint (a SHA-256 of an HMAC of a fixed synthetic message). The script then uninstalls
# the example application and runs ReinstallTests.testReinstallVerify, which checks that no
# Barometer file survived, that initializing creates no key and that the first derivation uses
# a new key. With --control the application is not uninstalled, so the verification must fail.
#
# Usage: bash scripts/ios-reinstall-check.sh <simulator-udid> [--control]
# Simulators only. Run `flutter build ios --debug --simulator` in example/ first so the Pods and
# Flutter configuration exist. The application is left installed.
set -euo pipefail

udid="${1:?usage: $0 <simulator-udid> [--control]}"
control=false
case "${2:-}" in
  '') ;;
  --control) control=true ;;
  *) echo "usage: $0 <simulator-udid> [--control]" >&2; exit 2 ;;
esac
if ! xcrun simctl list devices | grep -q "($udid)"; then
  echo 'Refusing: not a simulator' >&2
  exit 1
fi

bundle_id=com.tvrain.barometerFlutterExample
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

common=(
  -workspace "$root/example/ios/Runner.xcworkspace" -scheme Runner
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$work/dd"
  -parallel-testing-enabled NO -collect-test-diagnostics never
)

# xcodebuild shuts down a simulator it booted itself, and simctl uninstall needs it booted.
xcrun simctl bootstatus "$udid" -b >/dev/null

xcodebuild build-for-testing "${common[@]}" >"$work/build.log" 2>&1 || {
  tail -40 "$work/build.log"
  exit 1
}

xcrun simctl uninstall "$udid" "$bundle_id" || true
TEST_RUNNER_BAROMETER_REINSTALL=seed xcodebuild test-without-building "${common[@]}" \
  -only-testing:RunnerTests/ReinstallTests/testReinstallSeed >"$work/seed.log" 2>&1 || true
if ! grep -q "testReinstallSeed.*passed" "$work/seed.log"; then
  echo 'The seed failed' >&2
  tail -40 "$work/seed.log" >&2
  exit 1
fi
fingerprint=$(sed -n 's/.*keyFingerprint=\([0-9a-f]\{64\}\).*/\1/p' "$work/seed.log" | head -n 1)
[ -n "$fingerprint" ] || { echo 'The seed reported no key fingerprint' >&2; exit 1; }
echo 'Seeded: records, a pending bundle, the Keychain key and the sentinel'

if [ "$control" = true ]; then
  echo 'Control: not uninstalled'
else
  xcrun simctl uninstall "$udid" "$bundle_id"
  echo 'Uninstalled'
fi

TEST_RUNNER_BAROMETER_REINSTALL=verify TEST_RUNNER_BAROMETER_PREVIOUS_KEY="$fingerprint" \
  xcodebuild test-without-building "${common[@]}" \
  -only-testing:RunnerTests/ReinstallTests/testReinstallVerify >"$work/verify.log" 2>&1 || true
survived=$(sed -En 's/.*keychainItemSurvived=(true|false).*/\1/p' "$work/verify.log" | head -n 1)
if grep -q "testReinstallVerify.*passed" "$work/verify.log"; then
  [ "$control" = false ] || { echo 'Control failed: the verification passed without an uninstall' >&2; exit 1; }
  echo "Reinstalled: no Barometer file survived, the Keychain item survived the uninstall: ${survived:-unknown}, and the first derivation used a new key"
else
  if [ "$control" = false ]; then
    echo 'Barometer state or the earlier key survived the reinstall' >&2
    grep -E 'error:' "$work/verify.log" >&2 || tail -40 "$work/verify.log" >&2
    exit 1
  fi
  echo 'Control: the verification failed as expected'
  grep -E 'error:' "$work/verify.log" | sed 's/.*error: [^:]*: //' || true
  xcrun simctl uninstall "$udid" "$bundle_id" || true
fi
