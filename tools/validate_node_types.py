#!/usr/bin/env python3
"""Assert every node type in workflows/ is provided by a pack we actually install.

CI could not detect a missing node pack at all. The Dockerfile's node-type gate
is a hand-maintained comment that nothing greps, and it had already drifted.
That is the one class of gap the rest of CI is structurally blind to: a
workflow can reference a pack nobody installs and every check still passes,
right up until a customer's pod shows a red node.

Packs come from three places, and all three count:
  1. the Dockerfile clone loop            -- baked into the image
  2. comfyui-runtime's src/runtime_nodes.json -- cloned at boot for every template
  3. template.json custom_nodes.repos     -- cloned at boot for this template

Nodes carry their own provenance: litegraph writes `properties.cnr_id` and
`properties.aux_id` when a node is placed. Matching is on the repository NAME,
not owner/repo, so a node authored against a fork of a pack we do install is
not a false alarm.

Run: python3 tools/validate_node_types.py
Stdlib only.
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_models import runtime_dir  # noqa: E402

REPO = Path(__file__).resolve().parents[1]

# Types with no usable provenance in the JSON. rgthree's Bookmark and Fast
# Groups Bypasser are frontend-only JS with no Python class, so litegraph
# records no cnr_id; Note and MarkdownNote are litegraph built-ins.
NO_PROVENANCE = {
    "Note": "comfy-core",
    "MarkdownNote": "comfy-core",
    "Bookmark (rgthree)": "rgthree-comfy",
    "Fast Groups Bypasser (rgthree)": "rgthree-comfy",
    "Fast Groups Muter (rgthree)": "rgthree-comfy",
}


def norm(name: str) -> str:
    """Repo/pack identity, case- and separator-insensitive."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def repo_name(url: str) -> str:
    return url.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")


def installed_packs() -> dict:
    """{normalised pack name: where it comes from}"""
    packs = {}

    dockerfile = (REPO / "Dockerfile").read_text()
    # The clone loop lists one URL per continuation line.
    for url in re.findall(r"https://github\.com/[\w.-]+/[\w.-]+\.git", dockerfile):
        packs.setdefault(norm(repo_name(url)), "Dockerfile")

    template = json.loads((REPO / "template.json").read_text())
    for entry in (template.get("custom_nodes") or {}).get("repos", []):
        packs.setdefault(norm(repo_name(entry.split("|")[0])), "template.json")

    rn = runtime_dir() / "src" / "runtime_nodes.json"
    if rn.is_file():
        for entry in json.loads(rn.read_text()):
            packs.setdefault(norm(repo_name(entry.split("|")[0])), "runtime_nodes.json")
    else:
        print(f"⚠️  no runtime_nodes.json at {rn}; checking without it", file=sys.stderr)

    return packs


def provider(node: dict):
    """(pack name, is_core) declared by this node, or (None, False) if unknown."""
    props = node.get("properties") or {}
    cnr, aux = props.get("cnr_id"), props.get("aux_id")
    if cnr == "comfy-core":
        return "comfy-core", True
    if aux:
        return repo_name(aux), False
    if cnr:
        return cnr, False
    known = NO_PROVENANCE.get(node.get("type"))
    if known:
        return known, known == "comfy-core"
    return None, False


def main() -> int:
    packs = installed_packs()
    errors, unknown = [], []

    for wf in sorted((REPO / "workflows").rglob("*.json")):
        graph = json.loads(wf.read_text())
        for node in graph.get("nodes", []):
            name, is_core = provider(node)
            if is_core:
                continue
            if name is None:
                unknown.append((wf.name, node["id"], node.get("type")))
                continue
            if norm(name) not in packs:
                errors.append((wf.name, node["id"], node.get("type"), name))

    for wfname, nid, ntype, name in errors:
        print(f"❌ {wfname}: node {nid} ({ntype}) needs pack {name!r}, "
              f"which no Dockerfile / runtime_nodes.json / template.json entry installs")
    for wfname, nid, ntype in unknown:
        print(f"⚠️  {wfname}: node {nid} ({ntype}) declares no cnr_id/aux_id; "
              f"add it to NO_PROVENANCE in this script once you know its pack")

    print(f"🔎 {len(packs)} pack(s) installed: {', '.join(sorted(packs))}")
    if errors:
        print(f"💥 {len(errors)} node type(s) with no installing pack")
        return 1
    print(f"✅ node types validated, {len(unknown)} without declared provenance")
    return 0


if __name__ == "__main__":
    sys.exit(main())
