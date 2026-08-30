#!/usr/bin/env bash
# Boots a ComfyUI template image's REAL frontend (headless Chromium) and
# runs a Playwright probe script against it, then tears the container down.
# For discovering the true serialized JSON shape of a node whose inputs/
# widgets are added dynamically by client-side JS -- object_info only shows
# the SERVER-declared schema, which is often empty or misleading for these
# (rgthree's Power Puter and Fast Groups Bypasser, any node with a "+" button
# to add sockets, interactive editor nodes, etc). Hand-authoring workflow
# JSON for a node like this from object_info alone is how you ship a
# plausible-looking but wrong structure.
#
# Usage:
#   boot-and-probe.sh <docker-image> <probe.js> [--install-repo <git-url>]
#
# --install-repo clones an extra custom-node repo into custom_nodes BEFORE
# starting the server -- for testing whether a not-yet-added pack even
# imports cleanly (some don't: a repo that looked fine on GitHub can still
# fail against this specific frontend/ComfyUI version, e.g. an old node
# copying JS into a legacy web/extensions/ path that no longer exists).
# Confirm this BEFORE adding the repo to template.json's custom_nodes.repos.
#
# The probe.js is a Node script using Playwright, run with `node`, that
# talks to the ALREADY-RUNNING server. It should:
#   - launch its own chromium via `require('playwright')` (resolve it from
#     this skill directory's node_modules, or render-comfyui-workflow's --
#     see examples/probe_node_shape.js for the exact require path)
#   - page.goto the boot URL and wait for `window.app && window.app.graph`
#   - build/connect nodes via `LiteGraph.createNode(type)`, `node.connect()`
#   - print `JSON.stringify(graph.serialize().nodes.find(...), null, 2)`
#
# See examples/probe_node_shape.js for a complete worked example and the
# critical debounce gotcha (many dynamic-input nodes add new sockets on a
# DEBOUNCED onConnectionsChange callback, not synchronously on .connect() --
# batch every connection in one page.evaluate() and slots after the first
# will silently not exist yet; call connect(), then `await
# page.waitForTimeout(300)`, per connection).

set -euo pipefail

IMAGE="${1:?usage: boot-and-probe.sh <docker-image> <probe.js> [--install-repo <git-url>]}"
PROBE="${2:?probe.js required}"
shift 2

INSTALL_REPO=""
while [ $# -gt 0 ]; do
    case "$1" in
        --install-repo) INSTALL_REPO="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${COMFYUI_PROBE_PORT:-18199}"
CONTAINER_NAME="comfyui-probe-$$"
PROBE="$(cd "$(dirname "$PROBE")" && pwd)/$(basename "$PROBE")"

cleanup() { docker stop "$CONTAINER_NAME" > /dev/null 2>&1 || true; }
trap cleanup EXIT

# Reuses render-comfyui-workflow's playwright install rather than managing a
# separate one -- your probe.js should require() it from there, e.g.:
#   require('<repo>/.claude/skills/render-comfyui-workflow/node_modules/playwright')
# See examples/probe_node_shape.js. If that skill isn't present, `npm install
# playwright && npx playwright install chromium` in this skill directory
# first and require from here instead.

BOOT_CMD="cd /ComfyUI"
if [ -n "$INSTALL_REPO" ]; then
    BOOT_CMD="cd /ComfyUI/custom_nodes && git clone -q '$INSTALL_REPO' && cd /ComfyUI"
fi
BOOT_CMD="$BOOT_CMD && python3 main.py --listen 0.0.0.0 --cpu --disable-auto-launch"

echo "==> Booting $IMAGE on port $PORT (container: $CONTAINER_NAME, --cpu mode)..."
docker run --rm -d --name "$CONTAINER_NAME" -p "${PORT}:8188" \
    --entrypoint bash "$IMAGE" -c "$BOOT_CMD" \
    > /dev/null

echo "==> Waiting for the server to come up..."
for i in $(seq 1 90); do
    if curl -sf -o /dev/null "http://localhost:${PORT}/"; then
        echo "    up after ${i}s"
        break
    fi
    if [ "$i" -eq 90 ]; then
        echo "FATAL: server never came up. Boot log:" >&2
        docker logs "$CONTAINER_NAME" 2>&1 | tail -80 >&2
        exit 1
    fi
    sleep 1
done

if [ -n "$INSTALL_REPO" ]; then
    if ! docker logs "$CONTAINER_NAME" 2>&1 | grep -q "^Import times for custom nodes:"; then
        echo "==> Import status unclear, dumping recent log lines:" >&2
        docker logs "$CONTAINER_NAME" 2>&1 | tail -40 >&2
    elif docker logs "$CONTAINER_NAME" 2>&1 | grep -A5 "^Import times for custom nodes:" | grep -qi "IMPORT FAILED"; then
        echo "==> WARNING: a custom node failed to import. Log excerpt:" >&2
        docker logs "$CONTAINER_NAME" 2>&1 | grep -B2 -A5 "IMPORT FAILED" >&2
    fi
fi

echo "==> Running probe: $PROBE"
COMFYUI_PROBE_PORT="$PORT" node "$PROBE"
