assertions = import_module("./assertions.star")


def execute_reload_test(
    plan,
    dirk_service_names,
    vouch_service_names,
    ca_cert_artifact,
    client_cert_artifact,
    client_key_artifact,
    tempo_query_url=None,
):
    """Execute the full SIGHUP certificate reload test cycle.

    Phase B: Reload to replacement certs (good certs, verify continuity)
    Phase C: Reload to expired certs (error scenario)
    Phase D: Recovery back to good replacement certs
    """
    plan.print("=== Phase B: Reload to replacement certificates ===")
    _phase_b_reload_to_replacement(
        plan,
        dirk_service_names,
        vouch_service_names,
        ca_cert_artifact,
        client_cert_artifact,
        client_key_artifact,
    )

    plan.print("=== Phase C: Reload to expired certificates (error test) ===")
    _phase_c_reload_to_expired(
        plan,
        dirk_service_names,
        ca_cert_artifact,
        client_cert_artifact,
        client_key_artifact,
    )

    plan.print("=== Phase D: Recovery — reload back to good certificates ===")
    _phase_d_recovery(
        plan,
        dirk_service_names,
        vouch_service_names,
        ca_cert_artifact,
        client_cert_artifact,
        client_key_artifact,
    )

    # Trace assertions (non-blocking — traces may take time to propagate)
    if tempo_query_url != None:
        plan.print("=== Checking OTel traces in Tempo ===")
        for service_name in dirk_service_names:
            assertions.check_traces_present(plan, tempo_query_url, service_name)
        for service_name in vouch_service_names:
            assertions.check_traces_present(plan, tempo_query_url, service_name)


def _phase_b_reload_to_replacement(
    plan,
    dirk_service_names,
    vouch_service_names,
    ca_cert_artifact,
    client_cert_artifact,
    client_key_artifact,
):
    """Phase B: Swap to replacement certs, SIGHUP, verify operations continue."""
    # 1. Copy replacement certs into the live cert directory
    for service_name in dirk_service_names:
        plan.exec(
            service_name=service_name,
            recipe=ExecRecipe(
                command=[
                    "/bin/sh",
                    "-c",
                    "cp /certs-replacement/server.crt /certs/server.crt && cp /certs-replacement/server.key /certs/server.key",
                ],
            ),
            acceptable_codes=[0],
            description="Copying replacement certs to {0}".format(service_name),
        )

    # 2. Send SIGHUP to trigger reload (Dirk is PID 1)
    _send_sighup(plan, dirk_service_names)

    # 3. Assert SIGHUP was logged
    assertions.assert_sighup_logged(plan, dirk_service_names)

    # 4. Assert no reload failure
    assertions.assert_no_reload_failure(plan, dirk_service_names)

    # 5. Verify the cert is reachable via openssl s_client
    assertions.verify_cert_reachable(
        plan,
        dirk_service_names,
        ca_cert_artifact,
        client_cert_artifact,
        client_key_artifact,
        expected_description="replacement",
    )

    # 6. Wait and verify attestations continue
    assertions.wait_for_attestations(
        plan,
        vouch_service_names,
        phase_label="phase-b-replacement",
    )


def _phase_c_reload_to_expired(
    plan,
    dirk_service_names,
    ca_cert_artifact,
    client_cert_artifact,
    client_key_artifact,
):
    """Phase C: Swap to expired certs, SIGHUP, verify Dirk rejects them and continues serving previous good cert."""
    # 1. Copy expired certs
    for service_name in dirk_service_names:
        plan.exec(
            service_name=service_name,
            recipe=ExecRecipe(
                command=[
                    "/bin/sh",
                    "-c",
                    "cp /certs-expired/server.crt /certs/server.crt && cp /certs-expired/server.key /certs/server.key",
                ],
            ),
            acceptable_codes=[0],
            description="Copying expired certs to {0}".format(service_name),
        )

    # 2. Send SIGHUP
    _send_sighup(plan, dirk_service_names)

    # 3. Assert SIGHUP was logged (Dirk loads whatever is on disk)
    assertions.assert_sighup_logged(plan, dirk_service_names)

    # 4. Assert Dirk rejected the expired cert
    for dirk_service_name in dirk_service_names:
        plan.exec(
            service_name=dirk_service_name,
            recipe=ExecRecipe(
                command=[
                    "/bin/sh",
                    "-c",
                    'grep -q "Failed to reload certificates" /tmp/dirk.log',
                ],
            ),
            acceptable_codes=[0],
            description="Asserting expired cert rejection in {0}".format(
                dirk_service_name
            ),
        )

    # 5. Verify Dirk still serves the previous good cert (not the expired one)
    assertions.verify_cert_reachable(
        plan,
        dirk_service_names,
        ca_cert_artifact,
        client_cert_artifact,
        client_key_artifact,
        expected_description="post-expired-still-valid",
    )


def _phase_d_recovery(
    plan,
    dirk_service_names,
    vouch_service_names,
    ca_cert_artifact,
    client_cert_artifact,
    client_key_artifact,
):
    """Phase D: Recover from expired certs by loading good replacements again."""
    # 1. Copy replacement certs back
    for service_name in dirk_service_names:
        plan.exec(
            service_name=service_name,
            recipe=ExecRecipe(
                command=[
                    "/bin/sh",
                    "-c",
                    "cp /certs-replacement/server.crt /certs/server.crt && cp /certs-replacement/server.key /certs/server.key",
                ],
            ),
            acceptable_codes=[0],
            description="Restoring good certs to {0}".format(service_name),
        )

    # 2. SIGHUP to reload
    _send_sighup(plan, dirk_service_names)

    # 3. Verify good cert is loaded
    assertions.verify_cert_reachable(
        plan,
        dirk_service_names,
        ca_cert_artifact,
        client_cert_artifact,
        client_key_artifact,
        expected_description="recovered",
    )

    # 4. Wait and verify attestations resume
    assertions.wait_for_attestations(
        plan,
        vouch_service_names,
        phase_label="phase-d-recovery",
    )


def _send_sighup(plan, dirk_service_names):
    """Send SIGHUP to each Dirk instance (Dirk is PID 1)."""
    for service_name in dirk_service_names:
        plan.exec(
            service_name=service_name,
            recipe=ExecRecipe(
                command=["/bin/sh", "-c", "kill -HUP 1"],
            ),
            acceptable_codes=[0],
            description="Sending SIGHUP to {0}".format(service_name),
        )
