# Tests for src/vc/vouch_strategies.star. The runner appends this file to the module.
# Run from this directory: go run . ../../../src/vc/vouch_strategies.star vouch_strategies_test.star

DEFAULTS = """strategies:
  aggregateattestation:
    style: 'best'
  attestationdata:
    style: 'majority'
    majority:
      threshold: 2
    timeout: '2s'
  beaconblockheader:
    style: 'first'
  beaconblockproposal:
    style: 'best'
    timeout: '1.5s'
  beaconblockroot:
    style: 'majority'
  signedbeaconblock:
    style: 'first'
  synccommitteecontribution:
    style: 'best'
    timeout: '1s'
submitter:
  style: 'multinode'
"""


def eq(name, got, want):
    if got != want:
        fail("{0}\n--- got\n{1}\n--- want\n{2}".format(name, got, want))


def has(name, got, want):
    if want not in got:
        fail("{0}: {1!r} not in {2!r}".format(name, want, got))


def render_with(overrides, nodes=2, package=True):
    return render(beacon_nodes=nodes, package_strategies=package, overrides=overrides)


def yaml_of(text):
    return json.decode(yaml_to_json(text))


def test_defaults():
    eq("defaults", render_with({}), DEFAULTS)
    eq(
        "threshold follows the node count",
        render_with({}, nodes=1),
        DEFAULTS.replace("threshold: 2", "threshold: 1"),
    )
    eq("threshold stops at 2", render_with({}, nodes=5), DEFAULTS)
    # The block Vouch's YAML parser reads, with the dropped duties key absent.
    parsed = yaml_of(render_with({}))
    eq(
        "parsed threshold",
        parsed["strategies"]["attestationdata"]["majority"]["threshold"],
        2,
    )
    eq("parsed submitter", parsed["submitter"], {"style": "multinode"})
    eq("no duties", "duties" in parsed["strategies"], False)


def test_package_strategies_off():
    # Nothing to render, so the fixtures that turn the package strategies off keep their config.
    eq("off", render_with({}, package=False), "")
    eq("off, empty submitter", render_with({"submitter": {}}, package=False), "")
    eq(
        "off, empty settings",
        render_with({"attestationdata": {}}, package=False),
        "strategies:\n  attestationdata: {}\n",
    )
    # Overrides alone: strategies first, then submitter.
    eq(
        "off + overrides",
        render_with(
            {
                "submitter": {"style": "immediate"},
                "attestationdata": {"style": "first"},
            },
            package=False,
        ),
        "strategies:\n  attestationdata:\n    style: 'first'\nsubmitter:\n  style: 'immediate'\n",
    )


def test_merge():
    eq(
        "empty settings keep the defaults",
        render_with({"attestationdata": {}}),
        DEFAULTS,
    )
    eq(
        "a leaf changes and its siblings stay",
        render_with({"beaconblockproposal": {"timeout": "1800ms"}}),
        DEFAULTS.replace("timeout: '1.5s'", "timeout: '1800ms'"),
    )
    eq(
        "submitter merges at the top level",
        render_with({"submitter": {"style": "immediate"}}),
        DEFAULTS.replace("'multinode'", "'immediate'"),
    )

    # A new style leaves the stale majority block, which Vouch ignores, and appends its own.
    combined = render_with(
        {
            "attestationdata": {
                "style": "combinedmajority",
                "combinedmajority": {"threshold": 2},
            }
        }
    )
    eq(
        "combinedmajority",
        combined,
        DEFAULTS.replace(
            "    style: 'majority'\n    majority:\n      threshold: 2\n    timeout: '2s'\n",
            "    style: 'combinedmajority'\n    majority:\n      threshold: 2\n    timeout: '2s'\n    combinedmajority:\n      threshold: 2\n",
        ),
    )
    eq(
        "combinedmajority parses",
        yaml_of(combined)["strategies"]["attestationdata"]["combinedmajority"],
        {"threshold": 2},
    )

    # The input as Kurtosis delivers it, with sorted keys: the vouch.yml of the 2026-11-06 Gloas run.
    gloas = render_with(
        {
            "attestationdata": {
                "combinedmajority": {"threshold": 2},
                "style": "combinedmajority",
            },
            "payloadattestationdata": {
                "majority": {"threshold": 1},
                "style": "majority",
            },
        }
    )
    eq(
        "gloas",
        gloas,
        DEFAULTS.replace(
            "    style: 'majority'\n    majority:\n      threshold: 2\n    timeout: '2s'\n",
            "    style: 'combinedmajority'\n    majority:\n      threshold: 2\n    timeout: '2s'\n    combinedmajority:\n      threshold: 2\n",
        ).replace(
            "submitter:",
            "  payloadattestationdata:\n    majority:\n      threshold: 1\n    style: 'majority'\nsubmitter:",
        ),
    )

    # Three levels deep, and the caller's settings are left alone.
    deep = {
        "builderbid": {
            "deadline": {"bid-gap": "100ms", "deadline": "1s"},
            "style": "deadline",
        }
    }
    eq(
        "deep",
        yaml_of(render_with(deep))["strategies"]["builderbid"],
        {"deadline": {"bid-gap": "100ms", "deadline": "1s"}, "style": "deadline"},
    )
    user = {"attestationdata": {"style": "first"}}
    render_with(user)
    eq("caller untouched", user, {"attestationdata": {"style": "first"}})


def test_scalars():
    text = render_with(
        {
            "builderbid": {
                "count": 3,
                "ratio": 0.5,
                "enabled": True,
                "disabled": False,
                "addrs": ["a:1", "it's"],
                "none": [],
            }
        },
        package=False,
    )
    eq(
        "types",
        text,
        "strategies:\n  builderbid:\n    count: 3\n    ratio: 0.5\n    enabled: true\n    disabled: false\n    addrs: ['a:1', 'it''s']\n    none: []\n",
    )
    eq(
        "types parse",
        yaml_of(text)["strategies"]["builderbid"]["addrs"],
        ["a:1", "it's"],
    )
    eq("uppercase key", try_call(validate, {"attestationdata": {"Style": "first"}}), "")


def test_names():
    eq(
        "known",
        try_call(validate, {"attestationdata": {"style": "first"}, "submitter": {}}),
        "",
    )
    for name in STRATEGY_NAMES:
        eq("name " + name, try_call(validate, {name: {}}), "")
    has(
        "unknown",
        try_call(validate, {"attestationdta": {}}),
        "unknown strategy 'attestationdta'; expected one of aggregateattestation, attestationdata",
    )
    has(
        "duties is not a strategy",
        try_call(validate, {"duties": {"style": "first"}}),
        "unknown strategy 'duties'",
    )
    has(
        "not a map",
        try_call(validate, "first"),
        "must map a strategy name to its settings",
    )
    has("none", try_call(validate, None), "must map a strategy name to its settings")
    has(
        "settings not a map",
        try_call(validate, {"attestationdata": "first"}),
        "vouch_strategies.attestationdata must map settings to values",
    )


def test_combinedmajority_threshold():
    want = "combinedmajority.threshold must be 1 or more"
    for combinedmajority in [
        {},
        {"threshold": 0},
        {"threshold": False},
        {"threshold": 1.5},
        2,
        None,
    ]:
        has(
            "threshold " + repr(combinedmajority),
            try_call(
                validate,
                {
                    "attestationdata": {
                        "style": "combinedmajority",
                        "combinedmajority": combinedmajority,
                    }
                },
            ),
            want,
        )
    has(
        "majority threshold does not count",
        try_call(
            validate,
            {
                "attestationdata": {
                    "style": "combinedmajority",
                    "majority": {"threshold": 2},
                }
            },
        ),
        want,
    )
    eq(
        "threshold 1",
        try_call(
            validate,
            {
                "attestationdata": {
                    "style": "combinedmajority",
                    "combinedmajority": {"threshold": 1},
                }
            },
        ),
        "",
    )
    eq(
        "other styles",
        try_call(validate, {"attestationdata": {"style": "majority"}}),
        "",
    )


def test_shapes():
    # A scalar must not replace the package's mapping: majority: 2 would delete its threshold.
    has(
        "scalar over mapping",
        try_call(validate, {"attestationdata": {"majority": 2}}),
        "vouch_strategies: strategies.attestationdata.majority must be a mapping of settings",
    )
    has(
        "mapping over scalar",
        try_call(validate, {"attestationdata": {"style": {"a": 1}}}),
        "vouch_strategies: strategies.attestationdata.style must be a single value",
    )
    has(
        "submitter path",
        try_call(validate, {"submitter": {"style": {"a": 1}}}),
        "vouch_strategies: submitter.style must be a single value",
    )


def test_values():
    # Vouch reads a bare number as nanoseconds, so durations need a unit.
    for timeout in [1800, 2.5, "1800", "", True]:
        has(
            "duration " + repr(timeout),
            try_call(validate, {"beaconblockproposal": {"timeout": timeout}}),
            "strategies.beaconblockproposal.timeout needs a unit",
        )
    for timeout in ["1800ms", "2s", "1.5s", "0s"]:
        eq(
            "duration " + timeout,
            try_call(validate, {"beaconblockproposal": {"timeout": timeout}}),
            "",
        )
    eq(
        "builderbid durations",
        try_call(
            validate,
            {"builderbid": {"deadline": {"bid-gap": "100ms", "deadline": "1s"}}},
        ),
        "",
    )
    has(
        "bid gap",
        try_call(validate, {"builderbid": {"deadline": {"bid-gap": 100}}}),
        "strategies.builderbid.deadline.bid-gap needs a unit",
    )

    has(
        "none value",
        try_call(validate, {"attestationdata": {"style": None}}),
        "strategies.attestationdata.style must be a string, number, boolean or list of those, got NoneType",
    )
    has(
        "nested path",
        try_call(validate, {"attestationdata": {"x": {"y": None}}}),
        "strategies.attestationdata.x.y must be a string",
    )
    has(
        "nested list", try_call(validate, {"attestationdata": {"x": [[1]]}}), "got list"
    )
    for control in ["a\nb", "a\rb", "a\tb", "a\x00b"]:
        has(
            "control " + repr(control),
            try_call(validate, {"attestationdata": {"x": control}}),
            "strategies.attestationdata.x cannot contain control characters",
        )

    for key in ["a b", "stylé", "a:b", "a.b", ""]:
        has(
            "key " + repr(key),
            try_call(validate, {"attestationdata": {key: "first"}}),
            "may only use letters, digits, - and _",
        )
    has(
        "int key",
        try_call(validate, {"attestationdata": {1: "first"}}),
        "key 1 under strategies.attestationdata",
    )


def test_limits():
    deep = {"x": "ok"}
    for _ in range(10):
        deep = {"k": deep}
    eq("deep", try_call(validate, {"builderbid": deep}), "")
    too_deep = {"x": "ok"}
    for _ in range(600):
        too_deep = {"k": too_deep}
    has(
        "too deep",
        try_call(validate, {"builderbid": too_deep}),
        "more than 500 settings or nests them too deeply",
    )
    wide = {"key{0}".format(i): "ok" for i in range(600)}
    has(
        "too wide",
        try_call(validate, {"builderbid": wide}),
        "more than 500 settings or nests them too deeply",
    )


test_defaults()
test_package_strategies_off()
test_merge()
test_scalars()
test_names()
test_combinedmajority_threshold()
test_shapes()
test_values()
test_limits()
