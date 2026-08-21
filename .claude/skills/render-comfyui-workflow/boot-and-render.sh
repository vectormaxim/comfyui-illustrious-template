#!/usr/bin/env bash
# Boots a ComfyUI template image in CPU-only mode, loads a workflow JSON into
# the REAL frontend via a headless Chromium, and reports back errors + a
# screenshot. Generic across any comfyui-runtime-based template image.
#
# Usage:
#   boot-and-render.sh <docker-image> <workflow.json> <out-dir> [extra render.js args...]
#
# Example:
#   boot-and-render.sh docker.io/vectormaxim/comfyui-illustrious-template:latest \
#     workflows/Illustrious/Illustrious_Detailer_Pipeline.json /tmp/render-out \
#     --node-id 230 --group "HIPS/GROIN"
#
# Requires: docker, node+npm/npx (playwright + its chromium build are installed
# on first run into this skill directory's node_modules, then cached).
#
# Why --cpu: the image's ComfyUI core (comfy.model_management) calls
# torch.cuda.current_device() at import time; with no GPU in the box that
# raises immediately unless --cpu is passed, which routes device selection
# around the CUDA path before that call happens. This only boots the frontend
# far enough to render the graph -- it cannot actually run inference.

set -euo pipefail

IMAGE="${1:?usage: boot-and-render.sh <docker-image> <workflow.json> <out-dir> [render.js args...]}"
WORKFLOW="${2:?workflow.json path required}"
OUT_DIR="${3:?out-dir required}"
shift 3
EXTRA_ARGS=("$@")

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${COMFYUI_PREVIEW_PORT:-18188}"
CONTAINER_NAME="comfyui-preview-$$"

mkdir -p "$OUT_DIR"
WORKFLOW="$(cd "$(dirname "$WORKFLOW")" && pwd)/$(basename "$WORKFLOW")"

cleanup() {
    docker stop "$CONTAINER_NAME" > /dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Ensuring Playwright + Chromium are installed (cached after first run)..."
cd "$SKILL_DIR"
if [ ! -d node_modules/playwright ]; then
    npm install playwright > /dev/null
fi
if [ ! -d "$HOME/.cache/ms-playwright" ]; then
    npx playwright install chromium
fi

echo "==> Booting $IMAGE on port $PORT (container: $CONTAINER_NAME, --cpu mode)..."
docker run --rm -d --name "$CONTAINER_NAME" -p "${PORT}:8188" \
    --entrypoint bash "$IMAGE" \
    -c "cd /ComfyUI && python3 main.py --listen 0.0.0.0 --cpu --disable-auto-launch" \
    > /dev/null

echo "==> Waiting for the server to come up..."
for i in $(seq 1 60); do
    if curl -sf -o /dev/null "http://localhost:${PORT}/"; then
        echo "    up after ${i}s"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "FATAL: server never came up. Boot log:" >&2
        docker logs "$CONTAINER_NAME" 2>&1 | tail -60 >&2
        exit 1
    fi
    sleep 1
done

echo "==> Rendering $WORKFLOW..."
node "$SKILL_DIR/render.js" --port "$PORT" --workflow "$WORKFLOW" --out "$OUT_DIR" "${EXTRA_ARGS[@]}"

echo "==> Done. Screenshots + report.json in $OUT_DIR"
