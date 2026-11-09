#!/usr/bin/env bash
# Runs TrustRootDeviceTests with a synthetic CA generated at run time, so no key is committed.
#
#   generate <dir>
#       Writes a synthetic CA valid for two days, a leaf for dns.google issued by it, the leaf and
#       its key as PKCS #12 and a configuration profile `barometer-test-ca.mobileconfig` that
#       installs the CA. <dir> must be a new or empty directory outside the repository.
#   run <dir> <none|profile-untrusted|profile-trusted> <destination> [xcodebuild arguments...]
#       Runs the test against the generated material on an xcodebuild destination, for example
#       'platform=iOS Simulator,id=<udid>' or 'platform=iOS,id=<udid>'. The scenario names the
#       state of the device's trust store; installing the profile and turning full trust on in
#       Settings > General > About > Certificate Trust Settings is done by hand on the device.
#       Further arguments, such as signing settings for a device, go to xcodebuild unchanged.
#
# Remove the profile from the device and delete <dir> when the runs are done: anyone holding the
# CA key can intercept the device's TLS while the profile is trusted. Run
# `flutter build ios --debug --simulator` or `--no-codesign` in example/ first. The application is
# installed over any earlier copy and left installed. The host needs OpenSSL 3 or later, named by
# OPENSSL when the first openssl on PATH is older or LibreSSL.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
password=barometer-synthetic
openssl="${OPENSSL:-openssl}"

generate() {
  local dir="$1"
  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd)"
  case "$dir/" in "$root"/*) echo 'Refusing: the directory is inside the repository' >&2; exit 1 ;; esac
  if [ -n "$(ls -A "$dir")" ]; then
    echo 'Refusing: the directory is not empty' >&2
    exit 1
  fi
  (
    cd "$dir"
    umask 077
    "$openssl" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
      -subj '/CN=Barometer synthetic test CA (remove after testing)' \
      -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -keyout ca-key.pem -out ca.pem 2>/dev/null
    "$openssl" req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj '/CN=dns.google' \
      -keyout leaf-key.pem -out leaf.csr 2>/dev/null
    printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' \
      'extendedKeyUsage=serverAuth' 'subjectAltName=DNS:dns.google' >leaf.ext
    "$openssl" x509 -req -in leaf.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -days 2 \
      -extfile leaf.ext -out leaf.pem 2>/dev/null
    "$openssl" pkcs12 -export -inkey leaf-key.pem -in leaf.pem -passout "pass:$password" -out leaf.p12
    "$openssl" x509 -in ca.pem -outform der -out ca.der
    cat >barometer-test-ca.mobileconfig <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadCertificateFileName</key><string>barometer-test-ca.cer</string>
      <key>PayloadContent</key><data>$(base64 <ca.der | tr -d '\n')</data>
      <key>PayloadDisplayName</key><string>Barometer synthetic test CA</string>
      <key>PayloadIdentifier</key><string>org.example.barometer.test-ca.root</string>
      <key>PayloadType</key><string>com.apple.security.root</string>
      <key>PayloadUUID</key><string>$(uuidgen)</string>
      <key>PayloadVersion</key><integer>1</integer>
    </dict>
  </array>
  <key>PayloadDescription</key><string>Synthetic CA for a Barometer test. Remove it after the test.</string>
  <key>PayloadDisplayName</key><string>Barometer synthetic test CA</string>
  <key>PayloadIdentifier</key><string>org.example.barometer.test-ca</string>
  <key>PayloadRemovalDisallowed</key><false/>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadUUID</key><string>$(uuidgen)</string>
  <key>PayloadVersion</key><integer>1</integer>
</dict>
</plist>
EOF
  )
  echo "Generated in $dir"
}

run() {
  local dir="$1" scenario="$2" destination="$3"
  shift 3
  case "$scenario" in none | profile-untrusted | profile-trusted) ;; *) usage ;; esac
  [ -f "$dir/leaf.p12" ] || { echo "No leaf.p12 in $dir; run generate first" >&2; exit 1; }
  local log
  log="$(mktemp)"
  trap 'rm -f "$log"' RETURN
  if TEST_RUNNER_BAROMETER_TRUST_SCENARIO="$scenario" \
    TEST_RUNNER_BAROMETER_TRUST_IDENTITY="$(base64 <"$dir/leaf.p12" | tr -d '\n')" \
    TEST_RUNNER_BAROMETER_TRUST_IDENTITY_PASSWORD="$password" \
    xcodebuild test -workspace "$root/example/ios/Runner.xcworkspace" -scheme Runner \
      -destination "$destination" -only-testing:RunnerTests/TrustRootDeviceTests \
      -parallel-testing-enabled NO -collect-test-diagnostics never "$@" >"$log" 2>&1; then
    grep -E "Test (Case|Suite).*TrustRootDeviceTests.*(passed|failed|skipped)" "$log" || true
    echo "TrustRootDeviceTests passed ($scenario)"
  else
    grep -E "error|failed|TrustRootDeviceTests" "$log" | tail -30
    echo "TrustRootDeviceTests failed ($scenario)" >&2
    exit 1
  fi
}

usage() {
  echo "usage: $0 generate <dir> | run <dir> <none|profile-untrusted|profile-trusted> <destination> [xcodebuild arguments...]" >&2
  exit 2
}

case "${1:-}" in
  generate) [ $# -eq 2 ] || usage; generate "$2" ;;
  run) [ $# -ge 4 ] || usage; shift; run "$@" ;;
  *) usage ;;
esac
