OPENSSL_IMAGE = "alpine/openssl:3.5.5@sha256:7a1465c710d66ef753236a2d96c9c41f1fb0453862e5794640d6065aa1853087"

CERT_VALIDITY_DAYS_LONG = 1825
TEMPO_SERVICE_DNS = "tempo"
TEMPO_CLIENT_CN = "vouch-tracing-client"


def generate_tempo_certs(plan):
    store_specs = [
        StoreSpec(src="/certs/ca/ca.crt", name="tempo-ca-cert"),
        StoreSpec(src="/certs/server/", name="tempo-server-cert"),
        StoreSpec(
            src="/certs/client/{0}.crt".format(TEMPO_CLIENT_CN),
            name="tempo-client-cert",
        ),
        StoreSpec(
            src="/certs/client/{0}.key".format(TEMPO_CLIENT_CN), name="tempo-client-key"
        ),
    ]
    result = plan.run_sh(
        name="generate-tempo-mtls-certs",
        description="Generating Tempo CA, server, and Vouch tracing client certificates",
        run=_build_tempo_cert_script(),
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
    ca = "/certs/ca/ca"
    server = "/certs/server/server"
    client = "/certs/client/{0}".format(TEMPO_CLIENT_CN)
    return "\n".join(
        [
            "set -e",
            "mkdir -p /certs/ca /certs/server /certs/client",
            "openssl genrsa -out {0}.key 4096".format(ca),
            'openssl req -x509 -new -nodes -key {0}.key -sha256 -days {1} -out {0}.crt -subj "/CN=Tempo CA" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"'.format(
                ca, CERT_VALIDITY_DAYS_LONG
            ),
            "openssl genrsa -out {0}.key 4096".format(server),
            "cat > {0}.ext <<EOF\nauthorityKeyIdentifier=keyid,issuer\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:tempo\nEOF".format(
                server
            ),
            'openssl req -new -key {0}.key -out {0}.csr -subj "/CN=tempo"'.format(
                server
            ),
            "openssl x509 -req -in {0}.csr -CA {1}.crt -CAkey {1}.key -CAcreateserial -out {0}.crt -days {2} -sha256 -extfile {0}.ext".format(
                server, ca, CERT_VALIDITY_DAYS_LONG
            ),
            "openssl genrsa -out {0}.key 4096".format(client),
            "cat > {0}.ext <<EOF\nauthorityKeyIdentifier=keyid,issuer\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\nEOF".format(
                client
            ),
            'openssl req -new -key {0}.key -out {0}.csr -subj "/CN={1}"'.format(
                client, TEMPO_CLIENT_CN
            ),
            "openssl x509 -req -in {0}.csr -CA {1}.crt -CAkey {1}.key -CAcreateserial -out {0}.crt -days {2} -sha256 -extfile {0}.ext".format(
                client, ca, CERT_VALIDITY_DAYS_LONG
            ),
        ]
    )
