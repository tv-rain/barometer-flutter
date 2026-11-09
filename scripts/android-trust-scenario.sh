#!/usr/bin/env bash
set -euo pipefail

# Prepares an Android emulator for TrustRootDeviceTest. Emulators only: the script
# refuses any other device, needs `adb root` (a `default` or `google_apis` system image)
# and installs only the synthetic test CA from the test assets.
#
#   user-ca         install the synthetic CA as a user-installed CA, in the platform's
#                   user store and in the legacy directory Go's own loader reads
#   updatable-only  replace the updatable store /apex/com.android.conscrypt/cacerts, as
#                   applications see it, with the synthetic CA alone (API 34 and later)
#   system-only     replace the system store /system/etc/security/cacerts, as applications
#                   see it, with the synthetic CA alone
#   reset           undo all of the above
#
# A store is replaced by a bind mount in the zygote mount namespaces, labeled like the
# store it replaces, so applications started afterwards see it and nothing is written to
# the system or APEX images. Run `reset` before using the emulator for anything else; a
# reboot also undoes the mounts.
# The host needs adb and openssl.

scenario=${1:-}
adb=${ADB:-adb}
root=$(cd "$(dirname "$0")/.." && pwd)
ca="$root/android/src/androidTest/assets/barometer/trust-roots/ca.pem"
staging=/data/local/tmp/barometer-trust-store
updatable=/apex/com.android.conscrypt/cacerts
system=/system/etc/security/cacerts

case "$scenario" in
  user-ca | updatable-only | system-only | reset) ;;
  *) echo 'Usage: bash scripts/android-trust-scenario.sh user-ca|updatable-only|system-only|reset' >&2; exit 2 ;;
esac

qemu=$("$adb" shell 'getprop ro.kernel.qemu; getprop ro.boot.qemu' | tr -d '\r[:space:]')
case "$qemu" in
  *1*) ;;
  *) echo 'Refusing: the connected device is not an emulator' >&2; exit 1 ;;
esac
"$adb" root >/dev/null
"$adb" wait-for-device

name="$(openssl x509 -in "$ca" -noout -subject_hash_old).0"
"$adb" push "$ca" "/data/local/tmp/$name" >/dev/null

# Runs a command in the mount namespace of every zygote process. Images without
# nsenter (API 24) run it in the shell's namespace, from which /system mounts
# propagate to the zygotes.
in_zygotes() {
  "$adb" shell "if command -v nsenter >/dev/null; then
      for z in \$(pidof zygote64) \$(pidof zygote); do nsenter -t \$z -m -- $1; done
    else $1; fi"
}

unmount_all() {
  for dir in "$updatable" "$system"; do
    in_zygotes "sh -c 'grep -q \" $dir \" /proc/self/mountinfo && umount $dir || true'"
  done
}

case "$scenario" in
  user-ca)
    "$adb" shell "set -e
      for dir in /data/misc/user/0/cacerts-added /data/misc/keychain/certs-added; do
        mkdir -p \$dir
        cp /data/local/tmp/$name \$dir/$name
        chown system:system \$dir \$dir/$name
        chmod 644 \$dir/$name
        restorecon -R \$dir
      done"
    ;;
  updatable-only | system-only)
    target=$updatable
    [ "$scenario" = system-only ] && target=$system
    unmount_all
    "$adb" shell "set -e
      [ -d $target ]
      rm -rf $staging
      mkdir -p $staging
      cp /data/local/tmp/$name $staging/$name
      chmod 755 $staging
      chmod 644 $staging/$name
      chcon -R \$(ls -dZ $target | cut -d ' ' -f 1) $staging"
    in_zygotes "mount -o bind $staging $target"
    "$adb" shell "for z in \$(pidof zygote64) \$(pidof zygote); do grep -q ' $target ' /proc/\$z/mountinfo; done" ||
      { echo "The zygote does not see the replaced store" >&2; exit 1; }
    ;;
  reset)
    unmount_all
    "$adb" shell "rm -f /data/misc/user/0/cacerts-added/$name /data/misc/keychain/certs-added/$name
      rmdir /data/misc/keychain/certs-added 2>/dev/null || true
      rm -rf $staging"
    ;;
esac
"$adb" shell "rm -f /data/local/tmp/$name"
echo "Prepared $scenario"
