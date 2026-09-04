# Illustrious SDXL Detailer Pipeline, ComfyUI on RunPod

SDXL/Illustrious generation followed by a cascade of Impact-Pack detailer passes — face, eyes,
mouth, hands, body, hips — then an Ultimate SD Upscale pass and a final detailer pass on the
upscaled image. Three workflows ship, same job at different sizes; see
[Which workflow](#which-workflow).

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
| `CIVITAI_CHECKPOINTS` | empty | Comma-separated CivitAI version IDs, downloaded to `models/checkpoints`. This is how you get the SDXL/Illustrious checkpoint. |
| `CIVITAI_LORAS` | empty | Comma-separated CivitAI version IDs, downloaded to `models/loras`. This is how you get your character/style LoRAs. |
| `civitai_token` | empty | Your CivitAI API token |
| `HF_TOKEN` | empty | Optional. Raises your Hugging Face rate limit, which makes a first boot less likely to stall. |

## Once it is up

Click Connect, then open port 8188 for ComfyUI or port 8888 for JupyterLab. The boot log is at
`/workspace/comfyui.log`.

Open the Workflows tab in ComfyUI and look in the `Illustrious` folder. The pod also writes three
notes into the top of that list on first boot: Welcome, Adding Models, and Troubleshooting.

The two older workflows carry notes in the graph explaining each group of nodes. The subgraph
workflow does not — its stages are named and self-contained, and the walkthrough below replaces
them.

### Which workflow

Three ship in the `Illustrious` folder. They do the same job at different
sizes:

| Workflow | Nodes | Notes |
|---|---|---|
| `Illustrious_Detailer_Subgraphs` | 51 | **Start here.** Each detailer stage is one node built from subgraphs. No rgthree, so "Nodes 2.0" is safe. |
| `Illustrious_Detailer_Pipeline_Ultimate` | 156 | The flat version. Same features, everything on one canvas. |
| `Illustrious_Detailer_Pipeline` | 207 | The original reference build, kept deliberately flat, plus an XY-plot stage. |

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

### "Nodes 2.0" and the older workflows

ComfyUI's new node rendering is opt-in from the app menu. It has documented
breakage in two rgthree nodes: **Fast Groups Bypasser** and **Power Lora
Loader** inside collapsed subgraphs.

`Illustrious_Detailer_Subgraphs` uses **no rgthree nodes at all** and is safe
to run with Nodes 2.0 on. The other two are not: the Ultimate pipeline has 11
rgthree nodes and the reference pipeline 18, both including the group bypasser
that switches their detailer stages on and off. Keep Nodes 2.0 off for those —
if group toggles stop responding or a loader renders blank, that is why.
