shared_utils = import_module("../shared_utils/shared_utils.star")
constants = import_module("../package_io/constants.star")

_SAFE_FILENAME_CHARS = (
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
)


def validate_binary_filename(filename):
    """Validate that a binary filename contains only safe characters for shell interpolation."""
    for c in filename.elems():
        if c not in _SAFE_FILENAME_CHARS:
            fail(
                (
                    "vc_binary_artifact filename '{0}' contains unsafe character '{1}'. "
                    + "Only alphanumeric, dots, dashes, and underscores are allowed."
                ).format(filename, c)
            )


VALIDATOR_HTTP_PORT_NUM = 5056
VALIDATOR_CLIENT_METRICS_PORT_NUM = 8080
METRICS_PATH = "/metrics"

VALIDATOR_CLIENT_USED_PORTS = {
    constants.METRICS_PORT_ID: shared_utils.new_port_spec(
        VALIDATOR_CLIENT_METRICS_PORT_NUM,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    ),
}

VALIDATOR_KEYMANAGER_USED_PORTS = {
    constants.VALIDATOR_HTTP_PORT_ID: shared_utils.new_port_spec(
        VALIDATOR_HTTP_PORT_NUM,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    )
}
