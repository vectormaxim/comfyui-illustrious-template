# syntax=docker/dockerfile:1
# ============================================================================
# comfyui-illustrious-template image, built FROM the shared base
# (hearmeman/comfyui-base, comfyui-runtime/base/Dockerfile).
#
# The base owns: python 3.12 + /opt/venv (on PATH), the pinned torch trio +
# /torch-constraint.txt applied via ENV PIP_CONSTRAINT, pip tooling, pyyaml/
# gdown/triton/jupyterlab, huggingface_hub + hf_xet, opencv-python, ComfyUI
# pinned at COMFYUI_REF, /comfyui-approved-ref, ComfyUI-Manager, both
# SageAttention wheels under /opt/sage/, the CivitAI downloader, and ENV
# ORT_INDEX_ARGS (the per-CUDA-variant onnxruntime index nuance).
#
# This layer adds ONLY the SDXL/Illustrious detailer-pipeline node set, the
# onnxruntime-gpu reassert, and the entrypoint. BASE_IMAGE is passed by CI
# from pins.json's "base_image"; the default below mirrors that pin so a
# plain build stays coherent.
#
# Node-type gate (17 non-core types across the 1 shipped workflow, verified
# by cloning each pack at HEAD and grepping its actual node registration,
# 2026-08-21, updated 2026-08-22 for the XY-plot base-gen rework): ltdrdata/ComfyUI-Impact-Pack
# registers BboxDetectorSEGS, SegmDetectorSEGS, DetailerForEachDebugPipe and
# ToBasicPipe (branch "Main", capital M); ltdrdata/ComfyUI-Impact-Subpack
# registers UltralyticsDetectorProvider — a separate companion repo, NOT part
# of Impact-Pack itself, assumed present alongside it; Fannovel16/comfyui_controlnet_aux
# registers CannyEdgePreprocessor and DepthAnythingPreprocessor (branch main;
# DepthAnythingPreprocessor no longer needs a models_registry entry — current
# HEAD routes depth_anything_vitl14.pth through a HF `transformers`
# AutoModelForDepthEstimation call, cached in the normal HF cache, so that
# basename is only in template.json's auto_download list, to suppress the
# boot report's missing-model warning); rgthree/rgthree-comfy registers
# "Power Puter (rgthree)", "Any Switch (rgthree)", "Bookmark (rgthree)" (frontend-only JS, no
# Python class) and "Fast Groups Bypasser (rgthree)"; ssitu/ComfyUI_UltimateSDUpscale
# registers UltimateSDUpscaleCustomSample alongside the stock
# UltimateSDUpscale/UltimateSDUpscaleNoUpscale/UltimateSDUpscaleGuider (in
# usdu_nodes.py — same repo, not a fork); geroldmeisinger/ComfyUI-outputlists-combiner (branch main)
# registers XyzGridPlot, CombineOutputLists, FormattedString, JSONOutputList,
# NumberOutputList and StringOutputList — the XY-plot grid (LoRA strength x
# expression prompt) added to the base-gen stage; pythongosssss/ComfyUI-Custom-Scripts
# (branch main, no requirements.txt) registers "ShowText|pysssss";
# chrisgoringe/cg-image-filter (branch main, no requirements.txt) registers
# "Image Filter", "Mask Image Filter", "Text Image Filter" and the helper
# "Image List From Batch" -- the pause-and-pick stage. NOTE: no SHIPPED
# workflow uses these yet; the pack is baked so a batch-pick workflow can be
# opened without a manual clone (the node draws a popup, and its `timeout` /
# `ontimeout` widgets mean a paused run auto-resolves instead of wedging the
# queue). Everything
# else the workflow uses (CLIPTextEncode, CLIPSetLastLayer,
# CheckpointLoaderSimple, ControlNetLoader, ControlNetApplyAdvanced,
# EmptyLatentImage, KSamplerAdvanced, LoadImage, LoraLoader, PreviewImage,
# SaveImage, VAEDecode, VAEEncode, UpscaleModelLoader, Note) is ComfyUI core.
# Cache-busters, one per pack (CLAUDE.md section 8): docker_layer_caching
# serves the cached clone layer forever otherwise, so a rebuild silently
# reships whatever HEAD the FIRST build happened to resolve. Each ADD
# re-reads the GitHub API every build; any pack moving invalidates the whole
# loop below.

ARG BASE_IMAGE=hearmeman/comfyui-base:cu130-comfy0.32.0-torch2.11.0
FROM ${BASE_IMAGE}

ADD https://api.github.com/repos/ltdrdata/ComfyUI-Impact-Pack/git/refs/heads/Main /pack-refs/ComfyUI-Impact-Pack.json
ADD https://api.github.com/repos/ltdrdata/ComfyUI-Impact-Subpack/git/refs/heads/main /pack-refs/ComfyUI-Impact-Subpack.json
ADD https://api.github.com/repos/Fannovel16/comfyui_controlnet_aux/git/refs/heads/main /pack-refs/comfyui_controlnet_aux.json
ADD https://api.github.com/repos/rgthree/rgthree-comfy/git/refs/heads/main /pack-refs/rgthree-comfy.json
ADD https://api.github.com/repos/ssitu/ComfyUI_UltimateSDUpscale/git/refs/heads/main /pack-refs/ComfyUI_UltimateSDUpscale.json
ADD https://api.github.com/repos/geroldmeisinger/ComfyUI-outputlists-combiner/git/refs/heads/main /pack-refs/ComfyUI-outputlists-combiner.json
ADD https://api.github.com/repos/pythongosssss/ComfyUI-Custom-Scripts/git/refs/heads/main /pack-refs/ComfyUI-Custom-Scripts.json
ADD https://api.github.com/repos/chrisgoringe/cg-image-filter/git/refs/heads/main /pack-refs/cg-image-filter.json
# PIP_CONSTRAINT (base-owned) applies to every requirements install below.
# --no-build-isolation is required here: ComfyUI-Impact-Pack's requirements.txt
# pulls `git+https://github.com/facebookresearch/sam2`, whose pyproject.toml
# build-system declares `torch>=2.5.1`. In an isolated build env pip tries to
# install a FRESH torch to satisfy that, which collides with PIP_CONSTRAINT's
# pinned torch==2.11.0+cu130 (ResolutionImpossible) and silently fails the
# entire `pip install -r requirements.txt` line for that pack -- not just the
# sam2 line, all of it, including piexif, which Impact-Pack's __init__.py
# imports unconditionally, so the whole pack fails to load at runtime with no
# build-time error (the outer `for` loop has no `set -e`, by design, so one
# pack's dependency failure doesn't abort every other pack's install).
# --no-build-isolation makes sam2's build use the already-installed,
# constraint-pinned torch instead of resolving its own; harmless for the other
# packs' requirements, which install from prebuilt wheels.
RUN for repo in \
    https://github.com/ltdrdata/ComfyUI-Impact-Pack.git \
    https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git \
    https://github.com/Fannovel16/comfyui_controlnet_aux.git \
    https://github.com/rgthree/rgthree-comfy.git \
    https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git \
    https://github.com/geroldmeisinger/ComfyUI-outputlists-combiner.git \
    https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git \
    https://github.com/chrisgoringe/cg-image-filter.git; \
    do \
        cd /ComfyUI/custom_nodes; \
        repo_dir=$(basename "$repo" .git); \
        if [ "$repo" = "https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git" ]; then \
            git clone --recursive "$repo"; \
        else \
            git clone "$repo"; \
        fi; \
        if [ -f "/ComfyUI/custom_nodes/$repo_dir/requirements.txt" ]; then \
            pip install --no-build-isolation -r "/ComfyUI/custom_nodes/$repo_dir/requirements.txt"; \
        fi; \
        if [ -f "/ComfyUI/custom_nodes/$repo_dir/install.py" ]; then \
            python "/ComfyUI/custom_nodes/$repo_dir/install.py"; \
        fi; \
    done

# Force GPU onnxruntime. comfyui_controlnet_aux and Impact-Pack/Subpack both
# pull in plain `onnxruntime` (CPU) via their requirements, which shadows the
# GPU install because both provide the same `onnxruntime` module and last
# install wins. This reassert therefore comes AFTER the clone loop, and no
# later RUN may pip install anything (comfyui-runtime base Dockerfile,
# onnxruntime ordering trap). ORT_INDEX_ARGS is base-owned data: the Azure
# onnxruntime-cuda-12 index on cu128, empty on cu130 where PyPI's
# onnxruntime-gpu links CUDA 13.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip uninstall -y onnxruntime onnxruntime-gpu 2>/dev/null || true; \
    pip install onnxruntime-gpu $ORT_INDEX_ARGS

# Build-time gate: the shipped image must expose the CUDA provider. Provider
# enumeration is import-only and works with no GPU present, so this fails the
# CI build, not a customer pod. CI greps this Dockerfile for the
# CUDAExecutionProvider assertion and for the no-pip-install-after-it rule.
RUN python3 -c "import onnxruntime; p = onnxruntime.get_available_providers(); assert 'CUDAExecutionProvider' in p, p; print('onnxruntime providers OK:', p)"

# Build-time gate: every baked pack must actually import. The clone loop above
# deliberately has no `set -e`, so a failed `git clone` or a failed
# `pip install -r requirements.txt` leaves a green build and a pack that dies
# at import -- surfacing as a red node in a customer's pod with nothing in the
# build log. `--quick-test-for-ci` runs ComfyUI's own node-loading path and
# exits non-zero if any pack fails to import, turning that into a build
# failure here. `--cpu` because CI builders have no GPU; node import does not
# need one. Not a pip install, so it does not violate the ordering rule above.
RUN cd /ComfyUI && python main.py --quick-test-for-ci --cpu

COPY src/start_script.sh /start_script.sh
RUN chmod +x /start_script.sh

CMD ["/start_script.sh"]
