#!/usr/bin/env bash
# Sourced by comfyui-runtime/src/start.sh immediately before the provisioner
# (CONTRACTS.md section 7). Sourced, not executed: `return`, never `exit`.
#
# Point the lazily-fetched annotator weights at the network volume.
#
# comfyui_controlnet_aux downloads DWPose (yolox_l.onnx +
# dw-ll_ucoco_384_bs5.torchscript.pt) into its own package directory, and
# DepthAnything pulls depth_anything_vitl14.pth through transformers into the
# HF cache. Neither location is on the volume -- custom_nodes/ is not symlinked
# and $HOME is container-local -- so roughly 1.7 GB re-downloads on every cold
# boot. Those three basenames sit on template.json's auto_download list, which
# suppresses the boot report's missing-model warning, so the re-download is
# silent as well as slow.
#
# Nodes 277, 321 and 336 are all live in the shipped workflows, so this fires
# on the first queued prompt every single time.
#
# Both paths stay inside $PERSIST_ROOT/models: that subtree is already the
# volume-backed model store, so this persists the weights without adding a new
# top-level directory to the frozen $PERSIST_ROOT layout.

export AUX_ANNOTATOR_CKPTS_PATH="${PERSIST_ROOT}/models/annotator"
export HF_HOME="${PERSIST_ROOT}/models/.huggingface"

mkdir -p "$AUX_ANNOTATOR_CKPTS_PATH" "$HF_HOME" 2>/dev/null || true

echo "🔗 annotator weights persist to ${AUX_ANNOTATOR_CKPTS_PATH}"
echo "🔗 HF cache persists to ${HF_HOME}"
