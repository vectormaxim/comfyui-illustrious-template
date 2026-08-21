# Illustrious SDXL Detailer Pipeline, ComfyUI on RunPod

Created by HearmemanAI. Something not working, or a question about the workflow? Ask in
help-and-support on [my Discord](https://discord.gg/ZVWVhT43GW). That is the only place I do
support, and it is also where new releases are announced.

One SDXL/Illustrious img2img pipeline: dual-ControlNet (canny + depth) base generation, then a
cascade of Impact-Pack detailer passes (face, eyes, mouth, hands, body), an Ultimate SD Upscale
pass, and a final detailer pass on the upscaled image.

## Before you deploy

Click Edit Template and open the environment variables tab. Set `download_illustrious` to `true`.
It is off by default. A pod with the flag off boots a working but empty ComfyUI: the workflow
opens with blank loader dropdowns and looks broken.

This template ships **no checkpoint and no LoRAs of its own**. The checkpoint slot, every LoRA
slot, the final upscale model, and one NSFW body detector all carry the same placeholder,
`Your_Character_LoRA_Here.safetensors`. Bring your own checkpoint/LoRAs via `CIVITAI_CHECKPOINTS` /
`CIVITAI_LORAS` (see below); upload the upscale model and the detector by hand, to
`models/upscale_models/` and `models/ultralytics/bbox/`. Either way, pick your file from each
loader's dropdown once it has landed. The two `LoadImage` nodes work the same way: upload your own
reference images and point the loaders at them.

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

Open the Workflows tab in ComfyUI. The workflow carries notes in the graph telling you what each
group of nodes does. The pod also writes three notes into the top of that same list on first boot:
Welcome, Adding Models, and Troubleshooting.

[My other templates](https://docs.google.com/spreadsheets/d/1NfbfZLzE9GIAD5B_y6xjK1IdW95c14oS1JuIG9QihL8/edit)
