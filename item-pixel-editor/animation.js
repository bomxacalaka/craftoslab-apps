"use strict";

const DEFAULT_SWATCHES = ["#eee846", "#e6a83b", "#d46536", "#9c3d3d", "#6e8f3c", "#3f7547", "#48a7a0", "#477fba", "#4d55a2", "#83549b", "#cf7194", "#efe4d0", "#9b8c77", "#5d5b57", "#292b2b", "#080909"];
const STORAGE_KEY = "blocksmith-animation-project-v1";
const JSON_FORMAT = "blocksmith-animation";
const CC_TEXTURES = "assets/computercraft/textures/item";

const canvas = document.querySelector("#editorCanvas");
const gridCanvas = document.querySelector("#gridCanvas");
const ctx = canvas.getContext("2d", { willReadFrequently: true });
const gridCtx = gridCanvas.getContext("2d");
const canvasWrap = document.querySelector("#canvasWrap");
const dropZone = document.querySelector("#dropZone");
const fileInput = document.querySelector("#fileInput");
const jsonInput = document.querySelector("#jsonInput");
const colourInput = document.querySelector("#colourInput");
const inventoryPreview = document.querySelector("#inventoryPreview");
const inventoryCtx = inventoryPreview.getContext("2d");
const frameRenderer = document.createElement("canvas");
const frameRendererCtx = frameRenderer.getContext("2d");

const state = {
  tool: "pencil",
  colour: "#eee846",
  size: 1,
  variation: 24,
  zoom: 24,
  drawing: false,
  rightErasing: false,
  straightLine: false,
  lineStart: null,
  lineBase: null,
  lastPoint: null,
  frames: [],
  currentFrame: 0,
  previewFrame: 0,
  frameSize: 16,
  frametime: 8,
  playing: true,
  playbackTimer: null,
  undo: [],
  redo: [],
  filename: "animated_item.png",
  exportFormat: "png",
  ccLayers: false,
  activeLayer: "animation",
  bodyLayer: null,
  lightLayer: null,
  swatches: [...DEFAULT_SWATCHES],
};

const ccAssetsPromise = Promise.all([
  imageDataFromSource(`${CC_TEXTURES}/pocket_computer_advanced.png`),
  imageDataFromSource(`${CC_TEXTURES}/pocket_computer_light.png`),
]);

function emptyFrame(size = state.frameSize) {
  return new ImageData(size, size);
}

function cloneImageData(image) {
  return new ImageData(new Uint8ClampedArray(image.data), image.width, image.height);
}

function snapshot() {
  return ctx.getImageData(0, 0, canvas.width, canvas.height);
}

function commitCurrentFrame() {
  if (!state.frames.length) return;
  if (state.activeLayer === "body") state.bodyLayer = snapshot();
  else if (state.activeLayer === "light") state.lightLayer = snapshot();
  else state.frames[state.currentFrame] = snapshot();
}

function currentEditableImage() {
  if (state.activeLayer === "body") return state.bodyLayer;
  if (state.activeLayer === "light") return state.lightLayer;
  return state.frames[state.currentFrame];
}

function historyEntry() {
  return { layer: state.activeLayer, frame: state.currentFrame, image: snapshot() };
}

function pushUndo() {
  state.undo.push(historyEntry());
  if (state.undo.length > 80) state.undo.shift();
  state.redo.length = 0;
  updateHistoryButtons();
}

function restoreHistory(entry) {
  commitCurrentFrame();
  state.activeLayer = entry.layer || "animation";
  state.currentFrame = entry.frame;
  if (state.activeLayer === "body") state.bodyLayer = cloneImageData(entry.image);
  else if (state.activeLayer === "light") state.lightLayer = cloneImageData(entry.image);
  else state.frames[entry.frame] = cloneImageData(entry.image);
  showCurrentFrame();
}

function undo() {
  if (!state.undo.length) return;
  state.redo.push(historyEntry());
  restoreHistory(state.undo.pop());
  updateHistoryButtons();
  saveProject();
}

function redo() {
  if (!state.redo.length) return;
  state.undo.push(historyEntry());
  restoreHistory(state.redo.pop());
  updateHistoryButtons();
  saveProject();
}

function updateHistoryButtons() {
  document.querySelector("#undoButton").disabled = !state.undo.length;
  document.querySelector("#redoButton").disabled = !state.redo.length;
}

function resizeCanvas(size, updateFrameSize = true) {
  if (updateFrameSize) state.frameSize = size;
  canvas.width = size;
  canvas.height = size;
  gridCanvas.width = size;
  gridCanvas.height = size;
  frameRenderer.width = size;
  frameRenderer.height = size;
  canvasWrap.style.setProperty("--canvas-w", size);
  canvasWrap.style.setProperty("--canvas-h", size);
  drawGrid();
  updateDimensions();
}

function drawGrid() {
  gridCtx.clearRect(0, 0, gridCanvas.width, gridCanvas.height);
  gridCtx.strokeStyle = "rgba(25, 25, 25, .38)";
  gridCtx.lineWidth = 0.045;
  for (let x = 1; x < gridCanvas.width; x++) {
    gridCtx.beginPath(); gridCtx.moveTo(x, 0); gridCtx.lineTo(x, gridCanvas.height); gridCtx.stroke();
  }
  for (let y = 1; y < gridCanvas.height; y++) {
    gridCtx.beginPath(); gridCtx.moveTo(0, y); gridCtx.lineTo(gridCanvas.width, y); gridCtx.stroke();
  }
}

function pointFromEvent(event) {
  const rect = canvas.getBoundingClientRect();
  return {
    x: Math.max(0, Math.min(canvas.width - 1, Math.floor((event.clientX - rect.left) * canvas.width / rect.width))),
    y: Math.max(0, Math.min(canvas.height - 1, Math.floor((event.clientY - rect.top) * canvas.height / rect.height))),
  };
}

function varyColour(hex) {
  const variation = state.variation / 100;
  const rgb = hex.match(/[a-f\d]{2}/gi).map(part => parseInt(part, 16));
  const strength = 1 + (Math.random() * 2 - 1) * 0.75 * variation;
  return `rgb(${rgb.map(channel => Math.max(0, Math.min(255, Math.round(channel * strength)))).join(",")})`;
}

function paintPixel(x, y) {
  const offset = Math.floor((state.size - 1) / 2);
  if (state.tool === "eraser" || state.rightErasing) {
    ctx.clearRect(x - offset, y - offset, state.size, state.size);
    return;
  }
  ctx.fillStyle = state.tool === "variable" ? varyColour(state.colour) : state.colour;
  ctx.fillRect(x - offset, y - offset, state.size, state.size);
}

function drawLine(from, to) {
  let x0 = from.x, y0 = from.y;
  const x1 = to.x, y1 = to.y;
  const dx = Math.abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
  const dy = -Math.abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
  let error = dx + dy;
  while (true) {
    paintPixel(x0, y0);
    if (x0 === x1 && y0 === y1) break;
    const twice = error * 2;
    if (twice >= dy) { error += dy; x0 += sx; }
    if (twice <= dx) { error += dx; y0 += sy; }
  }
}

function fillClickedArea(point, erase) {
  const image = snapshot();
  const startPixel = point.y * canvas.width + point.x;
  const target = Array.from(image.data.slice(startPixel * 4, startPixel * 4 + 4));
  const replacement = erase || state.tool === "eraser"
    ? [0, 0, 0, 0]
    : [...state.colour.match(/[a-f\d]{2}/gi).map(part => parseInt(part, 16)), 255];
  if (target.every((channel, index) => replacement[index] === channel)) return;
  const matchesTarget = offset => target[3] === 0
    ? image.data[offset + 3] === 0
    : target.every((channel, index) => image.data[offset + index] === channel);

  const queue = new Int32Array(canvas.width * canvas.height);
  let head = 0, tail = 0;
  queue[tail++] = startPixel;
  image.data.set(replacement, startPixel * 4);
  while (head < tail) {
    const pixel = queue[head++];
    const x = pixel % canvas.width;
    const neighbours = [];
    if (x > 0) neighbours.push(pixel - 1);
    if (x < canvas.width - 1) neighbours.push(pixel + 1);
    if (pixel >= canvas.width) neighbours.push(pixel - canvas.width);
    if (pixel < canvas.width * (canvas.height - 1)) neighbours.push(pixel + canvas.width);
    for (const neighbour of neighbours) {
      const offset = neighbour * 4;
      if (matchesTarget(offset)) {
        image.data.set(replacement, offset);
        queue[tail++] = neighbour;
      }
    }
  }
  ctx.putImageData(image, 0, 0);
}

canvas.addEventListener("pointerdown", event => {
  event.preventDefault();
  if (![0, 2].includes(event.button)) return;
  canvas.setPointerCapture(event.pointerId);
  const point = pointFromEvent(event);
  if (event.ctrlKey && event.shiftKey) {
    pushUndo();
    fillClickedArea(point, event.button === 2);
    finishFrameEdit();
    return;
  }
  if (state.tool === "picker" && event.button !== 2) {
    pickColour(point);
    return;
  }
  pushUndo();
  state.rightErasing = event.button === 2;
  state.drawing = true;
  state.straightLine = event.altKey;
  state.lineStart = point;
  state.lineBase = state.straightLine ? snapshot() : null;
  state.lastPoint = point;
  paintPixel(point.x, point.y);
  commitCurrentFrame();
  if (!state.playing) updateInventoryPreview();
});

canvas.addEventListener("pointermove", event => {
  if (!state.drawing) return;
  const point = pointFromEvent(event);
  if (point.x === state.lastPoint.x && point.y === state.lastPoint.y) return;
  if (state.straightLine) {
    ctx.putImageData(state.lineBase, 0, 0);
    drawLine(state.lineStart, point);
  } else {
    drawLine(state.lastPoint, point);
  }
  state.lastPoint = point;
  commitCurrentFrame();
  if (!state.playing) updateInventoryPreview();
});

function finishFrameEdit() {
  commitCurrentFrame();
  updateFramePalette();
  renderTimeline();
  updateInventoryPreview();
  saveProject();
}

function stopDrawing() {
  if (state.drawing) finishFrameEdit();
  state.drawing = false;
  state.rightErasing = false;
  state.straightLine = false;
  state.lineStart = null;
  state.lineBase = null;
  state.lastPoint = null;
}

canvas.addEventListener("pointerup", stopDrawing);
canvas.addEventListener("pointercancel", stopDrawing);
canvas.addEventListener("contextmenu", event => event.preventDefault());

function selectTool(tool) {
  state.tool = tool;
  document.querySelectorAll(".tool").forEach(button => button.classList.toggle("active", button.dataset.tool === tool));
  document.querySelector("#variationControl").style.opacity = tool === "variable" ? "1" : ".45";
  canvas.style.cursor = tool === "picker" ? "copy" : "crosshair";
}

function rgbaToHex(data) {
  return `#${[data[0], data[1], data[2]].map(value => value.toString(16).padStart(2, "0")).join("")}`;
}

function pickColour(point) {
  const pixel = ctx.getImageData(point.x, point.y, 1, 1).data;
  if (pixel[3]) setColour(rgbaToHex(pixel));
}

function setColour(hex) {
  state.colour = hex.toLowerCase();
  colourInput.value = state.colour;
  document.querySelector("#colourPreview").style.background = state.colour;
  document.querySelector("#hexValue").textContent = state.colour.toUpperCase();
  renderSwatches();
  saveProject();
}

function renderSwatches() {
  const host = document.querySelector("#swatches");
  host.replaceChildren(...state.swatches.map(colour => {
    const button = document.createElement("button");
    button.className = `swatch${colour.toLowerCase() === state.colour ? " selected" : ""}`;
    button.style.setProperty("--swatch", colour);
    button.title = colour.toUpperCase();
    button.addEventListener("click", () => setColour(colour));
    return button;
  }));
}

function updateFramePalette() {
  const pixels = snapshot().data;
  const counts = new Map();
  for (let index = 0; index < pixels.length; index += 4) {
    if (pixels[index + 3] < 32) continue;
    const hex = rgbaToHex(pixels.slice(index, index + 4));
    counts.set(hex, (counts.get(hex) || 0) + 1);
  }
  const colours = [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 16).map(entry => entry[0]);
  const host = document.querySelector("#itemSwatches");
  host.replaceChildren(...colours.map(colour => {
    const button = document.createElement("button");
    button.className = "swatch";
    button.style.setProperty("--swatch", colour);
    button.title = colour.toUpperCase();
    button.addEventListener("click", () => setColour(colour));
    return button;
  }));
}

function drawInventorySlot() {
  inventoryCtx.clearRect(0, 0, 18, 18);
  inventoryCtx.fillStyle = "#8b8b8b";
  inventoryCtx.fillRect(0, 0, 18, 18);
  inventoryCtx.fillStyle = "#373737";
  inventoryCtx.fillRect(0, 0, 17, 1);
  inventoryCtx.fillRect(0, 0, 1, 17);
  inventoryCtx.fillStyle = "#ffffff";
  inventoryCtx.fillRect(1, 17, 17, 1);
  inventoryCtx.fillRect(17, 1, 1, 17);
}

function drawLayerInSlot(image) {
  if (!image) return;
  frameRenderer.width = image.width;
  frameRenderer.height = image.height;
  frameRendererCtx.clearRect(0, 0, image.width, image.height);
  frameRendererCtx.putImageData(image, 0, 0);
  inventoryCtx.drawImage(frameRenderer, 1, 1, 16, 16);
}

function updateInventoryPreview(frameIndex = state.playing ? state.previewFrame : state.currentFrame) {
  if (!state.frames.length) return;
  drawInventorySlot();
  inventoryCtx.imageSmoothingEnabled = false;
  drawLayerInSlot(state.frames[Math.min(frameIndex, state.frames.length - 1)]);
  if (state.ccLayers) {
    drawLayerInSlot(state.bodyLayer);
    drawLayerInSlot(state.lightLayer);
  }
  document.querySelectorAll(".frame-card").forEach((card, index) => card.classList.toggle("previewing", index === frameIndex));
}

function showCurrentFrame() {
  const editable = currentEditableImage();
  if (!editable) return;
  if (canvas.width !== editable.width) resizeCanvas(editable.width, state.activeLayer === "animation");
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.putImageData(editable, 0, 0);
  state.previewFrame = state.currentFrame;
  updateFramePalette();
  renderTimeline();
  updateLayerControls();
  updateInventoryPreview();
  updateDimensions();
}

function selectLayer(layer) {
  if (!["animation", "body", "light"].includes(layer) || layer === state.activeLayer) return;
  commitCurrentFrame();
  state.activeLayer = layer;
  if (layer !== "animation") {
    state.ccLayers = true;
    document.querySelector("#ccLayersToggle").checked = true;
  }
  showCurrentFrame();
  fitZoom();
  saveProject();
}

function updateLayerControls() {
  document.querySelectorAll("[data-layer]").forEach(button => button.classList.toggle("active", button.dataset.layer === state.activeLayer));
  const exportButton = document.querySelector("#exportLayerButton");
  exportButton.hidden = state.activeLayer === "animation";
  if (!exportButton.hidden) exportButton.textContent = state.activeLayer === "body" ? "Export body PNG" : "Export light PNG";
}

function selectFrame(index) {
  if (index < 0 || index >= state.frames.length || index === state.currentFrame) return;
  commitCurrentFrame();
  state.currentFrame = index;
  showCurrentFrame();
  saveProject();
}

function renderTimeline() {
  const strip = document.querySelector("#frameStrip");
  strip.replaceChildren(...state.frames.map((frame, index) => {
    const card = document.createElement("button");
    card.type = "button";
    card.className = `frame-card${index === state.currentFrame ? " active" : ""}${index === state.previewFrame ? " previewing" : ""}`;
    const thumbnail = document.createElement("canvas");
    thumbnail.width = state.frameSize;
    thumbnail.height = state.frameSize;
    const thumbnailScale = Math.max(1, Math.floor(48 / state.frameSize));
    const thumbnailSize = state.frameSize * thumbnailScale;
    thumbnail.style.width = `${thumbnailSize}px`;
    thumbnail.style.height = `${thumbnailSize}px`;
    card.style.width = `${thumbnailSize + 12}px`;
    thumbnail.getContext("2d").putImageData(frame, 0, 0);
    const label = document.createElement("span");
    label.textContent = `FRAME ${index + 1}`;
    card.append(thumbnail, label);
    card.addEventListener("click", () => selectFrame(index));
    return card;
  }));
  document.querySelector("#deleteFrameButton").disabled = state.frames.length <= 1;
  updateDimensions();
}

function addBlankFrame() {
  commitCurrentFrame();
  state.frames.splice(state.currentFrame + 1, 0, emptyFrame());
  state.currentFrame++;
  state.undo.length = state.redo.length = 0;
  showCurrentFrame();
  restartPlayback();
  saveProject();
}

function duplicateFrame() {
  commitCurrentFrame();
  state.frames.splice(state.currentFrame + 1, 0, cloneImageData(state.frames[state.currentFrame]));
  state.currentFrame++;
  state.undo.length = state.redo.length = 0;
  showCurrentFrame();
  restartPlayback();
  saveProject();
}

function deleteFrame() {
  if (state.frames.length <= 1) return;
  state.frames.splice(state.currentFrame, 1);
  state.currentFrame = Math.min(state.currentFrame, state.frames.length - 1);
  state.undo.length = state.redo.length = 0;
  showCurrentFrame();
  restartPlayback();
  saveProject();
}

function updateDimensions() {
  const layerName = state.activeLayer === "body" ? "advanced body layer" : state.activeLayer === "light" ? "light overlay" : `${state.frames.length} frame${state.frames.length === 1 ? "" : "s"}`;
  document.querySelector("#dimensions").textContent = `${canvas.width} × ${canvas.height} px · ${layerName}`;
}

function restartPlayback() {
  clearInterval(state.playbackTimer);
  state.playbackTimer = null;
  document.querySelector("#playButton").textContent = state.playing ? "❚❚" : "▶";
  if (!state.playing || state.frames.length < 2) {
    state.previewFrame = state.currentFrame;
    updateInventoryPreview();
    return;
  }
  state.previewFrame %= state.frames.length;
  state.playbackTimer = setInterval(() => {
    state.previewFrame = (state.previewFrame + 1) % state.frames.length;
    updateInventoryPreview();
  }, state.frametime * 50);
}

function makeSheetCanvas() {
  commitCurrentFrame();
  const sheet = document.createElement("canvas");
  sheet.width = state.frameSize;
  sheet.height = state.frameSize * state.frames.length;
  const sheetCtx = sheet.getContext("2d");
  state.frames.forEach((frame, index) => sheetCtx.putImageData(frame, 0, index * state.frameSize));
  return sheet;
}

function imageDataCanvas(image) {
  const output = document.createElement("canvas");
  output.width = image.width;
  output.height = image.height;
  output.getContext("2d").putImageData(image, 0, 0);
  return output;
}

function imageDataFromSource(source) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => {
      const output = document.createElement("canvas");
      output.width = image.naturalWidth;
      output.height = image.naturalHeight;
      const outputCtx = output.getContext("2d", { willReadFrequently: true });
      outputCtx.drawImage(image, 0, 0);
      resolve(outputCtx.getImageData(0, 0, output.width, output.height));
    };
    image.onerror = reject;
    image.src = source;
  });
}

function loadSpriteSheet(source, filename, options = {}) {
  const image = new Image();
  image.onload = () => {
    if (!image.naturalWidth || image.naturalHeight % image.naturalWidth !== 0) {
      alert("Minecraft sprite sheets must contain square frames stacked vertically.");
      return;
    }
    const size = image.naturalWidth;
    const count = image.naturalHeight / size;
    const sourceCanvas = document.createElement("canvas");
    sourceCanvas.width = size;
    sourceCanvas.height = image.naturalHeight;
    const sourceCtx = sourceCanvas.getContext("2d", { willReadFrequently: true });
    sourceCtx.drawImage(image, 0, 0);
    resizeCanvas(size);
    state.frames = Array.from({ length: count }, (_, index) => sourceCtx.getImageData(0, index * size, size, size));
    state.currentFrame = Math.min(options.currentFrame || 0, count - 1);
    state.previewFrame = state.currentFrame;
    state.bodyLayer = options.bodyLayer ? cloneImageData(options.bodyLayer) : (state.bodyLayer || emptyFrame(16));
    state.lightLayer = options.lightLayer ? cloneImageData(options.lightLayer) : (state.lightLayer || emptyFrame(16));
    state.activeLayer = ["animation", "body", "light"].includes(options.activeLayer) ? options.activeLayer : "animation";
    state.filename = filename.replace(/\.(?:png|webp)$/i, "") + (/\.webp$/i.test(filename) ? ".webp" : ".png");
    state.exportFormat = options.exportFormat || (/\.webp$/i.test(filename) ? "webp" : "png");
    state.frametime = Math.max(1, Number(options.frametime) || 8);
    state.ccLayers = Boolean(options.ccLayers);
    state.undo = options.restoreUndo ? [options.restoreUndo] : [];
    state.redo.length = 0;
    document.querySelector("#documentName").textContent = state.filename;
    document.querySelector("#exportFormat").value = state.exportFormat;
    document.querySelector("#frametimeInput").value = state.frametime;
    document.querySelector("#secondsOutput").textContent = `${(state.frametime / 20).toFixed(2)} s`;
    document.querySelector("#ccLayersToggle").checked = state.ccLayers;
    fitZoom();
    showCurrentFrame();
    updateHistoryButtons();
    restartPlayback();
    if (!options.restoring) saveProject();
  };
  image.onerror = () => alert("That sprite sheet could not be opened.");
  image.src = source;
}

async function importFile(file) {
  if (file && (file.type === "application/json" || /\.json$/i.test(file.name))) { await importJsonFile(file); return; }
  const supported = file && (["image/png", "image/webp"].includes(file.type) || /\.(?:png|webp)$/i.test(file.name));
  if (!supported) return alert("Please choose a PNG or WebP sprite sheet.");
  const isCcBlink = /pocket_computer_blink/i.test(file.name);
  const [bodyLayer, lightLayer] = isCcBlink ? await ccAssetsPromise : [state.bodyLayer, state.lightLayer];
  const reader = new FileReader();
  reader.onload = () => loadSpriteSheet(reader.result, file.name, { ccLayers: isCcBlink, bodyLayer, lightLayer });
  reader.readAsDataURL(file);
}

function projectPayload() {
  return {
    sheet: makeSheetCanvas().toDataURL("image/png"),
    filename: state.filename,
    currentFrame: state.currentFrame,
    frametime: state.frametime,
    exportFormat: state.exportFormat,
    ccLayers: state.ccLayers,
    activeLayer: state.activeLayer,
    bodyLayer: state.bodyLayer ? imageDataCanvas(state.bodyLayer).toDataURL("image/png") : null,
    lightLayer: state.lightLayer ? imageDataCanvas(state.lightLayer).toDataURL("image/png") : null,
    colour: state.colour,
    size: state.size,
    variation: state.variation,
    swatches: state.swatches,
  };
}

function downloadJson(object, filename) {
  const blob = new Blob([`${JSON.stringify(object, null, 2)}\n`], { type: "application/json" });
  download(URL.createObjectURL(blob), filename, true);
}

function exportJson() {
  downloadJson({ ...projectPayload(), format: JSON_FORMAT, version: 1 }, `${baseFilename()}.json`);
}

async function importJsonFile(file) {
  const text = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = reject;
    reader.readAsText(file);
  });
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    return alert("That file is not a valid JSON project file.");
  }
  if (parsed?.format === "blocksmith-item") return alert("That is a static item project — open the Static item tab to import it.");
  if (parsed?.format !== JSON_FORMAT) return alert("That file is not a Blocksmith animation project for this editor.");
  if (parsed.version !== undefined && parsed.version !== 1) return alert(`This project file is version ${parsed.version}; this editor understands version 1.`);
  if (typeof parsed.sheet !== "string" || !parsed.sheet) return alert("That file is not a complete Blocksmith animation project.");
  if (!confirm(`Import ${file.name}? This replaces your current work (you can still undo).`)) return;
  applySavedSettings(parsed);
  commitCurrentFrame();
  const previous = historyEntry();
  try {
    const defaults = await ccAssetsPromise;
    const [bodyLayer, lightLayer] = await Promise.all([
      parsed.bodyLayer ? imageDataFromSource(parsed.bodyLayer) : Promise.resolve(defaults[0]),
      parsed.lightLayer ? imageDataFromSource(parsed.lightLayer) : Promise.resolve(defaults[1]),
    ]);
    loadSpriteSheet(parsed.sheet, parsed.filename || "animated_item.png", { ...parsed, bodyLayer, lightLayer, restoreUndo: previous });
  } catch (error) {
    alert("That project file could not be opened.");
  }
}

function applySavedSettings(saved) {
  if (/^#[0-9a-f]{6}$/i.test(saved.colour || "")) state.colour = saved.colour.toLowerCase();
  if (Number.isInteger(saved.size) && saved.size >= 1 && saved.size <= 4) state.size = saved.size;
  if (Number.isFinite(saved.variation) && saved.variation >= 0 && saved.variation <= 100) state.variation = saved.variation;
  if (Array.isArray(saved.swatches)) state.swatches = saved.swatches.filter(colour => /^#[0-9a-f]{6}$/i.test(colour)).slice(0, 48);
  document.querySelector("#sizeRange").value = state.size;
  document.querySelector("#sizeOutput").textContent = `${state.size} px`;
  document.querySelector("#variationRange").value = state.variation;
  document.querySelector("#variationOutput").textContent = `${state.variation}%`;
  setColour(state.colour);
}

function newAnimation() {
  resizeCanvas(16);
  state.frames = [emptyFrame(16), emptyFrame(16)];
  state.currentFrame = 0;
  state.previewFrame = 0;
  state.filename = "animated_item.png";
  state.frametime = 8;
  state.ccLayers = false;
  state.activeLayer = "animation";
  if (!state.bodyLayer) state.bodyLayer = emptyFrame(16);
  if (!state.lightLayer) state.lightLayer = emptyFrame(16);
  state.undo.length = state.redo.length = 0;
  document.querySelector("#documentName").textContent = state.filename;
  document.querySelector("#frametimeInput").value = 8;
  document.querySelector("#secondsOutput").textContent = "0.40 s";
  document.querySelector("#ccLayersToggle").checked = false;
  showCurrentFrame();
  fitZoom();
  updateHistoryButtons();
  restartPlayback();
  saveProject();
}

function exportSheet() {
  const mime = state.exportFormat === "webp" ? "image/webp" : "image/png";
  const url = makeSheetCanvas().toDataURL(mime, 1);
  if (!url.startsWith(`data:${mime}`)) return alert(`This browser cannot export ${state.exportFormat.toUpperCase()}.`);
  download(url, `${baseFilename()}.${state.exportFormat}`);
}

function exportMetadata() {
  const metadata = { animation: { frametime: state.frametime, frames: state.frames.map((_, index) => index) } };
  const blob = new Blob([`${JSON.stringify(metadata, null, 2)}\n`], { type: "application/json" });
  download(URL.createObjectURL(blob), `${baseFilename()}.${state.exportFormat}.mcmeta`, true);
}

function exportCurrentLayer() {
  commitCurrentFrame();
  const image = state.activeLayer === "body" ? state.bodyLayer : state.lightLayer;
  const filename = state.activeLayer === "body" ? "pocket_computer_advanced.png" : "pocket_computer_light.png";
  download(imageDataCanvas(image).toDataURL("image/png"), filename);
}

function crc32(bytes) {
  if (!crc32.table) {
    crc32.table = Array.from({ length: 256 }, (_, value) => {
      let crc = value;
      for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
      return crc >>> 0;
    });
  }
  let crc = 0xffffffff;
  for (const byte of bytes) crc = (crc >>> 8) ^ crc32.table[(crc ^ byte) & 0xff];
  return (crc ^ 0xffffffff) >>> 0;
}

function zipTimestamp() {
  const now = new Date();
  return {
    time: (now.getHours() << 11) | (now.getMinutes() << 5) | (now.getSeconds() >> 1),
    date: ((Math.max(1980, now.getFullYear()) - 1980) << 9) | ((now.getMonth() + 1) << 5) | now.getDate(),
  };
}

function createZip(entries) {
  const encoder = new TextEncoder();
  const localParts = [];
  const centralParts = [];
  const stamp = zipTimestamp();
  let offset = 0;

  for (const entry of entries) {
    const name = encoder.encode(entry.name);
    const data = entry.data instanceof Uint8Array ? entry.data : encoder.encode(entry.data);
    const checksum = crc32(data);
    const local = new Uint8Array(30 + name.length);
    const localView = new DataView(local.buffer);
    localView.setUint32(0, 0x04034b50, true);
    localView.setUint16(4, 20, true);
    localView.setUint16(6, 0, true);
    localView.setUint16(8, 0, true);
    localView.setUint16(10, stamp.time, true);
    localView.setUint16(12, stamp.date, true);
    localView.setUint32(14, checksum, true);
    localView.setUint32(18, data.length, true);
    localView.setUint32(22, data.length, true);
    localView.setUint16(26, name.length, true);
    localView.setUint16(28, 0, true);
    local.set(name, 30);
    localParts.push(local, data);

    const central = new Uint8Array(46 + name.length);
    const centralView = new DataView(central.buffer);
    centralView.setUint32(0, 0x02014b50, true);
    centralView.setUint16(4, 20, true);
    centralView.setUint16(6, 20, true);
    centralView.setUint16(8, 0, true);
    centralView.setUint16(10, 0, true);
    centralView.setUint16(12, stamp.time, true);
    centralView.setUint16(14, stamp.date, true);
    centralView.setUint32(16, checksum, true);
    centralView.setUint32(20, data.length, true);
    centralView.setUint32(24, data.length, true);
    centralView.setUint16(28, name.length, true);
    centralView.setUint16(30, 0, true);
    centralView.setUint16(32, 0, true);
    centralView.setUint16(34, 0, true);
    centralView.setUint16(36, 0, true);
    centralView.setUint32(38, 0, true);
    centralView.setUint32(42, offset, true);
    central.set(name, 46);
    centralParts.push(central);
    offset += local.length + data.length;
  }

  const centralSize = centralParts.reduce((total, part) => total + part.length, 0);
  const end = new Uint8Array(22);
  const endView = new DataView(end.buffer);
  endView.setUint32(0, 0x06054b50, true);
  endView.setUint16(4, 0, true);
  endView.setUint16(6, 0, true);
  endView.setUint16(8, entries.length, true);
  endView.setUint16(10, entries.length, true);
  endView.setUint32(12, centralSize, true);
  endView.setUint32(16, offset, true);
  endView.setUint16(20, 0, true);
  return new Blob([...localParts, ...centralParts, end], { type: "application/zip" });
}

async function canvasPngBytes(sourceCanvas) {
  const blob = await new Promise(resolve => sourceCanvas.toBlob(resolve, "image/png"));
  return new Uint8Array(await blob.arrayBuffer());
}

async function fetchedBytes(path) {
  const response = await fetch(path);
  if (!response.ok) throw new Error(`Could not include ${path}`);
  return new Uint8Array(await response.arrayBuffer());
}

function makePackIcon() {
  const icon = document.createElement("canvas");
  icon.width = 64;
  icon.height = 64;
  const iconCtx = icon.getContext("2d");
  iconCtx.fillStyle = "#202122";
  iconCtx.fillRect(0, 0, 64, 64);
  iconCtx.imageSmoothingEnabled = false;
  const draw = image => iconCtx.drawImage(imageDataCanvas(image), 8, 8, 48, 48);
  draw(state.frames[0]);
  draw(state.bodyLayer);
  draw(state.lightLayer);
  return icon;
}

async function exportPackZip() {
  const button = document.querySelector("#exportButton");
  const oldText = button.innerHTML;
  button.disabled = true;
  button.textContent = "Building pack…";
  try {
    commitCurrentFrame();
    const root = "assets/computercraft";
    const textureRoot = `${root}/textures/item`;
    const modelNames = [
      "pocket_computer_advanced.json",
      "pocket_computer_advanced_on.json",
      "pocket_computer_advanced_blinking.json",
      "pocket_computer_colour.json",
      "pocket_computer_colour_on.json",
      "pocket_computer_colour_blinking.json",
    ];
    const unchangedTextures = ["pocket_computer_frame.png", "pocket_computer_on.png", "pocket_computer_colour.png"];
    const metadata = { animation: { frametime: state.frametime, frames: state.frames.map((_, index) => index) } };
    const entries = [
      {
        name: "pack.mcmeta",
        data: `${JSON.stringify({ pack: { pack_format: 34, description: "Blocksmith animated CC:Tweaked pocket computer" } }, null, 2)}\n`,
      },
      {
        name: "BLOCKSMITH-README.txt",
        data: "Blocksmith CC:Tweaked animated pocket computer resource pack\n\nMinecraft: 1.21.1\nCC:Tweaked: 1.120.0\n\nInstall: place this ZIP in your Minecraft resourcepacks folder and enable it in Options > Resource Packs.\n",
      },
      { name: `${textureRoot}/pocket_computer_blink.png`, data: await canvasPngBytes(makeSheetCanvas()) },
      { name: `${textureRoot}/pocket_computer_blink.png.mcmeta`, data: `${JSON.stringify(metadata, null, 2)}\n` },
      { name: `${textureRoot}/pocket_computer_advanced.png`, data: await canvasPngBytes(imageDataCanvas(state.bodyLayer)) },
      { name: `${textureRoot}/pocket_computer_light.png`, data: await canvasPngBytes(imageDataCanvas(state.lightLayer)) },
      { name: "pack.png", data: await canvasPngBytes(makePackIcon()) },
    ];
    const bundled = await Promise.all([
      ...modelNames.map(async name => ({ name: `${root}/models/item/${name}`, data: await fetchedBytes(`${root}/models/item/${name}`) })),
      ...unchangedTextures.map(async name => ({ name: `${textureRoot}/${name}`, data: await fetchedBytes(`${textureRoot}/${name}`) })),
    ]);
    entries.push(...bundled);
    const zipUrl = URL.createObjectURL(createZip(entries));
    download(zipUrl, `${baseFilename()}-resource-pack.zip`, true);
  } catch (error) {
    console.error(error);
    alert("The resource pack could not be built. Make sure the editor is running through server.py.");
  } finally {
    button.disabled = false;
    button.innerHTML = oldText;
  }
}

function baseFilename() {
  return state.filename.replace(/\.(?:png|webp)$/i, "") || "animated_item";
}

function download(url, filename, revoke = false) {
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  if (revoke) setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function saveProject() {
  if (!state.frames.length) return;
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(projectPayload()));
  } catch (error) {
    console.warn("Could not save the animation locally.", error);
  }
}

async function restoreProject() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    if (saved?.sheet) {
      applySavedSettings(saved);
      const defaults = await ccAssetsPromise;
      const [bodyLayer, lightLayer] = await Promise.all([
        saved.bodyLayer ? imageDataFromSource(saved.bodyLayer) : Promise.resolve(defaults[0]),
        saved.lightLayer ? imageDataFromSource(saved.lightLayer) : Promise.resolve(defaults[1]),
      ]);
      loadSpriteSheet(saved.sheet, saved.filename || "animated_item.png", { ...saved, bodyLayer, lightLayer, restoring: true });
      return;
    }
  } catch (error) {
    console.warn("Could not restore the saved animation.", error);
  }
  newAnimation();
}

function setZoom(value) {
  state.zoom = Math.max(4, Math.min(48, value));
  canvasWrap.style.setProperty("--zoom", state.zoom);
  document.querySelector("#zoomOutput").textContent = `${state.zoom * 100}%`;
}

function fitZoom() {
  const maxWidth = Math.max(240, dropZone.clientWidth - 100);
  const maxHeight = Math.max(240, dropZone.clientHeight - 300);
  setZoom(Math.max(4, Math.min(32, Math.floor(Math.min(maxWidth, maxHeight) / canvas.width))));
}

document.querySelectorAll(".tool").forEach(button => button.addEventListener("click", () => selectTool(button.dataset.tool)));
document.querySelector("#importButton").addEventListener("click", () => fileInput.click());
document.querySelector("#exportJsonButton").addEventListener("click", exportJson);
document.querySelector("#importJsonButton").addEventListener("click", () => jsonInput.click());
document.querySelector("#newButton").addEventListener("click", newAnimation);
document.querySelector("#ccPresetButton").addEventListener("click", async () => {
  const [bodyLayer, lightLayer] = await ccAssetsPromise;
  loadSpriteSheet(`${CC_TEXTURES}/pocket_computer_blink.png`, "pocket_computer_blink.png", { frametime: 8, ccLayers: true, bodyLayer, lightLayer });
});
fileInput.addEventListener("change", () => { importFile(fileInput.files[0]); fileInput.value = ""; });
jsonInput.addEventListener("change", () => { importFile(jsonInput.files[0]); jsonInput.value = ""; });
document.querySelector("#exportButton").addEventListener("click", exportPackZip);
document.querySelector("#sheetButton").addEventListener("click", exportSheet);
document.querySelector("#metaButton").addEventListener("click", exportMetadata);
document.querySelector("#exportLayerButton").addEventListener("click", exportCurrentLayer);
document.querySelectorAll("[data-layer]").forEach(button => button.addEventListener("click", () => selectLayer(button.dataset.layer)));
document.querySelector("#exportFormat").addEventListener("change", event => { state.exportFormat = event.target.value; saveProject(); });
document.querySelector("#undoButton").addEventListener("click", undo);
document.querySelector("#redoButton").addEventListener("click", redo);
document.querySelector("#addFrameButton").addEventListener("click", addBlankFrame);
document.querySelector("#duplicateFrameButton").addEventListener("click", duplicateFrame);
document.querySelector("#deleteFrameButton").addEventListener("click", deleteFrame);
document.querySelector("#playButton").addEventListener("click", () => { state.playing = !state.playing; restartPlayback(); });
document.querySelector("#frametimeInput").addEventListener("change", event => {
  state.frametime = Math.max(1, Math.min(200, Number(event.target.value) || 1));
  event.target.value = state.frametime;
  document.querySelector("#secondsOutput").textContent = `${(state.frametime / 20).toFixed(2)} s`;
  restartPlayback();
  saveProject();
});
document.querySelector("#ccLayersToggle").addEventListener("change", event => {
  state.ccLayers = event.target.checked;
  if (!state.ccLayers && state.activeLayer !== "animation") selectLayer("animation");
  updateInventoryPreview();
  saveProject();
});
document.querySelector("#zoomIn").addEventListener("click", () => setZoom(state.zoom + 2));
document.querySelector("#zoomOut").addEventListener("click", () => setZoom(state.zoom - 2));
document.querySelector("#gridToggle").addEventListener("change", event => canvasWrap.classList.toggle("no-grid", !event.target.checked));
document.querySelector("#sizeRange").addEventListener("input", event => { state.size = Number(event.target.value); document.querySelector("#sizeOutput").textContent = `${state.size} px`; saveProject(); });
document.querySelector("#variationRange").addEventListener("input", event => { state.variation = Number(event.target.value); document.querySelector("#variationOutput").textContent = `${state.variation}%`; saveProject(); });
document.querySelector("#colourPreview").addEventListener("click", () => colourInput.click());
colourInput.addEventListener("input", event => setColour(event.target.value));
document.querySelector("#addSwatch").addEventListener("click", () => { if (!state.swatches.some(colour => colour.toLowerCase() === state.colour)) state.swatches.unshift(state.colour); renderSwatches(); saveProject(); });
document.querySelector("#refreshPalette").addEventListener("click", updateFramePalette);

let dragDepth = 0;
dropZone.addEventListener("dragenter", event => { event.preventDefault(); dragDepth++; dropZone.classList.add("dragging"); });
dropZone.addEventListener("dragover", event => event.preventDefault());
dropZone.addEventListener("dragleave", () => { dragDepth--; if (dragDepth <= 0) { dragDepth = 0; dropZone.classList.remove("dragging"); } });
dropZone.addEventListener("drop", event => { event.preventDefault(); dragDepth = 0; dropZone.classList.remove("dragging"); importFile(event.dataTransfer.files[0]); });

document.addEventListener("keydown", event => {
  const command = event.ctrlKey || event.metaKey;
  if (command && event.key.toLowerCase() === "z") { event.preventDefault(); event.shiftKey ? redo() : undo(); return; }
  if (command && event.key.toLowerCase() === "y") { event.preventDefault(); redo(); return; }
  if (event.target.matches("input")) return;
  const tools = { b: "pencil", v: "variable", e: "eraser", i: "picker" };
  if (tools[event.key.toLowerCase()]) selectTool(tools[event.key.toLowerCase()]);
  if (event.key === " ") { event.preventDefault(); state.playing = !state.playing; restartPlayback(); }
});

renderSwatches();
selectTool("pencil");
restoreProject();
