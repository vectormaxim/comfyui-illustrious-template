#!/usr/bin/env python3
"""Apply personal defaults (checkpoint, LoRAs, prompts) to a workflow copy.

The shipped workflows in workflows/ must keep placeholders: validate_models
errors on any loader naming a model the template does not ship, and CI gates
the build on it. Personal values live in local/personal_defaults.json, which is
gitignored, and this applies them to a copy.

    python3 tools/apply_personal.py IN.json OUT.json [--defaults local/personal_defaults.json]

Stdlib only.
"""
import argparse
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--defaults", default=str(REPO / "local" / "personal_defaults.json"))
    args = ap.parse_args()

    d = json.loads(Path(args.src).read_text())
    cfg = json.loads(Path(args.defaults).read_text())
    applied = []

    for n in d["nodes"]:
        title = n.get("title") or ""
        wv = n.get("widgets_values")
        if not isinstance(wv, list) or not wv:
            continue
        if n["type"] == "CheckpointLoaderSimple" and cfg.get("checkpoint"):
            wv[0] = cfg["checkpoint"]; applied.append("checkpoint")
        elif n["type"] == "LoraLoader" and title in (cfg.get("loras") or {}):
            wv[0] = cfg["loras"][title]
            n["mode"] = 0                      # a named LoRA is one you want on
            applied.append(f"lora:{title}")
        elif n["type"] == "PrimitiveStringMultiline" and title in (cfg.get("prompts") or {}):
            wv[0] = cfg["prompts"][title]; applied.append(title)
        elif n["type"] == "CLIPTextEncode" and title.startswith("MAIN NEGATIVE") and cfg.get("negative"):
            # only when the negative is still a plain widget; newer builds feed
            # it from a shared string box instead
            if not any(i["name"] == "text" and i.get("link") is not None for i in n.get("inputs") or []):
                wv[0] = cfg["negative"]; applied.append("negative")
        elif n["type"] == "PrimitiveStringMultiline" and title.startswith("Negative prompt") and cfg.get("negative"):
            wv[0] = cfg["negative"]; applied.append("negative")

    Path(args.dst).write_text(json.dumps(d, indent=2) + "\n")
    print(f"applied {len(applied)}: {', '.join(applied)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
