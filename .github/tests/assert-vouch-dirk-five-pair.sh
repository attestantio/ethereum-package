#!/usr/bin/env bash
# Five-pair checks. Exit 0: pass. 1: a check failed. 2: the checks could not run (the last line is
# then RESULT: ERROR). 4: blocked and nothing failed (the head is not on Gloas yet, or a cluster has
# no Gloas proposal yet).
#   Config   each Vouch uses beacon nodes 1 to 5, its own Dirk peers and its delays.
#   Gloas    each cluster's proposals have their payloads built on by the next block.
#   Metrics  each Vouch manages its cluster's accounts, the passive Vouch yields to the active one,
#            and Dirk signed what Vouch reports.
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 ENCLAVE" >&2; exit 2; }
enclave=$1
tmp=$(mktemp -d)
finished=
# Any exit before the result below, including a command that failed under set -e, is "could not run".
trap 'rm -rf "$tmp"; if [[ -z $finished ]]; then echo "RESULT: ERROR"; exit 2; fi' EXIT

fails=0 blocked=0
die() { echo "ERROR: $*" >&2; exit 2; }
ok() { echo "OK      $*"; }
fail() { echo "FAIL    $*"; fails=$((fails + 1)); }
block() { echo "BLOCKED $*"; blocked=$((blocked + 1)); }
# expect WHAT GOT WANT
expect() { if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi; }
# assert WHAT ARITHMETIC-EXPRESSION
assert() { if (($2)); then ok "$1"; else fail "$1"; fi; }
lines() { awk 'END { print NR }' "$1"; }

vc_a=vc-4-erigon-lodestar-vouch vc_b=vc-5-besu-nimbus-vouch vc_p=vc-6-geth-lighthouse-vouch
endpoint() { kurtosis port print "$enclave" "$1" "$2" --format ip,number | tr ' ' ':'; }
beacon=http://$(endpoint cl-2-lighthouse-nethermind http) || die "no http port on cl-2-lighthouse-nethermind"

# Saves the beacon node's answer in $tmp/body and its status in $code. Fails unless the status is 200.
fetch() {
  code=$(curl -sS -m 10 -o "$tmp/body" -w '%{http_code}' "$beacon$1") || code=failed
  [[ $code == 200 ]]
}

# Cluster membership: each cluster's DKG pubkeys, found in the genesis validators.
fetch /eth/v1/beacon/states/genesis/validators || die "genesis validators: $code"
mv "$tmp/body" "$tmp/genesis"
for c in a b; do
  kurtosis files download "$enclave" "dkg-validators-file-$c" "$tmp/dkg-$c" >/dev/null || die "cannot download dkg-validators-file-$c"
  grep '^0x' "$tmp/dkg-$c/validators.txt" | cut -d: -f1 | tr 'A-F' 'a-f' >"$tmp/keys-$c" || die "no DKG pubkeys for cluster $c"
  jq -r --rawfile keys "$tmp/keys-$c" '($keys | split("\n")) as $k | .data[] | select(.validator.pubkey | ascii_downcase | IN($k[])) | .index' "$tmp/genesis" >"$tmp/idx-$c"
  expect "cluster $c: its $(lines "$tmp/keys-$c") DKG validators are in genesis" "$(lines "$tmp/idx-$c")" "$(lines "$tmp/keys-$c")"
done
count_a=$(lines "$tmp/keys-a") count_b=$(lines "$tmp/keys-b")

# check_config SERVICE CLUSTER MULTI-INSTANCE
check_config() {
  local yml="$tmp/$1.yml"
  kurtosis service exec "$enclave" "$1" 'cat /config/vouch.yml' >"$yml" || die "cannot read /config/vouch.yml of $1"
  expect "$1 beacon nodes" "$(sed -n "s|^  - 'http://cl-\([0-9]*\)-.*|\1|p" "$yml" | tr '\n' ' ')" "1 2 3 4 5 "
  expect "$1 Dirk peers" "$(sed -n "s|^      - '\(dirk-[^']*\)'$|\1|p" "$yml" | tr '\n' ' ')" "dirk-$2-1:8881 dirk-$2-2:8881 dirk-$2-3:8881 "
  expect "$1 multi-instance" "$(awk '/^multiinstance:/ { m = 1; next } /^[^ ]/ { m = 0 } m && /(style|attester-delay|proposer-delay):/ { gsub(/[ \047]/, ""); printf "%s ", $0 }' "$yml")" "$3"
}
check_config "$vc_a" a ""
check_config "$vc_b" b "style:static-delay attester-delay:250ms proposer-delay:500ms "
check_config "$vc_p" b "style:static-delay attester-delay:4s proposer-delay:2s "

# Gloas blocks, from the head back along parent roots to the last block before the fork. A missed slot
# leaves no block, and any block the node cannot serve stops the run.
: >"$tmp/blocks"
id=head child=-
while :; do
  fetch "/eth/v2/beacon/blocks/$id" || die "block $id, the parent of slot $child: $code"
  read -r version parent slot < <(jq -r '"\(.version) \(.data.message.parent_root) \(.data.message.slot)"' "$tmp/body") || die "block $id is not a block"
  [[ $version != null && $parent != null ]] || die "block $id has no version or parent root"
  [[ $version == gloas ]] || break
  cat "$tmp/body" >>"$tmp/blocks"
  id=$parent child=$slot
done
if [[ $id == head ]]; then
  block "the head, slot $slot, is on $version, not gloas"
else
  # A missing field is "-": two empty fields would compare equal.
  jq -r '.data.message | [.slot, .proposer_index, (.body.signed_execution_payload_bid.message.parent_block_hash // "-"), (.body.signed_execution_payload_bid.message.block_hash // "-")] | @tsv' "$tmp/blocks" | sort -n >"$tmp/rows" || die "unexpected block data"
  # A block is judged by its successor, so the head is not counted.
  awk -F'\t' -v a="$tmp/idx-a" -v b="$tmp/idx-b" '
    BEGIN { while ((getline i < a) > 0) who[i] = "a"; while ((getline i < b) > 0) who[i] = "b" }
    $3 == "-" || $4 == "-" { printf "FAIL    slot %s: the block has no payload bid\n", $1; prev = ""; next }
    prev != "" {
      seen[prev]++
      if ($3 == hash) built[prev]++
      else printf "FAIL    slot %s (cluster %s): the next block, slot %s, does not build on its payload\n", slot, prev, $1
    }
    { slot = $1; prev = who[$2]; hash = $4 }
    END {
      for (n = 1; n <= 2; n++) {
        k = substr("ab", n, 1)
        if (!seen[k]) printf "BLOCKED cluster %s: no Gloas proposal yet\n", k
        else if (built[k] == seen[k]) printf "OK      cluster %s: %d Gloas proposals, %d payloads built on\n", k, seen[k], built[k]
        else printf "INFO    cluster %s: %d Gloas proposals, %d payloads built on\n", k, seen[k], built[k]
      }
    }' "$tmp/rows" >"$tmp/walk"
  cat "$tmp/walk"
  fails=$((fails + $(grep -c '^FAIL' "$tmp/walk" || true)))
  blocked=$((blocked + $(grep -c '^BLOCKED' "$tmp/walk" || true)))
fi

# Metrics. Vouch is read before Dirk, so each Dirk counter is at least as new as the Vouch counter it backs.
scrape() {
  local addr
  addr=$(endpoint "$1" metrics) && curl -fsS -m 10 "http://$addr/metrics" >"$tmp/metrics-$1" || die "cannot read the metrics of $1"
}
val() { awk -v s="$2" '$1 == s { v = $2 } END { printf "%.0f\n", v }' "$tmp/metrics-$1"; }
# dirk CLUSTER REQUEST RESULT: the cluster's three Dirk peers added up
dirk() {
  local n=0 i
  for i in 1 2 3; do n=$((n + $(val "dirk-$1-$i" "dirk_signer_process_requests_total{request=\"$2\",result=\"$3\"}"))); done
  echo "$n"
}
if ((blocked)); then
  block "metrics: both clusters need a Gloas proposal first"
else
  for s in "$vc_a" "$vc_b" "$vc_p" dirk-a-1 dirk-a-2 dirk-a-3 dirk-b-1 dirk-b-2 dirk-b-3; do scrape "$s"; done
  att='vouch_attestation_process_requests_total{result="succeeded"}'
  prop='vouch_beaconblockproposal_process_requests_total{result="succeeded"}'
  accounts='vouch_accountmanager_accounts_total{state="active_ongoing"}'
  a_att=$(val "$vc_a" "$att") b_att=$(val "$vc_b" "$att") p_att=$(val "$vc_p" "$att")
  a_prop=$(val "$vc_a" "$prop") b_prop=$(val "$vc_b" "$prop") p_prop=$(val "$vc_p" "$prop")
  # An active account is one Vouch found on its own Dirk cluster and the chain knows as a validator.
  expect "$vc_a manages its cluster's accounts" "$(val "$vc_a" "$accounts")" "$count_a"
  expect "$vc_b manages its cluster's accounts" "$(val "$vc_b" "$accounts")" "$count_b"
  expect "$vc_p manages its cluster's accounts" "$(val "$vc_p" "$accounts")" "$count_b"
  assert "$vc_a signed $a_att attestations" "a_att > 0"
  assert "$vc_p yields to $vc_b: it signed $p_att attestations, $vc_b $b_att" "p_att < b_att"
  for request in attestation proposal; do
    case $request in
      attestation) vouch_a=$a_att vouch_b=$((b_att + p_att)) ;;
      proposal) vouch_a=$a_prop vouch_b=$((b_prop + p_prop)) ;;
    esac
    dirk_a=$(dirk a "$request" succeeded) dirk_b=$(dirk b "$request" succeeded)
    assert "Dirk cluster a signed $dirk_a ${request}s, at least 2 x the $vouch_a Vouch reports" "dirk_a >= 2 * vouch_a"
    assert "Dirk cluster b signed $dirk_b ${request}s, at least 2 x the $vouch_b Vouch reports" "dirk_b >= 2 * vouch_b"
  done
  # Either instance of cluster b may win a proposal race, so these are reported, not compared.
  echo "INFO    proposals signed: $vc_a $a_prop, $vc_b $b_prop, $vc_p $p_prop; Dirk denied $(dirk a proposal denied) in cluster a and $(dirk b proposal denied) in cluster b"
fi

finished=1
if ((fails)); then echo "RESULT: FAIL"; exit 1; fi
if ((blocked)); then echo "RESULT: BLOCKED"; exit 4; fi
echo "RESULT: PASS"
