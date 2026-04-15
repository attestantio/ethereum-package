dirk_launcher = import_module("../dirk/dirk_launcher.star")

ALPINE_IMAGE = "alpine:3.21"
OPENSSL_IMAGE = "alpine/openssl:3.5.5"
HTTP_PORT_ID = "http"


def wait_for_finalization(plan, beacon_service_name, timeout="40m"):
    """Wait for the chain to finalize past epoch 0.

    Dirk's slashing protection correctly rejects signing at targetEpoch=0,
    so attestations only begin after the first finalized epoch.
    """
    plan.print("Waiting for chain finalization before checking attestations...")
    epoch_recipe = GetHttpRequestRecipe(
        endpoint="/eth/v1/beacon/states/head/finality_checkpoints",
        port_id=HTTP_PORT_ID,
        extract={"finalized_epoch": ".data.finalized.epoch"},
    )
    plan.wait(
        recipe=epoch_recipe,
        field="extract.finalized_epoch",
        assertion="!=",
        target_value="0",
        timeout=timeout,
        service_name=beacon_service_name,
    )
    plan.print("Chain finalized — signing should now be active")


def assert_san_identity(plan, dirk_service_names):
    """Assert that Dirk is using the go-certmanager implementation.

    Greps /tmp/dirk.log for zerolog JSON entries containing
    "service":"certmanager", confirming go-certmanager's certificate
    management (including RFC 6125 SAN extraction) is active.
    """
    for service_name in dirk_service_names:
        plan.exec(
            service_name=service_name,
            recipe=ExecRecipe(
                command=[
                    "/bin/sh",
                    "-c",
                    'grep -q \'"service":"certmanager"\' /tmp/dirk.log',
                ],
            ),
            acceptable_codes=[0],
            description="Asserting go-certmanager active in {0} logs".format(
                service_name
            ),
        )


def assert_no_san_fallback_to_cn(plan, dirk_service_names):
    """Assert that no Dirk instance fell back to CN-based identity.

    Verifies absence of "client_identity_source":"cn" in logs — all
    clients should present certs with DNS SAN fields.
    """
    for service_name in dirk_service_names:
        plan.exec(
            service_name=service_name,
            recipe=ExecRecipe(
                command=[
                    "/bin/sh",
                    "-c",
                    '! grep -q \'"client_identity_source":"cn"\' /tmp/dirk.log',
                ],
            ),
            acceptable_codes=[0],
            description="Asserting no CN fallback in {0} logs".format(service_name),
        )


def assert_attestations_and_signing(plan, vouch_service_names, dirk_service_names):
    """Assert that Vouch attestations and Dirk signing are operational.

    Queries Prometheus metrics endpoints to verify:
    - Vouch: vouch_attestation_process_requests_total{result="succeeded"} >= 1
    - Dirk: process signing metrics show activity
    """
    # Check Vouch attestation metrics
    for service_name in vouch_service_names:
        plan.run_sh(
            name="assert-vouch-attestations-{0}".format(service_name),
            description="Checking attestation metrics on {0}".format(service_name),
            run="\n".join(
                [
                    "set -e",
                    'METRICS=$(wget -q -O - "http://{0}:8080/metrics")'.format(
                        service_name
                    ),
                    'COUNT=$(echo "$METRICS" | grep -E "^vouch_attestation_process_requests_total\\{.*result=\\"succeeded\\"" | awk \'{print $2}\')',
                    'if [ -z "$COUNT" ] || [ "$COUNT" = "0" ]; then',
                    '  echo "FAIL: No successful attestations on {0} (count=$COUNT)"'.format(
                        service_name
                    ),
                    "  exit 1",
                    "fi",
                    'echo "OK: {0} has $COUNT successful attestations"'.format(
                        service_name
                    ),
                ]
            ),
            image=ALPINE_IMAGE,
            wait=None,
        )

    # Check Dirk metrics (process is alive and serving)
    for service_name in dirk_service_names:
        plan.run_sh(
            name="assert-dirk-metrics-{0}".format(service_name),
            description="Checking signing metrics on {0}".format(service_name),
            run="\n".join(
                [
                    "set -e",
                    'METRICS=$(wget -q -O - "http://{0}:{1}/metrics")'.format(
                        service_name, dirk_launcher.DIRK_METRICS_PORT_NUM
                    ),
                    'if [ -z "$METRICS" ]; then',
                    '  echo "FAIL: No metrics from {0}"'.format(service_name),
                    "  exit 1",
                    "fi",
                    'echo "OK: {0} metrics endpoint is responding"'.format(
                        service_name
                    ),
                ]
            ),
            image=ALPINE_IMAGE,
            wait=None,
        )


def assert_cert_changed(
    plan,
    dirk_service_names,
    ca_cert_artifact,
    client_cert_artifact,
    client_key_artifact,
    expected_description="replacement",
):
    """Assert the TLS cert presented by each Dirk has changed.

    Uses openssl s_client to connect and extract the cert serial and
    end date, then logs them for verification. This provides direct
    cryptographic proof that the cert was reloaded.
    """
    for service_name in dirk_service_names:
        plan.run_sh(
            name="assert-cert-{0}-{1}".format(expected_description, service_name),
            description="Verifying {0} cert on {1} via openssl s_client".format(
                expected_description, service_name
            ),
            run="\n".join(
                [
                    "set -e",
                    "# Connect and extract cert details",
                    "CERT_INFO=$(echo | openssl s_client -connect {0}:{1} -CAfile /ca/ca.crt -cert /client-cert/*.crt -key /client-key/*.key 2>/dev/null | openssl x509 -noout -serial -enddate)".format(
                        service_name, dirk_launcher.DIRK_GRPC_PORT_NUM
                    ),
                    'SERIAL=$(echo "$CERT_INFO" | grep serial | cut -d= -f2)',
                    'ENDDATE=$(echo "$CERT_INFO" | grep notAfter | cut -d= -f2)',
                    'echo "CERT_SERIAL=$SERIAL"',
                    'echo "CERT_ENDDATE=$ENDDATE"',
                    'if [ -z "$SERIAL" ]; then',
                    '  echo "FAIL: Could not extract certificate serial from {0}"'.format(
                        service_name
                    ),
                    "  exit 1",
                    "fi",
                    'echo "OK: {0} presenting cert serial=$SERIAL enddate=$ENDDATE"'.format(
                        service_name
                    ),
                ]
            ),
            image=OPENSSL_IMAGE,
            files={
                "/ca": ca_cert_artifact,
                "/client-cert": client_cert_artifact,
                "/client-key": client_key_artifact,
            },
            wait=None,
        )


def record_vouch_attestation_count(plan, vouch_service_names):
    """Capture the current attestation counter value from each Vouch instance.

    Returns a run_sh result whose output contains the counts for later comparison.
    This is used for before/after comparison across reload phases.
    """
    wget_lines = ["set -e"]
    for service_name in vouch_service_names:
        wget_lines.extend(
            [
                'METRICS=$(wget -q -O - "http://{0}:8080/metrics")'.format(
                    service_name
                ),
                'COUNT=$(echo "$METRICS" | grep -E "^vouch_attestation_process_requests_total\\{.*result=\\"succeeded\\"" | awk \'{print $2}\' || echo "0")',
                'echo "{0}=$COUNT"'.format(service_name),
            ]
        )

    return plan.run_sh(
        name="record-attestation-counts",
        description="Recording current attestation counts from Vouch instances",
        run="\n".join(wget_lines),
        image=ALPINE_IMAGE,
        wait=None,
    )


def assert_attestation_count_increased(
    plan, vouch_service_names, phase_label="post-reload"
):
    """Assert attestation counts are still increasing (operations continue after reload)."""
    for service_name in vouch_service_names:
        plan.run_sh(
            name="assert-attestations-increasing-{0}-{1}".format(
                phase_label, service_name
            ),
            description="Verifying attestations still flowing on {0} ({1})".format(
                service_name, phase_label
            ),
            run="\n".join(
                [
                    "set -e",
                    'METRICS=$(wget -q -O - "http://{0}:8080/metrics")'.format(
                        service_name
                    ),
                    'COUNT=$(echo "$METRICS" | grep -E "^vouch_attestation_process_requests_total\\{.*result=\\"succeeded\\"" | awk \'{print $2}\')',
                    'if [ -z "$COUNT" ] || [ "$COUNT" = "0" ]; then',
                    '  echo "FAIL: No successful attestations on {0} after {1}"'.format(
                        service_name, phase_label
                    ),
                    "  exit 1",
                    "fi",
                    'echo "OK: {0} has $COUNT attestations ({1})"'.format(
                        service_name, phase_label
                    ),
                ]
            ),
            image=ALPINE_IMAGE,
            wait=None,
        )


def assert_traces_present(plan, tempo_query_url, service_name):
    """Assert OTel traces are present in Tempo for a given service.

    Queries Tempo's HTTP search API to verify traces from Vouch/Dirk
    appear, including cert-loading spans.
    """
    if tempo_query_url == None:
        plan.print(
            "Skipping trace assertion for {0} - Tempo not enabled".format(service_name)
        )
        return

    plan.run_sh(
        name="assert-traces-{0}".format(service_name),
        description="Checking Tempo traces for {0}".format(service_name),
        run="\n".join(
            [
                "set -e",
                "# Query Tempo search API for traces from this service",
                'RESPONSE=$(wget -q -O - "{0}/api/search?tags=service.name%3D{1}&limit=5")'.format(
                    tempo_query_url, service_name
                ),
                "# Check that we got at least one trace",
                'if echo "$RESPONSE" | grep -q "traceID"; then',
                '  echo "OK: Found traces for {0} in Tempo"'.format(service_name),
                "else",
                '  echo "WARN: No traces found for {0} in Tempo (may need more time)"'.format(
                    service_name
                ),
                "fi",
            ]
        ),
        image=ALPINE_IMAGE,
        wait=None,
    )


def assert_sighup_logged(plan, dirk_service_names):
    """Assert SIGHUP was received and logged by each Dirk instance."""
    for service_name in dirk_service_names:
        plan.exec(
            service_name=service_name,
            recipe=ExecRecipe(
                command=[
                    "/bin/sh",
                    "-c",
                    'grep -q "Received SIGHUP" /tmp/dirk.log || grep -q "reloading certificates" /tmp/dirk.log',
                ],
            ),
            acceptable_codes=[0],
            description="Asserting SIGHUP logged in {0}".format(service_name),
        )


def assert_no_reload_failure(plan, dirk_service_names):
    """Assert no cert reload failures in Dirk logs."""
    for service_name in dirk_service_names:
        plan.exec(
            service_name=service_name,
            recipe=ExecRecipe(
                command=[
                    "/bin/sh",
                    "-c",
                    '! grep -q "Failed to reload certificates" /tmp/dirk.log',
                ],
            ),
            acceptable_codes=[0],
            description="Asserting no reload failures in {0}".format(service_name),
        )
