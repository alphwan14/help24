// A small Chrome DevTools Protocol driver for e2e/run.mjs — just enough to
// drive a real Chromium (Edge or Chrome) through the dashboard. No dependency:
// Node ≥ 22 has fetch and WebSocket built in.
import { spawn, spawnSync } from "node:child_process";
import { existsSync, rmSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

const CANDIDATES = [
  process.env.E2E_BROWSER,
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Google/Chrome/Application/chrome.exe",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
  "/usr/bin/google-chrome",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/usr/bin/microsoft-edge",
].filter(Boolean);

export function findBrowser() {
  const found = CANDIDATES.find((p) => existsSync(p));
  if (!found) throw new Error("No Chromium browser found. Set E2E_BROWSER to Edge or Chrome.");
  return found;
}

/**
 * Stop every browser process started with this run's throwaway profile — and
 * only those. Edge's main process outlives its launcher, so killing the PID we
 * spawned is not enough, and the person's own browser must never be touched.
 */
function stopByProfile(profileDir) {
  if (process.platform === "win32") {
    const pattern = profileDir.replace(/'/g, "''");
    spawnSync("powershell", ["-NoProfile", "-Command",
      `Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*${pattern}*' -and $_.Name -match 'msedge|chrome' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`,
    ], { stdio: "ignore" });
  } else {
    spawnSync("pkill", ["-f", profileDir], { stdio: "ignore" });
  }
}

export async function launchBrowser({ profileDir, port }) {
  rmSync(profileDir, { recursive: true, force: true });
  const proc = spawn(findBrowser(), [
    "--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profileDir}`,
    "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--disable-sync",
    "--window-size=1280,900", "about:blank",
  ], { stdio: "ignore" });

  let wsUrl;
  for (let i = 0; !wsUrl; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      wsUrl = list.find((t) => t.type === "page")?.webSocketDebuggerUrl;
    } catch {}
    if (!wsUrl) {
      if (i > 150) throw new Error("the browser never exposed a page target");
      await sleep(200);
    }
  }

  const ws = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let seq = 0;
  const pending = new Map();
  const consoleLines = [];
  const exceptions = [];
  const requests = [];
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result);
    } else if (msg.method === "Runtime.consoleAPICalled") {
      consoleLines.push(msg.params.args.map((a) => a.value ?? a.description ?? "").join(" "));
    } else if (msg.method === "Runtime.exceptionThrown") {
      exceptions.push(msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text);
    } else if (msg.method === "Network.requestWillBeSent") {
      requests.push({ url: msg.params.request.url, method: msg.params.request.method, postData: msg.params.request.postData ?? "" });
    }
  };
  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = ++seq;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });
  for (const domain of ["Page", "Runtime", "Network"]) await send(`${domain}.enable`);

  async function evaluate(expression) {
    const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
    return r.result.value;
  }

  const page = {
    send,
    evaluate,
    consoleLines,
    exceptions,
    requests,
    async waitFor(expression, what, timeout = 90000) {
      const t0 = Date.now();
      while (Date.now() - t0 < timeout) {
        try { if (await evaluate(expression)) return true; } catch {}
        await sleep(150);
      }
      throw new Error(`timed out waiting for ${what}`);
    },
    async goto(url) {
      await send("Page.navigate", { url });
      await sleep(250);
      await page.waitFor("document.readyState === 'complete'", `load of ${url}`);
    },
    /** Type into a field the way a person does — and check it took. */
    async fill(selector, text) {
      // After a full page load the server's HTML arrives before React does;
      // typing into it first gets wiped when hydration resets a controlled
      // field. Wait until React has attached to the element.
      await page.waitFor(
        `(() => { const el = document.querySelector(${JSON.stringify(selector)}); return !!el && Object.keys(el).some((k) => k.startsWith("__reactProps")); })()`,
        `React to attach to ${selector}`,
        30000,
      );
      // Let any focus the app scheduled for the next frame (an error moving
      // focus to the first invalid field) land BEFORE we take focus.
      await evaluate("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(true))))");
      await evaluate(`(() => { const el = document.querySelector(${JSON.stringify(selector)}); el.focus(); el.select(); return true; })()`);
      if (text) await send("Input.insertText", { text });
      else for (const type of ["keyDown", "keyUp"]) await send("Input.dispatchKeyEvent", { type, key: "Backspace", code: "Backspace", windowsVirtualKeyCode: 8 });
      const got = await evaluate(`document.querySelector(${JSON.stringify(selector)}).value`);
      if (got !== text) throw new Error(`fill(${selector}) holds ${got.length} chars, expected ${text.length}`);
    },
    // Clicks wait for React too: a click on server-rendered HTML before
    // hydration has no handler behind it and is simply lost.
    async click(selector) {
      const find = `document.querySelector(${JSON.stringify(selector)})`;
      await page.waitFor(`(() => { const el = ${find}; return !!el && Object.keys(el).some((k) => k.startsWith("__reactProps")); })()`, `React to attach to ${selector}`, 30000);
      return evaluate(`(() => { ${find}.click(); return true; })()`);
    },
    async clickText(text, scope = "button, a") {
      const find = `[...document.querySelectorAll(${JSON.stringify(scope)})].find(e => e.textContent.trim() === ${JSON.stringify(text)} && e.offsetParent !== null)`;
      await page.waitFor(`(() => { const el = ${find}; return !!el && Object.keys(el).some((k) => k.startsWith("__reactProps")); })()`, `React to attach to "${text}"`, 30000);
      return evaluate(`(() => { ${find}.click(); return true; })()`);
    },
    value: (selector) => evaluate(`document.querySelector(${JSON.stringify(selector)}).value`),
    bodyHas: (text) => `document.body && document.body.innerText.includes(${JSON.stringify(text)})`,
    pathIs: (p) => `location.pathname === ${JSON.stringify(p)}`,
    async cookie(origin, name) {
      const { cookies } = await send("Network.getCookies", { urls: [origin] });
      return cookies.find((c) => c.name === name) ?? null;
    },
    async cookies(origin) {
      return (await send("Network.getCookies", { urls: [origin] })).cookies;
    },
    clearCookies: () => send("Network.clearBrowserCookies"),
    async shot(path, fullPage = false) {
      let params = { format: "png" };
      if (fullPage) {
        const h = await evaluate("Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)");
        const w = await evaluate("document.documentElement.clientWidth");
        params = { ...params, captureBeyondViewport: true, clip: { x: 0, y: 0, width: w, height: h, scale: 1 } };
      }
      const { data } = await send("Page.captureScreenshot", params);
      writeFileSync(path, Buffer.from(data, "base64"));
    },
  };

  return {
    page,
    stop() {
      try { ws.close(); } catch {}
      try { proc.kill(); } catch {}
      stopByProfile(profileDir);
    },
  };
}
