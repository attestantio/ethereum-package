OPENSSL_IMAGE = "alpine/openssl:3.5.5"

CERT_VALIDITY_DAYS_LONG = 1825
CERT_VALIDITY_DAYS_SHORT = 1  # Fallback if -not_after unsupported
INITIAL_CERT_MINUTES = 10


def generate_test_certs(
    plan, dirk_service_names, vouch_client_name="vouch-client", cluster_id=""
):
    """Generate all TLS certificates for certmanager testing.

    Produces three sets of server certs from one CA:
    - Initial: short-lived (~10 min) for baseline testing
    - Replacement: long-lived (5 years) for reload testing
    - Expired: already-expired for error/recovery testing

    Client certs (vouch, ethdo) are long-lived and shared across all phases.

    Returns a struct matching the normal cert_result shape (ca_cert, server_certs,
    vouch_client_cert, vouch_client_key, ethdo_client_cert, ethdo_client_key)
    plus extra fields: replacement_server_certs, expired_server_certs.
    """
    ethdo_client_name = "ethdo-client"
    prefix = "dirk-{0}".format(cluster_id) if cluster_id else "dirk"
    test_prefix = "{0}-test".format(prefix)

    # Build StoreSpec entries — order matters for artifact indexing
    store_specs = []

    # [0] CA cert
    store_specs.append(
        StoreSpec(src="/certs/ca/ca.crt", name="{0}-ca-cert".format(prefix))
    )

    # [1..N] Initial server certs (short-lived)
    for name in dirk_service_names:
        store_specs.append(
            StoreSpec(
                src="/certs/servers-initial/{0}/".format(name),
                name="{0}-server-cert-{1}".format(prefix, name),
            )
        )

    # [N+1..2N] Replacement server certs (long-lived)
    for name in dirk_service_names:
        store_specs.append(
            StoreSpec(
                src="/certs/servers-replacement/{0}/".format(name),
                name="{0}-replacement-cert-{1}".format(test_prefix, name),
            )
        )

    # [2N+1..3N] Expired server certs
    for name in dirk_service_names:
        store_specs.append(
            StoreSpec(
                src="/certs/servers-expired/{0}/".format(name),
                name="{0}-expired-cert-{1}".format(test_prefix, name),
            )
        )

    # [3N+1] vouch client cert
    store_specs.append(
        StoreSpec(
            src="/certs/clients/{0}/{0}.crt".format(vouch_client_name),
            name="{0}-vouch-client-cert".format(prefix),
        )
    )
    # [3N+2] vouch client key
    store_specs.append(
        StoreSpec(
            src="/certs/clients/{0}/{0}.key".format(vouch_client_name),
            name="{0}-vouch-client-key".format(prefix),
        )
    )
    # [3N+3] ethdo client cert
    store_specs.append(
        StoreSpec(
            src="/certs/clients/{0}/{0}.crt".format(ethdo_client_name),
            name="{0}-ethdo-client-cert".format(prefix),
        )
    )
    # [3N+4] ethdo client key
    store_specs.append(
        StoreSpec(
            src="/certs/clients/{0}/{0}.key".format(ethdo_client_name),
            name="{0}-ethdo-client-key".format(prefix),
        )
    )

    script = _build_test_cert_script(
        dirk_service_names, vouch_client_name, ethdo_client_name
    )

    step_name = "generate-{0}-test-certs".format(prefix)
    result = plan.run_sh(
        name=step_name,
        description="Generating test TLS certificates (initial/replacement/expired) for certmanager testing",
        run=script,
        image=OPENSSL_IMAGE,
        store=store_specs,
        wait=None,
    )

    num_servers = len(dirk_service_names)

    # Map artifacts: indices follow store_specs order
    # [0] = ca_cert
    # [1..N] = initial server certs
    # [N+1..2N] = replacement server certs
    # [2N+1..3N] = expired server certs
    # [3N+1..3N+4] = client certs/keys

    server_certs = {}
    replacement_server_certs = {}
    expired_server_certs = {}

    for i, name in enumerate(dirk_service_names):
        server_certs[name] = result.files_artifacts[1 + i]
        replacement_server_certs[name] = result.files_artifacts[1 + num_servers + i]
        expired_server_certs[name] = result.files_artifacts[1 + 2 * num_servers + i]

    client_base = 1 + 3 * num_servers

    return struct(
        # Standard cert_result fields (compatible with existing downstream code)
        ca_cert=result.files_artifacts[0],
        server_certs=server_certs,
        vouch_client_cert=result.files_artifacts[client_base],
        vouch_client_key=result.files_artifacts[client_base + 1],
        ethdo_client_cert=result.files_artifacts[client_base + 2],
        ethdo_client_key=result.files_artifacts[client_base + 3],
        # Extra fields for certmanager testing
        replacement_server_certs=replacement_server_certs,
        expired_server_certs=expired_server_certs,
    )


def _build_test_cert_script(dirk_service_names, vouch_client_name, ethdo_client_name):
    """Build shell script that generates all certificate sets in one shot."""
    lines = [
        "set -e",
        "",
        "# Create output directories",
        "mkdir -p /certs/ca",
    ]

    for name in dirk_service_names:
        lines.append("mkdir -p /certs/servers-initial/{0}".format(name))
        lines.append("mkdir -p /certs/servers-replacement/{0}".format(name))
        lines.append("mkdir -p /certs/servers-expired/{0}".format(name))

    lines.append("mkdir -p /certs/clients/{0}".format(vouch_client_name))
    lines.append("mkdir -p /certs/clients/{0}".format(ethdo_client_name))

    # Generate CA (long-lived)
    lines.extend(
        [
            "",
            "# Generate CA key and self-signed certificate",
            "openssl genrsa -out /certs/ca/ca.key 4096",
            'openssl req -x509 -new -nodes -key /certs/ca/ca.key -sha256 -days {0} -out /certs/ca/ca.crt -subj "/CN=Dirk CA"'.format(
                CERT_VALIDITY_DAYS_LONG
            ),
        ]
    )

    # Compute timestamps for short-lived and expired certs.
    # OpenSSL 3.x supports -not_after for sub-day precision; we try it and
    # fall back to -days if the flag isn't available.
    lines.extend(
        [
            "",
            "# Compute timestamps for short-lived / expired certs",
            "NOW=$(date -u +%s)",
            "INITIAL_END=$(( NOW + {0} * 60 ))".format(INITIAL_CERT_MINUTES),
            "EXPIRED_END=$(( NOW - 60 ))",  # 1 minute in the past
            "",
            "# Format as GeneralizedTime (YYYYMMDDHHMMSSZ) for -not_after",
            "INITIAL_NOT_AFTER=$(date -u -d @$INITIAL_END +%Y%m%d%H%M%SZ 2>/dev/null || date -u -r $INITIAL_END +%Y%m%d%H%M%SZ)",
            "EXPIRED_NOT_AFTER=$(date -u -d @$EXPIRED_END +%Y%m%d%H%M%SZ 2>/dev/null || date -u -r $EXPIRED_END +%Y%m%d%H%M%SZ)",
            "NOW_NOT_BEFORE=$(date -u -d @$NOW +%Y%m%d%H%M%SZ 2>/dev/null || date -u -r $NOW +%Y%m%d%H%M%SZ)",
            "",
            "# Detect if openssl supports -not_after (OpenSSL 3.x feature)",
            "HAS_NOT_AFTER=false",
            'if openssl x509 -help 2>&1 | grep -q "not_after"; then',
            "  HAS_NOT_AFTER=true",
            "fi",
        ]
    )

    # Generate initial server certs (short-lived ~10 min)
    for name in dirk_service_names:
        lines.extend(
            _server_cert_commands(
                name,
                "/certs/servers-initial",
                "initial",
            )
        )

    # Generate replacement server certs (long-lived)
    for name in dirk_service_names:
        lines.extend(
            _server_cert_commands(
                name,
                "/certs/servers-replacement",
                "replacement",
            )
        )

    # Generate expired server certs
    for name in dirk_service_names:
        lines.extend(
            _server_cert_commands(
                name,
                "/certs/servers-expired",
                "expired",
            )
        )

    # Generate client certs (long-lived)
    lines.extend(_client_cert_commands(vouch_client_name))
    lines.extend(_client_cert_commands(ethdo_client_name))

    # Copy CA cert into each server directory
    for name in dirk_service_names:
        lines.append(
            "cp /certs/ca/ca.crt /certs/servers-initial/{0}/ca.crt".format(name)
        )
        lines.append(
            "cp /certs/ca/ca.crt /certs/servers-replacement/{0}/ca.crt".format(name)
        )
        lines.append(
            "cp /certs/ca/ca.crt /certs/servers-expired/{0}/ca.crt".format(name)
        )

    return "\n".join(lines)


def _server_cert_commands(service_name, base_dir, cert_type):
    """Return shell commands to generate a server certificate.

    cert_type: "initial" (short-lived), "replacement" (long-lived), or "expired".
    """
    base = "{0}/{1}/{1}".format(base_dir, service_name)
    ext_file = "{0}/{1}/{1}.ext".format(base_dir, service_name)

    lines = [
        "",
        "# {0} server certificate for {1}".format(cert_type.capitalize(), service_name),
        "openssl genrsa -out {0}.key 4096".format(base),
        "cat > {0} <<EOF\nauthorityKeyIdentifier=keyid,issuer\nbasicConstraints=CA:FALSE\nkeyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment\nsubjectAltName = @alt_names\n\n[alt_names]\nDNS.1 = {1}\nEOF".format(
            ext_file, service_name
        ),
        'openssl req -out {0}.csr -key {0}.key -new -subj "/CN={1}" -addext "subjectAltName=DNS:{1}"'.format(
            base, service_name
        ),
    ]

    if cert_type == "initial":
        # Short-lived: use -not_after if available, else -days 1
        lines.extend(
            [
                'if [ "$HAS_NOT_AFTER" = "true" ]; then',
                "  openssl x509 -req -in {0}.csr -CA /certs/ca/ca.crt -CAkey /certs/ca/ca.key -CAcreateserial -out {0}.crt -sha256 -extfile {1} -not_before $NOW_NOT_BEFORE -not_after $INITIAL_NOT_AFTER".format(
                    base, ext_file
                ),
                "else",
                "  openssl x509 -req -in {0}.csr -CA /certs/ca/ca.crt -CAkey /certs/ca/ca.key -CAcreateserial -out {0}.crt -days {1} -sha256 -extfile {2}".format(
                    base, CERT_VALIDITY_DAYS_SHORT, ext_file
                ),
                "fi",
            ]
        )
    elif cert_type == "replacement":
        # Long-lived replacement cert
        lines.append(
            "openssl x509 -req -in {0}.csr -CA /certs/ca/ca.crt -CAkey /certs/ca/ca.key -CAcreateserial -out {0}.crt -days {1} -sha256 -extfile {2}".format(
                base, CERT_VALIDITY_DAYS_LONG, ext_file
            )
        )
    elif cert_type == "expired":
        # Already expired: use -not_after in the past if available, else -days 0
        lines.extend(
            [
                'if [ "$HAS_NOT_AFTER" = "true" ]; then',
                "  openssl x509 -req -in {0}.csr -CA /certs/ca/ca.crt -CAkey /certs/ca/ca.key -CAcreateserial -out {0}.crt -sha256 -extfile {1} -not_before 20240101000000Z -not_after $EXPIRED_NOT_AFTER".format(
                    base, ext_file
                ),
                "else",
                "  # Fallback: create cert with -days 1 then backdate via faketime or accept it as near-expired",
                "  openssl x509 -req -in {0}.csr -CA /certs/ca/ca.crt -CAkey /certs/ca/ca.key -CAcreateserial -out {0}.crt -days 0 -sha256 -extfile {1}".format(
                    base, ext_file
                ),
                "fi",
            ]
        )

    return lines


def _client_cert_commands(client_name):
    """Return shell commands to generate a long-lived client certificate with DNS SAN."""
    base = "/certs/clients/{0}/{0}".format(client_name)
    ext_file = "/certs/clients/{0}/{0}.ext".format(client_name)
    return [
        "",
        "# Client certificate for {0}".format(client_name),
        "openssl genrsa -out {0}.key 4096".format(base),
        "cat > {0} <<EOF\nauthorityKeyIdentifier=keyid,issuer\nbasicConstraints=CA:FALSE\nkeyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment\nsubjectAltName = @alt_names\n\n[alt_names]\nDNS.1 = {1}\nEOF".format(
            ext_file, client_name
        ),
        'openssl req -out {0}.csr -key {0}.key -new -subj "/CN={1}" -addext "subjectAltName=DNS:{1}"'.format(
            base, client_name
        ),
        "openssl x509 -req -in {0}.csr -CA /certs/ca/ca.crt -CAkey /certs/ca/ca.key -CAcreateserial -out {0}.crt -days {1} -sha256 -extfile {2}".format(
            base, CERT_VALIDITY_DAYS_LONG, ext_file
        ),
    ]
