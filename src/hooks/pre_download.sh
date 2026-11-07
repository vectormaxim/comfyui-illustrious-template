#!/usr/bin/env bash
# Sourced by comfyui-runtime/src/start.sh immediately before the provisioner
# (CONTRACTS.md section 7). Sourced, not executed: `return`, never `exit`.

# ---------------------------------------------------------------------------
# 1. Persist the lazily-fetched annotator weights.
#
# comfyui_controlnet_aux downloads DWPose (yolox_l.onnx +
# dw-ll_ucoco_384_bs5.torchscript.pt) into its own package directory, and
# DepthAnything pulls depth_anything_vitl14.pth through transformers into the
# HF cache. Neither location is on the volume -- custom_nodes/ is not symlinked
# and $HOME is container-local -- so roughly 1.7 GB re-downloads on every cold
# boot. Those three basenames sit on template.json's auto_download list, which
# suppresses the boot report's missing-model warning, so the re-download is
# silent as well as slow. Nodes 277, 321 and 336 are live in the shipped
# workflows, so it fires on the first queued prompt every time.
#
# Both paths stay inside $PERSIST_ROOT/models: already the volume-backed model
# store, so this persists the weights without adding a new top-level directory
# to the frozen $PERSIST_ROOT layout.
# ---------------------------------------------------------------------------
export AUX_ANNOTATOR_CKPTS_PATH="${PERSIST_ROOT}/models/annotator"
export HF_HOME="${PERSIST_ROOT}/models/.huggingface"
mkdir -p "$AUX_ANNOTATOR_CKPTS_PATH" "$HF_HOME" 2>/dev/null || true
echo "🔗 annotator weights persist to ${AUX_ANNOTATOR_CKPTS_PATH}"
echo "🔗 HF cache persists to ${HF_HOME}"

# ---------------------------------------------------------------------------
# 2. Retry this template's own custom-node clones.
#
# Observed on a live pod: anonymous git-over-HTTPS to github.com from a shared
# RunPod IP fails most of the time, with
#
#     fatal: could not read Username for 'https://github.com': ...
#     fatal: expected flush after ref listing
#
# A controlled test cloned the same public repo 6 times and succeeded once.
# The runtime's clone loop makes exactly one attempt per pack and only warns on
# failure, so the pod comes up "successfully" with node types missing --
# ComfyUI-HipRegionMask among them, which node 322 (HIPS/GROIN pose branch) uses
# and which ships LIVE. This hook runs after that loop, so it is the right place
# to give the template's own packs another try.
#
# Bounded: 6 attempts, 3s apart, --max-time on each, and never fatal.
# ---------------------------------------------------------------------------
_retry_missing_packs() {
    local dir url name attempt
    dir="${CUSTOM_NODES_DIR:-/ComfyUI/custom_nodes}"
    [ -d "$dir" ] || return 0

    while IFS= read -r url; do
        [ -n "$url" ] || continue
        url="${url%%|*}"                      # strip a "|<sha>" / "|force" pin
        name="$(basename "$url" .git)"
        [ -d "$dir/$name/.git" ] && continue

        echo "🔁 $name is missing after the clone loop; retrying..."
        for attempt in 1 2 3 4 5 6; do
            rm -rf "${dir:?}/$name"
            if GIT_TERMINAL_PROMPT=0 timeout 120 git clone --depth=1 -q "$url" "$dir/$name" 2>/dev/null; then
                echo "✅ $name cloned on retry $attempt"
                if [ -f "$dir/$name/requirements.txt" ]; then
                    timeout 300 pip install -q -r "$dir/$name/requirements.txt" \
                        || echo "⚠️  $name requirements install failed"
                fi
                break
            fi
            sleep 3
        done
        [ -d "$dir/$name/.git" ] || echo "❌ $name still missing after 6 retries; its nodes will be absent"
    done < <(python3 -c "
import json
try:
    t = json.load(open('${TEMPLATE_DIR:-/comfyui-illustrious-template}/template.json'))
    for r in (t.get('custom_nodes') or {}).get('repos', []):
        print(r)
except Exception:
    pass
" 2>/dev/null)
}
_retry_missing_packs

# ---------------------------------------------------------------------------
# 3. Print progress lines for the CivitAI downloads.
#
# The runtime's CivitAI downloader (aria2c, vendor/civitai_downloader) prints one line when a
# file starts and one when it ends, and nothing in between: a 7 GB checkpoint is silent for ~4
# minutes, so ishikawa's Studio card cannot show a bar. aria2c writes the file's pieces in
# place under a hidden staging name, `.civitai-<file id>-<key>.part`, in the model folder. With
# --file-allocation=none and 8 splits its apparent size jumps to nearly the full size at once,
# but its ALLOCATED size (st_blocks) grows with the bytes really written. This watcher prints
# that, every few seconds, as
#
#     [civitai-progress] t=<epoch> file=.civitai-<file id>-<key>.part bytes=<allocated bytes>
#
# into the boot log, which ishikawa reads over Jupyter (app/bootlog.py). It touches nothing:
# read-only stat calls, started detached (`( ... & )`, so a `wait` in start.sh cannot hold on to
# it), and it ends when the staging files are gone (the downloads finished), after 15 minutes if none ever
# appeared, or after an hour.
# Hooks run on every boot, so a restart starts a new one; none is left behind.
# ---------------------------------------------------------------------------
_civitai_progress_watch() {
    local every="${CIVITAI_PROGRESS_INTERVAL:-5}" deadline give_up f found seen=0 idle=0
    deadline=$(( $(date +%s) + 3600 ))
    give_up=$(( $(date +%s) + 900 ))   # no CivitAI download ever started (none was asked for): stop waiting
    while [ "$(date +%s)" -lt "$deadline" ]; do
        found=0
        for f in "${PERSIST_ROOT}"/models/*/.civitai-*.part; do
            [ -e "$f" ] || continue
            found=1
            echo "[civitai-progress] t=$(date +%s) file=$(basename "$f") bytes=$(( $(stat -c %b "$f") * $(stat -c %B "$f") ))"
        done
        if [ "$found" = 1 ]; then
            seen=1; idle=0
        elif [ "$seen" = 1 ]; then
            idle=$(( idle + 1 ))
            [ "$idle" -ge 2 ] && break
        fi
        [ "$seen" = 0 ] && [ "$(date +%s)" -ge "$give_up" ] && break
        sleep "$every"
    done
}
( _civitai_progress_watch & )
