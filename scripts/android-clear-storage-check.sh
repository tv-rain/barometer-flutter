#!/usr/bin/env bash
set -euo pipefail

# Checks operating-system data clearing on an Android emulator: ClearStorageDeviceTest
# seeds Barometer state (records, a pending bundle, the linkage key and its sentinel) in the
# plugin's test application, `pm clear` then clears the application's data the way
# Settings > Storage > Clear storage does, without calling Barometer, and the test verifies
# that no Barometer file or Keystore key survived and that no key is created before linkage
# needs one. With `--control` the clearing step is skipped, so the verification must fail.
#
#   bash scripts/android-clear-storage-check.sh [--control]
#
# Emulators only: the script refuses any other device. It builds and installs the test APK
# from example/android and leaves it installed. The host needs adb.

control=false
case "${1:-}" in
  '') ;;
  --control) control=true ;;
  *) echo 'Usage: bash scripts/android-clear-storage-check.sh [--control]' >&2; exit 2 ;;
esac

adb=${ADB:-adb}
root=$(cd "$(dirname "$0")/.." && pwd)
package=com.tvrain.barometer_flutter.test
runner=$package/androidx.test.runner.AndroidJUnitRunner
apk="$root/example/build/barometer_flutter/outputs/apk/androidTest/debug/barometer_flutter-debug-androidTest.apk"

qemu=$("$adb" shell 'getprop ro.kernel.qemu; getprop ro.boot.qemu' | tr -d '\r[:space:]')
case "$qemu" in
  *1*) ;;
  *) echo 'Refusing: the connected device is not an emulator' >&2; exit 1 ;;
esac

(cd "$root/example/android" && ./gradlew -q :barometer_flutter:assembleDebugAndroidTest)
"$adb" install -r -t "$apk" >/dev/null 2>&1

phase() {
  local out
  out=$("$adb" shell am instrument -w -e clearStorage "$1" \
    -e class "com.tvrain.barometer_flutter.ClearStorageDeviceTest#$2" "$runner" | tr -d '\r')
  echo "$out" | tail -n 3
  case "$out" in
    *'OK (1 test)'*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Android $("$adb" shell getprop ro.build.version.release | tr -d '\r') (API $("$adb" shell getprop ro.build.version.sdk | tr -d '\r'))"
phase seed seed
if [ "$control" = true ]; then
  echo 'Control: data not cleared'
else
  "$adb" shell pm clear "$package"
fi
if phase verify verifyCleared; then
  [ "$control" = false ] || { echo 'Control failed: the verification passed without clearing' >&2; exit 1; }
  echo 'Cleared: no Barometer file or key survived'
else
  [ "$control" = true ] || { echo 'Barometer state survived operating-system clearing' >&2; exit 1; }
  echo 'Control: the verification failed as expected'
  "$adb" shell pm clear "$package" >/dev/null
fi
