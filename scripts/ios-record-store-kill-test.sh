#!/usr/bin/env bash
# Checks durability under process kill on an iOS simulator or a connected device.
#
# - RecordStore writes are atomic under process kill and survive restart: each round runs
#   RecordStoreKillTests.testKillWriter, which SIGKILLs its own test process in the middle of
#   large record writes, and then testKillVerify in a new process.
# - Pending bundles, replay records and run-ledger entries survive a process kill during a run:
#   DurabilityTests.testDurabilityRun leaves them, starts an attempt that waits on a loopback
#   proxy and SIGKILLs its own process; testDurabilityVerify then checks them in a new process
#   and clears the scope.
#
# Usage: bash scripts/ios-record-store-kill-test.sh <simulator-or-device-udid> [rounds] [xcodebuild-arg...]
# Run `flutter build ios --debug --simulator` (or `--no-codesign` for a device) in example/ first
# so the Pods and Flutter configuration exist. For a device, pass the signing settings as
# xcodebuild arguments, for example -allowProvisioningUpdates DEVELOPMENT_TEAM=<team>; they are
# used on the command line only. The test application is installed over any existing one and
# never uninstalled.
set -euo pipefail

udid="${1:?usage: $0 <simulator-or-device-udid> [rounds] [xcodebuild-arg...]}"
rounds="${2:-5}"
shift $(($# < 2 ? $# : 2))
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if xcrun simctl list devices | grep -q "$udid"; then
  destination="platform=iOS Simulator,id=$udid"
else
  destination="platform=iOS,id=$udid"
fi
common=(
  -workspace "$root/example/ios/Runner.xcworkspace" -scheme Runner
  -destination "$destination" -derivedDataPath "$work/dd"
  -parallel-testing-enabled NO -collect-test-diagnostics never "$@"
)

xcodebuild build-for-testing "${common[@]}" >"$work/build.log" 2>&1 || {
  tail -40 "$work/build.log"
  exit 1
}

# Runs one test that kills its own process: xcodebuild reports a failure by design, and the
# test must have started, failed no assertion and been neither passed nor skipped.
killed() {
  local test=$1 log=$2
  shift 2
  env "$@" xcodebuild test-without-building "${common[@]}" -only-testing:"RunnerTests/$test" >"$log" 2>&1 || true
  grep -q "${test#*/}" "$log" && ! grep -q "${test#*/}.*\(passed\|skipped\)" "$log" &&
    ! grep -q "error: -\[RunnerTests\.${test%/*} ${test#*/}\]" "$log"
}

# Runs one test that must pass.
passes() {
  local test=$1 log=$2
  shift 2
  env "$@" xcodebuild test-without-building "${common[@]}" -only-testing:"RunnerTests/$test" >"$log" 2>&1 &&
    grep -q "${test#*/}.*passed" "$log"
}

for round in $(seq 1 "$rounds"); do
  after=$((3 + round * 7))
  if ! killed RecordStoreKillTests/testKillWriter "$work/write-$round.log" \
    TEST_RUNNER_BAROMETER_KILL_TEST=write TEST_RUNNER_BAROMETER_KILL_AFTER="$after"; then
    echo "round $round: the writer did not run or was not killed" >&2
    tail -40 "$work/write-$round.log" >&2
    exit 1
  fi
  if ! passes RecordStoreKillTests/testKillVerify "$work/verify-$round.log" TEST_RUNNER_BAROMETER_KILL_TEST=verify; then
    echo "round $round: verification failed" >&2
    tail -60 "$work/verify-$round.log" >&2
    exit 1
  fi
  echo "round $round: killed after $after+ writes; the earlier or the new value survived whole"
done
echo "record store kill test passed: $rounds rounds"

if ! killed DurabilityTests/testDurabilityRun "$work/durability-run.log" TEST_RUNNER_BAROMETER_DURABILITY_TEST=run; then
  echo "durability: the run phase did not run or was not killed" >&2
  tail -60 "$work/durability-run.log" >&2
  exit 1
fi
if ! passes DurabilityTests/testDurabilityVerify "$work/durability-verify.log" TEST_RUNNER_BAROMETER_DURABILITY_TEST=verify; then
  echo "durability: verification failed" >&2
  tail -60 "$work/durability-verify.log" >&2
  exit 1
fi
echo "durability test passed: pending bundle, replay records and run ledger survived a kill during a run"
