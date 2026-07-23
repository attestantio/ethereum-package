OPENSSL_IMAGE = "alpine/openssl:3.5.5"

CERT_VALIDITY_DAYS_LONG = 1825

TEMPO_SERVICE_DNS = "tempo"
TEMPO_CLIENT_CN = "vouch-tracing-client"


def generate_tempo_certs(plan):
    """Generate TLS material for Tempo mTLS on the OTLP gRPC ingress.

    Produces:
    - A Tempo CA (self-signed).
    - A Tempo server cert with DNS SAN = "tempo" signed by that CA.
    - A shared Vouch tracing client cert signed by that CA.

    Returns a struct with four file artifacts:
        ca_artifact               — contains ca.crt
        server_cert_artifact      — contains server.crt + server.key
        client_cert_artifact      — contains client.crt
        client_key_artifact       — contains client.key
    """
    store_specs = [
        StoreSpec(src="/certs/ca/ca.crt", name="tempo-ca-cert"),
        StoreSpec(src="/certs/server/", name="tempo-server-cert"),
        StoreSpec(
            src="/certs/client/{0}.crt".format(TEMPO_CLIENT_CN),
            name="tempo-client-cert",
        ),
        StoreSpec(
            src="/certs/client/{0}.key".format(TEMPO_CLIENT_CN),
            name="tempo-client-key",
        ),
    ]

    script = _build_tempo_cert_script()

    result = plan.run_sh(
        name="generate-tempo-mtls-certs",
        description="Generating Tempo CA + server + Vouch tracing client certificates",
        run=script,
        image=OPENSSL_IMAGE,
        store=store_specs,
        wait=None,
    )

    return struct(
        ca_artifact=result.files_artifacts[0],
        server_cert_artifact=result.files_artifacts[1],
        client_cert_artifact=result.files_artifacts[2],
        client_key_artifact=result.files_artifacts[3],
    )


def _build_tempo_cert_script():
    lines = [
        "set -e",
        "mkdir -p /certs/ca /certs/server /certs/client",
        "",
        "# Generate Tempo CA",
        "openssl genrsa -out /certs/ca/ca.key 4096",
        'openssl req -x509 -new -nodes -key /certs/ca/ca.key -sha256 -days {0} -out /certs/ca/ca.crt -subj "/CN=Tempo CA"'.format(
            CERT_VALIDITY_DAYS_LONG
        ),
    ]

    lines.extend(_server_cert_commands(TEMPO_SERVICE_DNS))
    lines.extend(_client_cert_commands(TEMPO_CLIENT_CN))

    return "\n".join(lines)


def _server_cert_commands(service_dns):
    base = "/certs/server/server"
    ext_file = "/certs/server/server.ext"
    return [
        "",
        "# Tempo server certificate (DNS SAN = {0})".format(service_dns),
        "openssl genrsa -out {0}.key 4096".format(base),
        "cat > {0} <<EOF\nauthorityKeyIdentifier=keyid,issuer\nbasicConstraints=CA:FALSE\nkeyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment\nextendedKeyUsage = serverAuth\nsubjectAltName = @alt_names\n\n[alt_names]\nDNS.1 = {1}\nEOF".format(
            ext_file, service_dns
        ),
        'openssl req -out {0}.csr -key {0}.key -new -subj "/CN={1}"'.format(
            base, service_dns
        ),
        "openssl x509 -req -in {0}.csr -CA /certs/ca/ca.crt -CAkey /certs/ca/ca.key -CAcreateserial -out {0}.crt -days {1} -sha256 -extfile {2}".format(
            base, CERT_VALIDITY_DAYS_LONG, ext_file
        ),
    ]


def _client_cert_commands(client_cn):
    base = "/certs/client/{0}".format(client_cn)
    ext_file = "/certs/client/{0}.ext".format(client_cn)
    return [
        "",
        "# Vouch tracing client certificate (CN={0})".format(client_cn),
        "openssl genrsa -out {0}.key 4096".format(base),
        "cat > {0} <<EOF\nauthorityKeyIdentifier=keyid,issuer\nbasicConstraints=CA:FALSE\nkeyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment\nextendedKeyUsage = clientAuth\nEOF".format(
            ext_file
        ),
        'openssl req -out {0}.csr -key {0}.key -new -subj "/CN={1}"'.format(
            base, client_cn
        ),
        "openssl x509 -req -in {0}.csr -CA /certs/ca/ca.crt -CAkey /certs/ca/ca.key -CAcreateserial -out {0}.crt -days {1} -sha256 -extfile {2}".format(
            base, CERT_VALIDITY_DAYS_LONG, ext_file
        ),
    ]
