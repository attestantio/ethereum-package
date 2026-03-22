def new_dirk_context(
    endpoints,
    ca_cert_artifact,
    client_cert_artifact,
    client_key_artifact,
    wallet_name="DistributedWallet",
    threshold=2,
    peer_count=3,
):
    return struct(
        endpoints=endpoints,
        ca_cert_artifact=ca_cert_artifact,
        client_cert_artifact=client_cert_artifact,
        client_key_artifact=client_key_artifact,
        wallet_name=wallet_name,
        threshold=threshold,
        peer_count=peer_count,
    )
