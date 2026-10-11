#!/usr/bin/env bash
# Prints the Telegram connection link of the running container.
set -euo pipefail
docker exec tgweb-proxy show-link
