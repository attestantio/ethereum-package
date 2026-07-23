constants = import_module("../package_io/constants.star")


def run_dkg_ceremony(
    plan,
    dirk_service_names,
    ethdo_certs,
    validator_count,
    signing_threshold,
    peer_count,
    wallet_name="DistributedWallet",
    account_start=0,
    cluster_id="",
):
    """Run the DKG ceremony to create distributed validator accounts.

    DKG creates new distributed keys. The composite public keys are then
    extracted and passed to the genesis generator via CL_ADDITIONAL_VALIDATORS
    so these validators are included in genesis state.

    Args:
        plan: The Kurtosis plan.
        dirk_service_names: List of Dirk service names.
        ethdo_certs: File artifact from prepare_ethdo_certs() — bundles
            ca.crt, ethdo.crt, ethdo.key.
        validator_count: Number of validator accounts to create.
        signing_threshold: Signing threshold for the distributed keys.
        peer_count: Total number of Dirk peers (participants).
        wallet_name: Name of the distributed wallet.
        account_start: Starting account index for DKG accounts.
        cluster_id: Optional cluster identifier for unique step names.

    Returns:
        A struct with validator_count and wallet_name for downstream use.
    """
    suffix = "-{0}".format(cluster_id) if cluster_id else ""

    first_dirk_service = dirk_service_names[0]
    account_end = account_start + validator_count - 1

    script_lines = [
        "set -e",
        "",
        'echo "Starting DKG ceremony: creating {0} distributed validator account(s) (indices {1}-{2})"'.format(
            validator_count, account_start, account_end
        ),
        'echo "  Remote: {0}:8881"'.format(first_dirk_service),
        'echo "  Threshold: {0}/{1}"'.format(signing_threshold, peer_count),
        "",
        "for i in $(seq {0} {1}); do".format(account_start, account_end),
        '  echo "Creating account {0}/$i ..."'.format(wallet_name),
        "  /app/ethdo account create \\",
        "    --remote={0}:8881 \\".format(first_dirk_service),
        "    --server-ca-cert=/certs/ca.crt \\",
        "    --client-cert=/certs/ethdo.crt \\",
        "    --client-key=/certs/ethdo.key \\",
        "    --account={0}/$i \\".format(wallet_name),
        "    --signing-threshold={0} \\".format(signing_threshold),
        "    --participants={0} \\".format(peer_count),
        # NOTE: Hardcoded passphrase — acceptable for ephemeral devnets only.
        '    --passphrase=secret --allow-weak-passphrases || {{ echo "ERROR: failed to create account {0}/$i"; exit 1; }}'.format(
            wallet_name
        ),
        '  echo "Successfully created account {0}/$i"'.format(wallet_name),
        "done",
        "",
        'echo "DKG ceremony completed successfully: {0} account(s) created"'.format(
            validator_count
        ),
    ]

    plan.run_sh(
        name="dkg-ceremony{0}".format(suffix),
        description="Running DKG ceremony to create {0} distributed validator account(s){1}".format(
            validator_count,
            " for cluster {0}".format(cluster_id) if cluster_id else "",
        ),
        run="\n".join(script_lines),
        image=constants.DEFAULT_ETHDO_IMAGE,
        files={
            "/certs": ethdo_certs,
        },
        wait="600s",
    )

    return struct(
        validator_count=validator_count,
        wallet_name=wallet_name,
    )


def extract_dkg_validators_file(
    plan,
    dirk_service_names,
    ethdo_certs,
    validator_count,
    wallet_name="DistributedWallet",
    account_start=0,
    cluster_id="",
):
    """Extract composite public keys from DKG accounts and create a validators file.

    The validators file has the format expected by ethereum-genesis-generator's
    --additional-validators / CL_ADDITIONAL_VALIDATORS env var:
        # <validator pubkey>:<withdrawal credentials>:<balance>
        0x<pubkey>:0x01<withdrawal_address>:32000000000

    Args:
        plan: The Kurtosis plan.
        dirk_service_names: List of Dirk service names.
        ethdo_certs: File artifact from prepare_ethdo_certs() — bundles
            ca.crt, ethdo.crt, ethdo.key.
        validator_count: Number of validator accounts created by DKG.
        wallet_name: Name of the distributed wallet.
        account_start: Starting account index for DKG accounts.
        cluster_id: Optional cluster identifier for unique step/artifact names.

    Returns:
        A file artifact containing validators.txt.
    """
    suffix = "-{0}".format(cluster_id) if cluster_id else ""

    first_dirk_service = dirk_service_names[0]
    account_end = account_start + validator_count - 1

    # Build withdrawal credentials from the withdrawal address
    # Format: 0x01 + 11 bytes of zeros + 20 byte address (without 0x prefix)
    withdrawal_address = constants.VALIDATING_REWARDS_ACCOUNT
    # Strip 0x prefix if present for the padding
    addr_hex = withdrawal_address
    if len(addr_hex) > 2 and addr_hex[0:2] == "0x":
        addr_hex = addr_hex[2:]

    withdrawal_credentials = "0x010000000000000000000000" + addr_hex

    script_lines = [
        "set -e",
        "",
        'echo "Extracting composite public keys from {0} DKG accounts (indices {1}-{2})"'.format(
            validator_count, account_start, account_end
        ),
        "",
        "OUTFILE=/out/validators.txt",
        "mkdir -p /out",
        'echo "# DKG validator pubkeys for genesis" > $OUTFILE',
        "",
        "for i in $(seq {0} {1}); do".format(account_start, account_end),
        '  echo "Getting account info for {0}/$i ..."'.format(wallet_name),
        "  INFO=$(/app/ethdo account info \\",
        "    --remote={0}:8881 \\".format(first_dirk_service),
        "    --server-ca-cert=/certs/ca.crt \\",
        "    --client-cert=/certs/ethdo.crt \\",
        "    --client-key=/certs/ethdo.key \\",
        "    --account={0}/$i \\".format(wallet_name),
        '    --verbose 2>&1) || { echo "ERROR: failed to get info for account $i"; echo "$INFO"; exit 1; }',
        "",
        "  # Try composite public key first (distributed accounts), fall back to public key",
        '  PUBKEY=$(echo "$INFO" | grep "Composite public key:" | sed "s/Composite public key: //")',
        '  if [ -z "$PUBKEY" ]; then',
        '    PUBKEY=$(echo "$INFO" | grep "Public key:" | sed "s/Public key: //")',
        "  fi",
        "",
        '  if [ -z "$PUBKEY" ]; then',
        '    echo "ERROR: Could not extract public key for account $i"',
        '    echo "Account info output:"',
        '    echo "$INFO"',
        "    exit 1",
        "  fi",
        "",
        '  echo "$PUBKEY:{0}:32000000000" >> $OUTFILE'.format(withdrawal_credentials),
        '  echo "  Account $i: $PUBKEY"',
        "done",
        "",
        'echo "Successfully extracted {0} public key(s)"'.format(validator_count),
        'echo "Validators file:"',
        "cat $OUTFILE",
    ]

    result = plan.run_sh(
        name="extract-dkg-validators{0}".format(suffix),
        description="Extracting {0} DKG composite public keys for genesis{1}".format(
            validator_count,
            " (cluster {0})".format(cluster_id) if cluster_id else "",
        ),
        run="\n".join(script_lines),
        image=constants.DEFAULT_ETHDO_IMAGE,
        files={
            "/certs": ethdo_certs,
        },
        store=[
            StoreSpec(src="/out/", name="dkg-validators-file{0}".format(suffix)),
        ],
        wait="600s",
    )

    return result.files_artifacts[0]


def prepare_ethdo_certs(plan, cert_result, cluster_id=""):
    """Assemble ethdo client certs and CA cert into a single directory artifact.

    Args:
        plan: The Kurtosis plan.
        cert_result: Return value from certs.generate_certs().
        cluster_id: Optional cluster identifier for unique step/artifact names.

    Returns a file artifact containing ca.crt, ethdo.crt, and ethdo.key.
    """
    suffix = "-{0}".format(cluster_id) if cluster_id else ""
    result = plan.run_sh(
        name="prepare-ethdo-certs{0}".format(suffix),
        description="Preparing ethdo client certificates{0}".format(
            " for cluster {0}".format(cluster_id) if cluster_id else ""
        ),
        run="\n".join(
            [
                "set -e",
                "mkdir -p /out",
                "cp /ca-cert/ca.crt /out/ca.crt",
                "cp /ethdo-cert/ethdo-client.crt /out/ethdo.crt",
                "cp /ethdo-key/ethdo-client.key /out/ethdo.key",
            ]
        ),
        image="alpine:3.21",
        files={
            "/ca-cert": cert_result.ca_cert,
            "/ethdo-cert": cert_result.ethdo_client_cert,
            "/ethdo-key": cert_result.ethdo_client_key,
        },
        store=[StoreSpec(src="/out/", name="ethdo-dkg-certs{0}".format(suffix))],
        wait=None,
    )

    return result.files_artifacts[0]
