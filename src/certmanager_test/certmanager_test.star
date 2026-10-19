assertions = import_module("./assertions.star")


def run_certmanager_tests(
    plan,
    dirk_cluster_info,
    tempo_query_url=None,
    tempo_mtls_enabled=False,
):
    """Run after the chain has finalized."""
    for cluster_id, info in dirk_cluster_info.items():
        plan.print("Checking certmanager cluster {0}".format(cluster_id))
        assertions.assert_san(plan, info.dirk_service_names, info.vouch_certs_artifact)
        # Released Dirk exports no certmanager gauges yet; check Dirk's once it does.
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
    # Dirk does not trace in Tempo mTLS mode.
    if not tempo_mtls_enabled:
        assertions.assert_traces(plan, tempo_query_url, "Dirk")
    assertions.assert_traces(plan, tempo_query_url, "Vouch")
