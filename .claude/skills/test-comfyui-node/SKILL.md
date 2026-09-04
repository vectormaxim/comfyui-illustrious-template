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

Read `run-python.sh`'s own header before iterating on a script that
downloads anything (DWPose's ONNX models especially): there's no cache
between runs by default, a red CUDA-library error on every ONNX-touching
run is expected noise on a CPU host not a real failure, and mount paths
must be directories without a `:` in them. All confirmed by hitting them,
not anticipated -- worth five minutes to read once so you don't re-learn
them by re-downloading 200MB three times.

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

## Verifying a run: "success" is not proof

This is the single most expensive lesson from using this skill in anger.

**`POST /prompt` returns HTTP 200 with a `node_errors` body when an output
node's subtree fails validation.** ComfyUI drops that output node, executes
everything else, and the run reports `status: "success"` with no error
messages in `/history`. A workflow whose final SaveImage never fired looks
exactly like a clean run.

Three runs "passed" that way in one session while the final image was never
produced. The cause was a single unconnected required input
(`HipRegionMask.image`) several nodes upstream.

So when you queue a prompt to verify something:

1. **Read `node_errors` on a 200 response**, not just non-200. If it is
   non-empty, the run is a failure no matter what `status` says.
2. **Check `outputs_to_execute`** in the history entry's prompt tuple
   (`prompt[4]`). If the output node you care about is missing from it,
   ComfyUI never intended to run it.
3. **Verify by effect, not by status.** What proved a 1.5x upscale actually
   ran was the output PNG being 1248x1824 instead of 832x1216. Success,
   output count, and even "cached nodes: 31" all looked fine while nothing
   had happened. Assert on a number that can only be true if the work
   happened: image dimensions, file size, a pixel diff against the input.
4. **A run that finishes suspiciously fast did not run.** Check
   `execution_start` vs `execution_success` timestamps in `/history`;
   24 milliseconds with 31 cached nodes means everything was skipped.

## Queueing a prompt correctly

- **Send `extra_data.extra_pnginfo.workflow`.** The real frontend always
  does. rgthree's Power Puter reads `pnginfo["workflow"]` directly and dies
  with `argument of type 'NoneType' is not iterable` without it, which looks
  like a workflow bug and is not.
- **Wait for `graphToPrompt()` to settle.** With subgraphs in the graph it
  returns a *partial* prompt while instances are still resolving --
  6 seconds after `loadGraphData` was not enough. Poll it until the node
  count stops changing, then queue that. Queueing early silently submits a
  smaller graph, and the symptom is a big `execution_cached` count.
- `page.waitForFunction(fn, arg, options)` takes options as the **third**
  argument. Passing `{timeout: N}` second makes it the *arg* and silently
  uses the 30s default.

## Importing ComfyUI internals outside the server

Mostly you cannot, and reaching for it wastes time:

- `nodes.init_extra_nodes()` is a **coroutine** now -- `asyncio.run()` it, or
  `NODE_CLASS_MAPPINGS` stays empty and every custom node lookup KeyErrors.
- Even then, **Impact-Pack raises `AttributeError: type object 'PromptServer'
  has no attribute 'instance'`** on import outside a running server. There is
  no cheap workaround. To test an Impact node's behavior, queue a small
  purpose-built workflow through a running server instead.
- Getting a script onto a pod without scp: `base64 -w0` it locally and
  `echo <b64> | base64 -d > /tmp/x.py` remotely. A heredoc nested inside a
  command that is itself fed over stdin gets eaten by the outer shell.

## Driving a remote pod (RunPod)

- The `ssh.runpod.io` proxy **refuses remote command execution** (hangs) and
  **refuses port forwarding** (`-L` fails), and demands a PTY. Feed commands
  over stdin to an interactive `ssh -tt` session and fence the real output
  with markers.
- The HTTP proxy at `https://<podid>-<port>.proxy.runpod.net` does work, and
  is how to point Playwright or `curl` at a pod's ComfyUI.
- **Anonymous git-over-HTTPS from a pod is unreliable** -- the same *public*
  repo cloned 1 time in 6 from one pod, failing with
  `could not read Username for 'https://github.com'` and
  `expected flush after ref listing`. That is throttling, not a private
  repo. Retry before concluding a pack is missing or a repo is gated.

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
