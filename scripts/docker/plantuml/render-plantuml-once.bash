#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GIT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

FORMAT="${1:-svg}"
TARGET="${2:-refactor/uml/*.puml}"
IMAGE_NAME="${PLANTUML_IMAGE_NAME:-local/plantuml-cli}"

case "$FORMAT" in
  svg|png|pdf|eps|txt|utxt)
    ;;
  *)
    echo "Unsupported PlantUML format: $FORMAT" >&2
    echo "Supported: svg, png, pdf, eps, txt, utxt" >&2
    exit 2
    ;;
esac

docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"

docker run --rm \
  -v "$GIT_ROOT:/work" \
  -w /work \
  --entrypoint sh \
  "$IMAGE_NAME" \
  -lc "plantuml -t${FORMAT} ${TARGET}"
