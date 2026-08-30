#!/usr/bin/env python3
"""Self-check: a provisioned pod must be internally consistent.

Drives the shared runtime's provisioner (comfyui-runtime/src/provisioner.py,
pinned by pins.json) against this repo's REAL template.json,
models_registry.json and workflows/. Single flag, no swap groups, no
precision profiles: the only shapes worth asserting are "flag off queues
nothing", "flag on copies every workflow in workflows/Illustrious and queues
their registry files", and "the scrubbed checkpoint/LoRA placeholders are
never queued".

Run: python3 tools/test_provisioner.py
Stdlib only, no pytest. Needs template.json + pins.json in the repo root.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_models import runtime_dir  # noqa: E402

CHECKPOINT_PLACEHOLDER = "Your_Checkpoint_Here.safetensors"
LORA_PLACEHOLDER = "Your_Character_LoRA_Here.safetensors"
FLAG = "download_illustrious"
# workflows/Illustrious/: the reference pipeline + the curated "Ultimate" build.
EXPECTED_WORKFLOW_COUNT = 2


def load_json(path: Path, hint: str) -> dict:
    try:
        return json.loads(path.read_text())
    except OSError as e:
        raise SystemExit(f"FATAL: cannot read {path.name} ({hint}): {e}")
    except ValueError as e:
        raise SystemExit(f"FATAL: {path.name} is not valid JSON: {e}")


def run_provisioner(provisioner: Path, template_path: Path, registry_path: Path,
                     env: dict, dst: Path, manifest: Path, models_root: Path):
    return subprocess.run(
        [sys.executable, str(provisioner),
         "--template", str(template_path),
         "--registry", str(registry_path),
         "--workflows-src", str(REPO / "workflows"),
         "--workflows-dst", str(dst),
         "--models-root", str(models_root),
         "--manifest", str(manifest)],
        env=env, capture_output=True, text=True,
    )


def base_env(**overrides) -> dict:
    env = dict(os.environ)
    env.pop(FLAG, None)
    env.update(overrides)
    return env


def main() -> int:
    template = load_json(REPO / "template.json", "template config")
    registry = load_json(REPO / "src" / "models_registry.json", "registry")

    assert not template.get("swap_groups"), "this template ships no precision/quant profiles"
    assert FLAG in template["flags"], f"missing flag: {FLAG}"
    assert template["flags"][FLAG]["folders"] == ["Illustrious"], template["flags"][FLAG]

    runtime = runtime_dir()
    provisioner = runtime / "src" / "provisioner.py"
    assert provisioner.is_file(), f"no provisioner at {provisioner}"

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)

        # --- Flag off: nothing copied, nothing queued ---
        dst, manifest = tmp / "wf-off", tmp / "manifest-off.tsv"
        proc = run_provisioner(provisioner, REPO / "template.json", REPO / "src" / "models_registry.json",
                                base_env(), dst, manifest, tmp / "models-off")
        assert proc.returncode == 0, f"flag off: exited {proc.returncode}\n{proc.stdout}\n{proc.stderr}"
        wf_count = len(list(dst.rglob("*.json"))) if dst.exists() else 0
        lines = [l for l in manifest.read_text().splitlines() if l] if manifest.exists() else []
        assert wf_count == 0 and len(lines) == 0, (wf_count, len(lines))
        print(f"✅ {FLAG}=unset: 0 workflows copied, 0 models queued")

        # --- Flag on: every Illustrious workflow copied, registry files queued ---
        dst, manifest = tmp / "wf-on", tmp / "manifest-on.tsv"
        proc = run_provisioner(provisioner, REPO / "template.json", REPO / "src" / "models_registry.json",
                                base_env(**{FLAG: "true"}), dst, manifest, tmp / "models-on")
        assert proc.returncode == 0, f"flag on: exited {proc.returncode}\n{proc.stdout}\n{proc.stderr}"
        wf_count = len(list(dst.rglob("*.json")))
        assert wf_count == EXPECTED_WORKFLOW_COUNT, (wf_count, EXPECTED_WORKFLOW_COUNT)
        lines = [l for l in manifest.read_text().splitlines() if l]
        downloaded = {l.split("\t")[1].rsplit("/", 1)[1] for l in lines}
        assert CHECKPOINT_PLACEHOLDER not in downloaded, \
            "the scrubbed checkpoint placeholder must never be queued for download"
        assert LORA_PLACEHOLDER not in downloaded, \
            "the scrubbed LoRA placeholder must never be queued for download"
        for name in downloaded:
            assert name in registry, f"queued file not in registry: {name}"
        print(f"✅ {FLAG}=true: {wf_count} workflow(s) copied, {len(downloaded)} model(s) queued, "
              f"placeholders untouched")

    print("✅ provisioner self-check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
