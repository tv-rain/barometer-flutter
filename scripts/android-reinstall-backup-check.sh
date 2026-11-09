#!/usr/bin/env bash
set -euo pipefail

# Checks the linkage key, its sentinel and the records across uninstall and reinstall and
# across backup and restore on an Android emulator. ReinstallBackupDeviceTest seeds Barometer
# state (records, a pending bundle, the Keystore key and the sentinel, with linkage on) and a
# control file in the backed-up files directory of the plugin's test application, then:
#
#   reinstall   uninstalls and reinstalls the test application; the verification checks that
#               no Barometer file or key survived and that the first derivation uses a new key.
#               With --control the application is not reinstalled, so the verification must
#               fail.
#   adb-backup  takes `adb backup` of the application, checks that the archive holds the
#               control file and nothing from the no-backup directory, restores it into a fresh
#               installation and into the existing one with `adb restore`, and verifies each
#               time that the control file came back and no Barometer state or key did.
#   bmgr        backs the application up with `bmgr backupnow` through the local transport,
#               checks the transport's copy as above (as root), restores it with `bmgr restore`
#               into a fresh installation, with automatic restore at install off, and verifies
#               as above. It exits with status 3 when
#               the image has no local transport.
#
#   bash scripts/android-reinstall-backup-check.sh reinstall [--control]
#   bash scripts/android-reinstall-backup-check.sh adb-backup|bmgr
#
# Linkage keys need API 23, so the checks need an API 23 or later emulator. Emulators only:
# the script refuses any other device. It builds the test APK from example/android, may
# uninstall and reinstall it, and leaves it installed. adb backup and restore wait for their
# confirmation screen, which the script accepts with `uiautomator` and `input tap`. The host
# needs adb and python3 (PYTHON overrides it).

mode=${1:-}
control=false
case "$mode:${2:-}" in
  reinstall:) ;;
  reinstall:--control) control=true ;;
  adb-backup:|bmgr:) ;;
  *) echo 'Usage: bash scripts/android-reinstall-backup-check.sh reinstall [--control] | adb-backup | bmgr' >&2; exit 2 ;;
esac

adb=${ADB:-adb}
python=${PYTHON:-python3}
root=$(cd "$(dirname "$0")/.." && pwd)
package=com.tvrain.barometer_flutter.test
runner=$package/androidx.test.runner.AndroidJUnitRunner
test=com.tvrain.barometer_flutter.ReinstallBackupDeviceTest
apk="$root/example/build/barometer_flutter/outputs/apk/androidTest/debug/barometer_flutter-debug-androidTest.apk"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

qemu=$("$adb" shell 'getprop ro.kernel.qemu; getprop ro.boot.qemu' | tr -d '\r[:space:]')
case "$qemu" in
  *1*) ;;
  *) echo 'Refusing: the connected device is not an emulator' >&2; exit 1 ;;
esac
sdk=$("$adb" shell getprop ro.build.version.sdk | tr -d '\r')
if [ "$sdk" -lt 23 ]; then
  echo "Refusing: linkage keys need API 23, the emulator is API $sdk" >&2
  exit 1
fi

(cd "$root/example/android" && ./gradlew -q :barometer_flutter:assembleDebugAndroidTest)

install() { "$adb" install -r -t "$apk" >/dev/null 2>&1; }
reinstall() {
  "$adb" uninstall "$package" >/dev/null 2>&1 || true
  install
}

# Runs one phase and prints its last lines; fails unless the test passed.
phase() {
  local out
  out=$("$adb" shell am instrument -w -e reinstallBackup "$1" ${2:+-e previousKey "$2"} \
    -e class "$test#$3" "$runner" | tr -d '\r')
  echo "$out" | grep -v keyFingerprint | tail -n 3
  case "$out" in
    *'OK (1 test)'*) last=$out; return 0 ;;
    *) return 1 ;;
  esac
}

seed() {
  phase seed '' seed
  fingerprint=$(echo "$last" | sed -n 's/.*INSTRUMENTATION_STATUS: keyFingerprint=\([0-9a-f]*\).*/\1/p')
  [ -n "$fingerprint" ] || { echo 'The seed reported no key fingerprint' >&2; exit 1; }
}

# Taps the allow button of the adb backup or restore confirmation screen.
confirm() {
  local bounds i
  for i in $(seq 1 30); do
    sleep 1
    "$adb" shell uiautomator dump /data/local/tmp/barometer-ui.xml >/dev/null 2>&1 || continue
    bounds=$("$adb" shell cat /data/local/tmp/barometer-ui.xml | tr '>' '\n' \
      | grep 'com.android.backupconfirm:id/button_allow' \
      | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p')
    if [ -n "$bounds" ]; then
      set -- $bounds
      "$adb" shell rm -f /data/local/tmp/barometer-ui.xml
      "$adb" shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
      return 0
    fi
  done
  echo 'No confirmation screen appeared' >&2
  return 1
}

# Checks a list of backed-up paths on stdin: the control file must be there, and nothing
# from the no-backup directory or named after Barometer state.
check_entries() {
  local entries
  # Paths inside the application's own part of the archive, without the package name.
  entries=$(sed "s#^apps/$package/##")
  echo "$entries" | grep -qx 'f/backup-control' || { echo 'The backup holds no control file' >&2; return 1; }
  if echo "$entries" | grep -E '(^|/)(nb|no_backup)(/|$)|barometer|linkage-sentinel|clearing\.reserve|owner\.lock'; then
    echo 'The backup holds Barometer state' >&2
    return 1
  fi
  echo "Backup entries: $(echo "$entries" | wc -l | tr -d ' '), control file present, no Barometer state"
}

# Lists the entries of an adb backup archive (unencrypted, compressed or not).
list_archive() {
  "$python" -I - "$1" <<'EOF'
import io, sys, tarfile, zlib
data = open(sys.argv[1], 'rb').read()
header = data.split(b'\n', 4)
if header[0] != b'ANDROID BACKUP' or header[3] != b'none':
    sys.exit('not an unencrypted adb backup archive')
body = zlib.decompress(header[4]) if header[2] == b'1' else header[4]
with tarfile.open(fileobj=io.BytesIO(body)) as archive:
    for member in archive.getmembers():
        print(member.name)
EOF
}

adb_backup() {
  local archive="$work/backup.ab"
  "$adb" backup -f "$archive" -noapk "$package" >/dev/null 2>&1 &
  local pid=$!
  confirm
  wait "$pid"
  [ -s "$archive" ] || { echo 'adb backup wrote no archive' >&2; exit 1; }
  list_archive "$archive" | check_entries
}

adb_restore() {
  # The restored control file shows that the restore completed.
  "$adb" shell run-as "$package" rm -f files/backup-control
  "$adb" restore "$work/backup.ab" >/dev/null 2>&1 &
  local pid=$!
  confirm
  wait "$pid"
  wait_restored
}

has_control() { "$adb" shell run-as "$package" ls files 2>/dev/null | tr -d '\r' | grep -qx backup-control; }

# Waits for the restored control file; a restore can return before it completes.
wait_restored() {
  local i
  for i in $(seq 1 30); do
    has_control && return 0
    sleep 1
  done
  echo 'The restore did not complete' >&2
  return 1
}

transport() {
  "$adb" shell bmgr list transports | tr -d '\r' | sed -n 's/^ *\*\{0,1\} *\(.*[Ll]ocal[Tt]ransport.*\)$/\1/p' | head -n 1
}

echo "Android $("$adb" shell getprop ro.build.version.release | tr -d '\r') (API $sdk)"
case "$mode" in
  reinstall)
    reinstall
    seed
    if [ "$control" = true ]; then
      echo 'Control: not reinstalled'
    else
      reinstall
    fi
    if phase verify-reinstall "$fingerprint" verify; then
      [ "$control" = false ] || { echo 'Control failed: the verification passed without a reinstall' >&2; exit 1; }
      echo 'Reinstalled: no Barometer file or key survived, and the first derivation used a new key'
    else
      [ "$control" = true ] || { echo 'Barometer state or the key survived the reinstall' >&2; exit 1; }
      echo 'Control: the verification failed as expected'
      reinstall
    fi
    ;;
  adb-backup)
    reinstall
    seed
    adb_backup
    reinstall
    adb_restore
    phase verify-restore "$fingerprint" verify || { echo 'Barometer state or the key came back after a restore into a fresh installation' >&2; exit 1; }
    echo 'Restored into a fresh installation: control file back, no Barometer state, a new key'
    seed
    adb_restore
    phase verify-restore "$fingerprint" verify || { echo 'Barometer state or the key survived a restore into the existing installation' >&2; exit 1; }
    echo 'Restored into the existing installation: control file back, no Barometer state, a new key'
    ;;
  bmgr)
    local_transport=$(transport)
    if [ -z "$local_transport" ]; then
      echo 'No local backup transport in this image'
      exit 3
    fi
    "$adb" root >/dev/null
    "$adb" wait-for-device
    previous_enabled=$("$adb" shell bmgr enabled | tr -d '\r')
    case "$("$adb" shell dumpsys backup | tr -d '\r')" in
      *'Auto-restore is disabled'*) previous_autorestore=false ;;
      *) previous_autorestore=true ;;
    esac
    previous_transport=$("$adb" shell bmgr list transports | tr -d '\r' | sed -n 's/^ *\* *//p')
    "$adb" shell bmgr enable true >/dev/null
    "$adb" shell bmgr transport "$local_transport" >/dev/null
    reinstall
    seed
    "$adb" shell bmgr backupnow "$package" | tr -d '\r' | tail -n 2
    # The local transport keeps a full backup as a tar file per package.
    copy=$("$adb" shell "find /data/cache/backup /data/data/com.android.localtransport -path '*_full*' -name $package 2>/dev/null" \
      | tr -d '\r' | head -n 1)
    [ -n "$copy" ] || { echo 'The local transport holds no full backup of the application' >&2; exit 1; }
    "$adb" shell "tar -tf $copy" | tr -d '\r' | check_entries
    # Without automatic restore at install, the control file comes back only from this restore.
    "$adb" shell bmgr autorestore false >/dev/null
    reinstall
    token=$("$adb" shell bmgr list sets | tr -d '\r' | sed -n 's/^ *\([0-9a-f]*\) : .*/\1/p' | head -n 1)
    [ -n "$token" ] || { echo 'The local transport lists no restore set' >&2; exit 1; }
    ! has_control || { echo 'The control file was restored at install' >&2; exit 1; }
    "$adb" shell bmgr restore "$token" "$package" | tr -d '\r' | tail -n 1
    wait_restored
    phase verify-restore "$fingerprint" verify || { echo 'Barometer state or the key came back after a bmgr restore' >&2; exit 1; }
    echo 'Restored by bmgr into a fresh installation: control file back, no Barometer state, a new key'
    [ -z "$previous_transport" ] || "$adb" shell bmgr transport "$previous_transport" >/dev/null
    [ "$previous_autorestore" = false ] || "$adb" shell bmgr autorestore true >/dev/null
    case "$previous_enabled" in *disabled*) "$adb" shell bmgr enable false >/dev/null ;; esac
    ;;
esac
