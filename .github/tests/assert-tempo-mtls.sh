#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 ENCLAVE" >&2; exit 2; }
enclave=$1
evidence_dir=${GLAM150_EVIDENCE_DIR:-}
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
for service in tempo grafana vc-2-geth-lighthouse-vouch dirk-1 dirk-2 dirk-3; do
  kurtosis enclave inspect "$enclave" | grep -A 2 -F "$service" | grep -q RUNNING
done
kurtosis service exec "$enclave" tempo 'cat /etc/tempo/tempo.yaml; ls -l /etc/tempo/tls; cat /etc/tempo/tls/ca.crt; cat /etc/tempo/tls/server.crt' > "$workdir/tempo"
kurtosis service exec "$enclave" vc-2-geth-lighthouse-vouch 'cat /config/vouch.yml; ls -l /tempo-certs; cat /tempo-certs/ca.crt; cat /tempo-certs/client.crt; cat /tempo-certs/client.key' > "$workdir/vouch"
kurtosis service exec "$enclave" grafana 'cat /config/datasources/datasource.yml' > "$workdir/grafana"
for service in dirk-1 dirk-2 dirk-3; do
  kurtosis service exec "$enclave" "$service" 'cat /config/dirk.yml' > "$workdir/$service"
  ! grep -q '^tracing:' "$workdir/$service"
  dirk_metrics=$(kurtosis port print "$enclave" "$service" metrics --format ip,number | tr ' ' ':')
  curl -fsS "http://$dirk_metrics/metrics" > "$workdir/$service.metrics"
  grep -q '^# HELP' "$workdir/$service.metrics"
done
kurtosis service logs "$enclave" dirk-1 > "$workdir/dirk-1.log"
grep -q 'vouch-client' "$workdir/dirk-1.log"
grep -q 'cert_file: /etc/tempo/tls/server.crt' "$workdir/tempo"
grep -q 'key_file: /etc/tempo/tls/server.key' "$workdir/tempo"
grep -q 'client_ca_file: /etc/tempo/tls/ca.crt' "$workdir/tempo"
grep -q 'rw-r--r--.*ca.crt' "$workdir/tempo"
grep -q 'rw-r--r--.*server.crt' "$workdir/tempo"
grep -q 'rw-r--r--.*server.key' "$workdir/tempo"
grep -q "client-cert: 'file:///tempo-certs/client.crt'" "$workdir/vouch"
grep -q "client-key: 'file:///tempo-certs/client.key'" "$workdir/vouch"
grep -q "ca-cert: 'file:///tempo-certs/ca.crt'" "$workdir/vouch"
grep -q 'url: http://tempo:3200' "$workdir/grafana"
awk '/BEGIN CERTIFICATE/{n++} n==1{print} /END CERTIFICATE/{if(n==1) exit}' "$workdir/tempo" > "$workdir/ca.crt"
awk '/BEGIN CERTIFICATE/{n++} n==2{print} /END CERTIFICATE/{if(n==2) exit}' "$workdir/tempo" > "$workdir/server.crt"
openssl x509 -in "$workdir/server.crt" -noout -text | grep -q 'DNS:tempo'
awk '/BEGIN CERTIFICATE/{n++} n==2{print} /END CERTIFICATE/{if(n==2) exit}' "$workdir/vouch" > "$workdir/client.crt"
awk '/BEGIN.*PRIVATE KEY/{p=1} p; /END.*PRIVATE KEY/{exit}' "$workdir/vouch" > "$workdir/client.key"
openssl verify -CAfile "$workdir/ca.crt" "$workdir/client.crt"
tempo_grpc=$(kurtosis port print "$enclave" tempo otlp-grpc --format ip,number | tr ' ' ':')
read -r -d '' probe <<'PY' || true
import socket, ssl, sys
host, port, ca, cert, key = sys.argv[1:]
ctx = ssl.create_default_context(cafile=ca)
ctx.check_hostname = True
try:
    with socket.create_connection((host, int(port)), timeout=5) as raw:
        with ctx.wrap_socket(raw, server_hostname="tempo") as tls:
            tls.sendall(b"x")
            tls.recv(1)
    print("unexpected clientless success")
    sys.exit(2)
except ssl.SSLError as exc:
    print("TLS client-certificate rejection: %s" % exc)
    sys.exit(1)
PY
set +e
python3 -c "$probe" "${tempo_grpc%:*}" "${tempo_grpc##*:}" "$workdir/ca.crt" "$workdir/client.crt" "$workdir/client.key" > "$workdir/no-client.txt" 2>&1
no_client_status=$?
set -e
[[ $no_client_status -ne 0 ]]
if [[ -n "$evidence_dir" ]]; then
  mkdir -p "$evidence_dir"
  cp "$workdir/no-client.txt" "$evidence_dir/no-client.txt"
fi
grep -qi 'tlsv13 alert certificate required' "$workdir/no-client.txt"
read -r -d '' probe <<'PY' || true
import socket, ssl, sys
host, port, ca, cert, key = sys.argv[1:]
ctx = ssl.create_default_context(cafile=ca)
ctx.check_hostname = True
ctx.load_cert_chain(cert, key)
with socket.create_connection((host, int(port)), timeout=5) as raw:
    with ctx.wrap_socket(raw, server_hostname="tempo") as tls:
        print("certificate verification: %s" % tls.version())
PY
python3 -c "$probe" "${tempo_grpc%:*}" "${tempo_grpc##*:}" "$workdir/ca.crt" "$workdir/client.crt" "$workdir/client.key" > "$workdir/authenticated-client.txt" 2>&1
grep -q 'certificate verification: TLS' "$workdir/authenticated-client.txt"
if [[ -n "$evidence_dir" ]]; then
  mkdir -p "$evidence_dir"
  cp "$workdir/authenticated-client.txt" "$evidence_dir/authenticated-client.txt"
fi
for _ in $(seq 1 60); do
  tempo=$(kurtosis port print "$enclave" tempo http --format ip,number | tr ' ' ':')
  if curl -fsS "http://$tempo/api/search?tags=service.name%3DVouch&limit=5" | jq -e '.traces | length > 0' >/dev/null; then exit 0; fi
  sleep 5
done
exit 1
