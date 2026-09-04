---
name: render-comfyui-workflow
description: Boot a ComfyUI template Docker image in CPU-only mode, load a workflow JSON into the real ComfyUI frontend via a headless browser, and screenshot it. Use whenever you've edited a ComfyUI workflow graph (added/moved/rewired nodes, changed groups) and want to verify it against the actual frontend instead of just reasoning about the JSON -- catches missing node types, corrupt link registration, and other structural bugs that pure JSON inspection misses. Works for any comfyui-runtime-based template image, not just one specific repo.
user-invocable: true
---

# Render a ComfyUI workflow for real verification

This is strictly better than eyeballing workflow JSON or hand-rolling an SVG
reconstruction: it boots the *actual* ComfyUI server from the *actual* built
image (so every custom node pack either imports cleanly or visibly fails to),
loads the *actual* workflow file into the *actual* frontend, and lets that
frontend's own validation (missing node types, rgthree's link-integrity
checker, the "N errors found" missing-models panel) do the checking.

No GPU is needed for this -- it boots ComfyUI with `--cpu`, which is enough to
render the graph and run its load-time validation, but NOT enough to actually
queue/run inference. This is a structural-correctness check, not an image
generation test.

## When to use this

After any edit to a workflow's node/link/group structure: adding nodes,
rewiring links, moving nodes between groups, splicing in a new detector
chain, etc. Anything that's pure metadata (widget values, prompt text,
scrubbing filenames to placeholders) doesn't need this -- only structural
graph changes do.

## Inputs to collect

- **Docker image**: must already be built and either loaded locally
  (`docker images` shows it) or pullable. If it only exists as a local
  Dockerfile, build it first (`docker build -t <tag> .`).
- **Workflow JSON path**: the file to load.
- **What to verify**: usually "does it load clean" is enough (the overview
  screenshot + report.json covers that). If you made a specific, localized
  edit (moved a node, added a group), pass `--node-id <id>` or
  `--group "<title substring>"` for a close-up screenshot of exactly that
  spot -- cheap to add, and it's the difference between "looks right" and
  "confirmed right" when reporting back to the user.

## Running it

```bash
bash .claude/skills/render-comfyui-workflow/boot-and-render.sh \
  <docker-image> <workflow.json> <out-dir> \
  [--node-id 230] [--group "HIPS/GROIN"]
```

First run downloads Playwright's Chromium build (~5 min, cached under
`~/.cache/ms-playwright` after that). The script picks port 18188 by default
(override with `COMFYUI_PREVIEW_PORT`), waits for the server to answer, runs
the render, and always stops the container on exit (including on failure --
there's a trap).

## Reading the output

`<out-dir>/report.json` has two things that mean very different severities:

- **`flagged_console_lines`**: real bugs. Anything matching "corrupt linking
  data", "is funky", a JS `Uncaught` exception, or a page error means the
  workflow JSON itself is structurally broken (e.g. a link registered on the
  consumer's `.link` field but missing from the producer's `outputs[].links`
  array -- this exact bug has happened before, see the comfyui-illustrious-
  template repo history). Fix these in the JSON directly, don't just let the
  frontend's live auto-patch paper over it (that patch is in-memory only,
  never written back to the file).
- **`missing_models_panel`**: almost always EXPECTED and benign in this kind
  of throwaway preview container, since nothing is downloaded and no image is
  uploaded. A template that scrubs checkpoint/LoRA/reference-image values to
  placeholders (see this repo's convention) is *supposed* to show these as
  missing here. Only worth a second look if it lists something you did NOT
  expect to be missing (e.g. a model that should already be baked into your
  registry, or a node type showing "Unknown").

`<out-dir>/overview.png` plus any `node-<id>.png` / `group-<slug>.png`
close-ups are the actual screenshots -- read them with the Read tool the same
way you'd read any image.

## Subgraphs

Established by probing frontend 1.48.7 directly, because the docs are thin
here and in one case say the opposite.

**The JSON shape.** `graph.serialize()` gains a `definitions` key holding
`definitions.subgraphs`: an array of `{id (a UUID), name, inputs, outputs,
inputNode: {id: -10, ...}, outputNode: {id: -20, ...}, nodes, links}`. A
top-level node whose `type` is one of those UUIDs is an *instance* of that
definition. **Inside a definition, `links` are objects** --
`{id, origin_id, origin_slot, target_id, target_slot, type}` -- not the
positional arrays used at the top level. Getting that wrong by analogy is
easy; check before hand-authoring.

**Instances share their definition.** Two instances of one subgraph in the
same workflow produce a single entry in `definitions.subgraphs` and both
carry the same UUID `type`. Editing the definition changes every instance.
(The docs' warning that instances are independent snapshots applies to
*Blueprints*, a different feature.) Promoted widgets, meanwhile, **are**
per-instance: two instances serialize with different `widgets_values`.

**What you cannot do.** `convertToSubgraph` creates boundary inputs only for
links that **cross the selection** -- a cluster built in isolation and then
collapsed gets no inputs at all. `convertWidgetToInput` is a silent no-op.
`subgraph.addInput(name, type)` does work but produces an input *socket*,
not a widget, so it needs a wire per instance. Net effect: **a COMBO widget
(a model dropdown) cannot be promoted**, so a node whose model choice varies
per stage cannot live in a *shared* definition. Subgraphs nest, which is the
way around it -- an outer per-stage definition can contain an instance of a
shared inner one.

**Validators must recurse.** A subgraph instance node reports
`properties.cnr_id: "comfy-core"` (it is a frontend construct), so a scan of
top-level `nodes` sees nothing pack-related while an Impact-Pack node sits
one level down inside the definition. Walk `definitions.subgraphs[].nodes`
too, and recursively, since definitions nest.

## Node types legitimately absent from /object_info

Do not treat these as missing packs -- they are frontend-only, with no
Python class, so they never appear in `/object_info`:

- `Note`, `MarkdownNote` (litegraph built-ins)
- `Bookmark (rgthree)`, `Fast Groups Bypasser (rgthree)`,
  `Fast Groups Muter (rgthree)`

Everything else in a workflow should resolve. If something does resolve in
`/object_info` on a booted server but the *preview container* reports it as
a missing node pack, check whether that pack is installed at boot by the
runtime rather than baked into the image -- the render harness boots the
bare image without the runtime entrypoint, so boot-installed packs are
absent there and the warning is an artifact.

But do not over-apply that: on a real pod the boot-time clone can also just
*fail* (see the RunPod notes in `test-comfyui-node`), so "installed at boot"
is not the same as "present". Confirm on the pod before concluding either
way.

## Gotchas

- The image must actually contain the node packs the workflow references, or
  you'll see real "unknown node type" errors in the panel -- that's not a
  render-script bug, that's the Dockerfile missing a pack.
- `--cpu` mode is slow to boot custom nodes with heavy import-time work
  (controlnet_aux, Impact-Pack) -- the wait loop allows up to 60s; raise it in
  the script if your image has more packs than that comfortably covers.
- This sandbox may not be an officially Playwright-supported OS (falls back
  to an Ubuntu build) -- if `npx playwright install chromium` fails outright,
  the environment likely lacks a package manager Playwright recognizes;
  installing shared-lib dependencies by hand is out of scope for this skill.
- Don't commit `node_modules/` from this skill directory -- it's gitignored.
