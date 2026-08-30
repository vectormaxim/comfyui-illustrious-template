// Worked example: discover the true serialized JSON shape of a node with
// DYNAMIC inputs (added by client-side JS, not declared in object_info).
// Run via boot-and-probe.sh, which starts the server and sets
// COMFYUI_PROBE_PORT before invoking this with `node`.
//
// This exact scenario (rgthree's "Power Puter") is why this example exists:
// object_info showed `"required": {}, "optional": {}` for it -- genuinely
// no static schema at all, because every input socket ("a", "b", "c", ...)
// gets added by the node's own onConnectionsChange handler as you connect
// things to it. Guessing that shape (how many inputs a fresh node starts
// with, what they're named, whether widgets_values is a flat array or has
// object-valued entries) and hand-authoring it into a workflow file is how
// you ship something that LOOKS plausible and fails to load, or loads but
// misbehaves silently.
//
// Adapt the node type names / connection plan below to whatever you're
// probing, then read the printed JSON for the real "inputs"/"outputs"/
// "widgets_values" shape and copy it into your hand-authored workflow node.

// Resolve playwright from render-comfyui-workflow's install (adjust the
// relative path if this skill lives somewhere else relative to it).
const path = require('path');
const { chromium } = require(
  path.join(__dirname, '..', '..', 'render-comfyui-workflow', 'node_modules', 'playwright')
);

const PORT = process.env.COMFYUI_PROBE_PORT || '18199';

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
  page.on('pageerror', (err) => console.error('[pageerror]', err.message));

  await page.goto(`http://localhost:${PORT}/`, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => window.app && window.app.graph, { timeout: 60000 });
  await page.waitForTimeout(2000); // let extensions finish registering node types

  // Build the source nodes and the node under test.
  await page.evaluate(() => {
    const graph = window.app.graph;
    window.__probe = {};
    function addNode(type, pos) {
      const node = LiteGraph.createNode(type);
      if (!node) throw new Error(`could not create node type "${type}" -- is it registered?`);
      node.pos = pos;
      graph.add(node);
      return node;
    }
    const sources = [
      addNode('PrimitiveStringMultiline', [0, 0]),
      addNode('PrimitiveStringMultiline', [0, 200]),
    ];
    sources.forEach((n, i) => { n.widgets[0].value = `source ${i + 1}`; });
    const target = addNode('Power Puter (rgthree)', [400, 100]);
    window.__probe = { sources, target };
  });

  // THE GOTCHA: many dynamic-input nodes add their next empty socket inside
  // a DEBOUNCED onConnectionsChange callback (rgthree's Power Puter debounces
  // at 64ms), not synchronously when .connect() returns. Connecting all
  // sources in one page.evaluate() call will silently fail past the first
  // one or two -- the later slots don't exist yet. Connect one at a time,
  // with a real wait after each, exactly like a human clicking in the UI
  // would produce.
  for (let i = 0; i < 2; i++) {
    const info = await page.evaluate((idx) => {
      const { sources, target } = window.__probe;
      const before = target.inputs.map((inp) => inp.name);
      const ok = !!sources[idx].connect(0, target, idx);
      return { idx, ok, before };
    }, i);
    console.error('connect step:', JSON.stringify(info));
    await page.waitForTimeout(300); // comfortably past the 64ms debounce
  }

  // Set any widgets the node needs (find them by name, not by index --
  // index order is easy to get wrong when a node has several).
  await page.evaluate(() => {
    const { target } = window.__probe;
    const codeWidget = target.widgets.find((w) => w.name === 'code');
    if (codeWidget) codeWidget.value = "', '.join([x for x in [a,b] if x])";
  });

  const result = await page.evaluate(() => {
    const { target, sources } = window.__probe;
    const serialized = window.app.graph.serialize();
    // Node ids from LiteGraph are numbers at runtime but the probe's own
    // JSON.stringify comparisons can trip on type -- compare as strings.
    return {
      targetNodeJson: serialized.nodes.find((n) => String(n.id) === String(target.id)),
      sourceNodeJson: serialized.nodes.find((n) => String(n.id) === String(sources[0].id)),
      relevantLinks: serialized.links.filter(
        (l) => String(l[3]) === String(target.id) || sources.some((s) => String(s.id) === String(l[1]))
      ),
    };
  });

  console.log(JSON.stringify(result, null, 2));
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
