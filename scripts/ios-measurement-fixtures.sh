#!/usr/bin/env bash
set -euo pipefail

# Prepares the host fixtures for the example's measurement integration test
# (example/integration_test/measurements_test.dart) on an iOS simulator or an iPhone, which
# run all nine registered measurements from Dart against synthetic fixtures on the host.
#
#   start [simulator-udid]   generate a synthetic CA and a server certificate for this run,
#                            start the host fixtures (scripts/measurement_fixtures.py) on
#                            the standard ports of every IPv6 address of the host, answering
#                            only peers of the host's own on-link IPv6 prefix, and print the
#                            fixture address to build the example with; with a simulator,
#                            also add the CA to that simulator's trust store
#   stop                     stop the fixtures and delete the generated keys
#
# An iPhone cannot be redirected like an emulator, and the library accepts only public
# targets, so the fixture address is the host's stable global IPv6 address, which an iPhone
# on the same network reaches directly. The build phase of the example writes it into the
# fixture tasks in place of 8.8.8.8 (BAROMETER_FIXTURE_ADDRESS). The address is used for the
# run only; do not record it. A simulator shares the host's network and reaches the same
# address. The CA's private key is deleted as soon as the server certificate is issued. On
# an iPhone the CA is not trusted unless the user installs and fully trusts it, so the
# TLS-dependent tasks see the fixtures' certificate rejected. A root added to a simulator
# cannot be removed reliably while it runs; use a simulator created for the run and delete it
# afterwards. The host needs openssl, python3 and route.

action=${1:-}
simulator=${2:-}
python=${PYTHON:-python3}
root=$(cd "$(dirname "$0")/.." && pwd)
state=${TMPDIR:-/tmp}/barometer-ios-measurement-fixtures
name=fixture.example.org

case "$action" in
  start | stop) ;;
  *) echo 'Usage: bash scripts/ios-measurement-fixtures.sh start [simulator-udid] | stop' >&2; exit 2 ;;
esac

stop() {
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

# The stable (not temporary, not deprecated) global address of the interface that carries
# the default IPv6 route, and its prefix length.
interface=$(route -n get -inet6 default 2>/dev/null | awk '/interface:/ {print $2}')
[ -n "$interface" ] || { echo 'No default IPv6 route on the host' >&2; exit 1; }
read -r address prefixlen < <(ifconfig "$interface" | awk '
  $1 == "inet6" && $2 ~ /^[23]/ && /secured|autoconf/ && !/temporary|deprecated|detached/ {
    for (i = 1; i <= NF; i++) if ($i == "prefixlen") { print $2, $(i + 1); exit }
  }')
[ -n "${address:-}" ] || { echo "No stable global IPv6 address on $interface" >&2; exit 1; }
network=$("$python" -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$address/$prefixlen")

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

# DNS answers carry the IPv4 literal of the committed fixture tasks; nothing connects to it.
"$python" "$root/scripts/measurement_fixtures.py" --cert leaf.pem --key leaf-key.pem \
  --address "$address" --answer 8.8.8.8 --listen :: --allow "$network" \
  --dns 53 --http 80 --https 443 --dot 853 > fixtures.log 2>&1 &
echo $! > fixtures.pid
for _ in $(seq 50); do
  grep -q ready fixtures.log 2>/dev/null && break
  sleep 0.2
done
grep -q ready fixtures.log || { cat fixtures.log >&2; stop; exit 1; }

if [ -n "$simulator" ]; then
  xcrun simctl keychain "$simulator" add-root-cert "$state/ca.pem"
  echo 'Added the synthetic CA to the simulator'
fi
echo "Started the measurement fixtures; build with BAROMETER_FIXTURE_ADDRESS=$address"
