constants = import_module("./constants.star")

# Cluster ID of the single cluster an active Vouch creates without dirk_cluster_id.
DEFAULT_CLUSTER_ID = ""
CLUSTER_ID_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789"


def plan_clusters(participants):
    """Validate Vouch participants and plan the Dirk clusters they need.

    Each active Vouch (validator_count > 0) creates one cluster holding
    validator_count accounts, numbered after the previous cluster's. A passive
    Vouch (validator_count == 0) joins an existing cluster by dirk_cluster_id
    and serves all of its accounts.

    Returns a struct with:
      clusters: cluster structs in creation order (id, peer_count, threshold,
        image, validator_count, account_start)
      cluster_ids: {participant index: cluster id} for every Vouch participant
    """
    clusters = []
    clusters_by_id = {}
    cluster_ids = {}
    implicit_active = 0
    next_account = 0

    for index, participant in enumerate(participants):
        if participant.vc_type != constants.VC_TYPE.vouch:
            continue
        if participant.validator_count == 0:
            continue
        cluster_id = participant.dirk_cluster_id
        if cluster_id == None:
            cluster_id = DEFAULT_CLUSTER_ID
            implicit_active += 1
        else:
            _check_cluster_id(cluster_id)
            if cluster_id in clusters_by_id:
                fail(
                    "dirk_cluster_id '{0}' already defined by another active Vouch participant".format(
                        cluster_id
                    )
                )
        if participant.dirk_peer_count < 1:
            fail(
                "dirk_peer_count must be at least 1, got {0}".format(
                    participant.dirk_peer_count
                )
            )
        if (
            participant.dirk_signing_threshold < 1
            or participant.dirk_signing_threshold > participant.dirk_peer_count
        ):
            fail(
                "dirk_signing_threshold ({0}) must be between 1 and dirk_peer_count ({1})".format(
                    participant.dirk_signing_threshold, participant.dirk_peer_count
                )
            )
        cluster = struct(
            id=cluster_id,
            peer_count=participant.dirk_peer_count,
            threshold=participant.dirk_signing_threshold,
            image=participant.dirk_image,
            validator_count=participant.validator_count,
            account_start=next_account,
        )
        clusters.append(cluster)
        clusters_by_id[cluster_id] = cluster
        cluster_ids[index] = cluster_id
        next_account += participant.validator_count

    if implicit_active > 0 and len(clusters) != 1:
        fail(
            "Every active Vouch needs a dirk_cluster_id when more than one active Vouch exists"
        )

    for index, participant in enumerate(participants):
        if participant.vc_type != constants.VC_TYPE.vouch:
            continue
        if participant.validator_count != 0:
            continue
        cluster_id = participant.dirk_cluster_id
        if cluster_id == None:
            fail("Passive Vouch requires an explicit dirk_cluster_id")
        _check_cluster_id(cluster_id)
        if cluster_id not in clusters_by_id:
            fail(
                "Vouch participant #{0} references missing dirk_cluster_id '{1}'".format(
                    index + 1, cluster_id
                )
            )
        cluster_ids[index] = cluster_id

    # Instances sharing a cluster sign the same accounts, so multi-instance
    # arbitration must decide which one signs.
    for i, first in cluster_ids.items():
        for j, second in cluster_ids.items():
            if i >= j or first != second:
                continue
            for k in (i, j):
                if participants[k].vouch_multiinstance_style != "static-delay":
                    fail(
                        "Vouch participants #{0} and #{1} share Dirk cluster '{2}', so both need vouch_multiinstance_style: static-delay".format(
                            i + 1, j + 1, first
                        )
                    )

    return struct(clusters=clusters, cluster_ids=cluster_ids)


def cluster_prefix(cluster_id):
    """Service and artifact prefix: dirk-<id>, or dirk for the default cluster."""
    return "dirk-{0}".format(cluster_id) if cluster_id != DEFAULT_CLUSTER_ID else "dirk"


def artifact_suffix(cluster_id):
    """Suffix for per-cluster run_sh names: -<id>, or nothing for the default cluster."""
    return "-{0}".format(cluster_id) if cluster_id != DEFAULT_CLUSTER_ID else ""


def _check_cluster_id(cluster_id):
    if len(cluster_id) != 1 or cluster_id not in CLUSTER_ID_CHARS:
        fail(
            "dirk_cluster_id must be one lowercase alphanumeric character, got '{0}'".format(
                cluster_id
            )
        )
