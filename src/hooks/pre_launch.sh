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
