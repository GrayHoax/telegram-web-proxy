#!/usr/bin/env bash
# Pulls this repository, rebuilds the image (also re-reads site/) and restarts.
#   sudo ./scripts/update.sh            # rebuild with the pinned upstream revision
#   sudo ./scripts/update.sh --latest   # rebuild with the latest upstream master
set -euo pipefail
cd "$(dirname "$0")/.."

compose=(docker compose -f compose.yaml)
if [[ -f .compose-files ]]; then
	mapfile -t compose < .compose-files
fi
build_args=()
if [[ "${1:-}" == "--latest" ]]; then
	build_args=(--build-arg TPROXY_REF=master --no-cache)
fi

if [[ -d .git ]]; then
	git pull --ff-only || echo "git pull failed, continuing with the local copy" >&2
fi
"${compose[@]}" build --pull "${build_args[@]}"
"${compose[@]}" up -d
sleep 5
docker exec tgweb-proxy show-link
