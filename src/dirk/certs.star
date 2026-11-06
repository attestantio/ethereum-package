constants = import_module("../package_io/constants.star")
dirk_clusters = import_module("../package_io/dirk_clusters.star")

ETHDO_CLIENT_NAME = "ethdo-client"


def generate_certs(plan, dirk_service_names, vouch_client_name, cluster_id):
    """Generate the TLS material for one Dirk cluster.

    Every artifact is a directory ready to mount, with the file names its
    consumer expects:
      server_certs[name]: server.crt, server.key, ca.crt for that Dirk peer
      vouch_certs: client.crt, client.key, ca.crt for Vouch
      ethdo_certs: ethdo.crt, ethdo.key, ca.crt for the DKG ceremony

    cluster_id is "" for the single default cluster.
    """
    prefix = dirk_clusters.cluster_prefix(cluster_id)
    store_specs = [
        StoreSpec(
            src="/certs/servers/{0}/".format(name),
            name="{0}-server-cert-{1}".format(prefix, name),
        )
        for name in dirk_service_names
    ] + [
        StoreSpec(src="/certs/vouch/", name="{0}-vouch-certs".format(prefix)),
        StoreSpec(src="/certs/ethdo/", name="{0}-ethdo-certs".format(prefix)),
    ]

    result = plan.run_sh(
        name="generate-{0}-certs".format(prefix),
        description="Generating TLS certificates for Dirk cluster {0}".format(prefix),
        run=_build_cert_script(dirk_service_names, vouch_client_name),
        image=constants.OPENSSL_IMAGE,
        store=store_specs,
        wait=None,
    )

    # files_artifacts follows the order of store_specs.
    num_servers = len(dirk_service_names)
    return struct(
        server_certs={
            name: result.files_artifacts[i] for i, name in enumerate(dirk_service_names)
        },
        vouch_certs=result.files_artifacts[num_servers],
        ethdo_certs=result.files_artifacts[num_servers + 1],
    )


def _build_cert_script(dirk_service_names, vouch_client_name):
    lines = [
        "set -e",
        "mkdir -p /certs/ca /certs/vouch /certs/ethdo",
        "openssl genrsa -out /certs/ca/ca.key 4096",
        'openssl req -x509 -new -nodes -key /certs/ca/ca.key -sha256 -days {0} -out /certs/ca/ca.crt -subj "/CN=Dirk CA"'.format(
            constants.CERT_VALIDITY_DAYS
        ),
    ]
    for name in dirk_service_names:
        directory = "/certs/servers/{0}".format(name)
        lines.append("mkdir -p {0}".format(directory))
        lines.extend(_cert_commands(directory, "server", name))
        lines.append("cp /certs/ca/ca.crt {0}/ca.crt".format(directory))
    lines.extend(_cert_commands("/certs/vouch", "client", vouch_client_name))
    lines.append("cp /certs/ca/ca.crt /certs/vouch/ca.crt")
    lines.extend(_cert_commands("/certs/ethdo", "ethdo", ETHDO_CLIENT_NAME))
    lines.append("cp /certs/ca/ca.crt /certs/ethdo/ca.crt")
    # Only the certificate and key files belong in the mounted directories.
    lines.append(
        "rm -f /certs/*/*.csr /certs/*/*.ext /certs/servers/*/*.csr /certs/servers/*/*.ext"
    )
    return "\n".join(lines)


def _cert_commands(directory, file_name, identity):
    """Commands that write <directory>/<file_name>.{key,crt} for identity, signed by the CA.

    The identity is both the CN and the only DNS SAN.
    """
    base = "{0}/{1}".format(directory, file_name)
    return [
        "openssl genrsa -out {0}.key 4096".format(base),
        "cat > {0}.ext <<EOF\nauthorityKeyIdentifier=keyid,issuer\nbasicConstraints=CA:FALSE\nkeyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment\nsubjectAltName = @alt_names\n\n[alt_names]\nDNS.1 = {1}\nEOF".format(
            base, identity
        ),
        'openssl req -out {0}.csr -key {0}.key -new -subj "/CN={1}" -addext "subjectAltName=DNS:{1}"'.format(
            base, identity
        ),
        "openssl x509 -req -in {0}.csr -CA /certs/ca/ca.crt -CAkey /certs/ca/ca.key -CAcreateserial -out {0}.crt -days {1} -sha256 -extfile {0}.ext".format(
            base, constants.CERT_VALIDITY_DAYS
        ),
    ]
