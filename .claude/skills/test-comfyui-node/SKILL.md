---
name: test-comfyui-node
description: Verify a ComfyUI detector model, preprocessor, or custom node's ACTUAL runtime behavior -- real confidences, real keypoints, real serialized JSON shape -- by running it inside the project's built Docker image, before wiring it into a workflow. Use before adding any new detector/model to a workflow (to check real confidence scores and coordinate conventions, not assumed ones), and before hand-authoring JSON for any node whose inputs/widgets are added dynamically by client-side JS (object_info alone won't show that shape). Complements render-comfyui-workflow, which checks JSON structure after the fact -- this checks behavior and unknown shapes before you write the JSON in the first place.
user-invocable: true
---

# Test a ComfyUI model/node's real behavior before wiring it in

Reading a model card, a node's Python source, or `/object_info` tells you the
*declared* interface. It does not tell you whether a detector actually fires
on your images, what confidence it fires at, whether its coordinates are
normalized or absolute pixels, or what JSON shape a node with dynamically-
added sockets actually serializes to. Every one of those has been wrong when
assumed and right when tested, in this exact project:

- A detector's default 0.5 confidence threshold was rejecting real
  detections that scored 0.2-0.45 -- invisible from reading the workflow,
  obvious from running the model against test images at conf=0.01.
- A pose-keypoint consumer assumed normalized [0,1] coordinates (matching a
  well-known community node that makes the same assumption); the actual
  build emits absolute pixels. The library's own coordinate-space heuristic
  (`util.is_normalized()`) has to guess this per-call -- it's genuinely
  build-dependent, not something you can know without running it.
- A "recommended" pose-editor node pack looked fine on GitHub (not
  archived, plausible README) and failed to import outright on this
  project's actual frontend version -- an old `web/extensions/` copy step
  that no longer applies. Found in under a minute by installing and
  booting it; would have been a confusing runtime failure otherwise.
- A dynamic-input rgthree node's `/object_info` showed `"required": {},
  "optional": {}` -- genuinely no static schema, because inputs are added by
  the node's own JS as you connect things. The real shape (how many inputs
  a fresh node starts with, exact widgets_values structure) only exists by
  actually building it in the real frontend and serializing the result.

## Two techniques, pick based on what you're unsure of

### 1. Inference testing: does this model/node actually do what I think?

For a detector `.pt` file, a pose estimator, or any node whose *runtime
output* you need to trust (confidence scores, coordinate space, detection
classes) before writing code or a threshold that depends on it.

```bash
bash .claude/skills/test-comfyui-node/run-python.sh \
  <docker-image> <script.py> \
  <host-dir>:<container-path>[:ro] ...
```

Runs `script.py` inside the image via `python3`, with directories mounted
in (models, test images). No server boot -- fast, and uses the exact
library versions the image ships. See `examples/inference_test_yolo.py`
(raw Ultralytics YOLO, bbox or segm, at conf=0.01 to see real scores) and
`examples/inference_test_dwpose.py` (DWPose keypoints + coordinate-space
detection) for complete worked examples to adapt.

### 2. Frontend shape probing: what does this node ACTUALLY serialize to?

For any node whose inputs/widgets aren't fully declared in `/object_info`
(dynamic "+" inputs, interactive editors, anything client-JS-managed) that
you need to hand-author into a workflow JSON file.

```bash
bash .claude/skills/test-comfyui-node/boot-and-probe.sh \
  <docker-image> <probe.js> [--install-repo <git-url>]
```

Boots the real frontend (headless Chromium, `--cpu`), runs your Playwright
probe script against it, tears down. `--install-repo` clones an extra
custom-node repo in first -- use this to confirm a not-yet-added pack even
imports cleanly on this specific image/ComfyUI version *before* adding it
to `template.json`. See `examples/probe_node_shape.js` for a complete
worked example, including:

- **The debounce gotcha**: many dynamic-input nodes add their next empty
  socket inside a debounced `onConnectionsChange` callback (rgthree's Power
  Puter: 64ms), not synchronously on `.connect()`. Batching every
  connection into one `page.evaluate()` call will silently leave later
  slots missing. Connect one at a time with a real `page.waitForTimeout()`
  between each, matching how a human clicking in the UI would produce it.
- Building nodes via `LiteGraph.createNode(type)` + `graph.add(node)`,
  connecting via `node.connect(outSlot, targetNode, inSlot)`, and reading
  the ground truth via `graph.serialize()`.

Read `<probe output>` for the exact `inputs`/`outputs`/`widgets_values`
shape and copy it into your hand-authored node JSON -- don't extrapolate
from a *different* node's shape or from `/object_info`'s partial schema.

## When you don't need this

Static, fully-declared nodes (`/object_info` shows a complete `required`/
`optional` schema, no dynamic sockets) don't need shape probing -- author
them straight from `/object_info` the way `render-comfyui-workflow`'s own
gotchas section assumes. And a model you already have hard confidence
numbers for (from a previous probe in this same conversation) doesn't need
re-testing.

## Relationship to render-comfyui-workflow

Different question, same "verify against the real thing" philosophy.
`render-comfyui-workflow` answers "does this workflow JSON load without
structural errors" *after* you've written it (corrupt links, unknown node
types, missing models). This skill answers "what will this actually do /
what shape does it actually need" *before* you write the JSON. Use this
first when there's real uncertainty about a node/model's behavior or
shape, then `render-comfyui-workflow` after splicing it in, to confirm the
result loads clean.

## Cleanup

Both scripts always stop their container on exit (`trap cleanup EXIT` /
`docker run --rm`). If a run is killed hard enough to skip that, `docker ps
-a` and remove anything named `comfyui-probe-*` by hand. Don't leave test
model files or downloaded checkpoints sitting in the repo -- use your
scratchpad directory for anything you download to feed these scripts.
