shared_utils = import_module("../shared_utils/shared_utils.star")
constants = import_module("../package_io/constants.star")
certs = import_module("./certs.star")

DIRK_GRPC_PORT_NUM = 8881
DIRK_GRPC_PORT_ID = "grpc"
DIRK_METRICS_PORT_NUM = 8181
DIRK_METRICS_PORT_ID = "metrics"

DIRK_CONFIG_MOUNTPOINT = "/config"
DIRK_CERTS_MOUNTPOINT = "/certs"
DIRK_WALLETS_MOUNTPOINT = "/wallets"
DIRK_STORAGE_MOUNTPOINT = "/storage"

DIRK_USED_PORTS = {
    DIRK_GRPC_PORT_ID: shared_utils.new_port_spec(
        DIRK_GRPC_PORT_NUM,
        shared_utils.TCP_PROTOCOL,
    ),
    DIRK_METRICS_PORT_ID: shared_utils.new_port_spec(
        DIRK_METRICS_PORT_NUM,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    ),
}

# dirk.yml template used by plan.render_templates()
DIRK_CONFIG_TEMPLATE = """server:
  id: {{ .Id }}
  name: {{ .ServiceName }}
  listen-address: 0.0.0.0:{{ .GrpcPort }}
log-level: Debug
certificates:
  ca-cert: file:///certs/ca.crt
  server-cert: file:///certs/server.crt
  server-key: file:///certs/server.key
metrics:
  listen-address: 0.0.0.0:{{ .MetricsPort }}
storage-path: /tmp/protection
stores:
- name: Local
  type: filesystem
  location: /wallets
peers:
{{ .PeerEntries }}
process:
  generation-passphrase: secret
  generation-timeout: 120s
unlocker:
  wallet-passphrases:
    - secret
  account-passphrases:
    - secret
permissions:
{{ .Permissions }}
{{ .TracingConfig }}
"""


def launch_dirk_cluster(
    plan,
    dirk_image,
    service_names,
    cert_result,
    vouch_client_name,
    tolerations,
    node_selectors,
    tempo_otlp_grpc_url=None,
    cluster_prefix="dirk",
):
    """Launch N Dirk instances as a distributed key management cluster.

    Args:
        plan: The Kurtosis plan.
        dirk_image: Docker image for Dirk.
        service_names: Dirk service names, one per peer.
        cert_result: Return value from certs.generate_certs().
        vouch_client_name: CN of the Vouch client certificate.
        tolerations: Kubernetes tolerations.
        node_selectors: Kubernetes node selectors.
    """
    peer_count = len(service_names)

    # Build the peers section (self-reference required even for single node)
    peer_lines = []
    for i in range(1, peer_count + 1):
        peer_lines.append(
            "  {0}: {1}:{2}".format(i, service_names[i - 1], DIRK_GRPC_PORT_NUM)
        )
    peer_entries = "\n".join(peer_lines)

    # Build the permissions section — grant both vouch and ethdo clients access
    permission_lines = [
        "  {0}:".format(vouch_client_name),
        "    {0}: All".format(constants.DIRK_WALLET_NAME),
        "  {0}:".format(certs.ETHDO_CLIENT_NAME),
        "    {0}: All".format(constants.DIRK_WALLET_NAME),
    ]
    permissions = "\n".join(permission_lines)
    tracing_config = ""
    if tempo_otlp_grpc_url != None:
        tracing_config = "tracing:\n  address: '{0}'".format(
            tempo_otlp_grpc_url.replace("http://", "")
        )

    # Create wallet artifacts for each instance using ethdo
    wallet_artifacts = _create_wallet_artifacts(plan, peer_count, cluster_prefix)

    # Render config and launch each Dirk instance
    for i in range(1, peer_count + 1):
        service_name = service_names[i - 1]

        # Render the config file for this instance
        config_template_data = {
            "Id": i,
            "ServiceName": service_name,
            "PeerEntries": peer_entries,
            "Permissions": permissions,
            "TracingConfig": tracing_config,
            "GrpcPort": DIRK_GRPC_PORT_NUM,
            "MetricsPort": DIRK_METRICS_PORT_NUM,
        }
        config_artifact = plan.render_templates(
            {
                "dirk.yml": struct(
                    template=DIRK_CONFIG_TEMPLATE,
                    data=config_template_data,
                ),
            },
            "{0}-config-{1}".format(cluster_prefix, i),
        )

        # Assemble file mounts
        files = {
            DIRK_CONFIG_MOUNTPOINT: config_artifact,
            DIRK_CERTS_MOUNTPOINT: cert_result.server_certs[service_name],
            DIRK_WALLETS_MOUNTPOINT: wallet_artifacts[i - 1],
        }

        config = ServiceConfig(
            image=dirk_image,
            ports=DIRK_USED_PORTS,
            cmd=["--base-dir=/config"],
            files=files,
            tolerations=tolerations,
            node_selectors=node_selectors,
        )

        plan.add_service(service_name, config)


def _create_wallet_artifacts(plan, peer_count, cluster_prefix):
    """Create wallet directories for each Dirk instance using ethdo.

    Creates an empty distributed wallet that will be populated by the
    DKG ceremony after Dirk is running.

    Returns a list of file artifacts, one per Dirk instance.
    """
    store_specs = []

    script_lines = ["set -e"]

    # Create wallet for first instance (distributed type for DKG)
    base_dir_1 = "/tmp/wallets-1"
    script_lines.append("mkdir -p {0}".format(base_dir_1))
    script_lines.append(
        "/app/ethdo --base-dir={0} wallet create --type=distributed --wallet={1}".format(
            base_dir_1, constants.DIRK_WALLET_NAME
        )
    )

    # Copy wallet to other instances
    for i in range(2, peer_count + 1):
        base_dir = "/tmp/wallets-{0}".format(i)
        script_lines.append("cp -r {0} {1}".format(base_dir_1, base_dir))

    for i in range(1, peer_count + 1):
        store_specs.append(
            StoreSpec(
                src="/tmp/wallets-{0}/".format(i),
                name="{0}-wallet-{1}".format(cluster_prefix, i),
            )
        )

    result = plan.run_sh(
        name="create-{0}-wallets".format(cluster_prefix),
        description="Creating wallets for Dirk instances",
        run="\n".join(script_lines),
        image=constants.DEFAULT_ETHDO_IMAGE,
        store=store_specs,
        wait=None,
    )

    return [result.files_artifacts[i] for i in range(peer_count)]
