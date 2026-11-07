# Vouch strategy settings: the package defaults, a participant's overrides and the YAML
# Vouch reads. Starlark has no recursion or while loops, so nested values use a worklist.

# Sections Vouch reads under `strategies:`. `submitter` sits beside `strategies:` instead.
# shortcut: copied from Vouch 1.14.0-alpha.2, add a name here when Vouch gains a strategy.
STRATEGY_NAMES = [
    "aggregateattestation",
    "attestationdata",
    "attestationpool",
    "beaconblockheader",
    "beaconblockproposal",
    "beaconblockroot",
    "blindedbeaconblockproposal",
    "builderbid",
    "payloadattestationdata",
    "signedbeaconblock",
    "synccommitteecontribution",
]
SUBMITTER = "submitter"

# Settings Vouch reads as durations. It reads a bare number as nanoseconds.
DURATION_KEYS = ["timeout", "deadline", "bid-gap"]
KEY_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"

# Entries visited per merge or render, so an oversized input fails instead of looping.
MAX_ENTRIES = 500


def validate(overrides):
    if type(overrides) != "dict":
        fail("vouch_strategies must map a strategy name to its settings")
    for name, settings in overrides.items():
        if name != SUBMITTER and name not in STRATEGY_NAMES:
            fail(
                "vouch_strategies has unknown strategy '{0}'; expected one of {1}".format(
                    name, ", ".join(STRATEGY_NAMES + [SUBMITTER])
                )
            )
        if type(settings) != "dict":
            fail("vouch_strategies.{0} must map settings to values".format(name))

    # shortcut: Vouch reads only combinedmajority.threshold for this style and defaults it to 0
    # (attestantio/vouch#463). Vouch's fix (#480) only warns about a threshold of 0 or 1 and keeps
    # 0 as the default. Remove once every Vouch image the package targets rejects a missing or
    # zero threshold for this style.
    attestationdata = overrides.get("attestationdata", {})
    combined = attestationdata.get("combinedmajority", {})
    threshold = combined.get("threshold") if type(combined) == "dict" else None
    if attestationdata.get("style") == "combinedmajority" and (
        type(threshold) != "int" or threshold < 1
    ):
        fail(
            "vouch_strategies.attestationdata.combinedmajority.threshold must be 1 or more with style combinedmajority: Vouch ignores majority.threshold for it, and a missing or zero threshold applies no minimum (attestantio/vouch#463)"
        )

    # Fail now, not when the launch reaches Vouch.
    render(beacon_nodes=1, package_strategies=True, overrides=overrides)


# The package strategies when package_strategies is set, with the overrides merged over them.
def render(beacon_nodes, package_strategies, overrides):
    config = {}
    if package_strategies:
        # Vouch refuses a threshold above its beacon node count.
        threshold = min(2, beacon_nodes)
        config = {
            "strategies": {
                "aggregateattestation": {"style": "best"},
                "attestationdata": {
                    "style": "majority",
                    "majority": {"threshold": threshold},
                    "timeout": "2s",
                },
                "beaconblockheader": {"style": "first"},
                "beaconblockproposal": {"style": "best", "timeout": "1.5s"},
                "beaconblockroot": {"style": "majority"},
                "signedbeaconblock": {"style": "first"},
                "synccommitteecontribution": {"style": "best", "timeout": "1s"},
            },
            "submitter": {"style": "multinode"},
        }
    named = {
        name: settings for name, settings in overrides.items() if name != SUBMITTER
    }
    if named:
        config["strategies"] = _merge(config.get("strategies", {}), named, "strategies")
    if overrides.get(SUBMITTER):
        config[SUBMITTER] = _merge(
            config.get(SUBMITTER, {}), overrides[SUBMITTER], SUBMITTER
        )
    return _yaml(config)


# Merges source into target in place and returns it. Mappings merge key by key; any other value
# replaces. A mapping and a single value never replace each other: a stray `majority: 2` would
# otherwise delete the package's threshold.
def _merge(target, source, path):
    pending = [(target, source, path)]
    for _ in range(MAX_ENTRIES):
        if not pending:
            break
        into, values, where = pending.pop()
        for key, value in values.items():
            here = "{0}.{1}".format(where, key)
            current = into.get(key)
            if current != None and (type(current) == "dict") != (type(value) == "dict"):
                fail(
                    "vouch_strategies: {0} must be {1}".format(
                        here,
                        "a mapping of settings"
                        if type(current) == "dict"
                        else "a single value",
                    )
                )
            if type(current) == "dict":
                pending.append((current, value, here))
            else:
                into[key] = value
    if pending:
        fail(_too_big())
    return target


# Block-style YAML for nested mappings of scalars and lists.
def _yaml(config):
    lines = []
    pending = [(0, key, config[key], key) for key in reversed(config.keys())]
    for _ in range(MAX_ENTRIES):
        if not pending:
            break
        depth, key, value, path = pending.pop()
        if (
            type(key) != "string"
            or not key
            or [c for c in key.elems() if c not in KEY_CHARS]
        ):
            fail(
                "vouch_strategies: key {0} under {1} may only use letters, digits, - and _".format(
                    repr(key), path.rsplit(".", 1)[0]
                )
            )
        indent = "  " * depth
        if type(value) != "dict":
            lines.append("{0}{1}: {2}".format(indent, key, _value(path, key, value)))
        elif not value:
            lines.append("{0}{1}: {{}}".format(indent, key))
        else:
            lines.append("{0}{1}:".format(indent, key))
            for child in reversed(value.keys()):
                pending.append(
                    (depth + 1, child, value[child], "{0}.{1}".format(path, child))
                )
    if pending:
        fail(_too_big())
    return "".join([line + "\n" for line in lines])


def _too_big():
    return (
        "vouch_strategies has more than {0} settings or nests them too deeply".format(
            MAX_ENTRIES
        )
    )


def _value(path, key, value):
    if type(value) == "list":
        return "[{0}]".format(", ".join([_scalar(path, key, item) for item in value]))
    return _scalar(path, key, value)


def _scalar(path, key, value):
    kind = type(value)
    if key in DURATION_KEYS and (kind != "string" or not value or value[-1:].isdigit()):
        fail(
            "vouch_strategies: {0} needs a unit, for example 2s or 1800ms".format(path)
        )
    if kind == "string":
        if [c for c in value.elems() if ord(c) < 32]:
            fail("vouch_strategies: {0} cannot contain control characters".format(path))
        return "'{0}'".format(value.replace("'", "''"))
    if kind == "bool":
        return "true" if value else "false"
    if kind == "int" or kind == "float":
        return str(value)
    fail(
        "vouch_strategies: {0} must be a string, number, boolean or list of those, got {1}".format(
            path, kind
        )
    )
