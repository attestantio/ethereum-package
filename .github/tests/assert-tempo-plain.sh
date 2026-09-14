#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 ENCLAVE" >&2; exit 2; }
enclave=$1
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
for service in tempo grafana vc-2-geth-lighthouse-vouch dirk-1 dirk-2 dirk-3; do
  kurtosis enclave inspect "$enclave" | grep -A 2 -F "$service" | grep -q RUNNING
done
kurtosis service exec "$enclave" tempo 'cat /etc/tempo/tempo.yaml; find /etc/tempo -type f | sort' > "$workdir/tempo"
kurtosis service exec "$enclave" grafana 'cat /config/datasources/datasource.yml' > "$workdir/grafana"
kurtosis service exec "$enclave" vc-2-geth-lighthouse-vouch 'cat /config/vouch.yml' > "$workdir/vouch"
for service in dirk-1 dirk-2 dirk-3; do
  kurtosis service exec "$enclave" "$service" 'cat /config/dirk.yml' > "$workdir/$service"
done
grep -q 'endpoint: 0.0.0.0:4317' "$workdir/tempo"
grep -q 'endpoint: 0.0.0.0:4318' "$workdir/tempo"
! grep -Eq 'cert_file:|key_file:|client_ca_file:|/etc/tempo/tls' "$workdir/tempo"
grep -q 'url: http://tempo:3200' "$workdir/grafana"
grep -q "address: 'tempo:4317'" "$workdir/vouch"
for service in dirk-1 dirk-2 dirk-3; do grep -A1 '^tracing:' "$workdir/$service" | grep -q "address: 'tempo:4317'"; done
tempo=$(kurtosis port print "$enclave" tempo http --format ip,number | tr ' ' ':')
for _ in $(seq 1 60); do
  dirk=$(curl -fsS "http://$tempo/api/search?tags=service.name%3DDirk&limit=5")
  vouch=$(curl -fsS "http://$tempo/api/search?tags=service.name%3DVouch&limit=5")
  if jq -e '.traces | length > 0' <<<"$dirk" >/dev/null && jq -e '.traces | length > 0' <<<"$vouch" >/dev/null; then exit 0; fi
  sleep 5
done
exit 1
