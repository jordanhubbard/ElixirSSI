// Drive a headless Chromium for scripts/test_monitor.py.
//
// One JSON request per line on stdin, one JSON reply per line on stdout:
//   {"op": "open", "url": ..., "width": 1280, "height": 900}   new context (fresh storage)
//   {"op": "trust", "pems": [...]}  accept exactly these server certificates (before the first open)
//   {"op": "click", "selector": ...} | {"op": "fill", "selector": ..., "value": ...}
//   {"op": "select", "selector": ..., "value": ...}
//   {"op": "eval", "js": "expression"}                          value of the expression
//   {"op": "wait", "js": "expression", "timeout": ms}           until the expression is truthy
//   {"op": "reload"} | {"op": "viewport", "width", "height"}
//   {"op": "shot", "path": ..., "full": true}
//   {"op": "problems"}       console errors and page errors since the last call
//   {"op": "quit"}
// Replies are {"ok": true, "value": ...} or {"ok": false, "error": "..."}.
//
// playwright-core is resolved from SSI_BROWSER_MODULES (build/browser/node_modules).
import { createHash, X509Certificate } from "node:crypto";
import { createRequire } from "node:module";
import readline from "node:readline";

const require = createRequire(`${process.env.SSI_BROWSER_MODULES}/`);
const { chromium } = require("playwright-core");

// A monitor reconnecting to members that are down logs these by design.
const EXPECTED = /WebSocket connection to '.*' failed/;

// Launched at the first open, so "trust" can add to its arguments.
let browser = null;
const args = [];
let context = null;
let page = null;
let problems = [];

function watch(p) {
  p.on("console", (m) => {
    if (m.type() === "error" && !EXPECTED.test(m.text())) problems.push(`console: ${m.text()}`);
  });
  p.on("pageerror", (e) => problems.push(`pageerror: ${e.message}`));
  p.on("requestfailed", (r) => {
    if (!r.url().startsWith("ws")) problems.push(`requestfailed: ${r.url()} ${r.failure()?.errorText}`);
  });
}

const ops = {
  // The test verifies each member's certificate against the cluster's web CA
  // itself (headless Chromium has no CA import), then has Chromium accept
  // exactly those certificates' keys: no blanket ignoring of errors.
  trust({ pems }) {
    if (browser) throw new Error("trust must come before the first open");
    const hashes = pems.map((pem) => {
      const spki = new X509Certificate(pem).publicKey.export({ type: "spki", format: "der" });
      return createHash("sha256").update(spki).digest("base64");
    });
    args.push(`--ignore-certificate-errors-spki-list=${hashes.join(",")}`);
    return hashes;
  },
  async open({ url, width = 1280, height = 900 }) {
    browser ||= await chromium.launch({ headless: true, args });
    if (context) await context.close();
    context = await browser.newContext({ viewport: { width, height } });
    page = await context.newPage();
    watch(page);
    await page.goto(url);
    return page.url();
  },
  eval: ({ js }) => page.evaluate(js),
  click: ({ selector }) => page.click(selector, { timeout: 5000 }).then(() => true),
  fill: ({ selector, value }) => page.fill(selector, value, { timeout: 5000 }).then(() => true),
  select: ({ selector, value }) => page.selectOption(selector, value, { timeout: 5000 }),
  async wait({ js, timeout = 30000 }) {
    await page.waitForFunction(js, null, { timeout, polling: 250 });
    return true;
  },
  async reload() {
    await page.reload();
    return true;
  },
  async viewport({ width, height }) {
    await page.setViewportSize({ width, height });
    return true;
  },
  async shot({ path, full = true }) {
    await page.screenshot({ path, fullPage: full });
    return path;
  },
  problems() {
    const out = problems;
    problems = [];
    return out;
  },
  async quit() {
    if (browser) if (browser) await browser.close();
    process.exit(0);
  },
};

const rl = readline.createInterface({ input: process.stdin });
for await (const line of rl) {
  let reply;
  try {
    const req = JSON.parse(line);
    reply = { ok: true, value: await ops[req.op](req) };
  } catch (e) {
    reply = { ok: false, error: String(e && e.message ? e.message.split("\n")[0] : e) };
  }
  process.stdout.write(JSON.stringify(reply) + "\n");
}
if (browser) await browser.close();
