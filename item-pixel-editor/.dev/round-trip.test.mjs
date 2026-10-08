#!/usr/bin/env node
// Round-trip verification for the JSON export/import feature of the Blocksmith
// item and animation editors.
//
// There is no browser-automation infra in this repo, so this script runs the
// real, unmodified app scripts (app.js / animation.js) inside Node's `vm`
// against a small stub DOM: canvases are backed by real pixel buffers that
// serialize to (and decode from) fake PNG data URLs, so the exported JSON
// carries genuine pixel payloads through FileReader/Image/Blob like in a
// browser. Each editor is exercised as three independent page loads:
//
//   session A — draw work, Export JSON, record the downloaded file + pixels
//   session B — fresh page with empty localStorage (simulates "clear site
//               data"); import session A's JSON; verify pixels/layers/timing
//               and that the previous work is one undo away
//   session C — fresh page with some work; import malformed, foreign-format,
//               wrong-version, and incomplete files, plus a cancelled import;
//               verify the work is untouched and friendly alerts fire
//
// Run:  node .dev/round-trip.test.mjs   (from anywhere)

import vm from "node:vm";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const ITEM_SOURCE = readFileSync(join(root, "app.js"), "utf8");
const ANIMATION_SOURCE = readFileSync(join(root, "animation.js"), "utf8");

let failures = 0;
function check(name, condition, detail = "") {
  console.log(`  ${condition ? "PASS" : "FAIL"}  ${name}${!condition && detail ? `  (${detail})` : ""}`);
  if (!condition) failures++;
}

const DATA_URL_PREFIX = "data:image/png;base64,";
function encodeImage(image) {
  return DATA_URL_PREFIX + Buffer.from(JSON.stringify({ w: image.width, h: image.height, d: Array.from(image.data) })).toString("base64");
}
function decodeImage(url) {
  const { w, h, d } = JSON.parse(Buffer.from(url.slice(DATA_URL_PREFIX.length), "base64").toString("utf8"));
  const image = new ImageData(w, h);
  image.data.set(d);
  return image;
}

class ImageData {
  constructor(a, b, c) {
    if (a && a.byteLength !== undefined) {
      this.data = new Uint8ClampedArray(a);
      this.width = b;
      this.height = c;
    } else {
      this.width = a;
      this.height = b;
      this.data = new Uint8ClampedArray(a * b * 4);
    }
  }
}

function parseStyle(style) {
  if (typeof style !== "string") return [0, 0, 0, 255];
  const hex = style.match(/^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i);
  if (hex) return [parseInt(hex[1], 16), parseInt(hex[2], 16), parseInt(hex[3], 16), 255];
  const rgb = style.match(/^rgb\((\d+),\s*(\d+),\s*(\d+)\)$/);
  if (rgb) return [Number(rgb[1]), Number(rgb[2]), Number(rgb[3]), 255];
  return [0, 0, 0, 255];
}

class CanvasCtx {
  constructor(canvas) {
    this.canvas = canvas;
    this.fillStyle = "#000000";
    this.strokeStyle = "#000000";
    this.lineWidth = 0;
    this.imageSmoothingEnabled = true;
  }
  clearRect(x, y, w, h) { this._fill(x, y, w, h, [0, 0, 0, 0]); }
  fillRect(x, y, w, h) { this._fill(x, y, w, h, parseStyle(this.fillStyle)); }
  _fill(x, y, w, h, rgba) {
    const c = this.canvas;
    for (let py = Math.max(0, y); py < Math.min(c.height, y + h); py++) {
      for (let px = Math.max(0, x); px < Math.min(c.width, x + w); px++) {
        const at = (py * c.width + px) * 4;
        c.backing.data[at] = rgba[0]; c.backing.data[at + 1] = rgba[1]; c.backing.data[at + 2] = rgba[2]; c.backing.data[at + 3] = rgba[3];
      }
    }
  }
  drawImage(src, ...args) {
    const source = src._image || src.backing;
    if (!source) return;
    const c = this.canvas;
    let sx = 0, sy = 0, sw = source.width, sh = source.height, dx = 0, dy = 0, dw = sw, dh = sh;
    if (args.length === 3) [dx, dy] = args;
    else if (args.length === 5) [dx, dy, dw, dh] = args;
    else if (args.length === 9) [sx, sy, sw, sh, dx, dy, dw, dh] = args;
    for (let py = 0; py < dh; py++) {
      const syi = sy + Math.min(sh - 1, Math.floor(py * sh / Math.max(1, dh)));
      const ty = dy + py;
      if (ty < 0 || ty >= c.height) continue;
      for (let px = 0; px < dw; px++) {
        const sxi = sx + Math.min(sw - 1, Math.floor(px * sw / Math.max(1, dw)));
        const tx = dx + px;
        if (tx < 0 || tx >= c.width) continue;
        const at = (syi * source.width + sxi) * 4;
        const to = (ty * c.width + tx) * 4;
        c.backing.data.set(source.data.subarray(at, at + 4), to);
      }
    }
  }
  getImageData(x, y, w, h) {
    const c = this.canvas;
    const out = new ImageData(Math.max(1, w), Math.max(1, h));
    for (let py = 0; py < out.height; py++) {
      const sy = y + py;
      if (sy < 0 || sy >= c.height) continue;
      for (let px = 0; px < out.width; px++) {
        const sx = x + px;
        if (sx < 0 || sx >= c.width) continue;
        out.data.set(c.backing.data.subarray((sy * c.width + sx) * 4, (sy * c.width + sx) * 4 + 4), (py * out.width + px) * 4);
      }
    }
    return out;
  }
  putImageData(img, x, y) {
    const c = this.canvas;
    for (let py = 0; py < img.height; py++) {
      const ty = y + py;
      if (ty < 0 || ty >= c.height) continue;
      for (let px = 0; px < img.width; px++) {
        const tx = x + px;
        if (tx < 0 || tx >= c.width) continue;
        c.backing.data.set(img.data.subarray((py * img.width + px) * 4, (py * img.width + px) * 4 + 4), (ty * c.width + tx) * 4);
      }
    }
  }
  beginPath() {} moveTo() {} lineTo() {} stroke() {}
}

class StubCanvas {
  constructor(width = 16, height = 16) {
    this._w = width; this._h = height;
    this.backing = new ImageData(width, height);
    this.style = { setProperty() {} };
    this._ctx = null;
    this.width = width; this.height = height;
  }
  get width() { return this._w; }
  set width(value) { this._w = value; this.backing = new ImageData(value, this._h); }
  get height() { return this._h; }
  set height(value) { this._h = value; this.backing = new ImageData(this._w, value); }
  getContext() { if (!this._ctx) this._ctx = new CanvasCtx(this); return this._ctx; }
  toDataURL() { return encodeImage(this.backing); }
  setPointerCapture() {}
  getBoundingClientRect() { return { left: 0, top: 0, width: this._w, height: this._h }; }
  addEventListener() {}
}

class StubImage {
  constructor() { this.naturalWidth = 0; this.naturalHeight = 0; this._image = null; }
  get src() { return this._src; }
  set src(value) {
    this._src = value;
    queueMicrotask(() => {
      if (!value) return;
      if (value.startsWith(DATA_URL_PREFIX)) {
        try { this._image = decodeImage(value); } catch { return this.onerror && this.onerror(new Error(value)); }
      } else {
        // A plain path (e.g. the CC:Tweaked preset textures): pretend it is a
        // solid-colour 16×16 texture, like a fetch through server.py would.
        const tint = value.includes("light") ? [200, 220, 255] : [245, 232, 70];
        const image = new ImageData(16, 16);
        for (let i = 0; i < image.data.length; i += 4) image.data.set([tint[0], tint[1], tint[2], 255], i);
        this._image = image;
      }
      this.naturalWidth = this._image.width;
      this.naturalHeight = this._image.height;
      this.onload && this.onload();
    });
  }
}

class StubFileReader {
  readAsText(file) { queueMicrotask(() => { this.result = file.content; this.onload && this.onload({ target: this }); }); }
  readAsDataURL(file) { queueMicrotask(() => { this.result = file.dataUrl; this.onload && this.onload({ target: this }); }); }
}

class StubBlob {
  constructor(parts, options = {}) {
    this.type = options.type || "";
    this.text = parts.map(part => (typeof part === "string" ? part : "")).join("");
  }
}

function makeElement(selector) {
  const el = {
    value: "", textContent: "", innerHTML: "", disabled: false, checked: false, hidden: false,
    title: "", className: "", type: "button", files: [], clientWidth: 640, clientHeight: 480,
    style: { setProperty() {} },
    dataset: {},
    firstChild: { textContent: "" },
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    addEventListener() {}, removeEventListener() {},
    replaceChildren() {}, append() {}, focus() {}, blur() {}, click() {},
    matches() { return false; },
  };
  if (selector === "#exportFormat") el.value = "png";
  if (selector === "#frametimeInput") el.value = 8;
  if (selector === "#gridToggle") el.checked = true;
  return el;
}

function makeContext() {
  const records = { alerts: [], confirms: [], downloads: [], urls: [] };
  const elements = new Map();
  const canvasIds = new Set(["#editorCanvas", "#gridCanvas"]);
  const element = selector => {
    if (!elements.has(selector)) {
      elements.set(selector, canvasIds.has(selector) ? new StubCanvas() : selector === "#inventoryPreview" ? new StubCanvas(18, 18) : makeElement(selector));
    }
    return elements.get(selector);
  };
  let nextUrl = 0;
  const storage = new Map();
  const context = {
    console,
    document: {
      querySelector: selector => element(selector),
      querySelectorAll() { return []; },
      createElement(tag) {
        if (tag === "canvas") return new StubCanvas();
        if (tag === "a") return { download: "", href: "", click() { records.downloads.push(this.download); } };
        return makeElement(tag);
      },
      addEventListener() {},
    },
    Image: StubImage,
    ImageData,
    FileReader: StubFileReader,
    Blob: StubBlob,
    URL: {
      createObjectURL: blob => { const url = `blob:stub-${nextUrl++}`; records.urls.push({ url, blob }); return url; },
      revokeObjectURL() {},
    },
    localStorage: {
      getItem: key => (storage.has(key) ? storage.get(key) : null),
      setItem: (key, value) => storage.set(key, String(value)),
      removeItem: key => storage.delete(key),
      clear: () => storage.clear(),
    },
    alert: message => records.alerts.push(message),
    confirm: message => { records.confirms.push(message); return context.confirmAnswer(); },
    confirmAnswer: () => true,
    alerts: records.alerts,
    confirms: records.confirms,
    downloads: records.downloads,
    urls: records.urls,
    setTimeout: (fn, ms, ...rest) => setTimeout(fn, ms, ...rest),
    setInterval: (fn, ms, ...rest) => setInterval(fn, ms, ...rest),
    clearTimeout: id => id && clearTimeout(id),
    clearInterval: id => id && clearInterval(id),
    fetch: () => Promise.reject(new Error("not available in the round-trip harness")),
  };
  vm.createContext(context);
  return context;
}

const TICK = `const tick = () => new Promise(resolve => setTimeout(resolve, 25));`;

// Run one "page load": the real app source plus an async driver (which can
// see the app's top-level state/functions because both are one script in the
// same realm) that stashes its findings on globalThis.__out.
function loadPage(source, driver, inject = {}) {
  const context = makeContext();
  for (const [key, value] of Object.entries(inject)) context[key] = value;
  vm.runInContext(source + "\n" + TICK + `\nglobalThis.__out = (async () => {\n${driver}\n})();`, context, { filename: "round-trip" });
  return { done: context.__out, context };
}

async function itemEditorTests() {
  console.log("Static item editor (app.js):");

  // Session A: create distinctive work and export it.
  const sessionA = loadPage(ITEM_SOURCE, `
    state.tool = "pencil";
    state.colour = "#ff0000"; paintPixel(2, 2);
    state.colour = "#00ff00"; paintPixel(7, 7);
    state.colour = "#0000ff"; paintPixel(11, 4);
    state.swatches = [...state.swatches, "#123456"];
    state.size = 2;
    saveProject();
    exportJson();
    await tick();
    globalThis.__export = {
      text: urls.at(-1).blob.text,
      downloadedAs: downloads.at(-1),
      pixels: Array.from(canvas.backing.data),
      storageImage: JSON.parse(localStorage.getItem(STORAGE_KEY)).image,
    };
  `);
  await sessionA.done;
  const a = sessionA.context.__export;
  const exported = JSON.parse(a.text);
  check("export downloads a versioned JSON project file", exported.format === "blocksmith-item" && exported.version === 1 && a.downloadedAs === "untitled_item.json");
  check("autosave object shape preserved, header appended last", JSON.stringify(Object.keys(exported)) === JSON.stringify(["image", "filename", "colour", "size", "variation", "exportFormat", "swatches", "format", "version"]));

  // Session B: fresh page, empty storage (simulated "clear site data"), import.
  const sessionB = loadPage(ITEM_SOURCE, `
    await tick();
    importJsonFile({ name: "my_item.json", type: "application/json", content: __importText });
    await tick();
    globalThis.__out2 = {
      pixelsAfterImport: Array.from(canvas.backing.data),
      undoLen: state.undo.length,
      storageImage: JSON.parse(localStorage.getItem(STORAGE_KEY)).image,
    };
    undo();
    await tick();
    globalThis.__pixelsAfterUndo = Array.from(canvas.backing.data);
  `, { __importText: a.text });
  await sessionB.done;
  const b = sessionB.context.__out2;
  check("round-trip: imported canvas is pixel-identical", JSON.stringify(b.pixelsAfterImport) === JSON.stringify(a.pixels));
  check("import pushed the pre-import canvas onto undo", b.undoLen === 1);
  check("undo restores the pre-import canvas", sessionB.context.__pixelsAfterUndo.every(v => v === 0));
  check("import re-autosaved the imported project", b.storageImage === a.storageImage);

  // Session C: foreign/corrupt files must not touch the work.
  const sessionC = loadPage(ITEM_SOURCE, `
    state.tool = "pencil"; state.colour = "#ff0000";
    pushUndo(); paintPixel(5, 5); saveProject();
    await tick();
    const before = Array.from(canvas.backing.data);
    importJsonFile({ name: "garbage.json", type: "application/json", content: "definitely not json" });
    await tick();
    importJsonFile({ name: "anim.json", type: "application/json", content: JSON.stringify({ format: "blocksmith-animation", version: 1, sheet: "data:image/png;base64,x" }) });
    await tick();
    importJsonFile({ name: "v2.json", type: "application/json", content: JSON.stringify({ format: "blocksmith-item", version: 2, image: "data:image/png;base64,x" }) });
    await tick();
    importJsonFile({ name: "anon.json", type: "application/json", content: JSON.stringify({ image: "data:image/png;base64,x" }) });
    await tick();
    confirmAnswer = () => false;
    importJsonFile({ name: "my_item.json", type: "application/json", content: __importText });
    await tick();
    globalThis.__workUntouched = JSON.stringify(Array.from(canvas.backing.data)) === JSON.stringify(before);
    globalThis.__sawConfirm = confirms.length === 1;
  `, { __importText: a.text });
  await sessionC.done;
    check("corrupt/foreign/wrong-version/incomplete imports leave work untouched", sessionC.context.__workUntouched);
  check("cancelled import (confirm = no) leaves work untouched", sessionC.context.__workUntouched);
  check("each bad file produced a friendly alert",
    sessionC.context.alerts.length === 4
    && sessionC.context.alerts.some(t => t.includes("not a valid JSON"))
    && sessionC.context.alerts.some(t => t.includes("animated sprite"))
    && sessionC.context.alerts.some(t => t.includes("version 2"))
    && sessionC.context.alerts.some(t => t.includes("not a Blocksmith item project")));
  check("only the valid file asked for confirmation", sessionC.context.__sawConfirm);
}

async function animationEditorTests() {
  console.log("Animated sprite editor (animation.js):");

  // Session A: build work across layers, set timing, export.
  const sessionA = loadPage(ANIMATION_SOURCE, `
    await tick();
    state.tool = "pencil";
    state.colour = "#ff0000"; paintPixel(3, 4); finishFrameEdit();
    state.activeLayer = "body"; state.ccLayers = true;
    state.colour = "#112233"; paintPixel(1, 1); finishFrameEdit();
    state.activeLayer = "light";
    state.colour = "#445566"; paintPixel(4, 2); finishFrameEdit();
    state.activeLayer = "animation";
    state.frametime = 5;
    exportJson();
    await tick();
    globalThis.__export = {
      text: urls.at(-1).blob.text,
      downloadedAs: downloads.at(-1),
      frame: Array.from(state.frames[0].data),
      body: Array.from(state.bodyLayer.data),
      light: Array.from(state.lightLayer.data),
      frametime: state.frametime,
      ccLayers: state.ccLayers,
    };
  `);
  await sessionA.done;
  const a = sessionA.context.__export;
  const exported = JSON.parse(a.text);
  check("export downloads a versioned JSON project file", exported.format === "blocksmith-animation" && exported.version === 1 && a.downloadedAs === "animated_item.json");
  check("export carries sheet, layers, and timing", typeof exported.sheet === "string" && exported.sheet.startsWith("data:image/png") && exported.bodyLayer && exported.lightLayer && exported.frametime === 5 && exported.ccLayers === true);

  // Session B: fresh page, import.
  const sessionB = loadPage(ANIMATION_SOURCE, `
    await tick();
    importJsonFile({ name: "my_animation.json", type: "application/json", content: __importText });
    await tick();
    globalThis.__out2 = {
      frame: Array.from(state.frames[0].data),
      body: Array.from(state.bodyLayer.data),
      light: Array.from(state.lightLayer.data),
      frametime: state.frametime,
      ccLayers: state.ccLayers,
      undoLen: state.undo.length,
      redoLen: state.redo.length,
      storageSheet: JSON.parse(localStorage.getItem(STORAGE_KEY)).sheet,
    };
    undo();
    await tick();
    globalThis.__afterUndoFrame0 = Array.from(state.frames[0].data);
  `, { __importText: a.text });
  await sessionB.done;
  const b = sessionB.context.__out2;
  const blank16 = Array.from(new ImageData(16, 16).data);
  check("round-trip: frame 0 is pixel-identical", JSON.stringify(b.frame) === JSON.stringify(a.frame));
  check("round-trip: body layer is pixel-identical", JSON.stringify(b.body) === JSON.stringify(a.body));
  check("round-trip: light layer is pixel-identical", JSON.stringify(b.light) === JSON.stringify(a.light));
  check("round-trip: frametime and CC-layer flag restored", b.frametime === 5 && b.ccLayers === true);
  check("import seeded undo (previous active-layer state) and cleared redo", b.undoLen === 1 && b.redoLen === 0);
  check("undo restores the pre-import frame", JSON.stringify(sessionB.context.__afterUndoFrame0) === JSON.stringify(blank16));
  check("import re-autosaved the imported sheet", b.storageSheet === exported.sheet);

  // Session C: bad files leave the work untouched.
  const sessionC = loadPage(ANIMATION_SOURCE, `
    await tick();
    state.tool = "pencil"; state.colour = "#ff0000";
    pushUndo(); paintPixel(2, 6); finishFrameEdit();
    await tick();
    const beforeFrame = Array.from(state.frames[0].data);
    const beforeFrame1 = Array.from(state.frames[1].data);
    importJsonFile({ name: "garbage.json", type: "application/json", content: "{ not json" });
    await tick();
    importJsonFile({ name: "item.json", type: "application/json", content: JSON.stringify({ format: "blocksmith-item", version: 1, image: "data:image/png;base64,x" }) });
    await tick();
    importJsonFile({ name: "v9.json", type: "application/json", content: JSON.stringify({ format: "blocksmith-animation", version: 9, sheet: "data:image/png;base64,x" }) });
    await tick();
    importJsonFile({ name: "half.json", type: "application/json", content: JSON.stringify({ format: "blocksmith-animation", version: 1 }) });
    await tick();
    confirmAnswer = () => false;
    importJsonFile({ name: "my_animation.json", type: "application/json", content: __importText });
    await tick();
    globalThis.__workUntouched = JSON.stringify(Array.from(state.frames[0].data)) === JSON.stringify(beforeFrame)
      && JSON.stringify(Array.from(state.frames[1].data)) === JSON.stringify(beforeFrame1);
    globalThis.__sawConfirm = confirms.length === 1;
  `, { __importText: a.text });
  await sessionC.done;
    check("corrupt/foreign/wrong-version/incomplete imports leave work untouched", sessionC.context.__workUntouched);
  check("cancelled import (confirm = no) leaves work untouched", sessionC.context.__workUntouched);
  check("each bad file produced a friendly alert",
    sessionC.context.alerts.length === 4
    && sessionC.context.alerts.some(t => t.includes("not a valid JSON"))
    && sessionC.context.alerts.some(t => t.includes("static item"))
    && sessionC.context.alerts.some(t => t.includes("version 9"))
    && sessionC.context.alerts.some(t => t.includes("not a complete Blocksmith animation")));
  check("only the valid file asked for confirmation", sessionC.context.__sawConfirm);
}

try {
  await itemEditorTests();
  await animationEditorTests();
} catch (error) {
  failures++;
  console.error("  FAIL  harness crashed:", error);
}
console.log(failures ? `\n${failures} check(s) FAILED` : "\nAll round-trip checks passed.");
process.exit(failures ? 1 : 0);
