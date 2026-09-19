#!/usr/bin/env bash
# Sourced by comfyui-runtime/src/start.sh immediately before the ComfyUI launch
# (CONTRACTS.md section 7). Sourced, not executed: `return`, never `exit`.

# ---------------------------------------------------------------------------
# 1. Give Civicomfy the CivitAI key without typing it into its settings panel.
#
# Civicomfy resolves its key in exactly two steps (server/utils.py,
# resolve_civitai_api_key): the `api_key` field of the request payload, then
# the CIVITAI_API_KEY environment variable. Nothing else. Leave the settings
# field blank and the env var is used -- type a key there and it wins over the
# env for that browser, which is the thing to avoid.
#
# The catch is the NAME. The runtime's civitai_env.sh standardises on
# CIVITAI_TOKEN for its own aria2 downloader and accepts civitai_token and
# CIVITAI_API_KEY as inputs, but it only ever *exports* CIVITAI_TOKEN and
# civitai_token -- it maps CIVITAI_API_KEY onto CIVITAI_TOKEN, not the reverse.
# So a pod whose template sets CIVITAI_TOKEN feeds the boot-time downloader
# fine and leaves Civicomfy with nothing.
#
# resolve_civitai_env runs at start.sh:662, this hook at start.sh:742, so by
# now CIVITAI_TOKEN holds the key whichever of the three names was set. Map it
# back onto the one name Civicomfy reads, and only when that name is empty, so
# an explicitly set CIVITAI_API_KEY is never overwritten.
#
# Nothing here is fatal: no key just means unauthenticated CivitAI browsing
# (lower rate limits, and gated models will not download).
# ---------------------------------------------------------------------------
if [ -z "${CIVITAI_API_KEY:-}" ]; then
    for _civitai_name in CIVITAI_TOKEN civitai_token; do
        if [ -n "${!_civitai_name:-}" ]; then
            export CIVITAI_API_KEY="${!_civitai_name}"
            echo "🔑 CIVITAI_API_KEY set from $_civitai_name for Civicomfy"
            break
        fi
    done
    unset _civitai_name
fi

if [ -n "${CIVITAI_API_KEY:-}" ]; then
    echo "🔑 Civicomfy will authenticate from the environment; leave its API Key field blank"
else
    echo "ℹ️  No CivitAI key in the environment: Civicomfy will browse unauthenticated"
fi

# Deliberately NOT setting a Civicomfy "Global Download Root". Left empty it
# uses ComfyUI's folder_paths, and template.json's models_symlink already points
# /ComfyUI/models at $NETWORK_VOLUME/ComfyUI/models, so downloads land on the
# volume and survive a restart. A global root would persist to
# custom_nodes/Civicomfy/root_settings.json, which is container-local and lost
# on every pod restart -- it would have to be rewritten here every boot to stick.

# ---------------------------------------------------------------------------
# 2. CIVITAI_DIFFUSION_MODELS: CIVITAI_CHECKPOINTS, for diffusion-model-only files.
#
# The runtime's CivitAI loop (start.sh:663-668) downloads into exactly two
# folders, models/checkpoints and models/loras. Anima checkpoints such as
# WAI-ANIMA (version 2983680) are diffusion-model-only files: UNETLoader lists
# models/diffusion_models and never models/checkpoints, so a file fetched with
# CIVITAI_CHECKPOINTS lands where the Anima workflow cannot see it.
#
# Same downloader, same token, different folder. download_with_aria.py asks for
# type=Model, which for a multi-file version is the Model-type file (for
# 2983680 that is waiANIMA_v10Base10.safetensors, not its bundled text encoder
# or VAE), and it skips a file that is already complete, so a restart does not
# re-download. resolve_civitai_env already ran at start.sh:662, so CIVITAI_TOKEN
# holds the key whichever spelling the template set.
#
# Sequential and blocking, like the runtime loop it mirrors: ComfyUI launches
# once the files are there. Never fatal: a failed ID warns and boot continues.
# ---------------------------------------------------------------------------
_civitai_diffusion_models() {
    local ids="${CIVITAI_DIFFUSION_MODELS:-}" dest id
    if [ -z "$ids" ] || [ "$ids" = "replace_with_ids" ]; then
        echo "⏭️  Skipping CivitAI diffusion-model downloads (CIVITAI_DIFFUSION_MODELS not set)"
        return 0
    fi
    if [ -z "${CIVITAI_TOKEN:-}${civitai_token:-}" ]; then
        echo "❌ CIVITAI_DIFFUSION_MODELS is set but there is no CivitAI token; skipping"
        declare -F report_warn >/dev/null \
            && report_warn "CIVITAI_DIFFUSION_MODELS needs civitai_token (or CIVITAI_TOKEN) to download"
        return 0
    fi

    dest="${PERSIST_ROOT:-/workspace/ComfyUI}/models/diffusion_models"
    mkdir -p "$dest" || return 0

    local IFS=','
    for id in $ids; do
        id="${id//[[:space:]]/}"
        [ -n "$id" ] || continue
        if ! [[ "$id" =~ ^[0-9]+$ ]]; then
            echo "❌ CIVITAI_DIFFUSION_MODELS: '$id' is not a CivitAI version ID; skipping"
            declare -F report_warn >/dev/null \
                && report_warn "CIVITAI_DIFFUSION_MODELS: '$id' is not a CivitAI version ID"
            continue
        fi
        echo "🚀 CivitAI diffusion model $id -> $dest"
        if ! download_with_aria.py -m "$id" -o "$dest"; then
            echo "❌ CivitAI diffusion model $id failed to download"
            declare -F report_warn >/dev/null \
                && report_warn "CivitAI diffusion model $id failed to download"
        fi
    done
}
_civitai_diffusion_models

# ---------------------------------------------------------------------------
# 3. Make cg-image-filter's Mask Image Filter work on Linux.
#
# At the pinned 9fe9e16 (1.9.1, "fix mask"), newest_mask_file() sorts the mask
# editor's saved files by stat().st_birthtime. Linux Python has no such field
# (3.12 in this image: AttributeError), so the FIX stage crashed the moment you
# pressed Save in the mask editor. Tested on this image in --cpu mode: with
# st_mtime instead, the painted mask arrives intact; Save without painting and
# a timeout both give a blank mask, so the image passes through unchanged.
#
# Idempotent, only touches the one attribute, and skipped once upstream stops
# using it. Never fatal: if the file is not there the stage simply is not
# available, which the runtime's missing-node report already shows.
# ---------------------------------------------------------------------------
_cg_filter_nodes="${CUSTOM_NODES_DIR:-/ComfyUI/custom_nodes}/cg-image-filter/image_filter_nodes.py"
if [ -f "$_cg_filter_nodes" ] && grep -q 'st_birthtime' "$_cg_filter_nodes"; then
    if sed -i 's/\.st_birthtime/.st_mtime/g' "$_cg_filter_nodes"; then
        echo "🩹 cg-image-filter: mask files sorted by st_mtime (Linux has no st_birthtime)"
    fi
fi
unset _cg_filter_nodes
