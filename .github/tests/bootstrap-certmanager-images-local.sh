#!/usr/bin/env bash
set -euo pipefail

# Local-only. This is deliberately not referenced by CI or package defaults.
registry_name=glam150-t2e1a3-registry
registry_port=5001
vouch_source=attestant/vouch:certmanager-test-64d4db5ddb3a5460c888579c6eaf47d3b3cf4ace
dirk_source=attestant/dirk:certmanager-test-55ef507-arm64
vouch_id=sha256:048a2384bf40dc6436b23a876e2f227dc70345b6bccbd7fa76a4d01182e4df5e
dirk_id=sha256:0069f3212131492a027d63ddd599bbf50641a28c5cb0a5bafa23b0714aa733fc

if [[ "${1:-}" == "--cleanup" ]]; then
  docker rm -f "$registry_name" >/dev/null 2>&1 || true
  exit 0
fi

for image_id in "$vouch_id" "$dirk_id"; do
  docker image inspect "$image_id" >/dev/null
done
[[ "$(docker image inspect "$vouch_source" --format '{{.Id}}')" == "$vouch_id" ]]
[[ "$(docker image inspect "$dirk_source" --format '{{.Id}}')" == "$dirk_id" ]]

docker rm -f "$registry_name" >/dev/null 2>&1 || true
docker run -d --name "$registry_name" -p "$registry_port:5000" registry:2 >/dev/null

for source in "$vouch_source" "$dirk_source"; do
  repository=${source%%:*}
  docker tag "$source" "localhost:$registry_port/$repository:certmanager-test-immutable"
  docker push "localhost:$registry_port/$repository:certmanager-test-immutable"
done

vouch_ref=$(docker image inspect "localhost:$registry_port/attestant/vouch:certmanager-test-immutable" --format '{{index .RepoDigests 0}}')
dirk_ref=$(docker image inspect "localhost:$registry_port/attestant/dirk:certmanager-test-immutable" --format '{{index .RepoDigests 0}}')
[[ "$vouch_ref" == "localhost:$registry_port/attestant/vouch@$vouch_id" ]]
[[ "$dirk_ref" == "localhost:$registry_port/attestant/dirk@$dirk_id" ]]
printf 'vouch=%s\ndirk=%s\n' "$vouch_ref" "$dirk_ref"
