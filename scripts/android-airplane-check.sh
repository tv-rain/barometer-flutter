#!/usr/bin/env bash
set -euo pipefail

# Runs NetworkSignalDeviceTest#airplaneModeRemovesTheNetworkAndRestoresIt on an Android
# emulator while switching airplane mode from the host. Before API 30 the instrumentation's
# shell user cannot switch airplane mode, so the instrumented test does it itself only from
# API 30; this script covers every API level. It switches airplane mode on about 8 seconds
# after the test starts and off about 15 seconds later, as root before API 30.
#
#   bash scripts/android-airplane-check.sh
#
# Emulators only: the script refuses any other device and needs `adb root` (a `default` or
# `google_apis` system image) before API 30. It builds and installs the test APK from
# example/android and leaves it installed. The host needs adb.

adb=${ADB:-adb}
root=$(cd "$(dirname "$0")/.." && pwd)
package=com.tvrain.barometer_flutter.test
runner=$package/androidx.test.runner.AndroidJUnitRunner
apk="$root/example/build/barometer_flutter/outputs/apk/androidTest/debug/barometer_flutter-debug-androidTest.apk"
test=com.tvrain.barometer_flutter.NetworkSignalDeviceTest#airplaneModeRemovesTheNetworkAndRestoresIt

qemu=$("$adb" shell 'getprop ro.kernel.qemu; getprop ro.boot.qemu' | tr -d '\r[:space:]')
case "$qemu" in
  *1*) ;;
  *) echo 'Refusing: the connected device is not an emulator' >&2; exit 1 ;;
esac
sdk=$("$adb" shell getprop ro.build.version.sdk | tr -d '\r')
echo "Android $("$adb" shell getprop ro.build.version.release | tr -d '\r') (API $sdk)"

airplane() {
  if [ "$sdk" -ge 30 ]; then
    "$adb" shell cmd connectivity airplane-mode "$([ "$1" = 1 ] && echo enable || echo disable)"
  else
    "$adb" shell "su 0 settings put global airplane_mode_on $1"
    "$adb" shell "su 0 am broadcast -a android.intent.action.AIRPLANE_MODE --ez state $([ "$1" = 1 ] && echo true || echo false)" >/dev/null
  fi
}

(cd "$root/example/android" && ./gradlew -q :barometer_flutter:assembleDebugAndroidTest)
"$adb" install -r -t "$apk" >/dev/null 2>&1

out=$(mktemp)
trap 'airplane 0; rm -f "$out"' EXIT
"$adb" shell am instrument -w -e airplaneByHost true -e class "$test" "$runner" > "$out" &
instrument=$!
sleep 8
airplane 1
sleep 15
airplane 0
wait "$instrument"
tr -d '\r' < "$out" | grep -E '^(Time|OK|FAILURES|Tests run)'
grep -q 'OK (1 test)' "$out"
