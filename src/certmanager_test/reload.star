assertions = import_module("./assertions.star")
dirk_launcher = import_module("../dirk/dirk_launcher.star")

DIRK_CERTMANAGER_LABELS = [("dirk", "server"), ("dirk", "client")]


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

    Phase B: Reload to replacement certs (good certs, verify continuity,
             serial changes, gauges refresh)
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

    # Trace assertions — fail if Tempo is enabled but has no traces.
    # Dirk/Vouch set OTel service.name per process (not per instance), so we
    # assert once per process type rather than per Kurtosis service.
    if tempo_query_url != None:
        plan.print("=== Asserting OTel traces in Tempo ===")
        if len(dirk_service_names) > 0:
            assertions.assert_traces_present(plan, tempo_query_url, "Dirk")
        if len(vouch_service_names) > 0:
            assertions.assert_traces_present(plan, tempo_query_url, "Vouch")


def _phase_b_reload_to_replacement(
    plan,
    dirk_service_names,
    vouch_service_names,
    ca_cert_artifact,
    client_cert_artifact,
    client_key_artifact,
):
    """Phase B: Swap to replacement certs, SIGHUP, verify operations continue.

    Also records pre-reload cert serials per Dirk and asserts they have
    changed after the reload, plus re-asserts the certmanager gauges have
    valid values for the new cert (values should shift to new expiry).
    """
    # 1. Record pre-reload cert serial per Dirk (baseline for comparison).
    pre_reload_serial_artifacts = {}
    for service_name in dirk_service_names:
        pre_reload_serial_artifacts[service_name] = assertions.record_cert_serial(
            plan,
            service_name,
            ca_cert_artifact,
            client_cert_artifact,
            client_key_artifact,
            tag="pre-reload",
        )

    # 2. Copy replacement certs into the live cert directory
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

    # 3. Send SIGHUP to trigger reload (Dirk is PID 1)
    _send_sighup(plan, dirk_service_names)

    # 4. Assert SIGHUP was logged
    assertions.assert_sighup_logged(plan, dirk_service_names)

    # 5. Assert no reload failure
    assertions.assert_no_reload_failure(plan, dirk_service_names)

    # 6. Verify the cert is reachable via openssl s_client
    assertions.verify_cert_reachable(
        plan,
        dirk_service_names,
        ca_cert_artifact,
        client_cert_artifact,
        client_key_artifact,
        expected_description="replacement",
    )

    # 7. Assert the serial changed on each Dirk — proves reload actually
    #    swapped the cert.
    for service_name in dirk_service_names:
        assertions.assert_cert_serial_changed(
            plan,
            service_name,
            pre_reload_serial_artifacts[service_name],
            ca_cert_artifact,
            client_cert_artifact,
            client_key_artifact,
            tag="post-reload",
        )

    # 8. Re-check certmanager gauges — values should reflect the new cert's
    #    expiry. Independent signal that reload took effect.
    for service_name in dirk_service_names:
        assertions.assert_certmanager_metrics(
            plan,
            service_name,
            dirk_launcher.DIRK_METRICS_PORT_NUM,
            DIRK_CERTMANAGER_LABELS,
            tag="post-reload",
        )

    # 9. Wait and verify attestations continue
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
