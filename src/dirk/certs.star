OPENSSL_IMAGE = "alpine/openssl:3.5.5"

CERT_VALIDITY_DAYS = 1825


def generate_certs(
    plan, dirk_service_names, vouch_client_name="vouch-client", cluster_id=""
):
    """Generate all TLS certificates needed for Dirk <-> Vouch communication.

    Args:
        plan: The Kurtosis plan.
        dirk_service_names: List of Dirk service names (e.g. ["dirk-1", "dirk-2", "dirk-3"]).
        vouch_client_name: CN for the Vouch client certificate.
        cluster_id: Optional cluster identifier for unique artifact names.

    Returns:
        A struct with file artifact UUIDs for all generated certs.
    """
    ethdo_client_name = "ethdo-client"
    prefix = "dirk-{0}".format(cluster_id) if cluster_id else "dirk"

    # Build the list of StoreSpec entries we will collect
    store_specs = [
        StoreSpec(src="/certs/ca/ca.crt", name="{0}-ca-cert".format(prefix)),
    ]

    for name in dirk_service_names:
        store_specs.append(
            StoreSpec(
                src="/certs/servers/{0}/".format(name),
                name="{0}-server-cert-{1}".format(prefix, name),
            )
        )

    store_specs.extend(
        [
            StoreSpec(
                src="/certs/clients/{0}/{0}.crt".format(vouch_client_name),
                name="{0}-vouch-client-cert".format(prefix),
            ),
            StoreSpec(
                src="/certs/clients/{0}/{0}.key".format(vouch_client_name),
                name="{0}-vouch-client-key".format(prefix),
            ),
            StoreSpec(
                src="/certs/clients/{0}/{0}.crt".format(ethdo_client_name),
                name="{0}-ethdo-client-cert".format(prefix),
            ),
            StoreSpec(
                src="/certs/clients/{0}/{0}.key".format(ethdo_client_name),
                name="{0}-ethdo-client-key".format(prefix),
            ),
        ]
    )

    # Build the shell script that generates all certs in one shot
    script = _build_cert_script(
        dirk_service_names, vouch_client_name, ethdo_client_name
    )

    step_name = "generate-{0}-certs".format(prefix)
    result = plan.run_sh(
        name=step_name,
        description="Generating TLS certificates for Dirk cluster {0}".format(
            cluster_id
        )
        if cluster_id
        else "Generating TLS certificates for Dirk cluster",
        run=script,
        image=OPENSSL_IMAGE,
        store=store_specs,
        wait=None,
    )

    # Map result artifacts back to a structured return value.
    # The artifacts list follows the same order as store_specs:
    #   [0] = ca cert
    #   [1..N] = server certs (one per dirk service)
    #   [N+1] = vouch client cert
    #   [N+2] = vouch client key
    #   [N+3] = ethdo client cert
    #   [N+4] = ethdo client key
    num_servers = len(dirk_service_names)

    server_certs = {}
    for i, name in enumerate(dirk_service_names):
        server_certs[name] = result.files_artifacts[1 + i]

    return struct(
        ca_cert=result.files_artifacts[0],
        server_certs=server_certs,
        vouch_client_cert=result.files_artifacts[1 + num_servers],
        vouch_client_key=result.files_artifacts[2 + num_servers],
        ethdo_client_cert=result.files_artifacts[3 + num_servers],
        ethdo_client_key=result.files_artifacts[4 + num_servers],
    )


def _build_cert_script(dirk_service_names, vouch_client_name, ethdo_client_name):
    """Build the shell script that generates all certificates."""
    lines = [
        "set -e",
        "",
        "# Create output directories",
        "mkdir -p /certs/ca",
    ]

    for name in dirk_service_names:
        lines.append("mkdir -p /certs/servers/{0}".format(name))

    lines.append("mkdir -p /certs/clients/{0}".format(vouch_client_name))
    lines.append("mkdir -p /certs/clients/{0}".format(ethdo_client_name))

    # Generate CA
    lines.extend(
        [
            "",
            "# Generate CA key and self-signed certificate",
            "openssl genrsa -out /certs/ca/ca.key 4096",
            'openssl req -x509 -new -nodes -key /certs/ca/ca.key -sha256 -days {0} -out /certs/ca/ca.crt -subj "/CN=Dirk CA"'.format(
                CERT_VALIDITY_DAYS
            ),
        ]
    )

    # Generate server certs
    for name in dirk_service_names:
        lines.extend(_server_cert_commands(name))

    # Generate client certs
    lines.extend(_client_cert_commands(vouch_client_name))
    lines.extend(_client_cert_commands(ethdo_client_name))

    # Copy CA cert into each server directory so Dirk can find it alongside its own cert
    for name in dirk_service_names:
        lines.append("cp /certs/ca/ca.crt /certs/servers/{0}/ca.crt".format(name))

    return "\n".join(lines)


def _server_cert_commands(service_name):
    """Return shell commands to generate a server certificate for a Dirk instance."""
    base = "/certs/servers/{0}/{0}".format(service_name)
    dir = "/certs/servers/{0}".format(service_name)
    return [
        "",
        "# Server certificate for {0}".format(service_name),
        "openssl genrsa -out {0}.key 4096".format(base),
        "cat > {0}.ext <<EOF\nauthorityKeyIdentifier=keyid,issuer\nbasicConstraints=CA:FALSE\nkeyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment\nsubjectAltName = @alt_names\n\n[alt_names]\nDNS.1 = {1}\nEOF".format(
            base, service_name
        ),
        'openssl req -out {0}.csr -key {0}.key -new -subj "/CN={1}" -addext "subjectAltName=DNS:{1}"'.format(
            base, service_name
        ),
        "openssl x509 -req -in {0}.csr -CA /certs/ca/ca.crt -CAkey /certs/ca/ca.key -CAcreateserial -out {0}.crt -days {1} -sha256 -extfile {0}.ext".format(
            base, CERT_VALIDITY_DAYS
        ),
        "# Rename to canonical names expected by Dirk",
        "mv {0}.crt {1}/server.crt".format(base, dir),
        "mv {0}.key {1}/server.key".format(base, dir),
    ]


def _client_cert_commands(client_name):
    """Return shell commands to generate a client certificate."""
    base = "/certs/clients/{0}/{0}".format(client_name)
    return [
        "",
        "# Client certificate for {0}".format(client_name),
        "openssl genrsa -out {0}.key 4096".format(base),
        "cat > {0}.ext <<EOF\nauthorityKeyIdentifier=keyid,issuer\nbasicConstraints=CA:FALSE\nkeyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment\nsubjectAltName = @alt_names\n\n[alt_names]\nDNS.1 = {1}\nEOF".format(
            base, client_name
        ),
        'openssl req -out {0}.csr -key {0}.key -new -subj "/CN={1}" -addext "subjectAltName=DNS:{1}"'.format(
            base, client_name
        ),
        "openssl x509 -req -in {0}.csr -CA /certs/ca/ca.crt -CAkey /certs/ca/ca.key -CAcreateserial -out {0}.crt -days {1} -sha256 -extfile {0}.ext".format(
            base, CERT_VALIDITY_DAYS
        ),
    ]
