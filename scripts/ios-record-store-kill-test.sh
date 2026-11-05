#!/usr/bin/env bash
# Checks that RecordStore writes are atomic under process kill and survive restart, on an iOS
# simulator. Each round runs RecordStoreKillTests.testKillWriter, which SIGKILLs its own test
# process in the middle of large record writes, and then testKillVerify in a new process.
#
# Usage: bash scripts/ios-record-store-kill-test.sh <simulator-udid> [rounds]
# Run `flutter build ios --debug --simulator` in example/ first so the Pods and Flutter
# configuration exist.
set -euo pipefail

udid="${1:?usage: $0 <simulator-udid> [rounds]}"
rounds="${2:-5}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

common=(
  -workspace "$root/example/ios/Runner.xcworkspace" -scheme Runner
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$work/dd"
  -parallel-testing-enabled NO -collect-test-diagnostics never
)

xcodebuild build-for-testing "${common[@]}" >"$work/build.log" 2>&1 || {
  tail -40 "$work/build.log"
  exit 1
}

for round in $(seq 1 "$rounds"); do
  after=$((3 + round * 7))
  # The writer kills its own process, so xcodebuild reports a failure here by design.
  TEST_RUNNER_BAROMETER_KILL_TEST=write TEST_RUNNER_BAROMETER_KILL_AFTER="$after" \
    xcodebuild test-without-building "${common[@]}" \
    -only-testing:RunnerTests/RecordStoreKillTests/testKillWriter >"$work/write-$round.log" 2>&1 || true
  if ! grep -q 'testKillWriter' "$work/write-$round.log" ||
    grep -q "testKillWriter.*\(passed\|skipped\)" "$work/write-$round.log"; then
    echo "round $round: the writer did not run or was not killed" >&2
    tail -40 "$work/write-$round.log" >&2
    exit 1
  fi
  if ! TEST_RUNNER_BAROMETER_KILL_TEST=verify \
    xcodebuild test-without-building "${common[@]}" \
    -only-testing:RunnerTests/RecordStoreKillTests/testKillVerify >"$work/verify-$round.log" 2>&1 ||
    ! grep -q "testKillVerify.*passed" "$work/verify-$round.log"; then
    echo "round $round: verification failed" >&2
    tail -60 "$work/verify-$round.log" >&2
    exit 1
  fi
  echo "round $round: killed after $after+ writes; the earlier or the new value survived whole"
done
echo "record store kill test passed: $rounds rounds"
