#!/usr/bin/env bash
# Chain health for one Kurtosis enclave, independent of task-specific API compatibility.
# Check progress, roots and finality; a running container or is_syncing=false is insufficient.
# Report a diverged node separately from the health of the reference chain.
#
# Usage: ./devnet-health.sh <enclave>

set -uo pipefail
if [[ $# != 1 || -z "$1" ]]; then
  echo "usage: $0 <enclave>" >&2
  exit 64
fi
ENCLAVE="$1"
FAIL=0        # the canonical chain itself is broken -> devnet unusable
DIVERGED=0    # canonical chain fine, but some node is not on it
DIVERGED_NAMES=""

note() { printf '%s\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
# A minority client off the canonical chain is a real cross-client finding, but it does NOT make
# the devnet unusable while the canonical chain still finalizes — the weighted config deliberately
# keeps >2/3 of stake on the reference client so that stays true. Track it separately, and never
# let it reach bad().
diverge() {
  printf '  \033[35mDIVERGED\033[0m %s\n' "$*"; DIVERGED=1
}
# Record a diverged node once, however many checks notice it.
mark_diverged() {
  case " $DIVERGED_NAMES " in *" $1 "*) return ;; esac
  DIVERGED_NAMES="$DIVERGED_NAMES $1"
}

inspect="$(kurtosis enclave inspect "$ENCLAVE" 2>/dev/null)" || {
  bad "enclave '$ENCLAVE' not found"; exit 1; }

# Discover service names rather than hardcoding client pairs — the topology changes when
# the participant list changes (e.g. swapping the mixed lighthouse/prysm config for the
# homogeneous prysm one renames cl-1-lighthouse-geth to cl-1-prysm-nethermind).
mapfile -t CLS < <(grep -oE '\bcl-[0-9]+-[a-z0-9-]+' <<<"$inspect" | sort -u)
mapfile -t ELS < <(grep -oE '\bel-[0-9]+-[a-z0-9-]+' <<<"$inspect" | sort -u)
(( ${#CLS[@]} )) || { bad "no cl-* services found in enclave '$ENCLAVE'"; exit 1; }

# `kurtosis port print` returns exactly one port. Do NOT parse the inspect table for this:
# the metrics row's value is itself an http:// URL, so a /http:/ match silently returns the
# metrics port instead of the beacon API port.
port_of() { kurtosis port print "$ENCLAVE" "$1" "$2" 2>/dev/null | grep -oE '[0-9]+$'; }

declare -a CL_NAME CL_PORT EL_NAME EL_PORT
for s in "${CLS[@]}"; do
  p="$(port_of "$s" http)"
  [[ -n "$p" ]] && { CL_NAME+=("$s"); CL_PORT+=("$p"); }
done
for s in "${ELS[@]}"; do
  p="$(port_of "$s" rpc)"
  [[ -n "$p" ]] && { EL_NAME+=("$s"); EL_PORT+=("$p"); }
done
(( ${#CL_PORT[@]} )) || { bad "no CL beacon-API ports resolved"; exit 1; }

# cl-3-prysm-geth and el-3-geth-prysm are the same participant. The leading index is the only
# stable link between them, so the EL comparison below can be scoped to the canonical cohort.
node_idx() { local s="${1#*-}"; printf '%s' "${s%%-*}"; }

bget() { curl -s -m 10 "http://127.0.0.1:$1$2"; }

# Walk a JSON object by successive keys from argv. No eval, so a response body can never
# become executable code.  e.g.  jqf data finalized root
jqf() {
  python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d[k]
print(d)
' "$@" 2>/dev/null
}

note "enclave $ENCLAVE"
for i in "${!CL_NAME[@]}"; do note "  CL ${CL_NAME[$i]} -> :${CL_PORT[$i]}"; done
for i in "${!EL_NAME[@]}"; do note "  EL ${EL_NAME[$i]} -> :${EL_PORT[$i]}"; done

boot="${CL_PORT[0]}"
genesis="$(bget "$boot" /eth/v1/beacon/genesis | jqf data genesis_time)"
spec="$(bget "$boot" /eth/v1/config/spec)"
sps="$(jqf data SECONDS_PER_SLOT <<<"$spec")"
spe="$(jqf data SLOTS_PER_EPOCH <<<"$spec")"
if [[ -z "$genesis" || -z "$sps" || -z "$spe" ]]; then
  bad "could not read genesis/spec from ${CL_NAME[0]} — is the node up?"; exit 1
fi
expected_slot=$(( ($(date +%s) - genesis) / sps ))
note "genesis=$genesis seconds_per_slot=$sps slots_per_epoch=$spe expected_slot=$expected_slot"

# ---------------------------------------------------------------------------------------------
# Gather raw per-node facts. NOTHING is ruled on here: a node's peer count and head slot only
# become PASS/FAIL/DIVERGED once we know whether that node is on the canonical chain, and that is
# not known until the block-root majority below.
# ---------------------------------------------------------------------------------------------
declare -a PEERS HEADS
for i in "${!CL_NAME[@]}"; do
  PEERS[$i]="$(bget "${CL_PORT[$i]}" /eth/v1/node/peer_count | jqf data connected)"
  HEADS[$i]="$(bget "${CL_PORT[$i]}" /eth/v1/node/syncing | jqf data head_slot)"
done

# The MEDIAN head, not the minimum. The minimum is whatever the most broken node reports, so a
# single frozen bystander used to drag every derived epoch back with it (on 2026-07-30: median
# 13874, minimum 4290, i.e. epoch 1734 vs 536). A median survives any minority of stalled nodes,
# which is the same >2/3-of-stake assumption the rest of this script already rests on.
mapfile -t _sorted < <(for h in "${HEADS[@]}"; do printf '%s\n' "${h:-0}"; done | sort -n)
med_head="${_sorted[$(( ${#_sorted[@]} / 2 ))]}"
: "${med_head:=0}"

note ""
note "canonical chain"
# The check a finalized-root comparison cannot make early on: do all clients agree on the block
# root at a slot they have all already passed? Divergence here is a fork, full stop, and it is
# visible from epoch 1 rather than only once something finalizes.
#
# The reference is chosen by MAJORITY, not by taking CL[0] on faith. That distinction is
# load-bearing: on 2026-07-29 cl-1 was the node that forked off with 1 peer, so a CL[0]-based
# reference reported the broken minority's view (just=0) while the other four were healthily
# justifying (just=2) — inverting the verdict AND printing an HTTP_ADDRESS pointing at the one
# node you must not test against.
declare -a CANON R
for i in "${!CL_NAME[@]}"; do CANON[$i]=0; R[$i]=""; done
cs=0
if (( med_head > 6 )); then
  # Probe backwards from the median head for a slot a majority of nodes actually have a block
  # for; missed slots are common here and comparing roots on an empty slot tells you nothing.
  # Roots are kept from the probe itself so the winning slot is not fetched twice.
  for back in 4 5 6 7 8 9 10 11 12; do
    try=$(( med_head - back )); (( try < 1 )) && continue
    have=0
    for i in "${!CL_NAME[@]}"; do
      R[$i]="$(bget "${CL_PORT[$i]}" "/eth/v1/beacon/blocks/$try/root" | jqf data root)"
      [[ -n "${R[$i]}" ]] && have=$((have+1))
    done
    if (( have * 2 > ${#CL_NAME[@]} )); then cs=$try; break; fi
  done
fi

if (( cs > 0 )); then
  # Most-common root wins; that is the canonical chain.
  best_root=""; best_n=0
  for i in "${!CL_NAME[@]}"; do
    [[ -z "${R[$i]}" ]] && continue
    n=0
    for j in "${!CL_NAME[@]}"; do [[ -n "${R[$j]}" && "${R[$j]}" == "${R[$i]}" ]] && n=$((n+1)); done
    if (( n > best_n )); then best_n=$n; best_root="${R[$i]}"; fi
  done
  for i in "${!CL_NAME[@]}"; do
    [[ -n "${R[$i]}" && "${R[$i]}" == "$best_root" ]] && CANON[$i]=1
  done
  note "  slot $cs root ${best_root:0:18} — ${best_n}/${#CL_NAME[@]} nodes agree"
else
  # Root comparison unavailable (chain too young, or the median-head neighbourhood is all missed
  # slots). Fall back to head proximity: a node within tolerance of the median is following the
  # same chain closely enough to be judged as part of it. This fallback matters — it is the path
  # the 2026-07-30 run actually took, and without it a stalled bystander goes back to voting.
  warn "no slot near the median head has a block on a majority — grouping by head proximity instead"
  for i in "${!CL_NAME[@]}"; do
    h="${HEADS[$i]:-0}"
    d=$(( med_head - h )); (( d < 0 )) && d=$(( -d ))
    (( d <= 100 )) && CANON[$i]=1
  done
fi

# Prefer a canonical node that still has peers: that is the one the suite can safely point at.
# A canonical node with 0 peers is on the right chain but about to go stale silently.
#
# Among equally-canonical, equally-peered nodes, prefer PRYSM — the reference client. This is not
# cosmetic: the ePBS routes the http/ suite exercises are not implemented by every client.
# Measured 2026-07-31 at epoch 1, same enclave, same fork:
#     cl-2-prysm   v2 proposer duties 200   ptc duties 200   payload_attestations pool 400
#     cl-1-nimbus  v2 proposer duties 404   ptc duties 404   payload_attestations pool 404
# (400 = route exists and rejected the request; bare 404 = no route at all.) Picking CL[0] made
# nimbus the reference once nimbus moved into participant 1 as the low-stake bootnode,
# which both printed an HTTP_ADDRESS missing the endpoints under test and made this script's own
# duty checks report "route absent on this build" for a perfectly healthy Gloas chain.
REF_IDX=-1
for want_prysm in 1 0; do
  for i in "${!CL_NAME[@]}"; do
    (( CANON[$i] )) || continue
    [[ -n "${PEERS[$i]}" ]] && (( ${PEERS[$i]} > 0 )) || continue
    if (( want_prysm )); then [[ "${CL_NAME[$i]}" == *prysm* ]] || continue; fi
    REF_IDX=$i; break
  done
  (( REF_IDX >= 0 )) && break
done
if (( REF_IDX < 0 )); then
  for i in "${!CL_NAME[@]}"; do (( CANON[$i] )) && { REF_IDX=$i; break; }; done
fi
if (( REF_IDX < 0 )); then
  bad "no node is on a canonical chain — the enclave has no usable majority"
  REF_IDX=0
fi
ref="${CL_PORT[$REF_IDX]}"
REF_NAME="${CL_NAME[$REF_IDX]}"
ref_head="${HEADS[$REF_IDX]:-0}"
head_ep=$(( ref_head / spe ))
note "  reference = $REF_NAME (head=$ref_head, epoch=$head_ep)"

# ---------------------------------------------------------------------------------------------
# Now, and only now, rule on each node. Nodes off the canonical chain get diverge() and never
# bad(): the chain carries on without them (the config caps every node at <=1/3 of stake, so
# losing one cannot stop finality). Only the canonical cohort — and above all the reference, the
# node HTTP_ADDRESS points at — can declare the devnet unusable.
# ---------------------------------------------------------------------------------------------
note ""
note "per-node status (tolerance 8 slots behind wall clock)"
for i in "${!CL_NAME[@]}"; do
  n="${CL_NAME[$i]}"; p="${PEERS[$i]}"; h="${HEADS[$i]}"
  is_ref=0; (( i == REF_IDX )) && is_ref=1

  if [[ -z "$p" && -z "$h" ]]; then
    if (( is_ref )); then bad "$n: no response from beacon API (and it is the reference)"
    else diverge "$n: no response from beacon API"; mark_diverged "$n"; fi
    continue
  fi

  if (( ! CANON[$i] )); then
    diverge "$n: not on the canonical chain (head=${h:-?}, ${p:-?} peer(s))"
    mark_diverged "$n"
    continue
  fi

  # Canonical cohort from here down.
  if [[ -z "$p" ]] || (( p < 1 )); then
    if (( is_ref )); then bad "$n: 0 connected peers, and it is the reference — unusable as a test target"
    else warn "$n: on the canonical chain but 0 connected peers — it will go stale"; fi
  fi
  if [[ -z "$h" ]]; then
    if (( is_ref )); then bad "$n: no head slot"; else warn "$n: no head slot"; fi
    continue
  fi
  gap=$(( expected_slot - h )); (( gap < 0 )) && gap=0
  if   (( gap > 100 )); then
    if (( is_ref )); then bad "$n: head=$h, $gap slots behind wall clock — stalled (reference)"
    else warn "$n: head=$h, $gap slots behind wall clock — stalled, but not the reference"; fi
  elif (( gap > 8 )); then warn "$n: head=$h, $gap slots behind wall clock"
  else ok "$n: head=$h ($gap behind wall clock), ${p:-0} peer(s)"; fi
done

note ""
note "finality (${REF_NAME})"
# Justification must advance. A 50/50 fork produces blocks forever while justification sits
# frozen (neither side reaches 2/3), so a stuck justified epoch is the earliest fork signal.
# head_ep comes from the REFERENCE, so these lags are real numbers; when it came from the global
# minimum head both lags went negative on a healthy chain and every comparison below passed
# vacuously — the checks looked green precisely because they had stopped working.
fc="$(bget "$ref" /eth/v1/beacon/states/head/finality_checkpoints)"
just="$(jqf data current_justified epoch <<<"$fc")"
fin="$(jqf data finalized epoch <<<"$fc")"
if [[ -n "$just" ]] && (( head_ep >= 4 )); then
  jlag=$(( head_ep - just ))
  if (( jlag > 4 )); then bad "justification frozen at epoch $just while head is at $head_ep — suspect a fork or <2/3 participation"
  else ok "justified epoch $just ($jlag behind head epoch $head_ep)"; fi
fi
if [[ -n "$fin" ]] && (( fin > 0 )); then
  flag=$(( head_ep - fin ))
  if (( flag > 6 )); then bad "finality lagging head by $flag epochs (head=$head_ep finalized=$fin)"
  else ok "finalized epoch $fin ($flag behind head)"; fi
elif (( head_ep >= 5 )); then
  bad "nothing finalized by head epoch $head_ep — producing blocks but not finalizing"
else
  warn "not finalized yet (head epoch $head_ep) — expected in the first ~4 epochs"
fi
# Cross-client finalized-root check, over the canonical cohort only: a node on another chain is
# expected to hold a different finalized root, so including it here would report a split that is
# already accounted for as a divergence.
if [[ -n "$fin" ]] && (( fin > 0 )); then
  fbase=""
  for i in "${!CL_NAME[@]}"; do
    (( CANON[$i] )) || continue
    c="$(bget "${CL_PORT[$i]}" /eth/v1/beacon/states/head/finality_checkpoints)"
    fe="$(jqf data finalized epoch <<<"$c")"; fr="$(jqf data finalized root <<<"$c")"
    [[ -z "$fr" ]] && continue
    if [[ -z "$fbase" ]]; then fbase="$fe:$fr"
    elif [[ "$fe" == "${fbase%%:*}" && "$fr" != "${fbase#*:}" ]]; then
      bad "SPLIT FINALITY: both at epoch $fe with different roots"
    fi
  done
fi

MISSED_WINDOW=32
note ""
note "missed-slot rate over last $MISSED_WINDOW slots (${REF_NAME})"
# Window anchored to the REFERENCE's own head. Anchoring it to the global minimum head asked the
# reference for 16 slots belonging to a dead node's fork, which it had never seen — reporting
# 16/16 missed (100%) on a chain that was missing nothing.
#
# 32 slots, not 16: at SLOTS_PER_EPOCH=8 a 16-slot window is two epochs and swings wildly (43%
# and 31% measured seconds apart on the same healthy chain), which is far too noisy to hang a
# 40% "fork signature" threshold on.
present=0; total=0
start=$(( ref_head - MISSED_WINDOW + 1 )); (( start < 1 )) && start=1

# Attribute each missed slot to the validator that owed it. A bare percentage is not actionable,
# and worse, the diverged-node excuse below can swallow a second unrelated outage: on 2026-07-30
# grandine was partitioned (6 missed) AND nimbus proposed nothing at all while sitting on the
# canonical chain with 3 peers and a current head (2 missed). Only attribution separates them.
declare -A PROPOSER=()
for e in $(seq $(( start / spe )) $(( ref_head / spe ))); do
  while read -r ds dv; do
    [[ -n "$ds" ]] && PROPOSER[$ds]="$dv"
  done < <(bget "$ref" "/eth/v1/validator/duties/proposer/$e" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)["data"]
except Exception:
    sys.exit()
for x in d:
    print(x["slot"], x["validator_index"])
' 2>/dev/null)
done

MISSED_PROPOSERS=""
for s in $(seq "$start" "$ref_head"); do
  total=$((total+1))
  if [[ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$ref/eth/v2/beacon/blocks/$s")" == "200" ]]; then
    present=$((present+1))
  else
    MISSED_PROPOSERS="$MISSED_PROPOSERS ${PROPOSER[$s]:-?}"
  fi
done
if (( total > 0 )); then
  missed=$(( total - present )); pct=$(( missed * 100 / total ))
  # This rate NEVER sets FAIL, deliberately. It is a small, noisy sample (measured 43% and 31%
  # seconds apart on the same finalizing chain), and every fork it could detect is already caught
  # authoritatively upstream — by the block-root majority and by frozen justification. Letting a
  # derived statistic also vote "destroy and relaunch" is how a working enclave gets thrown away.
  if   (( pct > 40 )); then warn "$missed/$total missed (${pct}%) — high; corroborate against the finality and root checks above, do not act on this line alone"
  elif (( pct > 15 )); then warn "$missed/$total missed (${pct}%)"
  else ok "$missed/$total missed (${pct}%)"; fi
  # Deliberately NOT phrased as "this is expected". A diverged node explains SOME misses; it is
  # the operator's job to check the indices below cluster where they should. Distinct validator
  # ranges among the missed proposers mean more than one participant is failing to propose.
  if (( missed > 0 )); then
    note "       missed proposers:$(printf '%s' "$MISSED_PROPOSERS" | tr ' ' '\n' | sort -n | uniq | tr '\n' ' ')"
    (( DIVERGED )) && note "       (${DIVERGED_NAMES# } is off the canonical chain, so its proposals cannot land here —"
    (( DIVERGED )) && note "        any missed proposer OUTSIDE that node's validator range is a separate problem)"
  fi
fi

note ""
note "execution layer (canonical cohort)"
# Scoped to the ELs paired with canonical CLs. An unscoped min/max spread means the EL behind the
# one partitioned CL fails the whole enclave on its own — a second, independent false UNHEALTHY
# that survived even after the CL-side loop was fixed.
el_num() { curl -s -m 10 -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
  "http://127.0.0.1:$1" | jqf result; }
CANON_IDX=""
for i in "${!CL_NAME[@]}"; do (( CANON[$i] )) && CANON_IDX="$CANON_IDX $(node_idx "${CL_NAME[$i]}")"; done
declare -a NUMS
for i in "${!EL_NAME[@]}"; do
  eidx="$(node_idx "${EL_NAME[$i]}")"
  hx="$(el_num "${EL_PORT[$i]}")"
  case " $CANON_IDX " in
    *" $eidx "*) ;;
    *) note "  ${EL_NAME[$i]} = $([[ -n "$hx" ]] && echo $((hx)) || echo unreachable) (skipped — its CL is off the canonical chain)"; continue ;;
  esac
  if [[ -z "$hx" ]]; then bad "${EL_NAME[$i]}: no answer to eth_blockNumber"; continue; fi
  NUMS+=("$((hx))")
  note "  ${EL_NAME[$i]} = $((hx))"
done
if (( ${#NUMS[@]} > 1 )); then
  lo=${NUMS[0]}; hi=${NUMS[0]}
  for n in "${NUMS[@]}"; do (( n < lo )) && lo=$n; (( n > hi )) && hi=$n; done
  d=$(( hi - lo ))
  if (( d > 5 )); then bad "EL heights diverge by $d blocks"; else ok "EL heights within $d blocks"; fi
fi

note ""
# Three outcomes, because "some client forked" and "the chain is dead" need different actions:
#   0 HEALTHY  — everything agrees and finalizes; run the suite
#   1 UNHEALTHY— the canonical chain is broken (no peers / stalled / not finalizing); investigate
#   2 DEGRADED — canonical chain finalizes, but a node is off it; suite is usable and you have a
#                genuine cross-client finding to chase
if   (( FAIL ));     then note "RESULT: UNHEALTHY — canonical chain is broken; preserve evidence and consult the approved recovery plan"; rc=1
elif (( DIVERGED )); then note "RESULT: DEGRADED — canonical chain is finalizing, but${DIVERGED_NAMES} diverged"
                          note "         The suite is usable against ${REF_NAME}. The divergence is a real"
                          note "         cross-client disagreement worth investigating, not a devnet fault."; rc=2
else                      note "RESULT: HEALTHY"; rc=0
fi
note ""
note "export HTTP_ADDRESS=http://127.0.0.1:$ref   # ${REF_NAME} (canonical chain)"
exit "$rc"
