# CLAUDE.md — comfyui-illustrious-template

Orientation for agents working in this repo. The authority for the runtime
contracts is `CONTRACTS.md` in the runtime repo
(https://github.com/Hearmeman24/comfyui-runtime, at the `runtime_ref` pinned in
`pins.json` — currently `stable`); this file says what is true *here* and points
there rather than restating it, because duplicated contracts drift.

`tools/validate_models.py` already keeps a checkout of that repo for validation.
`python3 -c "import sys; sys.path.insert(0,'tools'); from validate_models import
runtime_dir; print(runtime_dir())"` prints where, and `CONTRACTS.md` /
`ARCHITECTURE.md` are readable there without cloning anything.

---

## 1. Know which tier you are changing

From the runtime's `ARCHITECTURE.md`. Blast radius differs enormously, and
**you should prefer the lowest tier that solves the problem.**

| Tier | What | How it ships | Reaches |
|---|---|---|---|
| 1. Runtime | the runtime repo | promote by moving `stable` | all templates, next pod boot |
| 2. Template runtime files | `template.json`, `pins.json`, `workflows/**`, `src/` except `start_script.sh` | merge to `master` | this template, **next pod boot** |
| 3. Image | `Dockerfile`, `src/start_script.sh` | merge, then a new image must be built and published | only after the pod is redeployed |

A tier-2 merge reaches pods still running the *old* image. Removing something
those pods depend on breaks them until a new image is live — the runtime docs
record `wan` nearly stripping packs from every running pod this way. **If a
change spans both tiers, ship them together.**

Most work here is tier 2. Reach for tier 3 only when §2 says you must.

## 2. Bake a custom node, or provision it at boot?

Not a style choice. The boot-time clone loop (runtime `src/start.sh`, "custom-node
clone loop") runs:

```bash
git clone "$url" "$dir"                 # plain: no --recursive
pip install -r "$dir/requirements.txt"  # plain: no --no-build-isolation, backgrounded
```

**Provision at boot** (add to `template.json` → `custom_nodes.repos`, pinned as
`<url>|<40-hex-sha>`) when the pack needs neither flag. Dependency-free packs are
the clear case: `cg-image-filter` is 4.5MB with no `requirements.txt` and no
`install.py`, so it costs nothing at boot and updates without republishing an image.

**Bake in the Dockerfile** when the pack needs something the boot loop cannot
express:

| Pack | Why it must stay baked |
|---|---|
| `ComfyUI-Impact-Pack` | `requirements.txt` pulls `sam2`, whose build declares `torch>=2.5.1`. Without `--no-build-isolation` pip resolves a fresh torch against `PIP_CONSTRAINT`'s pinned `torch==2.11.0+cu130` → ResolutionImpossible, failing the *whole* requirements line including `piexif`, which `__init__.py` imports unconditionally |
| `ComfyUI_UltimateSDUpscale` | needs `git clone --recursive` for submodules |

The loop has no `set -e`, by design, so a pack whose install fails this way does
not abort the boot — you get a pod where the node silently isn't there. That
failure mode is why this decision matters more than it looks.

`CONTRACTS.md` §5 states the same rule for the runtime's shared list: favour
packs with no dependencies; anything heavy or version-sensitive belongs in a
template's own list or the base image.

## 3. CI does not exist here

`.circleci/config.yml` was inherited from the upstream Hearmeman template in the
initial import and has **never run for this repo** — 0 webhooks, 0 check-runs, 0
commit statuses, and `Project not found` from the CircleCI API. Its `docker-hub`
and `flowbot-webhook-token` contexts belong to upstream. The file's own header
says so.

Consequences:

- **A `vN` git tag publishes nothing.** Don't tag expecting a build.
- Tier-3 changes require a **local** `docker build` and `docker push`. That is how
  the published `:latest` was made.
- Don't propose GitHub Actions: hosted runners give ~14GB disk against a 29.7GB
  image on a 24.2GB base. The config's `machine` executor at `xlarge` with layer
  caching is the right shape.

Before publishing anything, run what CI would have: `tools/validate_node_types.py`,
`tools/validate_models.py`, `bash -n` over `src/` and `tools/`, and a JSON parse of
every `workflows/**`, `pins.json`, `template.json`, `src/models_registry.json`.

## 4. Workflows are not in the image

`src/start_script.sh` does `git reset --hard origin/master` on this repo at every
boot. Workflow JSONs and `template.json` are therefore always current no matter how
old the image is; only Dockerfile-baked packs are frozen at build time.

A workflow appearing on a pod proves nothing about the image's age. If a node type
fails to resolve, ask which tier provides it before suspecting the workflow.

## 5. Verify by booting, not by reading

`/object_info` and a pack's source tell you the *declared* interface. Both skills in
`.claude/skills/` exist because that has repeatedly not matched reality here.

- `test-comfyui-node` — real confidences, coordinate spaces, and the serialized JSON
  shape of dynamic-input nodes, before you hand-author graph JSON.
- `render-comfyui-workflow` — whether a workflow JSON loads clean in the real
  frontend, after you edit it.

To check what an image actually registers, boot it CPU-only and ask:

```bash
docker run -d --name probe -p 18288:8188 --entrypoint sh <image> \
  -c 'cd /ComfyUI && python3 main.py --cpu --listen 0.0.0.0 --port 8188'
curl -s http://127.0.0.1:18288/object_info   # then diff against the workflow's node types
```

Two traps this catches. Node types are **display names, not class names** —
`cg-image-filter` registers `"Image Filter"` and `"Image List From Batch"`, with
spaces, via `comfy_api.latest.ComfyExtension` rather than `NODE_CLASS_MAPPINGS`. And
`validate_node_types.py` only checks that *some installed pack claims* a type; it
cannot tell you the server actually registered it.

Such a probe runs `main.py` directly and so skips `start_script.sh`. Anything from
`template.json` or `runtime_nodes.json` (`HipRegionMask`, `OpenRouterSimple`,
`cg-image-filter`) will be reported missing. That is expected, not a failure.

Importing ComfyUI internals outside a server mostly does not work — on a GPU-less
host `import nodes` dies in CUDA init, and Impact-Pack raises on `PromptServer.instance`.
Boot with `--cpu` instead.

## 6. Inspect a published image without pulling 30GB

Authenticate at `auth.docker.io`, fetch the manifest, then the config blob, and read
`history[].created_by`. It names every `ADD` and `RUN` — definitive about what was
baked in, in seconds rather than a 30GB pull.

Compare timestamps carefully: registry times are UTC, git times are `+02:00`. An
image is also not necessarily built from a commit — the published `:latest` was
built from a dirty tree, containing packs 8 minutes *before* the commit that added
them. Don't infer image contents from git history.

## 7. Pins are deliberate

`pins.json` holds exactly two keys (`CONTRACTS.md` §6): `runtime_ref`, the runtime
commit boot pins, and `base_image`, the base tag the Dockerfile builds `FROM`.
`runtime_ref` deploys on the next pod restart with no rebuild; `base_image` reaches
only new pods via a rebuild and redeploy.

Pin custom nodes to a 40-hex SHA in `template.json`. An unpinned pack tracking a
branch can gain a `requirements.txt` upstream and start silently failing per §2.

## 8. Cache-busters, one per pack

Each baked pack has an `ADD https://api.github.com/repos/<owner>/<repo>/git/refs/heads/<branch>`
line above the clone loop. Without it `docker_layer_caching` serves the cached clone
layer forever, so a rebuild silently reships whatever HEAD the *first* build resolved.
Each `ADD` re-reads the GitHub API every build, and any pack moving invalidates the
whole loop.

Add one whenever you add a baked pack, and remove it when you unbake one.
