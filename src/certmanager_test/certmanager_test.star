assertions = import_module("./assertions.star")
reload = import_module("./reload.star")


def run_certmanager_tests(
    plan,
    dirk_cluster_info,
    vouch_service_names,
    beacon_service_name,
    tempo_query_url=None,
):
    """Run the full go-certmanager integration test suite.

    Orchestrates three sequential test phases:
    1. SAN identity verification — confirm Dirk uses go-certmanager
    2. Attestation & signing — confirm Vouch/Dirk are operational
    3. SIGHUP certificate reload — swap/reload/expired/recovery cycle

    Args:
        plan: The Kurtosis plan.
        dirk_cluster_info: Dict of cluster_id -> struct with:
            - dirk_service_names: list of Dirk service names
            - replacement_server_certs: dict of service_name -> artifact
            - expired_server_certs: dict of service_name -> artifact
            - ca_cert_artifact: CA cert file artifact
            - client_cert_artifact: Vouch client cert artifact
            - client_key_artifact: Vouch client key artifact
        vouch_service_names: List of Vouch service names.
        beacon_service_name: CL beacon node service name (for finalization wait).
        tempo_query_url: Tempo HTTP query URL (e.g. "http://tempo:3200"), or None.
    """
    plan.print("========================================")
    plan.print("  go-certmanager Integration Test Suite")
    plan.print("========================================")

    for cluster_id, info in dirk_cluster_info.items():
        dirk_service_names = info.dirk_service_names

        plan.print(
            "--- Cluster {0}: Phase A — SAN Identity Verification ---".format(
                cluster_id
            )
        )
        assertions.assert_san_identity(plan, dirk_service_names)
        assertions.assert_no_san_fallback_to_cn(plan, dirk_service_names)
        plan.print("Phase A passed: all Dirk instances using go-certmanager")

        plan.print(
            "--- Cluster {0}: Attestation & Signing Check ---".format(cluster_id)
        )
        assertions.wait_for_finalization(plan, beacon_service_name)
        assertions.assert_attestations_and_signing(
            plan, vouch_service_names, dirk_service_names
        )
        plan.print("Attestation check passed: Vouch and Dirk are operational")

        plan.print(
            "--- Cluster {0}: SIGHUP Certificate Reload Test ---".format(cluster_id)
        )
        reload.execute_reload_test(
            plan,
            dirk_service_names=dirk_service_names,
            vouch_service_names=vouch_service_names,
            replacement_server_certs=info.replacement_server_certs,
            expired_server_certs=info.expired_server_certs,
            ca_cert_artifact=info.ca_cert_artifact,
            client_cert_artifact=info.client_cert_artifact,
            client_key_artifact=info.client_key_artifact,
            tempo_query_url=tempo_query_url,
        )

    plan.print("========================================")
    plan.print("  All certmanager tests PASSED")
    plan.print("========================================")
