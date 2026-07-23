shared_utils = import_module("../shared_utils/shared_utils.star")
constants = import_module("../package_io/constants.star")

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
  listen-address: 0.0.0.0:8881
log-level: Debug
certificates:
  ca-cert: file:///certs/ca.crt
  server-cert: file:///certs/server.crt
  server-key: file:///certs/server.key
metrics:
  listen-address: 0.0.0.0:8181
storage-path: /tmp/protection
stores:
- name: Local
  type: filesystem
  location: /wallets
peers:
{{ .PeerEntries }}
process:
  # NOTE: Hardcoded passphrases — acceptable for ephemeral devnets only.
  generation-passphrase: secret
  generation-timeout: 120s
unlocker:
  wallet-passphrases:
    - secret
  account-passphrases:
    - secret
permissions:
{{ .Permissions }}
{{- if .TracingConfig }}
{{ .TracingConfig }}
{{- end }}"""


def launch_dirk_cluster(
    plan,
    dirk_image,
    peer_count,
    signing_threshold,
    cert_result,
    vouch_client_name,
    tolerations,
    node_selectors,
    cluster_prefix="dirk",
    tempo_otlp_grpc_url=None,
    dirk_service_names=None,
    replacement_server_certs=None,
    expired_server_certs=None,
    log_to_file=False,
):
    """Launch N Dirk instances as a distributed key management cluster.

    Args:
        plan: The Kurtosis plan.
        dirk_image: Docker image for Dirk.
        peer_count: Number of Dirk instances to launch.
        signing_threshold: Signing threshold for distributed keys.
        cert_result: Return value from certs.generate_certs().
        vouch_client_name: CN of the Vouch client certificate.
        tolerations: Kubernetes tolerations.
        node_selectors: Kubernetes node selectors.
        cluster_prefix: Prefix for service names (e.g. "dirk-a" → "dirk-a-1").
        tempo_otlp_grpc_url: OTLP gRPC URL for Tempo tracing, or None to disable.
        replacement_server_certs: Dict of service_name -> cert artifact for reload testing.
        expired_server_certs: Dict of service_name -> cert artifact for reload testing.
        log_to_file: When True, captures Dirk output to /tmp/dirk.log via named pipe.

    Returns:
        A list of Dirk service names.
    """
    if dirk_service_names == None:
        dirk_service_names = [
            "{0}-{1}".format(cluster_prefix, i) for i in range(1, peer_count + 1)
        ]

    # Build the peers section (self-reference required even for single node)
    peer_lines = []
    for i in range(1, peer_count + 1):
        service_name = dirk_service_names[i - 1]
        peer_lines.append("  {0}: {1}:{2}".format(i, service_name, DIRK_GRPC_PORT_NUM))
    peer_entries = "\n".join(peer_lines)

    # Build the permissions section — grant both vouch and ethdo clients access
    permission_lines = [
        "  {0}:".format(vouch_client_name),
        "    DistributedWallet: All",
        "  ethdo-client:",
        "    DistributedWallet: All",
    ]
    permissions = "\n".join(permission_lines)

    # Build tracing config (if Tempo is available)
    tracing_config = ""
    if tempo_otlp_grpc_url != None:
        # Dirk expects bare host:port for OTLP gRPC; strip http:// scheme
        tracing_address = tempo_otlp_grpc_url.replace("http://", "")
        tracing_config = "tracing:\n  address: '{0}'".format(tracing_address)

    # Create wallet artifacts for each instance using ethdo
    wallet_artifacts = _create_wallet_artifacts(plan, peer_count, cluster_prefix)

    # Render config and launch each Dirk instance
    for i in range(1, peer_count + 1):
        service_name = dirk_service_names[i - 1]

        # Render the config file for this instance
        config_template_data = {
            "Id": i,
            "ServiceName": service_name,
            "PeerEntries": peer_entries,
            "Permissions": permissions,
            "TracingConfig": tracing_config,
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

        server_cert_artifact = cert_result.server_certs[service_name]

        # Assemble file mounts
        files = {
            DIRK_CONFIG_MOUNTPOINT: config_artifact,
            DIRK_CERTS_MOUNTPOINT: server_cert_artifact,
            DIRK_WALLETS_MOUNTPOINT: wallet_artifacts[i - 1],
        }

        # Mount replacement/expired cert artifacts for certmanager reload testing.
        if (
            replacement_server_certs != None
            and service_name in replacement_server_certs
        ):
            files["/certs-replacement"] = replacement_server_certs[service_name]

        if expired_server_certs != None and service_name in expired_server_certs:
            files["/certs-expired"] = expired_server_certs[service_name]

        # Build service config — optionally with log-to-file entrypoint
        if log_to_file:
            # exec replaces sh with dirk so it stays as PID 1 (receives
            # SIGHUP directly from docker-init).  Output goes straight to
            # /tmp/dirk.log — no named pipe needed.
            config = ServiceConfig(
                image=dirk_image,
                ports=DIRK_USED_PORTS,
                entrypoint=["/bin/sh", "-c"],
                cmd=["exec /app/dirk --base-dir=/config > /tmp/dirk.log 2>&1"],
                files=files,
                tolerations=tolerations,
                node_selectors=node_selectors,
            )
        else:
            config = ServiceConfig(
                image=dirk_image,
                ports=DIRK_USED_PORTS,
                cmd=["--base-dir=/config"],
                files=files,
                tolerations=tolerations,
                node_selectors=node_selectors,
            )

        plan.add_service(service_name, config)

    return dirk_service_names


def _create_wallet_artifacts(plan, peer_count, cluster_prefix="dirk"):
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
        "/app/ethdo --base-dir={0} wallet create --type=distributed --wallet=DistributedWallet".format(
            base_dir_1
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
        description="Creating wallets for {0} instances".format(cluster_prefix),
        run="\n".join(script_lines),
        image=constants.DEFAULT_ETHDO_IMAGE,
        store=store_specs,
        wait=None,
    )

    return [result.files_artifacts[i] for i in range(peer_count)]
