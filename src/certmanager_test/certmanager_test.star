assertions = import_module("./assertions.star")


def run_certmanager_tests(
    plan,
    dirk_cluster_info,
    beacon_service_name,
    tempo_query_url=None,
    tempo_mtls_enabled=False,
):
    assertions.wait_for_finalization(plan, beacon_service_name)
    for cluster_id, info in dirk_cluster_info.items():
        plan.print("Checking certmanager cluster {0}".format(cluster_id))
        assertions.assert_san(
            plan,
            info.dirk_service_names,
            info.ca_cert_artifact,
            info.client_cert_artifact,
            info.client_key_artifact,
        )
        for service_name in info.dirk_service_names:
            assertions.assert_metrics(
                plan,
                service_name,
                info.dirk_metrics_port,
                assertions.DIRK_LABELS,
            )
        labels = (
            assertions.VOUCH_MTLS_LABELS
            if tempo_mtls_enabled
            else assertions.VOUCH_LABELS
        )
        for service_name in info.vouch_service_names:
            assertions.assert_metrics(
                plan, service_name, info.vouch_metrics_port, labels
            )
        assertions.assert_signing(
            plan, info.active_vouch_service_names, info.dirk_service_names
        )
    assertions.assert_traces(plan, tempo_query_url, "Dirk")
    assertions.assert_traces(plan, tempo_query_url, "Vouch")
