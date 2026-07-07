#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GIT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

IMAGE_NAME="${PLANTUML_IMAGE_NAME:-local/plantuml-cli}"
CONTAINER_NAME="${PLANTUML_CONTAINER_NAME:-plantuml-cli}"

docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

docker run -d \
  --name "$CONTAINER_NAME" \
  -v "$GIT_ROOT:/work" \
  -w /work \
  "$IMAGE_NAME"
