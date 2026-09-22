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
# 2. CIVITAI_DIFFUSION_MODELS / CIVITAI_TEXT_ENCODERS: CIVITAI_CHECKPOINTS for
#    the two model folders the runtime's own CivitAI loop cannot reach.
#
# The runtime's CivitAI loop (start.sh:663-668) downloads into exactly two
# folders, models/checkpoints and models/loras. Anima checkpoints such as
# WAI-ANIMA (version 2983680) are diffusion-model-only files: UNETLoader lists
# models/diffusion_models and never models/checkpoints, so a file fetched with
# CIVITAI_CHECKPOINTS lands where the Anima workflow cannot see it.
#
# download_with_aria.py takes a version's *primary* file, which on a
# multi-file version is the Model-type file and never its bundled text encoder
# or VAE. That is the right default, but several Anima finetunes ship a
# fine-tuned Qwen3-0.6B next to the model and are meant to be run against that
# encoder instead of the stock qwen_3_06b_base -- One obsession_Anima ships one
# for every version. Under the primary-file rule that encoder never lands, so
# the pod has a model whose conditioner is missing and the CLIPLoader has only
# the base encoder to offer. Hence CIVITAI_TEXT_ENCODERS.
#
# Both variables take a full CivitAI URL as well as a bare version ID, because
# a URL carrying fileId is the only way to name a non-primary file (the
# downloader's _select_version_file honours requested_file_id; a bare ID cannot
# express one). The fileId is in the version's API listing, and civitai.com,
# civitai.green and civitai.red are all accepted hosts. For One
# obsession_Anima v4.0:
#
#   CIVITAI_DIFFUSION_MODELS=3301424
#   CIVITAI_TEXT_ENCODERS=https://civitai.com/api/download/models/3301424?fileId=3186759
#
# Same downloader, same token, different folder, and it skips a file that is
# already complete so a restart does not re-download. resolve_civitai_env
# already ran at start.sh:662, so CIVITAI_TOKEN holds the key whichever
# spelling the template set.
#
# Sequential and blocking, like the runtime loop it mirrors: ComfyUI launches
# once the files are there. Never fatal: a failed ID warns and boot continues.
# ---------------------------------------------------------------------------
_civitai_download_into() {
    local var="$1" subdir="$2" label="$3" ids dest id
    ids="${!var:-}"
    if [ -z "$ids" ] || [ "$ids" = "replace_with_ids" ]; then
        echo "⏭️  Skipping CivitAI $label downloads ($var not set)"
        return 0
    fi
    if [ -z "${CIVITAI_TOKEN:-}${civitai_token:-}" ]; then
        echo "❌ $var is set but there is no CivitAI token; skipping"
        declare -F report_warn >/dev/null \
            && report_warn "$var needs civitai_token (or CIVITAI_TOKEN) to download"
        return 0
    fi

    dest="${PERSIST_ROOT:-/workspace/ComfyUI}/models/$subdir"
    mkdir -p "$dest" || return 0

    local IFS=','
    for id in $ids; do
        id="${id//[[:space:]]/}"
        [ -n "$id" ] || continue
        if ! [[ "$id" =~ ^[0-9]+$ ]] \
            && ! [[ "$id" =~ ^https?://([a-z0-9-]+\.)*civitai\.(com|green|red)/ ]]; then
            echo "❌ $var: '$id' is not a CivitAI version ID or CivitAI URL; skipping"
            declare -F report_warn >/dev/null \
                && report_warn "$var: '$id' is not a CivitAI version ID or CivitAI URL"
            continue
        fi
        echo "🚀 CivitAI $label $id -> $dest"
        if ! download_with_aria.py -m "$id" -o "$dest"; then
            echo "❌ CivitAI $label $id failed to download"
            declare -F report_warn >/dev/null \
                && report_warn "CivitAI $label $id failed to download"
        fi
    done
}
_civitai_download_into CIVITAI_DIFFUSION_MODELS diffusion_models "diffusion model"
_civitai_download_into CIVITAI_TEXT_ENCODERS text_encoders "text encoder"

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
