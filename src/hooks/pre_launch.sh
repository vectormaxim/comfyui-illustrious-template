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
# The runtime's CivitAI loop (start.sh:653, run_civitai_downloads) downloads
# into exactly two folders, models/checkpoints and models/loras. Anima
# checkpoints such as WAI-ANIMA (version 2983680) are diffusion-model-only
# files: UNETLoader lists models/diffusion_models and never models/checkpoints,
# so a file fetched with CIVITAI_CHECKPOINTS lands where the Anima workflow
# cannot see it.
#
# A CivitAI version resolves to its *primary* file, which on a multi-file
# version is the Model-type one. That is right for a plain Anima finetune, but
# several of them ship their own fine-tuned Qwen3-0.6B beside the model (typed
# "Text Encoder", usually named "..._txt.safetensors") and are meant to run
# against that rather than the stock qwen_3_06b_base -- One obsession_Anima
# ships one for every version. Under the primary-file rule that encoder never
# lands: the pod gets a model whose conditioner is missing and the CLIPLoader
# has nothing but the base encoder to offer. Hence CIVITAI_TEXT_ENCODERS, and
# hence both variables take any identifier that can name a specific FILE, not
# just a version -- an AIR with a file ID is the shell-friendliest:
#
#   CIVITAI_DIFFUSION_MODELS=3301424
#   CIVITAI_TEXT_ENCODERS=civitai:2695493@3301424+3186759
#
# WHICH DOWNLOADER, and why this is not one line. A pod carries TWO programs
# called download_with_aria.py and they are not the same:
#
#   /usr/local/bin/download_with_aria.py   baked into the base image, older
#                                          (Aug 13 on the current base tag).
#                                          -m takes a bare version ID only and
#                                          always resolves the primary file;
#                                          handed a URL it pastes it into the
#                                          metadata path and 404s.
#   $CIVITAI_DOWNLOADER                    the runtime's vendored copy, from
#                                          civitai_downloads.sh, sourced by
#                                          start.sh:411 and so in scope here.
#                                          Parses version IDs, model/version:N,
#                                          CivitAI URLs and AIRs, and honours a
#                                          file ID.
#
# PATH finds the base-image one, so a bare `download_with_aria.py` cannot fetch
# a non-primary file no matter how the identifier is written. Prefer the
# runtime copy; fall back to the base-image one for plain version IDs only, and
# say so plainly rather than letting an unsupported identifier 404 into a
# "download.bin" failure. Both were checked against the real pod (23fb4730f447,
# 2026-09-22): the runtime copy resolved civitai:2695493@3301424+3186759 to
# oneObsessionAnima_v40_txt.safetensors and verified its SHA-256.
#
# prepare_civitai_downloader only runs at boot when CIVITAI_CHECKPOINTS or
# CIVITAI_LORAS is set, so call it here too -- a pod that sets only these two
# variables would otherwise reach a downloader whose dependencies were never
# installed. It short-circuits when they already are.
#
# Same token either way. It skips a file that is already complete, so a restart
# does not re-download. resolve_civitai_env already ran at start.sh:412, so
# CIVITAI_TOKEN holds the key whichever spelling the template set.
#
# Sequential and blocking, like the runtime loop it mirrors: ComfyUI launches
# once the files are there. Never fatal: a failed ID warns and boot continues.
# ---------------------------------------------------------------------------
_civitai_warn_hook() {
    declare -F report_warn >/dev/null && report_warn "$1"
    return 0
}

# runtime | legacy | none -- see the table above.
_civitai_downloader_kind() {
    if [ -n "${CIVITAI_DOWNLOADER:-}" ] && [ -f "${CIVITAI_DOWNLOADER:-}" ] \
        && declare -F prepare_civitai_downloader >/dev/null; then
        echo runtime
    elif command -v download_with_aria.py >/dev/null 2>&1; then
        echo legacy
    else
        echo none
    fi
}

_civitai_download_into() {
    local var="$1" subdir="$2" label="$3"
    local ids dest id kind prepared=""
    local -a items=()

    ids="${!var:-}"
    if [ -z "$ids" ] || [ "$ids" = "replace_with_ids" ]; then
        echo "⏭️  Skipping CivitAI $label downloads ($var not set)"
        return 0
    fi
    if [ -z "${CIVITAI_TOKEN:-}${civitai_token:-}" ]; then
        echo "❌ $var is set but there is no CivitAI token; skipping"
        _civitai_warn_hook "$var needs civitai_token (or CIVITAI_TOKEN) to download"
        return 0
    fi

    kind="$(_civitai_downloader_kind)"
    if [ "$kind" = none ]; then
        echo "❌ $var is set but no CivitAI downloader is available; skipping"
        _civitai_warn_hook "$var: no CivitAI downloader on this pod"
        return 0
    fi

    dest="${PERSIST_ROOT:-/workspace/ComfyUI}/models/$subdir"
    mkdir -p "$dest" || return 0

    IFS=',' read -r -a items <<< "$ids"
    for id in "${items[@]}"; do
        id="${id//[[:space:]]/}"
        [ -n "$id" ] || continue

        if ! [[ "$id" =~ ^[0-9]+$ ]] \
            && ! [[ "$id" =~ ^(model|version):[0-9]+$ ]] \
            && ! [[ "$id" =~ ^(urn:air:|civitai:) ]] \
            && ! [[ "$id" =~ ^https?://([a-z0-9-]+\.)*civitai\.(com|green|red)/ ]]; then
            echo "❌ $var: '$id' is not a CivitAI version ID, AIR or CivitAI URL; skipping"
            _civitai_warn_hook "$var: '$id' is not a CivitAI version ID, AIR or CivitAI URL"
            continue
        fi
        if ! [[ "$id" =~ ^[0-9]+$ ]] && [ "$kind" != runtime ]; then
            echo "❌ $var: '$id' needs the runtime CivitAI downloader, which this pod does not have"
            echo "   (only the base image's older copy is here: it takes a bare version ID)"
            _civitai_warn_hook "$var: '$id' needs the runtime CivitAI downloader; use a bare version ID"
            continue
        fi

        if [ "$kind" = runtime ] && [ -z "$prepared" ]; then
            if prepare_civitai_downloader; then prepared=ok; else prepared=failed; fi
        fi
        if [ "$prepared" = failed ]; then
            echo "❌ CivitAI $label $id: the runtime downloader is not usable; skipping"
            _civitai_warn_hook "CivitAI $label $id skipped: runtime downloader unusable"
            continue
        fi

        echo "🚀 CivitAI $label $id -> $dest"
        if [ "$kind" = runtime ]; then
            "${CIVITAI_PYTHON:-python3}" "$CIVITAI_DOWNLOADER" -m "$id" -o "$dest"
        else
            download_with_aria.py -m "$id" -o "$dest"
        fi || {
            echo "❌ CivitAI $label $id failed to download"
            _civitai_warn_hook "CivitAI $label $id failed to download"
        }
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
