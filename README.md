# Illustrious SDXL Detailer Pipeline, ComfyUI on RunPod

SDXL/Illustrious generation followed by a cascade of Impact-Pack detailer passes — face, eyes,
mouth, hands, body, hips — then an Ultimate SD Upscale pass and a final detailer pass on the
upscaled image. Four workflows ship — three are the same job at different sizes, and one adds a
batch-and-pick step; see [Which workflow](#which-workflow).

## Before you deploy

Click Edit Template and open the environment variables tab. Set `download_illustrious` to `true`.
It is off by default. A pod with the flag off boots a working but empty ComfyUI: the workflow
opens with blank loader dropdowns and looks broken.

This template ships **no checkpoint and no LoRAs of its own** — those are the only two things you
have to supply. Both slots carry the placeholder `Your_Character_LoRA_Here.safetensors`; bring your
own via `CIVITAI_CHECKPOINTS` / `CIVITAI_LORAS` (see below), then pick your file from each loader's
dropdown once it has landed.

Everything else is fetched for you: the ControlNets, all the detector models, and the
`4x-AnimeSharp` upscale model come down with `download_illustrious`, and the DWPose and
DepthAnything weights are pulled on first use and cached on the network volume. The `LoadImage`
nodes are the exception — upload your own reference images and point the loaders at them.

FYI: this template is built for CUDA 13.0 and above.

## Environment variables

| Variable | Default | What it does |
|---|---|---|
| `download_illustrious` | false | Downloads the shared models (ControlNets, upscaler, detector models) and copies the workflow |
| `download_anima` | false | Copies the Anima keeper-filter detailer workflow and downloads its text encoder (Qwen3 0.6B), VAE (Qwen-Image), detectors and upscaler. The Anima diffusion model itself comes from `CIVITAI_DIFFUSION_MODELS` |
| `CIVITAI_CHECKPOINTS` | empty | Comma-separated CivitAI version IDs, downloaded to `models/checkpoints`. This is how you get the SDXL/Illustrious checkpoint. |
| `CIVITAI_DIFFUSION_MODELS` | empty | Comma-separated CivitAI version IDs, downloaded to `models/diffusion_models`. This is how you get an Anima model: `2983680` is WAI-ANIMA v1.0. Needs `civitai_token`. |
| `CIVITAI_LORAS` | empty | Comma-separated CivitAI version IDs, downloaded to `models/loras`. This is how you get your character/style LoRAs. |
| `civitai_token` | empty | Your CivitAI API token. Also feeds Civicomfy (see below), so leave its in-app API Key field blank. `CIVITAI_TOKEN` and `CIVITAI_API_KEY` work too. |
| `HF_TOKEN` | empty | Optional. Raises your Hugging Face rate limit, which makes a first boot less likely to stall. |

## Once it is up

Click Connect, then open port 8188 for ComfyUI or port 8888 for JupyterLab. The boot log is at
`/workspace/comfyui.log`.

Open the Workflows tab in ComfyUI and look in the `Illustrious` folder. The pod also writes three
notes into the top of that list on first boot: Welcome, Adding Models, and Troubleshooting.

The two older workflows carry notes in the graph explaining each group of nodes. The subgraph
workflow does not — its stages are named and self-contained, and the walkthrough below replaces
them.

### Downloading models on the fly

Civicomfy is installed, for pulling checkpoints and LoRAs from CivitAI mid-session without
restarting the pod. Open it from the **Civicomfy** button at the top right.

**Do not type your API key into its settings panel.** The key is already supplied from the pod
environment and the field is meant to stay empty: Civicomfy checks the settings field first and the
`CIVITAI_API_KEY` environment variable second, so anything typed there overrides your pod env for
that browser. Whichever of `civitai_token`, `CIVITAI_TOKEN` or `CIVITAI_API_KEY` you set is mapped
onto the name Civicomfy reads at boot; the log line `🔑 Civicomfy will authenticate from the
environment` confirms it.

Leave **Global Download Root** empty as well. Empty means Civicomfy uses ComfyUI's normal model
paths, which this template symlinks onto the network volume, so downloads persist across restarts
and appear in the loader nodes straight away. Setting a global root writes to
`custom_nodes/Civicomfy/root_settings.json`, which is container-local and lost on the next restart.

The rest of its settings live in your browser, not on the pod, so set them once per machine:

| Setting | Default | Worth knowing |
|---|---|---|
| Hide R-rated (Mature) images in search | off | Blurs mature previews in search results; click one to reveal it. Turn this on if you browse CivitAI with someone looking over your shoulder. |
| NSFW Blur Threshold (`nsfwLevel`) | 4 | CivitAI's own 0-128 rating scale, and the point at which a preview gets blurred. Lower blurs more aggressively, higher lets more through; `0` blurs essentially everything. Independent of the checkbox above, which only covers the R-rated tier. |
| Default Model Type | Checkpoint | Where a one-click download lands when the model page is ambiguous. Set it to **Lora** if you mostly pull LoRAs. |
| Switch to Status tab after starting download | off | Jumps to the progress view on each download. |

Downloads keep running in the background while you queue prompts; three run concurrently.

### Which workflow

Four ship in the `Illustrious` folder. The first three do the same job at
different sizes; the fourth adds a pick step:

| Workflow | Nodes | Notes |
|---|---|---|
| `Illustrious_Detailer_Subgraphs` | 51 | **Start here.** Each detailer stage is one node built from subgraphs. No rgthree, so "Nodes 2.0" is safe. |
| `Illustrious_Detailer_Pipeline_Ultimate` | 156 | The flat version. Same features, everything on one canvas. |
| `Illustrious_Detailer_Pipeline` | 207 | The original reference build, kept deliberately flat, plus an XY-plot stage. |
| `Illustrious_Detailer_Filter` | 53 | `Subgraphs` plus a **pick step**: generates a batch of 10, pops up a window, and only the images you pick go through the detailers. |

### Driving the subgraph workflow

**Set the two placeholders first.** It will not run until you do — both read
`Your_Character_LoRA_Here.safetensors`:

- `CHECKPOINT -- set once` → your SDXL/Illustrious checkpoint
- `LoRA 1 (all stages)` → your character LoRA, or bypass it with **Ctrl+B** if
  you do not want one. `LoRA 2` / `LoRA 3` are bypassed spares for stacking.

**Write the prompt.** Five boxes, `Prompt 1`–`Prompt 5`, joined with `", "` in
order; empty ones are skipped, so use them as categories — quality, character,
outfit, pose, scene. `Negative prompt` is a single box feeding base generation
and every detailer. The joined result is shown in `Merged prompt`, which is
exactly what the sampler receives.

**Turn stages on and off with Ctrl+B.** Each stage is one node, and a bypassed
stage passes its image straight through, so any combination is valid. On by
default: `FACE (bbox)`, `FACE (segm)`, `HIPS/GROIN (bbox)`. Off: `EYES`,
`MOUTH`, `HANDS`, `BREASTS`, the other HIPS variants, and both `POST-UPSCALE`
stages.

The four `HIPS/GROIN` stages are alternatives — **enable one**. `(bbox)` uses
an NSFW detector, `(pose)` derives the region from the pose skeleton and works
over clothing, `(manual mask)` takes an image you paint in MaskEditor.

**Tune the detailers in one place.** Double-click a stage to open it: you get
its detector and a nested `Detail regions (shared)` node. Double-click that,
and the sampler settings inside are **shared by every stage** — change
`denoise` once and all of them follow. Defaults are 30 steps, cfg 8,
euler/normal, denoise 0.5, guide_size 512. What stays per-stage, on each
stage's own canvas, is the detector model and its `threshold`.

**Optional extras**, all bypassed:

- *Upscale* — un-bypass `upscale model` **and** `UPSCALE (Ultimate SD Upscale)`
  together (1.5x at denoise 0.2), then optionally the `POST-UPSCALE` stages.
- *ControlNet* — un-bypass the four OpenPose nodes and load a reference image.
- *LLM prompt helper* — needs `OPENROUTER_API_KEY` in the pod environment. It
  is deliberately not wired into the prompt chain: it prints Danbooru tags for
  you to copy into a Prompt box, so a missing key can never break a run.

**Outputs.** Seed control is `randomize`, so every run differs. Two images are
saved: `00_base` (before any detailing) and `99_FINAL` (the end of the chain,
whatever stages are on). Comparing those two shows what the detailers did; the
crop previews inside each stage show before/after per detected region.

One extra knob: `FACE LoRA` feeds only the face stages, through their own
pipe. Set it if you want a style LoRA on faces alone.

### Picking from a batch

`Illustrious_Detailer_Filter` is `Subgraphs` with one extra stage spliced in
between the base generation and the detailers:

    decode base -> Image Filter -> Image List From Batch -> FACE (bbox) -> ...

`Resolution` is set to a batch of 10. When the run reaches `PICK KEEPERS`, a
popup appears with the ten images. Click the ones worth keeping (their border
turns green) and press **Send** — only those go through the detailer cascade,
so you are not paying for detailing on images you were going to throw away.
Hover an image and press **Space** to zoom it fullscreen, arrow keys to move
between them, **Escape** to cancel the run.

Two knobs on the `PICK KEEPERS` node:

- `pick_list` — leave empty for the popup. Put a comma-separated list of
  indices in it (e.g. `0,3`) and those get selected automatically with no
  popup, which is how you turn the pause off without rewiring anything. Zero
  indexed, or set `pick_list_start` to 1 to count from one.
- `timeout` / `ontimeout` — 600 seconds by default, then `send none`, which
  cancels. A forgotten popup times out instead of holding the queue open.

`Image List From Batch` after it is **not optional**: Impact-Pack's detailers
reject image batches outright (`DetailerForEach does not allow image batches`),
so the picks have to become a list, which is also what makes the chain run once
per picked image.

### "Nodes 2.0" and the older workflows

ComfyUI's new node rendering is opt-in from the app menu. It has documented
breakage in two rgthree nodes: **Fast Groups Bypasser** and **Power Lora
Loader** inside collapsed subgraphs.

`Illustrious_Detailer_Subgraphs` and `Illustrious_Detailer_Filter` use **no
rgthree nodes at all** and are safe to run with Nodes 2.0 on. The other two are not: the Ultimate pipeline has 11
rgthree nodes and the reference pipeline 18, both including the group bypasser
that switches their detailer stages on and off. Keep Nodes 2.0 off for those —
if group toggles stop responding or a loader renders blank, that is why.
