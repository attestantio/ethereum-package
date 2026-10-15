constants = import_module("./constants.star")

# Cluster ID of the single cluster an active Vouch creates without dirk_cluster_id.
DEFAULT_CLUSTER_ID = ""
CLUSTER_ID_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789"


def plan_clusters(participants):
    """Validate Vouch participants and plan the Dirk clusters they need.

    Each active Vouch (validator_count > 0) creates one cluster holding
    validator_count accounts, numbered after the previous cluster's. A passive
    Vouch (validator_count == 0) joins an existing cluster with an explicit
    account range.

    Returns a struct with:
      clusters: cluster structs in creation order (id, peer_count, threshold,
        image, validator_count, account_start)
      cluster_ids: {participant index: cluster id} for every Vouch participant
      account_ranges: {participant index: struct(start, count)}
    """
    clusters = []
    clusters_by_id = {}
    cluster_ids = {}
    account_ranges = {}
    implicit_active = 0
    next_account = 0

    for index, participant in enumerate(participants):
        if participant.vc_type != constants.VC_TYPE.vouch:
            continue
        if participant.validator_count == 0:
            continue
        if (
            participant.vouch_account_start != None
            or participant.vouch_account_count != None
        ):
            fail(
                "Vouch participant #{0}: vouch_account_start and vouch_account_count apply to passive Vouch (validator_count: 0) only".format(
                    index + 1
                )
            )
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
        account_ranges[index] = struct(
            start=next_account, count=participant.validator_count
        )
        next_account += participant.validator_count

    if implicit_active > 0 and len(clusters) != 1:
        fail("Multiple active Vouch creators without dirk_cluster_id are not supported")

    for index, participant in enumerate(participants):
        if participant.vc_type != constants.VC_TYPE.vouch:
            continue
        if participant.validator_count != 0:
            continue
        cluster_id = participant.dirk_cluster_id
        if cluster_id == None or cluster_id == DEFAULT_CLUSTER_ID:
            fail("Passive Vouch requires an explicit dirk_cluster_id")
        _check_cluster_id(cluster_id)
        if cluster_id not in clusters_by_id:
            fail(
                "Vouch participant #{0} references missing dirk_cluster_id '{1}'".format(
                    index + 1, cluster_id
                )
            )
        cluster = clusters_by_id[cluster_id]
        start = participant.vouch_account_start
        count = participant.vouch_account_count
        if (
            start < cluster.account_start
            or start + count > cluster.account_start + cluster.validator_count
        ):
            fail(
                "Vouch participant #{0}: account range [{1},{2}) is outside cluster '{3}' bounds [{4},{5})".format(
                    index + 1,
                    start,
                    start + count,
                    cluster_id,
                    cluster.account_start,
                    cluster.account_start + cluster.validator_count,
                )
            )
        cluster_ids[index] = cluster_id
        account_ranges[index] = struct(start=start, count=count)

    # Instances may share accounts only as identical static-delay ranges, so
    # multi-instance arbitration decides which one signs.
    for i, first in account_ranges.items():
        for j, second in account_ranges.items():
            if i >= j or cluster_ids[i] != cluster_ids[j]:
                continue
            if (
                first.start < second.start + second.count
                and second.start < first.start + first.count
            ) and (
                first.start != second.start
                or first.count != second.count
                or participants[i].vouch_multiinstance_style != "static-delay"
                or participants[j].vouch_multiinstance_style != "static-delay"
            ):
                fail(
                    "Vouch participants #{0} and #{1} have an invalid overlapping account range".format(
                        i + 1, j + 1
                    )
                )

    return struct(
        clusters=clusters,
        cluster_ids=cluster_ids,
        account_ranges=account_ranges,
    )


def _check_cluster_id(cluster_id):
    if len(cluster_id) != 1 or cluster_id not in CLUSTER_ID_CHARS:
        fail(
            "dirk_cluster_id must be one lowercase alphanumeric character, got '{0}'".format(
                cluster_id
            )
        )
