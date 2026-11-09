#!/usr/bin/env bash
# Checks on an iOS simulator that Barometer's writes fail closed on a full disk and that
# clearing still removes every record class and the linkage key (RunnerTests/StorageFullTests).
#
# The script creates a simulator for the run and mounts a size-limited APFS disk image in place
# of the directory that holds its applications' data containers, so that the test fills a
# volume that holds only those containers, as an application fills its own storage on a
# device, while the simulator's system data and Keychain stay on the host. It runs the test,
# checks that the test application's container was on the image, and then shuts the simulator
# down, detaches the image and deletes both.
#
# Usage: bash scripts/ios-storage-full-check.sh <device-type> <runtime-id> [image-size]
#   e.g. bash scripts/ios-storage-full-check.sh "iPhone 17" com.apple.CoreSimulator.SimRuntime.iOS-27-0 512m
# Run `flutter build ios --debug --simulator` in example/ first so the Pods and Flutter
# configuration exist. Never run the test on a device.
set -euo pipefail

type="${1:?usage: $0 <device-type> <runtime-id> [image-size]}"
runtime="${2:?usage: $0 <device-type> <runtime-id> [image-size]}"
size="${3:-512m}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
bundle=com.tvrain.barometerFlutterExample
udid=""
apps=""

cleanup() {
  if [ -n "$udid" ]; then
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    [ -n "$apps" ] && hdiutil detach "$apps" -force >/dev/null 2>&1 || true
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  fi
  hdiutil detach "$work/mnt" -force >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

udid=$(xcrun simctl create barometer-storage-full "$type" "$runtime")
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl shutdown "$udid"
apps="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Containers/Data/Application"
[ -d "$apps" ] || { echo "no application containers directory" >&2; exit 1; }

hdiutil create -quiet -size "$size" -fs APFS -type SPARSE -volname barometer-full "$work/full"
image="$work/full.sparseimage"
mkdir -p "$work/mnt"
hdiutil attach -quiet -nobrowse -owners on -mountpoint "$work/mnt" "$image"
ditto "$apps" "$work/mnt"
hdiutil detach -quiet "$work/mnt"
find "$apps" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
hdiutil attach -quiet -nobrowse -owners on -mountpoint "$apps" "$image"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
echo "container volume: $(df -h "$apps" | awk 'NR == 2 {print $2 " total, " $4 " available"}')"

common=(
  -workspace "$root/example/ios/Runner.xcworkspace" -scheme Runner
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$work/dd"
  -parallel-testing-enabled NO -collect-test-diagnostics never
)
log="$work/test.log"
if TEST_RUNNER_BAROMETER_STORAGE_FULL_TEST=1 xcodebuild test "${common[@]}" \
  -only-testing:RunnerTests/StorageFullTests >"$log" 2>&1 &&
  grep -q 'testWritesFailClosedAndClearingCompletesOnAFullDisk.*passed' "$log"; then
  container=$(xcrun simctl get_app_container "$udid" "$bundle" data)
  [ "$(df "$container" | awk 'NR == 2 {print $1}')" = "$(df "$apps" | awk 'NR == 2 {print $1}')" ] ||
    { echo "the test application's container was not on the image" >&2; exit 1; }
  echo "storage full check passed"
else
  grep -E "error: -|DIAG" "$log" | tail -30 >&2
  echo "storage full check failed" >&2
  exit 1
fi
