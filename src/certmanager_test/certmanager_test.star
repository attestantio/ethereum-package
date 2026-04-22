assertions = import_module("./assertions.star")
reload = import_module("./reload.star")
dirk_launcher = import_module("../dirk/dirk_launcher.star")
vc_shared = import_module("../vc/shared.star")

DIRK_CERTMANAGER_LABELS = [("dirk", "server"), ("dirk", "client")]
# When Tempo runs with plain HTTP, only the Dirk-comms client cert is managed.
# When Tempo mTLS is enabled, Vouch also registers a tracing client cert.
VOUCH_CERTMANAGER_LABELS_PLAIN = [("dirk", "client")]
VOUCH_CERTMANAGER_LABELS_WITH_TRACING = [("dirk", "client"), ("tracing", "client")]


def run_certmanager_tests(
    plan,
    dirk_cluster_info,
    beacon_service_name,
    tempo_query_url=None,
    tempo_mtls_enabled=False,
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
            - active_vouch_service_names: list of active Vouch service names
            - ca_cert_artifact: CA cert file artifact
            - client_cert_artifact: Vouch client cert artifact
            - client_key_artifact: Vouch client key artifact
        beacon_service_name: CL beacon node service name (for finalization wait).
        tempo_query_url: Tempo HTTP query URL (e.g. "http://tempo:3200"), or None.
        tempo_mtls_enabled: When True, Vouch manages an additional tracing
            client cert — expands the expected metric label set to include
            name="tracing" role="client".
    """
    vouch_certmanager_labels = (
        VOUCH_CERTMANAGER_LABELS_WITH_TRACING
        if tempo_mtls_enabled
        else VOUCH_CERTMANAGER_LABELS_PLAIN
    )
    plan.print("========================================")
    plan.print("  go-certmanager Integration Test Suite")
    plan.print("========================================")

    assertions.wait_for_finalization(plan, beacon_service_name)

    for cluster_id, info in dirk_cluster_info.items():
        dirk_service_names = info.dirk_service_names
        vouch_service_names = info.active_vouch_service_names

        plan.print(
            "--- Cluster {0}: Phase A — SAN Identity Verification ---".format(
                cluster_id
            )
        )
        assertions.assert_san_identity(plan, dirk_service_names)
        assertions.assert_no_san_fallback_to_cn(plan, dirk_service_names)
        plan.print("Phase A passed: all Dirk instances using go-certmanager")

        plan.print(
            "--- Cluster {0}: certmanager Metrics Verification ---".format(
                cluster_id
            )
        )
        # Dirk presents its own identity for both inbound (server) and peer
        # outbound (client) — same cert material, two role labels.
        for service_name in dirk_service_names:
            assertions.assert_certmanager_metrics(
                plan,
                service_name,
                dirk_launcher.DIRK_METRICS_PORT_NUM,
                DIRK_CERTMANAGER_LABELS,
                tag="phase-a",
            )
        # Vouch has a Dirk-comms client cert, plus a tracing client cert
        # when Tempo mTLS is enabled.
        for service_name in vouch_service_names:
            assertions.assert_certmanager_metrics(
                plan,
                service_name,
                vc_shared.VALIDATOR_CLIENT_METRICS_PORT_NUM,
                vouch_certmanager_labels,
                tag="phase-a",
            )
        plan.print("certmanager metrics verification passed")

        plan.print(
            "--- Cluster {0}: Attestation & Signing Check ---".format(cluster_id)
        )
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
            ca_cert_artifact=info.ca_cert_artifact,
            client_cert_artifact=info.client_cert_artifact,
            client_key_artifact=info.client_key_artifact,
            tempo_query_url=tempo_query_url,
            tempo_mtls_enabled=tempo_mtls_enabled,
        )

    plan.print("========================================")
    plan.print("  All certmanager tests PASSED")
    plan.print("========================================")
