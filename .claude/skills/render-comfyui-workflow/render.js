#!/usr/bin/env node
// Loads a ComfyUI workflow JSON into a running ComfyUI frontend (via a headless
// Chromium) and reports back: any missing-node-type / corrupt-link warnings,
// the "N errors found" panel contents if present, and a full-graph overview
// screenshot. Assumes a ComfyUI server is ALREADY running and reachable at
// --port (see boot-and-render.sh, which handles that + calls this).
//
// Usage:
//   node render.js --port 18188 --workflow /path/to/workflow.json --out /path/to/outdir [--node-id 230] [--group "HIPS/GROIN"]
//
// --node-id / --group are optional close-up shots: center the view on a
// specific node id, or fit-to-view a specific group by (partial, case-
// sensitive) title match. Either may be passed multiple times.

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const args = { nodeIds: [], groups: [] };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port') args.port = argv[++i];
    else if (a === '--workflow') args.workflow = argv[++i];
    else if (a === '--out') args.out = argv[++i];
    else if (a === '--node-id') args.nodeIds.push(argv[++i]);
    else if (a === '--group') args.groups.push(argv[++i]);
  }
  if (!args.port || !args.workflow || !args.out) {
    console.error('usage: node render.js --port <port> --workflow <path> --out <dir> [--node-id N] [--group "title"]');
    process.exit(2);
  }
  return args;
}

const BAD_PATTERNS = [
  /corrupt linking data/i,
  /is funky/i,
  /Cannot read propert/i,
  /Uncaught/i,
];

(async () => {
  const args = parseArgs(process.argv);
  fs.mkdirSync(args.out, { recursive: true });

  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });

  const consoleLines = [];
  const flagged = [];
  page.on('console', (msg) => {
    const text = msg.text();
    consoleLines.push(`[${msg.type()}] ${text}`);
    if (BAD_PATTERNS.some((re) => re.test(text))) flagged.push(text);
  });
  page.on('pageerror', (err) => {
    consoleLines.push(`[pageerror] ${err.message}`);
    flagged.push(err.message);
  });

  const url = `http://localhost:${args.port}/`;
  await page.goto(url, { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForSelector('canvas', { timeout: 30000 });
  await page.waitForTimeout(3000);

  const fileInput = page.locator('input[type="file"]').first();
  await fileInput.setInputFiles(path.resolve(args.workflow));
  await page.waitForTimeout(4000);

  // Read the "Missing Models" / "Missing Inputs" panel if ComfyUI raised one --
  // this is the EXPECTED, benign case when models/images aren't present in a
  // throwaway preview container. Flagged separately from real bugs above.
  let errorPanelText = null;
  const viewDetails = page.locator('text=View details');
  if ((await viewDetails.count()) > 0) {
    // A real simulated mouse click (even with force: true, which only skips
    // Playwright's actionability WAIT, not hit-testing) still gets routed to
    // the toast's own entrance-animation backdrop (dialog-overlay) if it's
    // still on top of that screen position -- so it silently "succeeds"
    // without ever opening the panel. Dispatching the click via the DOM
    // (el.click()) fires the button's handler directly, bypassing hit-
    // testing entirely.
    await viewDetails.evaluate((el) => el.click());
    await page.waitForTimeout(1000);
    errorPanelText = await page.locator('body').innerText();
  }

  // Full-graph overview: select all, fit view, deselect, screenshot.
  await page.evaluate(() => {
    const app = window.app;
    app.canvas.selectNodes();
    app.canvas.fitViewToSelectionAnimated();
    app.canvas.deselectAll();
  });
  await page.waitForTimeout(1200);
  await page.keyboard.press('Escape');
  await page.waitForTimeout(300);
  await page.screenshot({ path: path.join(args.out, 'overview.png') });

  // Optional close-ups.
  for (const nid of args.nodeIds) {
    const found = await page.evaluate((id) => {
      const app = window.app;
      const node = app.graph.getNodeById(Number(id));
      if (!node) return false;
      app.canvas.ds.offset[0] = -node.pos[0] + 700;
      app.canvas.ds.offset[1] = -node.pos[1] + 400;
      app.canvas.ds.scale = 0.5;
      app.canvas.setDirty(true, true);
      return true;
    }, nid);
    if (found) {
      await page.waitForTimeout(800);
      await page.screenshot({ path: path.join(args.out, `node-${nid}.png`) });
    } else {
      flagged.push(`--node-id ${nid}: no such node in the loaded graph`);
    }
  }
  for (const title of args.groups) {
    const found = await page.evaluate((t) => {
      const app = window.app;
      const group = app.graph._groups.find((g) => g.title.includes(t));
      if (!group) return false;
      app.canvas.ds.offset[0] = -group.pos[0] + 200;
      app.canvas.ds.offset[1] = -group.pos[1] + 150;
      app.canvas.ds.scale = 0.32;
      app.canvas.setDirty(true, true);
      return true;
    }, title);
    if (found) {
      await page.waitForTimeout(800);
      const slug = title.replace(/[^A-Za-z0-9]+/g, '_').slice(0, 40);
      await page.screenshot({ path: path.join(args.out, `group-${slug}.png`) });
    } else {
      flagged.push(`--group "${title}": no group title contains this string`);
    }
  }

  fs.writeFileSync(path.join(args.out, 'console.log'), consoleLines.join('\n'));
  const report = {
    url,
    workflow: path.resolve(args.workflow),
    flagged_console_lines: flagged,
    missing_models_panel: errorPanelText,
  };
  fs.writeFileSync(path.join(args.out, 'report.json'), JSON.stringify(report, null, 2));

  console.log('--- RENDER REPORT ---');
  console.log(JSON.stringify(report, null, 2));

  await browser.close();
})().catch((e) => {
  console.error('FATAL:', e.stack || e.message);
  process.exit(1);
});
