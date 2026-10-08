"use strict";

const DEFAULT_SWATCHES = ["#eee846", "#e6a83b", "#d46536", "#9c3d3d", "#6e8f3c", "#3f7547", "#48a7a0", "#477fba", "#4d55a2", "#83549b", "#cf7194", "#efe4d0", "#9b8c77", "#5d5b57", "#292b2b", "#080909"];
const STORAGE_KEY = "blocksmith-item-project-v1";
const JSON_FORMAT = "blocksmith-item";

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
  undo: [],
  redo: [],
  filename: "untitled_item.png",
  exportFormat: "png",
  swatches: [...DEFAULT_SWATCHES],
};

function snapshot() {
  return ctx.getImageData(0, 0, canvas.width, canvas.height);
}

function pushUndo() {
  state.undo.push({ width: canvas.width, height: canvas.height, image: snapshot(), filename: state.filename });
  if (state.undo.length > 60) state.undo.shift();
  state.redo.length = 0;
  updateHistoryButtons();
}

function restore(entry) {
  resizeCanvas(entry.width, entry.height);
  ctx.putImageData(entry.image, 0, 0);
  state.filename = entry.filename;
  document.querySelector("#documentName").textContent = state.filename;
  updateItemPalette();
  updateInventoryPreview();
}

function undo() {
  if (!state.undo.length) return;
  state.redo.push({ width: canvas.width, height: canvas.height, image: snapshot(), filename: state.filename });
  restore(state.undo.pop());
  updateHistoryButtons();
  saveProject();
}

function redo() {
  if (!state.redo.length) return;
  state.undo.push({ width: canvas.width, height: canvas.height, image: snapshot(), filename: state.filename });
  restore(state.redo.pop());
  updateHistoryButtons();
  saveProject();
}

function updateHistoryButtons() {
  document.querySelector("#undoButton").disabled = !state.undo.length;
  document.querySelector("#redoButton").disabled = !state.redo.length;
}

function resizeCanvas(width, height) {
  canvas.width = width;
  canvas.height = height;
  gridCanvas.width = width;
  gridCanvas.height = height;
  canvasWrap.style.setProperty("--canvas-w", width);
  canvasWrap.style.setProperty("--canvas-h", height);
  document.querySelector("#dimensions").textContent = `${width} × ${height} px`;
  drawGrid();
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
  // A single multiplier preserves the selected hue while varying its strength.
  // At 100%, pixels range from 25% to 175% of the base colour's brightness.
  const strength = 1 + (Math.random() * 2 - 1) * 0.75 * variation;
  const varied = rgb.map(channel => Math.max(0, Math.min(255, Math.round(channel * strength))));
  return `rgb(${varied.join(",")})`;
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
    const twice = 2 * error;
    if (twice >= dy) { error += dy; x0 += sx; }
    if (twice <= dx) { error += dx; y0 += sy; }
  }
}

function updateInventoryPreview() {
  inventoryCtx.clearRect(0, 0, inventoryPreview.width, inventoryPreview.height);
  inventoryCtx.imageSmoothingEnabled = false;
  // Minecraft inventory slots occupy an 18×18 GUI-pixel cell. The recessed
  // slot is one pixel deep on each edge, leaving exactly 16×16 for the item.
  inventoryCtx.fillStyle = "#8b8b8b";
  inventoryCtx.fillRect(0, 0, 18, 18);
  inventoryCtx.fillStyle = "#373737";
  inventoryCtx.fillRect(0, 0, 17, 1);
  inventoryCtx.fillRect(0, 0, 1, 17);
  inventoryCtx.fillStyle = "#ffffff";
  inventoryCtx.fillRect(1, 17, 17, 1);
  inventoryCtx.fillRect(17, 1, 1, 17);
  inventoryCtx.drawImage(canvas, 0, 0, canvas.width, canvas.height, 1, 1, 16, 16);
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

function rgbaToHex(data) {
  return `#${[data[0], data[1], data[2]].map(value => value.toString(16).padStart(2, "0")).join("")}`;
}

function pickColour(point) {
  const pixel = ctx.getImageData(point.x, point.y, 1, 1).data;
  if (pixel[3] === 0) return;
  setColour(rgbaToHex(pixel));
}

canvas.addEventListener("pointerdown", event => {
  event.preventDefault();
  if (![0, 2].includes(event.button)) return;
  canvas.setPointerCapture(event.pointerId);
  const point = pointFromEvent(event);
  if (event.ctrlKey && event.shiftKey) {
    pushUndo();
    fillClickedArea(point, event.button === 2);
    updateItemPalette();
    updateInventoryPreview();
    saveProject();
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
  updateInventoryPreview();
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
  updateInventoryPreview();
});

function stopDrawing() {
  if (state.drawing) {
    updateItemPalette();
    saveProject();
  }
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

document.querySelectorAll(".tool").forEach(button => button.addEventListener("click", () => selectTool(button.dataset.tool)));

function normalizeHex(hex) { return hex.toUpperCase(); }

function setColour(hex) {
  state.colour = hex.toLowerCase();
  colourInput.value = state.colour;
  document.querySelector("#colourPreview").style.background = state.colour;
  document.querySelector("#hexValue").textContent = normalizeHex(state.colour);
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

function updateItemPalette() {
  const pixels = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
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

function loadImage(source, filename, remember = true, preferredFormat = null) {
  const image = new Image();
  image.onload = () => {
    if (remember) pushUndo();
    resizeCanvas(image.naturalWidth, image.naturalHeight);
    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(image, 0, 0);
    const importedFormat = /\.webp$/i.test(filename) ? "webp" : "png";
    state.filename = filename.replace(/\.(?:png|webp)$/i, "") + `.${importedFormat}`;
    setExportFormat(preferredFormat || importedFormat);
    document.querySelector("#documentName").textContent = state.filename;
    fitZoom();
    updateItemPalette();
    updateInventoryPreview();
    saveProject();
  };
  image.onerror = () => alert("That PNG could not be opened.");
  image.src = source;
}

function importFile(file) {
  if (file && (file.type === "application/json" || /\.json$/i.test(file.name))) { importJsonFile(file); return; }
  const supportedType = file && ["image/png", "image/webp"].includes(file.type);
  const supportedName = file && /\.(?:png|webp)$/i.test(file.name);
  if (!file || (!supportedType && !supportedName)) {
    alert("Please choose a PNG or WebP image.");
    return;
  }
  const reader = new FileReader();
  reader.onload = () => loadImage(reader.result, file.name);
  reader.readAsDataURL(file);
}

function projectPayload() {
  return {
    image: canvas.toDataURL("image/png"),
    filename: state.filename,
    colour: state.colour,
    size: state.size,
    variation: state.variation,
    exportFormat: state.exportFormat,
    swatches: state.swatches,
  };
}

function downloadJson(object, filename) {
  const blob = new Blob([`${JSON.stringify(object, null, 2)}\n`], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function exportJson() {
  const baseName = (state.filename || "minecraft_item").replace(/\.(?:png|webp)$/i, "");
  downloadJson({ ...projectPayload(), format: JSON_FORMAT, version: 1 }, `${baseName}.json`);
}

function importJsonFile(file) {
  const reader = new FileReader();
  reader.onload = () => {
    let parsed;
    try {
      parsed = JSON.parse(reader.result);
    } catch (error) {
      return alert("That file is not a valid JSON project file.");
    }
    if (parsed?.format === "blocksmith-animation") return alert("That is an animated sprite project — open the Animated sprite tab to import it.");
    if (parsed?.format !== JSON_FORMAT) return alert("That file is not a Blocksmith item project for this editor.");
    if (parsed.version !== undefined && parsed.version !== 1) return alert(`This project file is version ${parsed.version}; this editor understands version 1.`);
    if (typeof parsed.image !== "string" || !parsed.image) return alert("That file is not a complete Blocksmith item project.");
    if (!confirm(`Import ${file.name}? This replaces your current work (you can still undo).`)) return;
    applySavedSettings(parsed);
    loadImage(parsed.image, parsed.filename || "untitled_item.png", true, parsed.exportFormat);
  };
  reader.readAsText(file);
}

function applySavedSettings(saved) {
  if (/^#[0-9a-f]{6}$/i.test(saved.colour || "")) state.colour = saved.colour.toLowerCase();
  if (Number.isInteger(saved.size) && saved.size >= 1 && saved.size <= 4) state.size = saved.size;
  if (Number.isFinite(saved.variation) && saved.variation >= 0 && saved.variation <= 100) state.variation = saved.variation;
  if (["png", "webp"].includes(saved.exportFormat)) state.exportFormat = saved.exportFormat;
  if (Array.isArray(saved.swatches)) state.swatches = saved.swatches.filter(colour => /^#[0-9a-f]{6}$/i.test(colour)).slice(0, 48);
  document.querySelector("#sizeRange").value = state.size;
  document.querySelector("#sizeOutput").textContent = `${state.size} px`;
  document.querySelector("#variationRange").value = state.variation;
  document.querySelector("#variationOutput").textContent = `${state.variation}%`;
  setColour(state.colour);
}

function exportImage() {
  const format = state.exportFormat;
  const mimeType = format === "webp" ? "image/webp" : "image/png";
  const dataUrl = canvas.toDataURL(mimeType, 1);
  if (!dataUrl.startsWith(`data:${mimeType}`)) {
    alert(`This browser cannot export ${format.toUpperCase()} images.`);
    return;
  }
  const link = document.createElement("a");
  const baseName = (state.filename || "minecraft_item").replace(/\.(?:png|webp)$/i, "");
  link.download = `${baseName}.${format}`;
  link.href = dataUrl;
  link.click();
}

function setExportFormat(format) {
  state.exportFormat = format === "webp" ? "webp" : "png";
  document.querySelector("#exportFormat").value = state.exportFormat;
  document.querySelector("#exportButton").firstChild.textContent = `Export ${state.exportFormat.toUpperCase()} `;
}

function saveProject() {
  if (!canvas.width || !canvas.height) return;
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(projectPayload()));
  } catch (error) {
    console.warn("Could not save the current item locally.", error);
  }
}

function newBlankCanvas() {
  pushUndo();
  resizeCanvas(16, 16);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  state.filename = "untitled_item.png";
  document.querySelector("#documentName").textContent = state.filename;
  fitZoom();
  updateItemPalette();
  updateInventoryPreview();
  saveProject();
}

function initializeProject() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    if (saved?.image) {
      applySavedSettings(saved);
      loadImage(saved.image, saved.filename || "untitled_item.png", false, saved.exportFormat);
      return;
    }
  } catch (error) {
    console.warn("Could not restore the saved item.", error);
  }
  resizeCanvas(16, 16);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  fitZoom();
  updateItemPalette();
  updateInventoryPreview();
  saveProject();
}

function setZoom(value) {
  state.zoom = Math.max(4, Math.min(48, value));
  canvasWrap.style.setProperty("--zoom", state.zoom);
  document.querySelector("#zoomOutput").textContent = `${state.zoom * 100}%`;
}

function fitZoom() {
  const maxWidth = Math.max(240, dropZone.clientWidth - 100);
  const maxHeight = Math.max(240, dropZone.clientHeight - 150);
  setZoom(Math.max(4, Math.min(32, Math.floor(Math.min(maxWidth / canvas.width, maxHeight / canvas.height)))));
}

document.querySelector("#importButton").addEventListener("click", () => fileInput.click());
document.querySelector("#exportJsonButton").addEventListener("click", exportJson);
document.querySelector("#importJsonButton").addEventListener("click", () => jsonInput.click());
document.querySelector("#newButton").addEventListener("click", newBlankCanvas);
fileInput.addEventListener("change", () => { importFile(fileInput.files[0]); fileInput.value = ""; });
jsonInput.addEventListener("change", () => { importFile(jsonInput.files[0]); jsonInput.value = ""; });
document.querySelector("#exportButton").addEventListener("click", exportImage);
document.querySelector("#exportFormat").addEventListener("change", event => {
  setExportFormat(event.target.value);
  saveProject();
});
document.querySelector("#undoButton").addEventListener("click", undo);
document.querySelector("#redoButton").addEventListener("click", redo);
document.querySelector("#zoomIn").addEventListener("click", () => setZoom(state.zoom + 2));
document.querySelector("#zoomOut").addEventListener("click", () => setZoom(state.zoom - 2));
document.querySelector("#gridToggle").addEventListener("change", event => canvasWrap.classList.toggle("no-grid", !event.target.checked));
document.querySelector("#sizeRange").addEventListener("input", event => {
  state.size = Number(event.target.value);
  document.querySelector("#sizeOutput").textContent = `${state.size} px`;
  saveProject();
});
document.querySelector("#variationRange").addEventListener("input", event => {
  state.variation = Number(event.target.value);
  document.querySelector("#variationOutput").textContent = `${state.variation}%`;
  saveProject();
});
document.querySelector("#colourPreview").addEventListener("click", () => colourInput.click());
colourInput.addEventListener("input", event => setColour(event.target.value));
document.querySelector("#addSwatch").addEventListener("click", () => {
  if (!state.swatches.some(colour => colour.toLowerCase() === state.colour)) state.swatches.unshift(state.colour);
  renderSwatches();
  saveProject();
});
document.querySelector("#refreshPalette").addEventListener("click", updateItemPalette);

let dragDepth = 0;
dropZone.addEventListener("dragenter", event => { event.preventDefault(); dragDepth++; dropZone.classList.add("dragging"); });
dropZone.addEventListener("dragover", event => event.preventDefault());
dropZone.addEventListener("dragleave", () => { dragDepth--; if (dragDepth <= 0) { dragDepth = 0; dropZone.classList.remove("dragging"); } });
dropZone.addEventListener("drop", event => {
  event.preventDefault(); dragDepth = 0; dropZone.classList.remove("dragging");
  importFile(event.dataTransfer.files[0]);
});

document.addEventListener("keydown", event => {
  const command = event.ctrlKey || event.metaKey;
  if (command && event.key.toLowerCase() === "z") { event.preventDefault(); event.shiftKey ? redo() : undo(); return; }
  if (command && event.key.toLowerCase() === "y") { event.preventDefault(); redo(); return; }
  if (event.target.matches("input")) return;
  const tools = { b: "pencil", v: "variable", e: "eraser", i: "picker" };
  if (tools[event.key.toLowerCase()]) selectTool(tools[event.key.toLowerCase()]);
});

renderSwatches();
selectTool("pencil");
initializeProject();
