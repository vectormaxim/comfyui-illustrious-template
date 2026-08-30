#!/usr/bin/env bash
# Runs a Python script INSIDE a ComfyUI template image, with directories
# mounted in, and prints its output. No server boot -- for testing a
# model's/node's actual runtime behavior directly (YOLO detect/segm
# confidences, DWPose keypoints, a custom node's Python logic), using the
# exact library versions the image ships, without waiting on a full
# ComfyUI boot.
#
# Usage:
#   run-python.sh <docker-image> <script.py> [mount ...]
#
# Each `mount` is `<host-dir>:<container-path>[:ro]`, passed straight to
# `docker run -v`. The script itself is always mounted read-only at
# /script.py and invoked as `python3 /script.py`.
#
# Example:
#   run-python.sh vectormaxim/comfyui-illustrious-template:latest \
#     ./probe.py \
#     ./test-images:/images:ro \
#     ./models:/models:ro
#
# Inside the container, ComfyUI's own custom_nodes are already on disk at
# /ComfyUI/custom_nodes -- e.g. to import comfyui_controlnet_aux's DWPose
# detector directly:
#   sys.path.insert(0, "/ComfyUI/custom_nodes/comfyui_controlnet_aux/src")
#   from custom_controlnet_aux.dwpose import DwposeDetector
#
# and ultralytics is already installed for any UltralyticsDetectorProvider
# model (`from ultralytics import YOLO; YOLO("/models/foo.pt")`).

set -euo pipefail

IMAGE="${1:?usage: run-python.sh <docker-image> <script.py> [host:container[:ro] ...]}"
SCRIPT="${2:?script.py required}"
shift 2

SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

MOUNT_ARGS=(-v "$SCRIPT:/script.py:ro")
for m in "$@"; do
    host="${m%%:*}"
    rest="${m#*:}"
    host="$(cd "$host" && pwd)"
    MOUNT_ARGS+=(-v "$host:${rest}")
done

docker run --rm "${MOUNT_ARGS[@]}" --entrypoint python3 "$IMAGE" /script.py
