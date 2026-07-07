#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GIT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

FORMAT="${1:-svg}"
TARGET="${2:-uml/*.puml}"
CONTAINER_NAME="${PLANTUML_CONTAINER_NAME:-plantuml-cli}"
PLANTUML_JAR="${PLANTUML_JAR:-/opt/plantuml.jar}"

case "$FORMAT" in
  svg|png|pdf|eps|txt|utxt)
    ;;
  *)
    echo "Unsupported PlantUML format: $FORMAT" >&2
    echo "Supported: svg, png, pdf, eps, txt, utxt" >&2
    exit 2
    ;;
esac

cd "$GIT_ROOT"

docker exec "$CONTAINER_NAME" sh -lc "java -jar ${PLANTUML_JAR} -t${FORMAT} ${TARGET}"
