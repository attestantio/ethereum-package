el_cl_genesis_data_generator = import_module(
    "./prelaunch_data_generator/el_cl_genesis/el_cl_genesis_generator.star"
)

input_parser = import_module("./package_io/input_parser.star")
shared_utils = import_module("./shared_utils/shared_utils.star")
static_files = import_module("./static_files/static_files.star")
constants = import_module("./package_io/constants.star")

ethereum_metrics_exporter = import_module(
    "./ethereum_metrics_exporter/ethereum_metrics_exporter_launcher.star"
)

participant_module = import_module("./participant.star")

xatu_sentry = import_module("./xatu_sentry/xatu_sentry_launcher.star")
launch_ephemery = import_module("./network_launcher/ephemery.star")
launch_public_network = import_module("./network_launcher/public_network.star")
launch_devnet = import_module("./network_launcher/devnet.star")
launch_kurtosis = import_module("./network_launcher/kurtosis.star")
launch_shadowfork = import_module("./network_launcher/shadowfork.star")

el_client_launcher = import_module("./el/el_launcher.star")
cl_client_launcher = import_module("./cl/cl_launcher.star")
vc = import_module("./vc/vc_launcher.star")
vc_shared = import_module("./vc/shared.star")
vc_context_l = import_module("./vc/vc_context.star")
node_metrics = import_module("./node_metrics_info.star")
remote_signer = import_module("./remote_signer/remote_signer_launcher.star")

beacon_snooper = import_module("./snooper/snooper_beacon_launcher.star")
snooper_el_launcher = import_module("./snooper/snooper_el_launcher.star")
blobber_launcher = import_module("./blobber/blobber_launcher.star")
cl_context_module = import_module("./cl/cl_context.star")
bootnodoor_launcher = import_module("./bootnodoor/bootnodoor_launcher.star")

dirk_launcher = import_module("./dirk/dirk_launcher.star")
dirk_certs = import_module("./dirk/certs.star")
dirk_dkg = import_module("./dirk/dkg.star")
dirk_context_module = import_module("./dirk/dirk_context.star")
certmanager_test_certs = import_module("./certmanager_test/certs_test.star")


def launch_participant_network(
    plan,
    args_with_right_defaults,
    network_params,
    jwt_file,
    keymanager_file,
    persistent,
    xatu_sentry_params,
    global_tolerations,
    global_node_selectors,
    keymanager_enabled,
    parallel_keystore_generation,
    extra_files_artifacts,
    tempo_otlp_grpc_url,
    backend,
    tempo_mtls_enabled=False,
    tempo_client_cert_artifact=None,
    tempo_client_key_artifact=None,
    tempo_ca_artifact=None,
):
    network_id = network_params.network_id
    num_participants = len(args_with_right_defaults.participants)
    total_number_of_validator_keys = 0
    latest_block = ""
    global_other_index = 0

    # Phase 0: DKG setup (if vouch participants exist) — must happen before genesis
    dkg_validators_artifact = None
    has_vouch_participant = False
    vouch_account_offset = 0
    vouch_account_ranges = {}
    _valid_multiinstance_styles = ["", "static-delay"]

    # Pass 1: Identify clusters and validate vouch participants
    # cluster_defs maps cluster_id -> struct(dirk_peer_count, dirk_signing_threshold, dirk_image, validator_count, account_start)
    cluster_defs = {}
    # Maps participant index -> cluster_id
    participant_cluster_map = {}
    # Auto-naming counter for clusters without explicit dirk_cluster_id
    auto_cluster_names = "abcdefghijklmnopqrstuvwxyz"
    auto_cluster_index = 0

    for index, participant in enumerate(args_with_right_defaults.participants):
        if participant.vc_type == constants.VC_TYPE.vouch:
            has_vouch_participant = True

            # Validate multiinstance style
            if participant.vouch_multiinstance_style not in _valid_multiinstance_styles:
                fail(
                    (
                        "Vouch participant #{0} has invalid vouch_multiinstance_style "
                        + "'{1}'. Valid values: {2}"
                    ).format(
                        index + 1,
                        participant.vouch_multiinstance_style,
                        ", ".join(
                            [
                                "'" + s + "'"
                                for s in _valid_multiinstance_styles
                                if s != ""
                            ]
                        ),
                    )
                )

            # Determine cluster membership
            cluster_id = participant.dirk_cluster_id

            # Validate cluster_id contains only safe characters (used in
            # shell commands and service names via plan.run_sh).
            if cluster_id != None:
                for c in cluster_id.elems():
                    if c not in "abcdefghijklmnopqrstuvwxyz0123456789":
                        fail(
                            (
                                "dirk_cluster_id '{0}' contains invalid character '{1}'. "
                                + "Only lowercase alphanumeric characters are allowed."
                            ).format(cluster_id, c)
                        )

            is_cluster_creator = (
                participant.dirk_peer_count > 0 and participant.validator_count > 0
            )

            if is_cluster_creator:
                # This participant creates a new cluster
                if cluster_id == None:
                    if auto_cluster_index >= len(auto_cluster_names):
                        fail(
                            (
                                "Vouch participant #{0}: too many auto-named clusters "
                                + "(max {1}). Use explicit dirk_cluster_id values."
                            ).format(index + 1, len(auto_cluster_names))
                        )
                    cluster_id = auto_cluster_names[auto_cluster_index]
                    auto_cluster_index += 1
                if cluster_id in cluster_defs:
                    fail(
                        (
                            "Vouch participant #{0}: dirk_cluster_id '{1}' already "
                            + "defined by another participant. Use a unique cluster_id "
                            + "or omit it for auto-assignment."
                        ).format(index + 1, cluster_id)
                    )
                cluster_defs[cluster_id] = struct(
                    dirk_peer_count=participant.dirk_peer_count,
                    dirk_signing_threshold=participant.dirk_signing_threshold,
                    dirk_image=participant.dirk_image,
                    validator_count=participant.validator_count,
                    account_start=vouch_account_offset,
                )

                # Compute account range for this participant
                vouch_account_ranges[index] = struct(
                    start=vouch_account_offset,
                    count=participant.validator_count,
                )
                vouch_account_offset += participant.validator_count
                participant_cluster_map[index] = cluster_id

            else:
                # Passive participant (validator_count=0) — joins existing cluster
                has_start = participant.vouch_account_start != None
                has_count = participant.vouch_account_count != None
                if has_start != has_count:
                    fail(
                        (
                            "Vouch participant #{0}: vouch_account_start and "
                            + "vouch_account_count must both be specified together."
                        ).format(index + 1)
                    )
                if not has_start:
                    fail(
                        (
                            "Vouch participant #{0} has validator_count=0 but no explicit "
                            + "vouch_account_start/vouch_account_count. Passive Vouch instances "
                            + "must specify their account range."
                        ).format(index + 1)
                    )
                vouch_account_ranges[index] = struct(
                    start=participant.vouch_account_start,
                    count=participant.vouch_account_count,
                )
                if cluster_id == None:
                    fail(
                        (
                            "Vouch participant #{0} is passive (validator_count=0) but has "
                            + "no dirk_cluster_id. Passive participants must specify "
                            + "dirk_cluster_id to join a cluster."
                        ).format(index + 1)
                    )
                if cluster_id not in cluster_defs:
                    # The cluster may be defined by a later participant; defer validation
                    pass
                participant_cluster_map[index] = cluster_id

    # Pass 2: Validate all passive participants reference valid clusters
    if has_vouch_participant:
        for index in participant_cluster_map:
            cid = participant_cluster_map[index]
            if cid not in cluster_defs:
                fail(
                    (
                        "Vouch participant #{0} references dirk_cluster_id '{1}' "
                        + "but no participant creates that cluster."
                    ).format(index + 1, cid)
                )

    # Pass 3: Detect overlapping account ranges without multiinstance coordination
    for i in vouch_account_ranges:
        for j in vouch_account_ranges:
            if i >= j:
                continue
            r1 = vouch_account_ranges[i]
            r2 = vouch_account_ranges[j]
            if r1.start < r2.start + r2.count and r2.start < r1.start + r1.count:
                # Overlap detected — only allowed with multiinstance
                p1 = args_with_right_defaults.participants[i]
                p2 = args_with_right_defaults.participants[j]
                if (
                    p1.vouch_multiinstance_style == ""
                    or p2.vouch_multiinstance_style == ""
                ):
                    fail(
                        (
                            "Vouch participants #{0} and #{1} have overlapping account ranges "
                            + "[{2},{3}) and [{4},{5}) but are not both configured with "
                            + "vouch_multiinstance_style. Overlapping ranges without "
                            + "multiinstance coordination risk double attestation."
                        ).format(
                            i + 1,
                            j + 1,
                            r1.start,
                            r1.start + r1.count,
                            r2.start,
                            r2.start + r2.count,
                        )
                    )

    # Validate account ranges are within cluster bounds
    for index in vouch_account_ranges:
        r = vouch_account_ranges[index]
        cid = participant_cluster_map[index]
        cdef = cluster_defs[cid]
        cluster_end = cdef.account_start + cdef.validator_count
        range_end = r.start + r.count
        if r.count > 0 and (r.start < cdef.account_start or range_end > cluster_end):
            fail(
                (
                    "Vouch participant #{0}: account range [{1},{2}) is outside "
                    + "cluster '{3}' bounds [{4},{5})."
                ).format(
                    index + 1,
                    r.start,
                    range_end,
                    cid,
                    cdef.account_start,
                    cluster_end,
                )
            )

    # Per-cluster setup: certs, launch, DKG, extract pubkeys
    cluster_dirk_contexts = {}
    cluster_validator_artifacts = []
    certmanager_test_enabled = args_with_right_defaults.certmanager_test_enabled
    certmanager_cluster_info = {}

    if has_vouch_participant:
        plan.print(
            "Setting up {0} Dirk cluster(s) and DKG before genesis generation".format(
                len(cluster_defs)
            )
        )

        for cluster_id in cluster_defs:
            cdef = cluster_defs[cluster_id]
            cluster_prefix = "dirk-{0}".format(cluster_id)

            # Validate Dirk cluster parameters
            if cdef.dirk_peer_count < 1:
                fail(
                    "Cluster {0}: dirk_peer_count must be at least 1, got {1}".format(
                        cluster_id, cdef.dirk_peer_count
                    )
                )
            if cdef.dirk_signing_threshold < 1:
                fail(
                    "Cluster {0}: dirk_signing_threshold must be at least 1, got {1}".format(
                        cluster_id, cdef.dirk_signing_threshold
                    )
                )
            if cdef.dirk_signing_threshold > cdef.dirk_peer_count:
                fail(
                    "Cluster {0}: dirk_signing_threshold ({1}) cannot exceed dirk_peer_count ({2})".format(
                        cluster_id,
                        cdef.dirk_signing_threshold,
                        cdef.dirk_peer_count,
                    )
                )

            # Generate Dirk service names and certificates for this cluster
            vouch_client_name = "vouch-client"
            wallet_name = "DistributedWallet"

            # launch_dirk_cluster computes service names internally;
            # we need them before launch for cert generation.
            dirk_service_names = [
                "{0}-{1}".format(cluster_prefix, i + 1)
                for i in range(cdef.dirk_peer_count)
            ]

            replacement_server_certs = None
            expired_server_certs = None

            if certmanager_test_enabled:
                cert_result = certmanager_test_certs.generate_test_certs(
                    plan,
                    dirk_service_names,
                    cluster_id=cluster_id,
                )
                replacement_server_certs = cert_result.replacement_server_certs
                expired_server_certs = cert_result.expired_server_certs
            else:
                cert_result = dirk_certs.generate_certs(
                    plan,
                    dirk_service_names,
                    cluster_id=cluster_id,
                )

            # Launch Dirk cluster
            dirk_service_names = dirk_launcher.launch_dirk_cluster(
                plan,
                dirk_image=cdef.dirk_image,
                peer_count=cdef.dirk_peer_count,
                signing_threshold=cdef.dirk_signing_threshold,
                cert_result=cert_result,
                vouch_client_name=vouch_client_name,
                tolerations=global_tolerations,
                node_selectors=global_node_selectors,
                cluster_prefix=cluster_prefix,
                tempo_otlp_grpc_url=tempo_otlp_grpc_url,
                dirk_service_names=dirk_service_names,
                replacement_server_certs=replacement_server_certs,
                expired_server_certs=expired_server_certs,
                log_to_file=certmanager_test_enabled,
            )

            # Run DKG ceremony
            dirk_dkg.run_dkg_ceremony(
                plan,
                dirk_service_names=dirk_service_names,
                cert_result=cert_result,
                validator_count=cdef.validator_count,
                signing_threshold=cdef.dirk_signing_threshold,
                peer_count=cdef.dirk_peer_count,
                wallet_name=wallet_name,
                account_start=cdef.account_start,
                cluster_id=cluster_id,
            )

            # Extract composite public keys
            validators_artifact = dirk_dkg.extract_dkg_validators_file(
                plan,
                dirk_service_names=dirk_service_names,
                cert_result=cert_result,
                validator_count=cdef.validator_count,
                wallet_name=wallet_name,
                account_start=cdef.account_start,
                cluster_id=cluster_id,
            )
            cluster_validator_artifacts.append(validators_artifact)

            # Create Dirk context for this cluster
            dirk_endpoints = [
                "{0}:{1}".format(name, dirk_launcher.DIRK_GRPC_PORT_NUM)
                for name in dirk_service_names
            ]
            cluster_dirk_contexts[cluster_id] = dirk_context_module.new_dirk_context(
                endpoints=dirk_endpoints,
                ca_cert_artifact=cert_result.ca_cert,
                client_cert_artifact=cert_result.vouch_client_cert,
                client_key_artifact=cert_result.vouch_client_key,
                wallet_name=wallet_name,
                threshold=cdef.dirk_signing_threshold,
                peer_count=cdef.dirk_peer_count,
            )

            # Collect cluster info for certmanager testing
            if certmanager_test_enabled:
                certmanager_cluster_info[cluster_id] = struct(
                    dirk_service_names=dirk_service_names,
                    replacement_server_certs=replacement_server_certs,
                    expired_server_certs=expired_server_certs,
                    ca_cert_artifact=cert_result.ca_cert,
                    client_cert_artifact=cert_result.vouch_client_cert,
                    client_key_artifact=cert_result.vouch_client_key,
                )

        # Merge per-cluster validators files into one artifact for genesis
        if len(cluster_validator_artifacts) == 1:
            dkg_validators_artifact = cluster_validator_artifacts[0]
        else:
            # Concatenate all per-cluster validators.txt files
            cat_lines = [
                "set -e",
                "mkdir -p /out",
                'echo "# DKG validator pubkeys for genesis (merged)" > /out/validators.txt',
            ]
            file_mounts = {}
            for i, artifact in enumerate(cluster_validator_artifacts):
                mount = "/cluster-{0}".format(i)
                file_mounts[mount] = artifact
                # Skip the single header line ("# DKG validator pubkeys for genesis")
                # written by extract_dkg_validators_file.
                cat_lines.append(
                    "tail -n +2 {0}/validators.txt >> /out/validators.txt".format(mount)
                )
            merge_result = plan.run_sh(
                name="merge-dkg-validators",
                description="Merging DKG validators from {0} clusters".format(
                    len(cluster_validator_artifacts)
                ),
                run="\n".join(cat_lines),
                image="alpine:3.21",
                files=file_mounts,
                store=[StoreSpec(src="/out/", name="dkg-validators-file-merged")],
                wait=None,
            )
            dkg_validators_artifact = merge_result.files_artifacts[0]

    # Phase 1: Genesis generation
    if (
        network_params.network == constants.NETWORK_NAME.kurtosis
        or constants.NETWORK_NAME.shadowfork in network_params.network
    ):
        if (
            constants.NETWORK_NAME.shadowfork in network_params.network
        ):  # shadowfork requires some preparation
            latest_block, network_id = launch_shadowfork.shadowfork_prep(
                plan,
                network_params,
                args_with_right_defaults.participants,
                global_tolerations,
                global_node_selectors,
            )

        # We are running a kurtosis or shadowfork network
        (
            total_number_of_validator_keys,
            ethereum_genesis_generator_image,
            final_genesis_timestamp,
            validator_data,
        ) = launch_kurtosis.launch(
            plan, network_params, args_with_right_defaults, parallel_keystore_generation
        )

        el_cl_genesis_config_template = read_file(
            static_files.EL_CL_GENESIS_GENERATION_CONFIG_TEMPLATE_FILEPATH
        )

        el_cl_genesis_additional_contracts_template = read_file(
            static_files.EL_CL_GENESIS_ADDITIONAL_CONTRACTS_TEMPLATE_FILEPATH
        )

        el_cl_data = el_cl_genesis_data_generator.generate_el_cl_genesis_data(
            plan,
            ethereum_genesis_generator_image,
            args_with_right_defaults.ethereum_genesis_generator_params,
            el_cl_genesis_config_template,
            el_cl_genesis_additional_contracts_template,
            final_genesis_timestamp,
            network_params,
            total_number_of_validator_keys,
            latest_block.files_artifacts[0] if latest_block != "" else "",
            global_tolerations,
            global_node_selectors,
            additional_validators_artifact=dkg_validators_artifact,
        )
    elif network_params.network == constants.NETWORK_NAME.ephemery:
        # We are running an ephemery network
        (
            el_cl_data,
            final_genesis_timestamp,
            network_id,
            validator_data,
        ) = launch_ephemery.launch(plan, global_tolerations, global_node_selectors)
    elif (
        network_params.network in constants.PUBLIC_NETWORKS
        and network_params.network != constants.NETWORK_NAME.ephemery
    ):
        # We are running a public network
        (
            el_cl_data,
            final_genesis_timestamp,
            network_id,
            validator_data,
        ) = launch_public_network.launch(
            plan,
            args_with_right_defaults.participants,
            network_params,
            global_tolerations,
            global_node_selectors,
        )
    else:
        # We are running a devnet
        (
            el_cl_data,
            final_genesis_timestamp,
            network_id,
            validator_data,
        ) = launch_devnet.launch(
            plan,
            network_params.network,
            network_params.devnet_repo,
            global_tolerations,
            global_node_selectors,
        )

    # Launch bootnodoor if configured
    bootnodoor_enr = None
    bootnodoor_enode = None
    if "bootnodoor" in args_with_right_defaults.additional_services:
        plan.print("Launching bootnodoor as bootnode service")
        args_with_right_defaults.additional_services.remove("bootnodoor")
        bootnodoor_enr, bootnodoor_enode = bootnodoor_launcher.launch_bootnodoor(
            plan,
            args_with_right_defaults.bootnodoor_params,
            el_cl_data,
            network_params,
            global_node_selectors,
            global_tolerations,
            args_with_right_defaults.docker_cache_params,
        )
        plan.print("Bootnodoor launched with ENR: {0}".format(bootnodoor_enr))
        plan.print("Bootnodoor launched with ENODE: {0}".format(bootnodoor_enode))

    # Upload binary artifacts when both binary_path and force_restart are enabled
    binary_artifacts = {}
    for index, participant in enumerate(args_with_right_defaults.participants):
        participant_binaries = {}
        for bin_type, bin_path, force_restart in [
            ("el", participant.el_binary_path, participant.el_force_restart),
            ("cl", participant.cl_binary_path, participant.cl_force_restart),
            ("vc", participant.vc_binary_path, participant.vc_force_restart),
        ]:
            if bin_path and force_restart:
                participant_binaries[bin_type] = struct(
                    artifact=plan.upload_files(
                        src="../" + bin_path,
                        name="{0}-binary-{1}".format(bin_type, index + 1),
                    ),
                    filename=bin_path.split("/")[-1],
                )
        if participant_binaries:
            binary_artifacts[index] = participant_binaries

    # Launch all execution layer clients
    all_el_contexts = el_client_launcher.launch(
        plan,
        network_params,
        el_cl_data,
        jwt_file,
        args_with_right_defaults.participants,
        args_with_right_defaults.global_log_level,
        global_node_selectors,
        global_tolerations,
        persistent,
        network_id,
        num_participants,
        args_with_right_defaults.port_publisher,
        args_with_right_defaults.mev_type,
        args_with_right_defaults.mev_params,
        extra_files_artifacts,
        bootnodoor_enode,
        binary_artifacts,
    )

    # Launch all consensus layer clients
    prysm_password_relative_filepath = (
        validator_data.prysm_password_relative_filepath
        if total_number_of_validator_keys > 0
        else None
    )
    prysm_password_artifact_uuid = (
        validator_data.prysm_password_artifact_uuid
        if total_number_of_validator_keys > 0
        else None
    )

    (
        all_cl_contexts,
        all_snooper_el_engine_contexts,
        preregistered_validator_keys_for_nodes,
        global_other_index,
        blobber_configs_with_contexts,
    ) = cl_client_launcher.launch(
        plan,
        network_params,
        el_cl_data,
        jwt_file,
        keymanager_file,
        args_with_right_defaults,
        all_el_contexts,
        global_node_selectors,
        global_tolerations,
        persistent,
        tempo_otlp_grpc_url,
        num_participants,
        validator_data,
        prysm_password_relative_filepath,
        prysm_password_artifact_uuid,
        global_other_index,
        extra_files_artifacts,
        backend,
        bootnodoor_enr,
        binary_artifacts,
    )

    # Stop beacon nodes for participants with skip_start enabled
    for index, participant in enumerate(args_with_right_defaults.participants):
        if participant.skip_start:
            cl_context = all_cl_contexts[index]
            plan.print(
                "Stopping beacon node {0} due to skip_start flag".format(
                    cl_context.beacon_service_name
                )
            )
            plan.stop_service(cl_context.beacon_service_name)

    # Launch all blobbers after all CLs are up
    cl_context_to_blobber_url = {}
    if len(blobber_configs_with_contexts) > 0:
        plan.print("Launching blobbers for CL clients that have them enabled")
        for config in blobber_configs_with_contexts:
            blobber = blobber_launcher.launch(
                plan,
                config.blobber_config.service_name,
                config.blobber_config.node_keystore_files,
                config.blobber_config.beacon_http_url,
                config.participant,
                config.blobber_config.node_selectors,
                global_tolerations,
            )

            # Store the blobber URL mapping
            blobber_http_url = "http://{0}:{1}".format(
                blobber.dns_name, blobber.port_num
            )
            cl_context_to_blobber_url[
                config.cl_context.beacon_service_name
            ] = blobber_http_url

    # Helper function to get cl_context with blobber URL if available
    def get_cl_context_with_blobber_url(cl_context):
        beacon_service_name = cl_context.beacon_service_name
        effective_beacon_url = cl_context_to_blobber_url.get(
            beacon_service_name, cl_context.beacon_http_url
        )

        if effective_beacon_url == cl_context.beacon_http_url:
            # No blobber, return original context
            return cl_context

        # Create a new cl_context with the blobber URL
        return cl_context_module.new_cl_context(
            client_name=cl_context.client_name,
            enr=cl_context.enr,
            ip_addr=cl_context.ip_addr,
            http_port=cl_context.http_port,
            beacon_http_url=effective_beacon_url,
            cl_nodes_metrics_info=cl_context.cl_nodes_metrics_info,
            beacon_service_name=cl_context.beacon_service_name,
            beacon_grpc_url=cl_context.beacon_grpc_url,
            multiaddr=cl_context.multiaddr,
            peer_id=cl_context.peer_id,
            snooper_enabled=cl_context.snooper_enabled,
            snooper_el_engine_context=cl_context.snooper_el_engine_context,
            validator_keystore_files_artifact_uuid=cl_context.validator_keystore_files_artifact_uuid,
            supernode=cl_context.supernode,
        )

    ethereum_metrics_exporter_context = None
    all_ethereum_metrics_exporter_contexts = []
    all_xatu_sentry_contexts = []
    all_vc_contexts = []
    all_remote_signer_contexts = []
    all_snooper_beacon_contexts = []
    all_snooper_el_rpc_contexts = []
    # Some CL clients cannot run validator clients in the same process and need
    # a separate validator client
    _cls_that_need_separate_vc = [
        constants.CL_TYPE.prysm,
        constants.CL_TYPE.lodestar,
        constants.CL_TYPE.lighthouse,
    ]

    current_vc_index = 0
    if not args_with_right_defaults.participants:
        fail("No participants configured")

    vc_service_configs = {}
    vc_service_info = {}

    for index, participant in enumerate(args_with_right_defaults.participants):
        el_type = participant.el_type
        cl_type = participant.cl_type
        vc_type = participant.vc_type
        remote_signer_type = participant.remote_signer_type
        index_str = shared_utils.zfill_custom(
            index + 1, len(str(len(args_with_right_defaults.participants)))
        )
        el_context = all_el_contexts[index] if index < len(all_el_contexts) else None
        cl_context = all_cl_contexts[index] if index < len(all_cl_contexts) else None

        node_selectors = input_parser.get_client_node_selectors(
            participant.node_selectors,
            global_node_selectors,
        )
        if participant.ethereum_metrics_exporter_enabled:
            pair_name = "{0}-{1}-{2}".format(index_str, cl_type, el_type)

            ethereum_metrics_exporter_service_name = (
                "ethereum-metrics-exporter-{0}".format(pair_name)
            )

            ethereum_metrics_exporter_context = ethereum_metrics_exporter.launch(
                plan,
                pair_name,
                ethereum_metrics_exporter_service_name,
                el_context,
                get_cl_context_with_blobber_url(cl_context),
                node_selectors,
                global_tolerations,
                args_with_right_defaults.port_publisher,
                global_other_index,
                args_with_right_defaults.docker_cache_params,
                persistent,
            )
            global_other_index += 1
            plan.print(
                "Successfully added {0} ethereum metrics exporter participants".format(
                    ethereum_metrics_exporter_context
                )
            )

            all_ethereum_metrics_exporter_contexts.append(
                ethereum_metrics_exporter_context
            )

            xatu_sentry_context = None

        if participant.xatu_sentry_enabled:
            pair_name = "{0}-{1}-{2}".format(index_str, cl_type, el_type)

            xatu_sentry_service_name = "xatu-sentry-{0}".format(pair_name)

            xatu_sentry_context = xatu_sentry.launch(
                plan,
                xatu_sentry_service_name,
                get_cl_context_with_blobber_url(cl_context),
                xatu_sentry_params,
                network_params,
                pair_name,
                node_selectors,
                global_tolerations,
            )
            plan.print(
                "Successfully added {0} xatu sentry participants".format(
                    xatu_sentry_context
                )
            )

            all_xatu_sentry_contexts.append(xatu_sentry_context)

        # Create snooper RPC context for all participants if snooper is enabled
        snooper_el_rpc_context = None
        if participant.snooper_enabled:
            snooper_service_name = "snooper-rpc-{0}-{1}".format(
                index_str,
                el_type,
            )
            snooper_el_rpc_context = snooper_el_launcher.launch_snooper(
                plan,
                snooper_service_name,
                el_context,
                node_selectors,
                global_tolerations,
                args_with_right_defaults.port_publisher,
                global_other_index,
                args_with_right_defaults.docker_cache_params,
                args_with_right_defaults.snooper_params,
            )
            global_other_index += 1
            plan.print(
                "Successfully added {0} snooper RPC participants".format(
                    snooper_el_rpc_context
                )
            )

        all_snooper_el_rpc_contexts.append(snooper_el_rpc_context)
        plan.print("Successfully added {0} CL participants".format(num_participants))

        plan.print("Start adding validators for participant #{0}".format(index_str))
        if participant.use_separate_vc == None:
            # This should only be the case for the MEV participant,
            # the regular participants default to False/True
            all_vc_contexts.append(None)
            all_remote_signer_contexts.append(None)
            all_snooper_beacon_contexts.append(None)
            continue

        if cl_type in _cls_that_need_separate_vc and not participant.use_separate_vc:
            fail("{0} needs a separate validator client!".format(cl_type))

        if not participant.use_separate_vc:
            all_vc_contexts.append(None)
            all_remote_signer_contexts.append(None)
            all_snooper_beacon_contexts.append(None)
            continue

        plan.print(
            "Using separate validator client for participant #{0}".format(index_str)
        )

        vc_keystores = None
        if participant.validator_count != 0:
            vc_keystores = preregistered_validator_keys_for_nodes[index]

        vc_context = None
        remote_signer_context = None
        snooper_beacon_context = None
        snooper_el_rpc_context = None

        if participant.snooper_enabled:
            snooper_service_name = "snooper-beacon-{0}-{1}-{2}".format(
                index_str,
                cl_type,
                vc_type,
            )
            snooper_beacon_context = beacon_snooper.launch(
                plan,
                snooper_service_name,
                get_cl_context_with_blobber_url(cl_context),
                node_selectors,
                global_tolerations,
                args_with_right_defaults.port_publisher,
                global_other_index,
                args_with_right_defaults.docker_cache_params,
                args_with_right_defaults.snooper_params,
            )
            plan.print(
                "Successfully added {0} snooper participants".format(
                    snooper_beacon_context
                )
            )
            global_other_index += 1

        all_snooper_beacon_contexts.append(snooper_beacon_context)

        full_name = (
            "{0}-{1}-{2}-{3}".format(
                index_str,
                el_type,
                cl_type,
                vc_type,
            )
            if participant.cl_type != participant.vc_type
            else "{0}-{1}-{2}".format(
                index_str,
                el_type,
                cl_type,
            )
        )

        if participant.use_remote_signer:
            remote_signer_context = remote_signer.launch(
                plan=plan,
                launcher=remote_signer.new_remote_signer_launcher(
                    el_cl_genesis_data=el_cl_data
                ),
                service_name="signer-{0}".format(full_name),
                remote_signer_type=remote_signer_type,
                image=participant.remote_signer_image,
                full_name="{0}-remote_signer".format(full_name),
                vc_type=vc_type,
                node_keystore_files=vc_keystores,
                participant=participant,
                global_tolerations=global_tolerations,
                node_selectors=node_selectors,
                port_publisher=args_with_right_defaults.port_publisher,
                remote_signer_index=current_vc_index,
            )

        all_remote_signer_contexts.append(remote_signer_context)
        if remote_signer_context and remote_signer_context.metrics_info:
            remote_signer_context.metrics_info["config"] = participant.prometheus_config

        service_name = "vc-{0}".format(full_name)
        vc_binary_artifact = binary_artifacts.get(index, {}).get("vc", None)
        vc_service_config = vc.get_vc_config(
            plan=plan,
            launcher=vc.new_vc_launcher(el_cl_genesis_data=el_cl_data),
            keymanager_file=keymanager_file,
            service_name=service_name,
            vc_type=vc_type,
            image=participant.vc_image,
            global_log_level=args_with_right_defaults.global_log_level,
            cl_context=get_cl_context_with_blobber_url(cl_context),
            all_cl_contexts=all_cl_contexts,
            el_context=el_context,
            remote_signer_context=remote_signer_context,
            full_name=full_name,
            snooper_enabled=participant.snooper_enabled,
            snooper_beacon_context=snooper_beacon_context,
            node_keystore_files=vc_keystores,
            participant=participant,
            prysm_password_relative_filepath=prysm_password_relative_filepath,
            prysm_password_artifact_uuid=prysm_password_artifact_uuid,
            global_tolerations=global_tolerations,
            node_selectors=node_selectors,
            network_params=network_params,
            port_publisher=args_with_right_defaults.port_publisher,
            vc_index=current_vc_index,
            extra_files_artifacts=extra_files_artifacts,
            tempo_otlp_grpc_url=tempo_otlp_grpc_url,
            tempo_mtls_enabled=tempo_mtls_enabled,
            tempo_client_cert_artifact=tempo_client_cert_artifact,
            tempo_client_key_artifact=tempo_client_key_artifact,
            tempo_ca_artifact=tempo_ca_artifact,
            vc_binary_artifact=vc_binary_artifact,
            dirk_context=cluster_dirk_contexts[participant_cluster_map[index]]
            if vc_type == constants.VC_TYPE.vouch and index in participant_cluster_map
            else None,
            vouch_account_start=vouch_account_ranges[index].start
            if index in vouch_account_ranges
            else None,
            vouch_account_count=vouch_account_ranges[index].count
            if index in vouch_account_ranges
            else None,
        )
        if vc_service_config == None:
            continue

        vc_service_configs[service_name] = vc_service_config
        vc_service_info[service_name] = {
            "client_name": vc_type,
            "participant_index": index,
            "participant": participant,
        }
        current_vc_index += 1

    # add vc's in parallel to speed package execution
    vc_services = shared_utils.add_services_with_force_restart(
        plan, vc_service_configs, vc_service_info, "vc_force_restart"
    )

    # Create VC contexts ordered by participant index
    vc_contexts_temp = {}
    for vc_service_name, vc_service in vc_services.items():
        vc_context = vc.get_vc_context(
            plan,
            vc_service_name,
            vc_service,
            vc_service_info[vc_service_name]["client_name"],
        )

        participant_index = vc_service_info[vc_service_name]["participant_index"]
        if vc_context and vc_context.metrics_info:
            vc_context.metrics_info["config"] = args_with_right_defaults.participants[
                participant_index
            ].prometheus_config

        vc_contexts_temp[participant_index] = vc_context

    # Convert to ordered list
    all_vc_contexts = []
    for i in range(len(args_with_right_defaults.participants)):
        if i in vc_contexts_temp:
            all_vc_contexts.append(vc_contexts_temp[i])
        else:
            all_vc_contexts.append(None)

    # Build per-cluster active Vouch service names for certmanager testing
    if certmanager_test_enabled and certmanager_cluster_info:
        cluster_vouch_names = {}
        for vc_service_name in vc_service_info:
            info = vc_service_info[vc_service_name]
            idx = info["participant_index"]
            parsed = args_with_right_defaults.participants[idx]
            if parsed.vc_type != constants.VC_TYPE.vouch:
                continue
            if idx not in participant_cluster_map:
                continue
            # Skip passive HA instances — they don't attest so have no metrics
            if parsed.vouch_multiinstance_attester_delay != "0s":
                continue
            cid = participant_cluster_map[idx]
            if cid not in cluster_vouch_names:
                cluster_vouch_names[cid] = []
            cluster_vouch_names[cid].append(vc_service_name)

        # Rebuild certmanager_cluster_info with active_vouch_service_names
        updated_info = {}
        for cid in certmanager_cluster_info:
            old = certmanager_cluster_info[cid]
            updated_info[cid] = struct(
                dirk_service_names=old.dirk_service_names,
                active_vouch_service_names=cluster_vouch_names.get(cid, []),
                replacement_server_certs=old.replacement_server_certs,
                expired_server_certs=old.expired_server_certs,
                ca_cert_artifact=old.ca_cert_artifact,
                client_cert_artifact=old.client_cert_artifact,
                client_key_artifact=old.client_key_artifact,
            )
        certmanager_cluster_info = updated_info

    all_participants = []
    for index, participant in enumerate(args_with_right_defaults.participants):
        el_type = participant.el_type
        cl_type = participant.cl_type
        vc_type = participant.vc_type
        remote_signer_type = participant.remote_signer_type
        snooper_el_engine_context = None
        snooper_beacon_context = None
        snooper_el_rpc_context = None

        el_context = all_el_contexts[index] if index < len(all_el_contexts) else None
        cl_context = all_cl_contexts[index] if index < len(all_cl_contexts) else None
        vc_context = all_vc_contexts[index] if index < len(all_vc_contexts) else None

        remote_signer_context = (
            all_remote_signer_contexts[index]
            if index < len(all_remote_signer_contexts)
            else None
        )

        if participant.snooper_enabled:
            snooper_el_engine_context = (
                all_snooper_el_engine_contexts[index]
                if index < len(all_snooper_el_engine_contexts)
                else None
            )
            snooper_beacon_context = (
                all_snooper_beacon_contexts[index]
                if index < len(all_snooper_beacon_contexts)
                else None
            )
            snooper_el_rpc_context = (
                all_snooper_el_rpc_contexts[index]
                if index < len(all_snooper_el_rpc_contexts)
                else None
            )

        ethereum_metrics_exporter_context = None

        if participant.ethereum_metrics_exporter_enabled:
            ethereum_metrics_exporter_context = all_ethereum_metrics_exporter_contexts[
                index
            ]
        xatu_sentry_context = None

        if participant.xatu_sentry_enabled and index < len(all_xatu_sentry_contexts):
            xatu_sentry_context = all_xatu_sentry_contexts[index]

        participant_entry = participant_module.new_participant(
            el_type,
            cl_type,
            vc_type,
            remote_signer_type,
            el_context,
            cl_context,
            vc_context,
            remote_signer_context,
            snooper_el_engine_context,
            snooper_beacon_context,
            snooper_el_rpc_context,
            ethereum_metrics_exporter_context,
            xatu_sentry_context,
        )

        all_participants.append(participant_entry)

    return (
        all_participants,
        final_genesis_timestamp,
        el_cl_data.genesis_validators_root,
        el_cl_data.files_artifact_uuid,
        network_id,
        el_cl_data.osaka_time,
        el_cl_data.shadowfork_block_height,
        certmanager_cluster_info,
    )
