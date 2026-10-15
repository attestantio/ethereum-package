constants = import_module("../package_io/constants.star")

CERT_VALIDITY_DAYS_LONG = 1825
TEMPO_CLIENT_CN = "vouch-tracing-client"


def generate_tempo_certs(plan):
    """Generate Tempo's mTLS material as two directories ready to mount.

    server_tls: server.crt, server.key and the client CA ca.crt, for Tempo.
    client_tls: client.crt, client.key and ca.crt, for Vouch.
    """
    result = plan.run_sh(
        name="generate-tempo-mtls-certs",
        description="Generating Tempo CA, server, and Vouch tracing client certificates",
        run=_build_tempo_cert_script(),
        image=constants.OPENSSL_IMAGE,
        store=[
            StoreSpec(src="/certs/server/", name="tempo-server-tls"),
            StoreSpec(src="/certs/client/", name="tempo-client-tls"),
        ],
        wait=None,
    )
    return struct(
        server_tls=result.files_artifacts[0],
        client_tls=result.files_artifacts[1],
    )


def _build_tempo_cert_script():
    ca = "/certs/ca/ca"
    server = "/certs/server/server"
    client = "/certs/client/client"
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
            "cp {0}.crt /certs/server/ca.crt".format(ca),
            "cp {0}.crt /certs/client/ca.crt".format(ca),
            "rm -f /certs/server/server.csr /certs/server/server.ext /certs/client/client.csr /certs/client/client.ext",
            # Tempo and Vouch run as non-root users that must read these files.
            "chmod 0644 /certs/server/* /certs/client/*",
        ]
    )
