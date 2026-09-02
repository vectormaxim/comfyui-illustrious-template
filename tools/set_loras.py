#!/usr/bin/env python3
"""Set the same LoRA across every Power Lora Loader in a workflow.

The Ultimate pipeline builds its LoRA/CLIP chain once per detailer stage, so a
single character LoRA has to be selected in ten separate `Power Lora Loader
(rgthree)` nodes. Doing that by hand in the UI is ten identical edits that have
to be redone on every fresh copy of the workflow; this does it in one command.

Slot 1 of each loader is the character-LoRA slot by convention. Loaders keep
their own strengths where those were deliberately tuned (152 -> 0.5, 276 ->
0.7) unless --force-strength is passed.

    python3 tools/set_loras.py WORKFLOW.json --lora NAME.safetensors --strength 1

Writes in place. Use --dry-run to preview. Stdlib only.
"""
import argparse
import json
import sys

LOADER_TYPE = "Power Lora Loader (rgthree)"


def slots(node):
    """Yield (index, widget) for each LoRA slot dict in a loader's widgets_values."""
    for i, w in enumerate(node.get("widgets_values") or []):
        if isinstance(w, dict) and "lora" in w:
            yield i, w


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("workflow")
    ap.add_argument("--lora", required=True, help="LoRA filename as ComfyUI lists it")
    ap.add_argument("--strength", type=float, default=1.0)
    ap.add_argument("--slot", type=int, default=1,
                    help="1-based LoRA slot within each loader (default 1)")
    ap.add_argument("--force-strength", action="store_true",
                    help="overwrite per-stage tuned strengths instead of keeping them")
    ap.add_argument("--enable", action="store_true", default=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    with open(args.workflow) as fh:
        wf = json.load(fh)

    touched = 0
    for node in wf["nodes"]:
        if node.get("type") != LOADER_TYPE:
            continue
        found = list(slots(node))
        if args.slot > len(found):
            print(f"  node {node['id']}: no slot {args.slot} (has {len(found)}) -- skipped")
            continue
        idx, widget = found[args.slot - 1]
        old = dict(widget)
        widget["lora"] = args.lora
        widget["on"] = args.enable
        # A strength that was never tuned away from the 1.0 default is safe to
        # set; a deliberately different one is left alone unless forced.
        if args.force_strength or old.get("strength") in (None, 1):
            # Keep whole numbers as ints; the workflow files write `1`, not `1.0`,
            # and gratuitous float formatting makes for a noisy diff.
            st = args.strength
            widget["strength"] = int(st) if st == int(st) else st
        touched += 1
        print(f"  node {node['id']} slot {args.slot}: "
              f"{old.get('lora')} @{old.get('strength')} on={old.get('on')}"
              f"  ->  {widget['lora']} @{widget['strength']} on={widget['on']}")

    if not touched:
        sys.exit("no Power Lora Loader nodes found")

    if args.dry_run:
        print(f"\n[dry-run] {touched} loader(s) would change; nothing written")
        return

    with open(args.workflow, "w") as fh:
        json.dump(wf, fh, indent=2)
        fh.write("\n")
    print(f"\nupdated {touched} loader(s) in {args.workflow}")


if __name__ == "__main__":
    main()
