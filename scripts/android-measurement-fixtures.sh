#!/usr/bin/env bash
set -euo pipefail

# Prepares an Android emulator for the example's measurement integration test
# (example/integration_test/measurements_test.dart), which runs all nine registered
# measurements from Dart against synthetic fixtures on the host.
#
#   start   generate a synthetic CA and server certificate for this run, start the host
#           fixtures (scripts/measurement_fixtures.py) on the host's loopback interface,
#           make the CA the emulator's only trust root (scripts/android-trust-scenario.sh:
#           updatable-only from API 34, system-only below), and redirect the emulator's
#           traffic for the fixture address to the fixtures
#   stop    undo all of the above and delete the generated keys
#
# The tasks name only the public literal 8.8.8.8, which the library accepts as a target;
# the emulator's packet filter rewrites every TCP and UDP packet for it on ports 53, 80, 443
# and 853 to the host (10.0.2.2) and rejects any other packet for it, so no task contacts
# that address. The CA's private key is deleted as soon as the server certificate is
# issued. Emulators only: the script refuses any other device and needs `adb root`
# (a `default` or `google_apis` system image). The host needs adb, openssl and python3.

action=${1:-}
adb=${ADB:-adb}
python=${PYTHON:-python3}
root=$(cd "$(dirname "$0")/.." && pwd)
state=${TMPDIR:-/tmp}/barometer-measurement-fixtures
address=8.8.8.8
name=fixture.example.org
host=10.0.2.2
chain=barometer_fixtures

case "$action" in
  start | stop) ;;
  *) echo 'Usage: bash scripts/android-measurement-fixtures.sh start|stop' >&2; exit 2 ;;
esac

qemu=$("$adb" shell 'getprop ro.kernel.qemu; getprop ro.boot.qemu' | tr -d '\r[:space:]')
case "$qemu" in
  *1*) ;;
  *) echo 'Refusing: the connected device is not an emulator' >&2; exit 1 ;;
esac
"$adb" root >/dev/null
"$adb" wait-for-device
api=$("$adb" shell getprop ro.build.version.sdk | tr -d '\r')

remove_rules() {
  "$adb" shell "for t in nat filter; do
      while iptables -w -t \$t -D OUTPUT -j $chain 2>/dev/null; do :; done
      iptables -w -t \$t -F $chain 2>/dev/null || true
      iptables -w -t \$t -X $chain 2>/dev/null || true
    done"
}

stop() {
  remove_rules
  bash "$root/scripts/android-trust-scenario.sh" reset >/dev/null || true
  if [ -f "$state/fixtures.pid" ]; then
    kill "$(cat "$state/fixtures.pid")" 2>/dev/null || true
  fi
  rm -rf "$state"
}

if [ "$action" = stop ]; then
  stop
  echo 'Stopped the measurement fixtures'
  exit 0
fi

stop
mkdir -p "$state"
cd "$state"
cat > leaf.cnf <<EOF
[req]
distinguished_name = dn
[dn]
[leaf]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$name, IP:$address
[ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=Barometer synthetic fixture CA' \
  -config leaf.cnf -extensions ca -keyout ca-key.pem -out ca.pem 2>/dev/null
openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$name" -config leaf.cnf \
  -keyout leaf-key.pem -out leaf.csr 2>/dev/null
openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -days 2 \
  -extfile leaf.cnf -extensions leaf -out leaf.pem 2>/dev/null
rm -f ca-key.pem ca.srl leaf.csr

"$python" "$root/scripts/measurement_fixtures.py" --cert leaf.pem --key leaf-key.pem \
  --address "$address" > fixtures.log 2>&1 &
echo $! > fixtures.pid
for _ in $(seq 50); do
  grep -q ready fixtures.log 2>/dev/null && break
  sleep 0.2
done
grep -q ready fixtures.log || { cat fixtures.log >&2; stop; exit 1; }

scenario=system-only
[ "$api" -ge 34 ] && scenario=updatable-only
BAROMETER_TRUST_CA="$state/ca.pem" bash "$root/scripts/android-trust-scenario.sh" "$scenario" >/dev/null

"$adb" shell "set -e
  iptables -w -t nat -N $chain
  for p in 53:10053 80:10080 443:10443 853:10853; do
    iptables -w -t nat -A $chain -d $address -p tcp --dport \${p%%:*} -j DNAT --to-destination $host:\${p#*:}
  done
  iptables -w -t nat -A $chain -d $address -p udp --dport 53 -j DNAT --to-destination $host:10053
  iptables -w -t nat -I OUTPUT 1 -j $chain
  iptables -w -t filter -N $chain
  iptables -w -t filter -A $chain -d $address -j REJECT
  iptables -w -t filter -I OUTPUT 1 -j $chain"
echo "Started the measurement fixtures on API $api ($scenario)"
