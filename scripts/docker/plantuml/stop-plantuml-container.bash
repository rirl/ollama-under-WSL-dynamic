#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${PLANTUML_CONTAINER_NAME:-plantuml-cli}"

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
