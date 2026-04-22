shared_utils = import_module("../shared_utils/shared_utils.star")
constants = import_module("../package_io/constants.star")
input_parser = import_module("../package_io/input_parser.star")

SERVICE_NAME = "tempo"

# Tempo standard ports
HTTP_PORT_ID = "http"
HTTP_PORT_NUMBER = 3200
GRPC_PORT_ID = "grpc"
GRPC_PORT_NUMBER = 9095
OTLP_GRPC_PORT_ID = "otlp-grpc"
OTLP_GRPC_PORT_NUMBER = 4317
OTLP_HTTP_PORT_ID = "otlp-http"
OTLP_HTTP_PORT_NUMBER = 4318

TEMPO_CONFIG_FILENAME = "tempo.yaml"
TEMPO_CONFIG_MOUNT_DIRPATH_ON_SERVICE = "/etc/tempo"
TEMPO_TLS_MOUNT_DIRPATH_ON_SERVICE = "/etc/tempo/tls"
TEMPO_SERVER_CERT_PATH = TEMPO_TLS_MOUNT_DIRPATH_ON_SERVICE + "/server.crt"
TEMPO_SERVER_KEY_PATH = TEMPO_TLS_MOUNT_DIRPATH_ON_SERVICE + "/server.key"
TEMPO_CLIENT_CA_PATH = TEMPO_TLS_MOUNT_DIRPATH_ON_SERVICE + "/ca.crt"

USED_PORTS = {
    HTTP_PORT_ID: shared_utils.new_port_spec(
        HTTP_PORT_NUMBER,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    ),
    GRPC_PORT_ID: shared_utils.new_port_spec(
        GRPC_PORT_NUMBER,
        shared_utils.TCP_PROTOCOL,
    ),
    OTLP_GRPC_PORT_ID: shared_utils.new_port_spec(
        OTLP_GRPC_PORT_NUMBER,
        shared_utils.TCP_PROTOCOL,
    ),
    OTLP_HTTP_PORT_ID: shared_utils.new_port_spec(
        OTLP_HTTP_PORT_NUMBER,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    ),
}


def launch_tempo(
    plan,
    config_template,
    global_node_selectors,
    global_tolerations,
    tempo_params,
    port_publisher,
    index,
    tempo_mtls_enabled=False,
    tempo_server_cert_artifact=None,
    tempo_client_ca_artifact=None,
):
    tolerations = shared_utils.get_tolerations(global_tolerations=global_tolerations)

    config_files_artifact_name = get_tempo_config_dir_artifact_uuid(
        plan,
        config_template,
        tempo_params,
        tempo_mtls_enabled,
    )

    public_ports = shared_utils.get_additional_service_standard_public_port(
        port_publisher,
        HTTP_PORT_ID,
        index,
        1,
    )

    tls_artifact = None
    if tempo_mtls_enabled:
        tls_artifact = _prepare_tempo_tls_artifact(
            plan,
            tempo_server_cert_artifact,
            tempo_client_ca_artifact,
        )

    config = get_config(
        config_files_artifact_name,
        global_node_selectors,
        tolerations,
        tempo_params,
        public_ports,
        tls_artifact,
    )

    service = plan.add_service(SERVICE_NAME, config)

    # Return connection info for other services
    return struct(
        service_name=SERVICE_NAME,
        ip_addr=service.name,
        http_port_num=HTTP_PORT_NUMBER,
        grpc_port_num=GRPC_PORT_NUMBER,
        otlp_grpc_port_num=OTLP_GRPC_PORT_NUMBER,
        otlp_http_port_num=OTLP_HTTP_PORT_NUMBER,
        http_url="http://{}:{}".format(service.name, HTTP_PORT_NUMBER),
        grpc_url="{}:{}".format(service.name, GRPC_PORT_NUMBER),
        otlp_grpc_url="{}:{}".format(SERVICE_NAME, OTLP_GRPC_PORT_NUMBER),
        otlp_http_url="http://{}:{}".format(SERVICE_NAME, OTLP_HTTP_PORT_NUMBER),
    )


def get_tempo_config_dir_artifact_uuid(
    plan,
    config_template,
    tempo_params,
    tempo_mtls_enabled=False,
):
    template_data = new_config_template_data(tempo_params, tempo_mtls_enabled)

    template_and_data = shared_utils.new_template_and_data(
        config_template, template_data
    )

    template_and_data_by_rel_dest_filepath = {}
    template_and_data_by_rel_dest_filepath[TEMPO_CONFIG_FILENAME] = template_and_data

    config_files_artifact_name = plan.render_templates(
        template_and_data_by_rel_dest_filepath, "tempo-config"
    )

    return config_files_artifact_name


def get_config(
    config_files_artifact_name,
    node_selectors,
    tolerations,
    tempo_params,
    public_ports,
    tls_artifact=None,
):
    config_file_path = shared_utils.path_join(
        TEMPO_CONFIG_MOUNT_DIRPATH_ON_SERVICE,
        TEMPO_CONFIG_FILENAME,
    )

    files = {
        TEMPO_CONFIG_MOUNT_DIRPATH_ON_SERVICE: config_files_artifact_name,
    }
    if tls_artifact != None:
        files[TEMPO_TLS_MOUNT_DIRPATH_ON_SERVICE] = tls_artifact

    return ServiceConfig(
        image=tempo_params.image,
        ports=USED_PORTS,
        public_ports=public_ports,
        files=files,
        cmd=[
            "-config.file={}".format(config_file_path),
        ],
        min_cpu=tempo_params.min_cpu,
        max_cpu=tempo_params.max_cpu,
        min_memory=tempo_params.min_mem,
        max_memory=tempo_params.max_mem,
        node_selectors=node_selectors,
        tolerations=tolerations,
    )


def new_config_template_data(tempo_params, tempo_mtls_enabled=False):
    return {
        "HTTPPort": HTTP_PORT_NUMBER,
        "GRPCPort": GRPC_PORT_NUMBER,
        "OTLPGRPCPort": OTLP_GRPC_PORT_NUMBER,
        "OTLPHTTPPort": OTLP_HTTP_PORT_NUMBER,
        "RetentionDuration": tempo_params.retention_duration,
        "IngestionRateLimit": tempo_params.ingestion_rate_limit,
        "IngestionBurstLimit": tempo_params.ingestion_burst_limit,
        "MaxSearchDuration": tempo_params.max_search_duration,
        "MaxBytesPerTrace": tempo_params.max_bytes_per_trace,
        "TempoMTLSEnabled": tempo_mtls_enabled,
        "TempoServerCertPath": TEMPO_SERVER_CERT_PATH,
        "TempoServerKeyPath": TEMPO_SERVER_KEY_PATH,
        "TempoClientCAPath": TEMPO_CLIENT_CA_PATH,
    }


def _prepare_tempo_tls_artifact(plan, server_cert_artifact, client_ca_artifact):
    """Combine the server cert/key and client CA into a single artifact with
    canonical filenames (server.crt, server.key, ca.crt) that the tempo.yaml
    template references. The server_cert_artifact is a directory containing
    both server.crt and server.key (produced by tempo_certs.star).
    """
    result = plan.run_sh(
        name="prepare-tempo-tls",
        description="Preparing Tempo TLS material for mTLS OTLP ingress",
        run="\n".join(
            [
                "set -e",
                "mkdir -p /out",
                "cp /server-cert/server.crt /out/server.crt",
                "cp /server-cert/server.key /out/server.key",
                "cp /ca/ca.crt /out/ca.crt",
                # Tempo container runs as a non-root user; openssl writes keys
                # mode 600 as root, so make them world-readable.
                "chmod 0644 /out/server.crt /out/server.key /out/ca.crt",
            ]
        ),
        image="alpine:3.21",
        files={
            "/server-cert": server_cert_artifact,
            "/ca": client_ca_artifact,
        },
        store=[StoreSpec(src="/out/", name="tempo-tls-mounted")],
        wait=None,
    )
    return result.files_artifacts[0]
