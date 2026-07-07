#!/usr/bin/env bash
set -euo pipefail

docker build -t local/plantuml-cli .
docker rm -f plantuml-cli 2>/dev/null || true

docker run -d \
  --name plantuml-cli \
  -v "$PWD:/work" \
  -w /work \
  local/plantuml-cli
