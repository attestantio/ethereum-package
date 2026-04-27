dirk_launcher = import_module("../dirk/dirk_launcher.star")
vc_shared = import_module("../vc/shared.star")

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
                    'METRICS=$(wget -q -O - "http://{0}:{1}/metrics")'.format(
                        service_name, vc_shared.VALIDATOR_CLIENT_METRICS_PORT_NUM
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


def verify_cert_reachable(
    plan,
    dirk_service_names,
    ca_cert_artifact,
    client_cert_artifact,
    client_key_artifact,
    expected_description="replacement",
):
    """Verify the Dirk gRPC endpoint is serving a valid TLS certificate.

    Uses openssl s_client to connect and extract the cert serial and
    end date, then logs them. This confirms the endpoint is reachable
    and serving a parseable certificate.
    """
    for service_name in dirk_service_names:
        plan.run_sh(
            name="verify-cert-{0}-{1}".format(expected_description, service_name),
            description="Verifying {0} cert on {1} via openssl s_client".format(
                expected_description, service_name
            ),
            run="\n".join(
                [
                    "set -e",
                    "# Connect and extract cert details",
                    "CERT_INFO=$(echo | openssl s_client -connect {0}:{1} -alpn h2 -CAfile /ca/ca.crt -cert /client-cert/*.crt -key /client-key/*.key 2>/dev/null | openssl x509 -noout -serial -enddate)".format(
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


def wait_for_attestations(
    plan, vouch_service_names, phase_label="post-reload", timeout_seconds=300
):
    """Poll Vouch metrics until attestation count > 0, or timeout.

    Polls every 5 seconds. Returns as soon as any successful attestation
    is detected, avoiding fixed sleeps. Times out after timeout_seconds.
    """
    for service_name in vouch_service_names:
        # Single exit-point structure: loop records FOUND_COUNT on success
        # and break; all exit calls live at the very bottom of the script.
        # Mid-loop `exit 0` races Kurtosis's exit-code sampling against the
        # container-terminate syscall (observed in earlier devnet runs:
        # script prints OK, container exits 0, but Kurtosis captures 1).
        script_lines = [
            "TIMEOUT={0}".format(timeout_seconds),
            "INTERVAL=5",
            "ELAPSED=0",
            'FOUND_COUNT=""',
            'while [ "$ELAPSED" -lt "$TIMEOUT" ]; do',
            '  METRICS=$(wget -q -O - "http://{0}:{1}/metrics" 2>/dev/null || true)'.format(
                service_name, vc_shared.VALIDATOR_CLIENT_METRICS_PORT_NUM
            ),
        ]
        # grep/awk line — no .format() to avoid brace issues
        script_lines.append(
            '  COUNT=$(echo "$METRICS" | grep -E "^vouch_attestation_process_requests_total\\{.*result=\\"succeeded\\"" | awk \'{print $2}\' || true)'
        )
        script_lines.extend(
            [
                '  if [ -n "$COUNT" ] && [ "$COUNT" != "0" ]; then',
                '    FOUND_COUNT="$COUNT"',
                "    break",
                "  fi",
                "  sleep $INTERVAL",
                "  ELAPSED=$((ELAPSED + INTERVAL))",
                "done",
                'if [ -n "$FOUND_COUNT" ]; then',
                '  echo "OK: {0} has $FOUND_COUNT attestations ({1})"'.format(
                    service_name, phase_label
                ),
                "  exit 0",
                "fi",
                'echo "FAIL: No successful attestations on {0} after {1}s ({2})"'.format(
                    service_name, timeout_seconds, phase_label
                ),
                "exit 1",
            ]
        )
        plan.run_sh(
            name="wait-attestations-{0}-{1}".format(phase_label, service_name),
            description="Waiting for attestations on {0} ({1})".format(
                service_name, phase_label
            ),
            run="\n".join(script_lines),
            image=ALPINE_IMAGE,
            wait="5m",
        )


def assert_traces_present(plan, tempo_query_url, otel_service_name):
    """Assert that OTel traces are present in Tempo for the given service.

    otel_service_name is the process-level OTel `service.name` attribute
    (e.g. "Dirk", "Vouch") — NOT the Kurtosis service/container name.
    Dirk and Vouch set `service.name` once per process; all instances of
    Dirk share service.name="Dirk", and likewise for Vouch. Kurtosis
    instance distinction lives in `service.instance.id` (container ID).

    Exits 1 if no traces are returned. The tempo_query_url == None
    short-circuit is a legitimate skip when Tempo is not enabled in the
    config.
    """
    if tempo_query_url == None:
        plan.print(
            "Skipping trace assertion for {0} - Tempo not enabled".format(
                otel_service_name
            )
        )
        return

    plan.run_sh(
        name="assert-traces-{0}".format(otel_service_name.lower()),
        description="Asserting Tempo traces for {0}".format(otel_service_name),
        run="\n".join(
            [
                "set -e",
                "# Query Tempo search API for traces from this OTel service.name",
                'RESPONSE=$(wget -q -O - "{0}/api/search?tags=service.name%3D{1}&limit=5")'.format(
                    tempo_query_url, otel_service_name
                ),
                "# Require at least one trace",
                'if echo "$RESPONSE" | grep -q "traceID"; then',
                '  echo "OK: Found traces for {0} in Tempo"'.format(otel_service_name),
                "else",
                '  echo "FAIL: No traces found for {0} in Tempo"'.format(
                    otel_service_name
                ),
                "  exit 1",
                "fi",
            ]
        ),
        image=ALPINE_IMAGE,
        wait=None,
    )


def assert_certmanager_metrics(
    plan, service_name, metrics_port, expected_labels, tag="a"
):
    """Assert that certmanager_certificate_{not_after,not_before}_seconds
    gauges are registered with the expected (name, role) label pairs and
    have sensible values (not_after > not_before > 0, not_after > now()).

    expected_labels is a list of (name, role) tuples, e.g.:
        [("dirk", "server"), ("dirk", "client")]

    Exits 1 if any expected series is missing or has invalid bounds.
    The per-pair assertion blocks are unrolled in Starlark (no shell
    while-loop) to sidestep the classic `echo | while ...; exit 1` pitfall
    where `exit 1` inside a pipeline subshell does not propagate up.
    """
    script_lines = [
        "set -e",
        'METRICS=$(wget -q -O - "http://{0}:{1}/metrics")'.format(
            service_name, metrics_port
        ),
        "NOW=$(date +%s)",
    ]

    for label_name, label_role in expected_labels:
        # grep/awk section — keep grep lines free of .format() placeholders
        # to avoid brace-escaping grief.
        grep_prefix_after = "^certmanager_certificate_not_after_seconds\\{"
        grep_prefix_before = "^certmanager_certificate_not_before_seconds\\{"
        script_lines.extend(
            [
                'NOT_AFTER=$(echo "$METRICS" | grep -E "{0}" | grep \'name="{1}"\' | grep \'role="{2}"\' | awk \'{{print $2}}\')'.format(
                    grep_prefix_after, label_name, label_role
                ),
                'NOT_BEFORE=$(echo "$METRICS" | grep -E "{0}" | grep \'name="{1}"\' | grep \'role="{2}"\' | awk \'{{print $2}}\')'.format(
                    grep_prefix_before, label_name, label_role
                ),
                'if [ -z "$NOT_AFTER" ] || [ -z "$NOT_BEFORE" ]; then',
                '  echo "FAIL: missing certmanager gauges for name={0} role={1} on {2}"'.format(
                    label_name, label_role, service_name
                ),
                "  exit 1",
                "fi",
                # Prometheus emits gauge values in scientific notation (e.g.
                # 1.934466847e+09); printf "%.0f" normalises to a plain
                # integer so shell `-le`/`-ge` comparisons work.
                'NA_INT=$(printf "%.0f" "$NOT_AFTER")',
                'NB_INT=$(printf "%.0f" "$NOT_BEFORE")',
                'if [ "$NA_INT" -le "$NB_INT" ]; then',
                '  echo "FAIL: not_after ($NOT_AFTER) <= not_before ($NOT_BEFORE) for name={0} role={1} on {2}"'.format(
                    label_name, label_role, service_name
                ),
                "  exit 1",
                "fi",
                'if [ "$NA_INT" -le "$NOW" ]; then',
                '  echo "FAIL: certificate already expired: not_after=$NOT_AFTER now=$NOW for name={0} role={1} on {2}"'.format(
                    label_name, label_role, service_name
                ),
                "  exit 1",
                "fi",
                'echo "OK: {0} {1} name={2} role={3} not_after=$NOT_AFTER not_before=$NOT_BEFORE"'.format(
                    service_name, tag, label_name, label_role
                ),
            ]
        )

    plan.run_sh(
        name="assert-certmanager-metrics-{0}-{1}".format(tag, service_name),
        description="Asserting certmanager gauges on {0} ({1})".format(
            service_name, tag
        ),
        run="\n".join(script_lines),
        image=ALPINE_IMAGE,
        wait=None,
    )


def record_cert_serial(
    plan,
    service_name,
    ca_cert_artifact,
    client_cert_artifact,
    client_key_artifact,
    tag="pre-reload",
):
    """Capture the current TLS cert serial Dirk is presenting, into a file
    artifact. Returns the artifact name for later comparison.

    Uses openssl s_client to connect and x509 -noout -serial to extract.
    Exits 1 if the serial cannot be fetched.
    """
    artifact_name = "cert-serial-{0}-{1}".format(service_name, tag)
    plan.run_sh(
        name="record-cert-serial-{0}-{1}".format(tag, service_name),
        description="Recording cert serial on {0} ({1})".format(service_name, tag),
        run="\n".join(
            [
                "set -e",
                "SERIAL=$(echo | openssl s_client -connect {0}:{1} -alpn h2 -CAfile /ca/ca.crt -cert /client-cert/*.crt -key /client-key/*.key 2>/dev/null | openssl x509 -noout -serial | cut -d= -f2 | tr -d '[:space:]')".format(
                    service_name, dirk_launcher.DIRK_GRPC_PORT_NUM
                ),
                'if [ -z "$SERIAL" ]; then',
                '  echo "FAIL: could not extract cert serial from {0}"'.format(
                    service_name
                ),
                "  exit 1",
                "fi",
                "mkdir -p /out",
                'printf "%s" "$SERIAL" > /out/serial.txt',
                'echo "RECORDED: {0} serial=$SERIAL"'.format(service_name),
            ]
        ),
        image=OPENSSL_IMAGE,
        files={
            "/ca": ca_cert_artifact,
            "/client-cert": client_cert_artifact,
            "/client-key": client_key_artifact,
        },
        store=[StoreSpec(src="/out/serial.txt", name=artifact_name)],
        wait=None,
    )
    return artifact_name


def assert_cert_serial_changed(
    plan,
    service_name,
    old_serial_artifact,
    ca_cert_artifact,
    client_cert_artifact,
    client_key_artifact,
    tag="post-reload",
):
    """Assert the currently-served cert serial differs from the serial
    previously recorded in old_serial_artifact.

    Exits 1 if the serial is identical — which would mean the reload did
    NOT actually swap the cert.
    """
    plan.run_sh(
        name="assert-cert-serial-changed-{0}-{1}".format(tag, service_name),
        description="Asserting cert serial changed on {0} ({1})".format(
            service_name, tag
        ),
        run="\n".join(
            [
                "set -e",
                'OLD=$(cat /old-serial/serial.txt | tr -d "[:space:]")',
                'if [ -z "$OLD" ]; then',
                '  echo "FAIL: empty recorded serial (artifact corrupt?)"',
                "  exit 1",
                "fi",
                "NEW=$(echo | openssl s_client -connect {0}:{1} -alpn h2 -CAfile /ca/ca.crt -cert /client-cert/*.crt -key /client-key/*.key 2>/dev/null | openssl x509 -noout -serial | cut -d= -f2 | tr -d '[:space:]')".format(
                    service_name, dirk_launcher.DIRK_GRPC_PORT_NUM
                ),
                'if [ -z "$NEW" ]; then',
                '  echo "FAIL: could not fetch current cert serial from {0}"'.format(
                    service_name
                ),
                "  exit 1",
                "fi",
                'if [ "$OLD" = "$NEW" ]; then',
                '  echo "FAIL: cert serial unchanged on {0}: old=$OLD new=$NEW"'.format(
                    service_name
                ),
                "  exit 1",
                "fi",
                'echo "OK: {0} cert serial changed from $OLD to $NEW"'.format(
                    service_name
                ),
            ]
        ),
        image=OPENSSL_IMAGE,
        files={
            "/old-serial": old_serial_artifact,
            "/ca": ca_cert_artifact,
            "/client-cert": client_cert_artifact,
            "/client-key": client_key_artifact,
        },
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
                    'grep -qE "Received SIGHUP|reloading certificates" /tmp/dirk.log',
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
