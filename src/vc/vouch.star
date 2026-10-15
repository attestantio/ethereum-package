constants = import_module("../package_io/constants.star")
input_parser = import_module("../package_io/input_parser.star")
shared_utils = import_module("../shared_utils/shared_utils.star")
vc_shared = import_module("./vc_shared.star")


VERBOSITY_LEVELS = {
    constants.GLOBAL_LOG_LEVEL.error: "error",
    constants.GLOBAL_LOG_LEVEL.warn: "warn",
    constants.GLOBAL_LOG_LEVEL.info: "info",
    constants.GLOBAL_LOG_LEVEL.debug: "debug",
    constants.GLOBAL_LOG_LEVEL.trace: "trace",
}

VOUCH_CONFIG_MOUNT_DIRPATH_ON_SERVICE = "/config"
VOUCH_CONFIG_FILENAME = "vouch.yml"
VOUCH_CERTS_MOUNT_DIRPATH_ON_SERVICE = "/certs"
VOUCH_TEMPO_CERTS_MOUNT_DIRPATH_ON_SERVICE = "/tempo-certs"

VOUCH_STRATEGIES_YAML = """strategies:
  aggregateattestation:
    style: 'best'
  attestationdata:
    style: 'majority'
    majority:
      threshold: 2
    timeout: '2s'
  beaconblockheader:
    style: 'first'
  beaconblockproposal:
    style: 'best'
    timeout: '1.5s'
  beaconblockroot:
    style: 'majority'
  duties:
    style: 'first'
  signedbeaconblock:
    style: 'first'
  synccommitteecontribution:
    style: 'best'
    timeout: '1s'
submitter:
  style: 'multinode'
"""


def get_config(
    plan,
    participant,
    el_cl_genesis_data,
    image,
    global_log_level,
    beacon_http_urls,
    cl_context,
    dirk_context,
    full_name,
    tolerations,
    node_selectors,
    port_publisher,
    vc_index,
    extra_files_artifacts,
    vc_binary_artifact=None,
    tempo_otlp_grpc_url=None,
    vouch_account_start=None,
    vouch_account_count=None,
    tempo_client_tls=None,
):
    log_level = input_parser.get_client_log_level_or_default(
        participant.vc_log_level, global_log_level, VERBOSITY_LEVELS
    )

    # Build the dirk endpoints list for the config
    dirk_endpoints_yaml = ""
    for endpoint in dirk_context.endpoints:
        dirk_endpoints_yaml += "      - '{0}'\n".format(endpoint)

    # Build beacon node addresses list for the config
    beacon_node_addresses_yaml = ""
    for url in beacon_http_urls:
        beacon_node_addresses_yaml += "  - '{0}'\n".format(url)

    tracing_yaml = ""
    if tempo_otlp_grpc_url != None:
        tracing_address = tempo_otlp_grpc_url.replace("http://", "")
        if tempo_client_tls != None:
            tracing_yaml = """tracing:
  address: '{0}'
  client-cert: 'file://{1}/client.crt'
  client-key: 'file://{1}/client.key'
  ca-cert: 'file://{1}/ca.crt'
""".format(
                tracing_address, VOUCH_TEMPO_CERTS_MOUNT_DIRPATH_ON_SERVICE
            )
        else:
            tracing_yaml = "tracing:\n  address: '{0}'\n".format(tracing_address)

    if vouch_account_start != None:
        accounts_yaml = (
            "\n".join(
                [
                    "      - '{0}/{1}'".format(constants.DIRK_WALLET_NAME, account)
                    for account in range(
                        vouch_account_start, vouch_account_start + vouch_account_count
                    )
                ]
            )
            + "\n"
        )
    else:
        accounts_yaml = "      - '{0}'\n".format(constants.DIRK_WALLET_NAME)

    if participant.vouch_default_strategies:
        strategies_yaml = ""
    elif participant.vouch_strategies_yaml != "":
        strategies_yaml = participant.vouch_strategies_yaml
        if not strategies_yaml.endswith("\n"):
            strategies_yaml += "\n"
    else:
        strategies_yaml = VOUCH_STRATEGIES_YAML

    multiinstance_yaml = ""
    if participant.vouch_multiinstance_style != "":
        multiinstance_yaml = """multiinstance:
  style: 'static-delay'
  static-delay:
    attester-delay: '{0}'
    proposer-delay: '{1}'
""".format(
            participant.vouch_multiinstance_attester_delay,
            participant.vouch_multiinstance_proposer_delay,
        )

    # The list values end in a newline, so the line after each starts cleanly.
    vouch_config = """log-level: '{log_level}'
beacon-node-addresses:
{beacon_nodes}accountmanager:
  dirk:
    endpoints:
{dirk_endpoints}    client-cert: 'file://{certs_dir}/client.crt'
    client-key: 'file://{certs_dir}/client.key'
    ca-cert: 'file://{certs_dir}/ca.crt'
    accounts:
{accounts}    timeout: '30s'
{strategies}{multiinstance}blockrelay:
  fallback-fee-recipient: '{fee_recipient}'
  fallback-gas-limit: 30000000
metrics:
  prometheus:
    listen-address: '0.0.0.0:{metrics_port}'
graffiti:
  static:
    value: '{graffiti}'
{tracing}""".format(
        log_level=log_level,
        beacon_nodes=beacon_node_addresses_yaml,
        dirk_endpoints=dirk_endpoints_yaml,
        certs_dir=VOUCH_CERTS_MOUNT_DIRPATH_ON_SERVICE,
        accounts=accounts_yaml,
        strategies=strategies_yaml,
        multiinstance=multiinstance_yaml,
        fee_recipient=constants.VALIDATING_REWARDS_ACCOUNT,
        metrics_port=vc_shared.VALIDATOR_CLIENT_METRICS_PORT_NUM,
        graffiti=full_name,
        tracing=tracing_yaml,
    )

    # Create the config file artifact using render_templates
    config_template_and_data = shared_utils.new_template_and_data(vouch_config, {})
    config_files_artifact_name = plan.render_templates(
        {VOUCH_CONFIG_FILENAME: config_template_and_data},
        "vouch-config-{0}".format(vc_index),
    )

    cmd = ["--base-dir=" + VOUCH_CONFIG_MOUNT_DIRPATH_ON_SERVICE]

    if len(participant.vc_extra_params) > 0:
        cmd.extend([param for param in participant.vc_extra_params])

    files = {
        VOUCH_CONFIG_MOUNT_DIRPATH_ON_SERVICE: config_files_artifact_name,
    }

    files[VOUCH_CERTS_MOUNT_DIRPATH_ON_SERVICE] = dirk_context.vouch_certs_artifact
    if tempo_client_tls != None:
        files[VOUCH_TEMPO_CERTS_MOUNT_DIRPATH_ON_SERVICE] = tempo_client_tls

    public_ports = {}
    if port_publisher.vc_enabled:
        public_ports_for_component = shared_utils.get_public_ports_for_component(
            "vc", port_publisher, vc_index
        )
        public_port_assignments = {
            constants.METRICS_PORT_ID: public_ports_for_component[0]
        }
        public_ports = shared_utils.get_port_specs(public_port_assignments)

    ports = {}
    ports.update(vc_shared.VALIDATOR_CLIENT_USED_PORTS)

    # Add extra mounts - automatically handle file uploads
    processed_mounts = shared_utils.process_extra_mounts(
        plan, participant.vc_extra_mounts, extra_files_artifacts
    )
    for mount_path, artifact in processed_mounts.items():
        files[mount_path] = artifact

    # Binary injection - mount custom binary directory if provided
    if vc_binary_artifact != None:
        files["/opt/bin"] = vc_binary_artifact.artifact

    config_args = {
        "image": image,
        "ports": ports,
        "public_ports": public_ports,
        "publish_udp": port_publisher.vc_enabled,
        "cmd": cmd,
        "files": files,
        "env_vars": participant.vc_extra_env_vars,
        "labels": shared_utils.label_maker(
            client=constants.VC_TYPE.vouch,
            client_type=constants.CLIENT_TYPES.validator,
            image=image[-constants.MAX_LABEL_LENGTH :],
            connected_client=cl_context.client_name,
            extra_labels=participant.vc_extra_labels
            | {constants.NODE_INDEX_LABEL_KEY: str(vc_index + 1)},
            supernode=participant.supernode,
        ),
        "tolerations": tolerations,
        "node_selectors": node_selectors,
    }

    # Binary injection - override entrypoint and cmd only when binary is provided
    if vc_binary_artifact != None:
        config_args["entrypoint"] = ["sh", "-c"]
        config_args["cmd"] = [
            "cp /opt/bin/{0} /usr/local/bin/vouch && vouch ".format(
                vc_binary_artifact.filename
            )
            + " ".join(cmd)
        ]

    if participant.vc_min_cpu > 0:
        config_args["min_cpu"] = participant.vc_min_cpu
    if participant.vc_max_cpu > 0:
        config_args["max_cpu"] = participant.vc_max_cpu
    if participant.vc_min_mem > 0:
        config_args["min_memory"] = participant.vc_min_mem
    if participant.vc_max_mem > 0:
        config_args["max_memory"] = participant.vc_max_mem
    if len(participant.vc_devices) > 0:
        config_args["devices"] = participant.vc_devices
    return ServiceConfig(**config_args)
