dirk_launcher = import_module("../dirk/dirk_launcher.star")
vc_shared = import_module("../vc/vc_shared.star")

DIRK_LABELS = [("dirk", "server"), ("dirk", "client")]
VOUCH_LABELS = [("dirk", "client")]
VOUCH_MTLS_LABELS = [("dirk", "client"), ("tracing", "client")]
OPENSSL_IMAGE = "alpine/openssl:3.5.5@sha256:7a1465c710d66ef753236a2d96c9c41f1fb0453862e5794640d6065aa1853087"
ALPINE_IMAGE = "alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d"


def wait_for_finalization(plan, beacon_service_name):
    plan.wait(
        recipe=GetHttpRequestRecipe(
            endpoint="/eth/v1/beacon/states/head/finality_checkpoints",
            port_id="http",
            extract={"finalized_epoch": ".data.finalized.epoch"},
        ),
        field="extract.finalized_epoch",
        assertion="!=",
        target_value="0",
        timeout="40m",
        service_name=beacon_service_name,
    )


def assert_san(
    plan, service_names, ca_artifact, client_cert_artifact, client_key_artifact
):
    for service_name in service_names:
        plan.run_sh(
            name="certmanager-san-{0}".format(service_name),
            description="Checking exact SAN identity for {0}".format(service_name),
            image=OPENSSL_IMAGE,
            files={
                "/ca": ca_artifact,
                "/client-cert": client_cert_artifact,
                "/client-key": client_key_artifact,
            },
            run="\n".join(
                [
                    "set -e",
                    "echo | openssl s_client -connect {0}:{1} -servername {0} -alpn h2 -CAfile /ca/ca.crt -cert /client-cert/* -key /client-key/* 2>/dev/null | openssl x509 -out /tmp/server.crt".format(
                        service_name, dirk_launcher.DIRK_GRPC_PORT_NUM
                    ),
                    "openssl verify -CAfile /ca/ca.crt -purpose sslserver -verify_hostname {0} /tmp/server.crt".format(
                        service_name
                    ),
                    "openssl x509 -in /tmp/server.crt -noout -checkend 0",
                    "openssl x509 -in /tmp/server.crt -noout -ext subjectAltName | grep -Eq 'DNS:{0}([,[:space:]]|$)'".format(
                        service_name
                    ),
                ]
            ),
            wait=None,
        )


def assert_metrics(plan, service_name, port, labels):
    lines = [
        "set -e",
        'METRICS=$(wget -q -O - "http://{0}:{1}/metrics")'.format(service_name, port),
        "NOW=$(date +%s)",
    ]
    for name, role in labels:
        lines.extend(
            [
                "AFTER=$(echo \"$METRICS\" | grep -E '^certmanager_certificate_not_after_seconds\\{{' | grep 'name=\"{0}\"' | grep 'role=\"{1}\"' | awk '{{print $2}}')".format(
                    name, role
                ),
                "BEFORE=$(echo \"$METRICS\" | grep -E '^certmanager_certificate_not_before_seconds\\{{' | grep 'name=\"{0}\"' | grep 'role=\"{1}\"' | awk '{{print $2}}')".format(
                    name, role
                ),
                'test -n "$AFTER" && test -n "$BEFORE"',
                'awk -v before="$BEFORE" -v now="$NOW" -v after="$AFTER" \'BEGIN { exit !(before < now && now < after) }\'',
            ]
        )
    plan.run_sh(
        name="certmanager-metrics-{0}".format(service_name),
        description="Checking certmanager validity gauges on {0}".format(service_name),
        image=ALPINE_IMAGE,
        run="\n".join(lines),
        wait=None,
    )


def assert_signing(plan, vouch_service_names, dirk_service_names):
    for service_name in vouch_service_names:
        plan.run_sh(
            name="certmanager-vouch-signing-{0}".format(service_name),
            description="Checking successful Vouch signing requests on {0}".format(
                service_name
            ),
            image=ALPINE_IMAGE,
            run="set -e\nMETRICS=$(wget -q -O - http://{0}:{1}/metrics)\nCOUNT=$(echo \"$METRICS\" | grep '^vouch_attestation_process_requests_total' | grep 'result=\"succeeded\"' | awk '{{sum += $2}} END {{print sum+0}}')\nawk \"BEGIN {{ exit !($COUNT > 0) }}\"".format(
                service_name, vc_shared.VALIDATOR_CLIENT_METRICS_PORT_NUM
            ),
            wait=None,
        )
    for service_name in dirk_service_names:
        plan.run_sh(
            name="certmanager-dirk-signing-{0}".format(service_name),
            description="Checking Dirk signing metrics on {0}".format(service_name),
            image=ALPINE_IMAGE,
            run="set -e\nMETRICS=$(wget -q -O - http://{0}:{1}/metrics)\necho \"$METRICS\" | grep -E '^dirk_.*(sign|request)' | grep -v ' 0$'".format(
                service_name, dirk_launcher.DIRK_METRICS_PORT_NUM
            ),
            wait=None,
        )


def assert_traces(plan, tempo_query_url, service_name):
    if tempo_query_url == None:
        return
    plan.run_sh(
        name="certmanager-traces-{0}".format(service_name.lower()),
        description="Checking {0} traces in Tempo".format(service_name),
        image=ALPINE_IMAGE,
        run="set -e\nRESPONSE=$(wget -q -O - '{0}/api/search?tags=service.name%3D{1}&limit=5')\necho \"$RESPONSE\" | grep -q 'traceID'".format(
            tempo_query_url, service_name
        ),
        wait=None,
    )
