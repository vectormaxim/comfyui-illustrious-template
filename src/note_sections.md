## What is in this template

This template runs a single SDXL/Illustrious img2img pipeline: base
generation with dual ControlNet guidance (canny + depth), then a cascade
of Impact-Pack detailer passes (face, eyes, mouth, hands, body), an
Ultimate SD Upscale pass, and a final detailer pass on the upscaled
image.

The flag is off by default. Set `download_illustrious` to `true` on the
template to pull in the shared models (ControlNets, upscaler, detector
models) and copy the workflow.

There is also an Anima version of the keeper-filter detailer workflow
(`download_anima`, also off by default). Anima is not SDXL: it loads a
diffusion model, a Qwen3 0.6B text encoder and the Qwen-Image VAE as three
separate files. The flag fetches the text encoder, the VAE and the detector
and upscale models; the diffusion model (for example WAI-ANIMA) is yours to
supply in `models/diffusion_models/`. `CIVITAI_CHECKPOINTS` downloads into
`models/checkpoints/`, which the Anima loader does not list, so move the file
across. SDXL LoRAs and ControlNets do not work with Anima.

## Bring your own checkpoint and LoRAs

This template ships no checkpoint and no character
LoRAs of its own: the base model, every LoRA slot, the final upscale
model, and one NSFW body detector all carry the same placeholder,
`Your_Character_LoRA_Here.safetensors` (or `bbox/Your_Character_LoRA_Here.safetensors`
for the detector slot). That is deliberate. These are exactly the kind
of files a checkpoint's, LoRA's or detector's own license usually
restricts from being rehosted, so I do not bundle them.

Get your checkpoint and LoRAs via `CIVITAI_CHECKPOINTS` and
`CIVITAI_LORAS` (see below), or upload manually to `models/checkpoints/`
and `models/loras/`. The upscale model goes in `models/upscale_models/`
and the NSFW detector in `models/ultralytics/bbox/`, both by hand (there
is no CivitAI ID flag for those categories). Either way, after a file
lands you still open the matching loader in ComfyUI and pick it from the
dropdown, replacing the placeholder text. The pod cannot do this last
step for you: it does not know which of your downloaded files belongs in
which slot.

The two `LoadImage` nodes are the same story: `Your_Reference_Image_Here.png`
drives the base generation and both ControlNet preprocessors, and
`Your_Secondary_Reference_Image_Here.png` feeds a second img2img pass.
Upload your own images and point both loaders at them.

## Settings you can change

Set these in the environment variables tab. Click Edit Template before
you deploy, or edit the variables on this pod and restart it.

| Variable | Default | What it does |
|---|---|---|
| download_illustrious | false | Downloads the shared models (ControlNets, upscaler, detector models) and copies the Illustrious detailer workflow. |
| download_anima | false | Downloads the Anima text encoder and VAE plus the detector and upscale models, and copies the Anima keeper-filter detailer workflow. |
| CIVITAI_CHECKPOINTS | unset | Comma-separated CivitAI model version IDs to download into models/checkpoints/. This is how you get the SDXL/Illustrious checkpoint itself. |
| CIVITAI_LORAS | unset | Comma-separated CivitAI model version IDs to download into models/loras/. This is how you get your character/style LoRAs. |
| civitai_token | unset | Your CivitAI API token. CIVITAI_TOKEN and CIVITAI_API_KEY are also accepted. |
| HF_TOKEN | unset | Your Hugging Face token. Recommended: unauthenticated downloads get rate-limited on a fresh pod. |

## Missing models

If a workflow references a model that is not in the registry (your
checkpoint, your LoRAs, anything you supply yourself), the boot log
prints a warning listing the missing basenames. That is expected for
every fresh deploy of this template until you supply your own files.
