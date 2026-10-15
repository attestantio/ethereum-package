def new_dirk_context(endpoints, vouch_certs_artifact, accounts):
    return struct(
        endpoints=endpoints,
        vouch_certs_artifact=vouch_certs_artifact,
        accounts=accounts,
    )
