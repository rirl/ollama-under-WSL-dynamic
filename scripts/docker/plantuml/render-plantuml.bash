#!/usr/bin/env bash
set -euo pipefail

FORMAT="${1:-svg}"
TARGET="${2:-refactor/uml/*.puml}"

docker exec plantuml-cli sh -lc "plantuml -t${FORMAT} ${TARGET}"
