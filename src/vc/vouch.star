constants = import_module("../package_io/constants.star")
input_parser = import_module("../package_io/input_parser.star")
shared_utils = import_module("../shared_utils/shared_utils.star")
vc_shared = import_module("./shared.star")


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
    vouch_account_start=None,
    vouch_account_count=None,
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

    # Build the accounts list YAML
    accounts_yaml = ""
    if (
        vouch_account_start != None
        and vouch_account_count != None
        and vouch_account_count > 0
    ):
        for i in range(vouch_account_start, vouch_account_start + vouch_account_count):
            accounts_yaml += "      - '{0}/{1}'\n".format(dirk_context.wallet_name, i)
    else:
        accounts_yaml += "      - '{0}'\n".format(dirk_context.wallet_name)

    # Build the multiinstance YAML block (if configured)
    multiinstance_yaml = ""
    if participant.vouch_multiinstance_style != "":
        multiinstance_yaml = """multiinstance:
  style: '{0}'
  {0}:
    attester-delay: '{1}'
    proposer-delay: '{2}'
""".format(
            participant.vouch_multiinstance_style,
            participant.vouch_multiinstance_attester_delay,
            participant.vouch_multiinstance_proposer_delay,
        )

    # Build the vouch.yml config file content
    # NOTE: {2} (dirk_endpoints_yaml) and {4} (accounts_yaml) must keep their
    # trailing \n — the next template line continues without a separator.
    vouch_config_template = """log-level: '{0}'
beacon-node-addresses:
{1}
accountmanager:
  dirk:
    endpoints:
{2}    client-cert: 'file://{3}/client.crt'
    client-key: 'file://{3}/client.key'
    ca-cert: 'file://{3}/ca.crt'
    accounts:
{4}    timeout: '30s'
blockrelay:
  fallback-fee-recipient: '{5}'
  fallback-gas-limit: 30000000
metrics:
  prometheus:
    listen-address: '0.0.0.0:{6}'
graffiti:
  static:
    value: '{7}'
{8}""".format(
        log_level,
        beacon_node_addresses_yaml.rstrip("\n"),
        dirk_endpoints_yaml,
        VOUCH_CERTS_MOUNT_DIRPATH_ON_SERVICE,
        accounts_yaml,
        constants.VALIDATING_REWARDS_ACCOUNT,
        vc_shared.VALIDATOR_CLIENT_METRICS_PORT_NUM,
        full_name,
        multiinstance_yaml,
    )

    # Create the config file artifact using render_templates
    config_template_and_data = shared_utils.new_template_and_data(
        vouch_config_template, {}
    )
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

    # Prepare a combined TLS cert artifact with canonical filenames
    # (client.crt, client.key, ca.crt) that Vouch expects.
    certs_artifact = _prepare_vouch_certs(
        plan,
        vc_index,
        dirk_context.ca_cert_artifact,
        dirk_context.client_cert_artifact,
        dirk_context.client_key_artifact,
    )
    files[VOUCH_CERTS_MOUNT_DIRPATH_ON_SERVICE] = certs_artifact

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


def _prepare_vouch_certs(
    plan, vc_index, ca_cert_artifact, client_cert_artifact, client_key_artifact
):
    """Combine separate TLS cert artifacts into a single artifact with canonical names.

    The dirk_context cert artifacts contain files named after the client CN
    (e.g. vouch-client.crt, vouch-client.key) and ca.crt. This function copies
    them into a single directory with the names client.crt, client.key, ca.crt
    that the vouch.yml config references.
    """
    result = plan.run_sh(
        name="prepare-vouch-certs-{0}".format(vc_index),
        description="Preparing TLS cert files for Vouch VC {0}".format(vc_index),
        run="\n".join(
            [
                "set -e",
                "mkdir -p /out",
                "cp /ca-cert/* /out/ca.crt",
                "cp /client-cert/* /out/client.crt",
                "cp /client-key/* /out/client.key",
            ]
        ),
        image="alpine:3.21",
        files={
            "/ca-cert": ca_cert_artifact,
            "/client-cert": client_cert_artifact,
            "/client-key": client_key_artifact,
        },
        store=[
            StoreSpec(
                src="/out/",
                name="vouch-certs-{0}".format(vc_index),
            )
        ],
        wait=None,
    )

    return result.files_artifacts[0]
