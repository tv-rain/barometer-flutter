#!/usr/bin/env bash
# Runs the example's integration test (`barometer_flow_test.dart`) once on a running Android
# emulator or booted iOS simulator, with a time limit. On timeout it prints diagnostics while
# the run is still stuck (the tail of the run's log, the host's adb, Flutter and simulator
# processes, the device state and the device log), then stops the run and fails.
#
# On Android it runs `flutter test`. On iOS it builds the example from the test's entry point
# and runs the test through the `integration_test` plugin's native runner from XCTest
# (`ios/RunnerTests/IntegrationTests.m`), because `flutter test` can miss the application's VM
# service on a simulator and then wait without a limit (docs/apple-validation.md).
#
#   bash scripts/integration-test.sh <device-id> [minutes]
#
# The mode is the one the example is configured for: on Android, umbrella mode through
# ORG_GRADLE_PROJECT_barometerUmbrellaArtifact and ORG_GRADLE_PROJECT_barometerUmbrellaRepository
# in the environment; on iOS, through the pods installed with BAROMETER_FLUTTER_UMBRELLA_MODULE.
set -uo pipefail

device=${1:?usage: integration-test.sh <device-id> [minutes]}
minutes=${2:-15}
cd "$(dirname "$0")/../example"
log=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/integration-test.XXXXXX")

case "$device" in
  emulator-*) platform=android ;;
  *) platform=ios ;;
esac

# Runs a diagnostic command for at most 30 seconds, so that a stuck device cannot hang it.
bounded() {
  perl -e 'alarm 30; exec @ARGV' "$@"
}

# Stops a process and all its descendants.
stop_tree() {
  local child
  for child in $(pgrep -P "$1"); do
    stop_tree "$child"
  done
  kill "$1" 2> /dev/null
}

if [ "$platform" = android ]; then
  # The boot flag is set before the package manager answers; wait for both.
  adb -s "$device" wait-for-device
  until [ "$(adb -s "$device" shell getprop sys.boot_completed | tr -d '\r')" = 1 ] &&
    adb -s "$device" shell pm path android > /dev/null 2>&1; do
    sleep 2
  done
fi

if [ "$platform" = android ]; then
  flutter test integration_test/barometer_flow_test.dart -d "$device" --verbose > "$log" 2>&1 &
else
  result="$log.xcresult"
  (
    flutter build ios --config-only --simulator --debug integration_test/barometer_flow_test.dart &&
      cd ios &&
      TEST_RUNNER_BAROMETER_INTEGRATION_TEST=1 xcodebuild test -quiet -workspace Runner.xcworkspace \
        -scheme Runner -destination "platform=iOS Simulator,arch=arm64,id=$device" \
        -only-testing:RunnerTests/IntegrationTests -parallel-testing-enabled NO \
        -resultBundlePath "$result"
  ) > "$log" 2>&1 &
fi
pid=$!
deadline=$((SECONDS + minutes * 60))
while kill -0 "$pid" 2> /dev/null && [ "$SECONDS" -lt "$deadline" ]; do
  sleep 5
done

if kill -0 "$pid" 2> /dev/null; then
  echo "::error::integration test did not finish within $minutes minutes on $device"
  echo "--- last lines of the run's log"
  tail -n 60 "$log"
  echo "--- host processes"
  ps -eo pid,ppid,etime,args | grep -E 'adb|flutter_tools|simctl|xcrun|xcodebuild' | grep -v grep | cut -c1-300
  if [ "$platform" = android ]; then
    echo "--- device state"
    bounded adb devices -l
    bounded adb -s "$device" shell getprop sys.boot_completed
    bounded adb -s "$device" shell pm path com.tvrain.barometer_flutter_example
    bounded adb -s "$device" shell df /data
    echo "--- device processes"
    bounded adb -s "$device" shell ps | grep -E 'system_server|installd|dex2oat|cmd|pm|barometer'
    echo "--- logcat (last 400 lines)"
    bounded adb -s "$device" logcat -d -t 400
    echo "--- adb server log (last 100 lines)"
    tail -n 100 "${TMPDIR:-/tmp}/adb.$(id -u).log"
  else
    echo "--- device state"
    xcrun simctl list devices | grep "$device"
    bounded xcrun simctl spawn "$device" launchctl list | grep -i barometer
    echo "--- Runner's Flutter and XCTest lines (last 15 minutes)"
    bounded xcrun simctl spawn "$device" log show --last 15m --style compact \
      --predicate 'process == "Runner" AND (senderImagePath ENDSWITH "/Flutter" OR subsystem == "com.apple.dt.xctest")' |
      cut -c1-200 | tail -n 80
  fi
  stop_tree "$pid"
  wait "$pid"
  exit 124
fi

wait "$pid"
status=$?
if [ "$platform" = android ]; then
  if [ "$status" -eq 0 ]; then
    # The test reporter's lines and the installation.
    grep -E '^[0-9]{2}:[0-9]{2} |Installing|exiting with code' "$log" | cut -c1-200
  else
    tail -n 200 "$log"
  fi
  exit "$status"
fi

grep -vE 'Stale file|^$' "$log" | tail -n 40
# Without the environment the XCTest has no test methods and would pass empty.
summary=$(xcrun xcresulttool get test-results summary --path "$result" --compact 2> /dev/null)
echo "$summary" | jq -c '{result, totalTestCount, passedTests, failedTests, device: [.devicesAndConfigurations[].device | "\(.deviceName) \(.osVersion)"]}'
if [ "$status" -eq 0 ] && ! echo "$summary" | jq -e '.passedTests >= 1 and .failedTests == 0' > /dev/null; then
  echo "::error::no passed integration test in the result bundle"
  status=1
fi
exit "$status"
