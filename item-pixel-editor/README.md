# Blocksmith item editor

A dependency-free, browser-based pixel editor for Minecraft item PNGs.

```bash
python3 server.py
```

Then open <http://127.0.0.1:8787>. A first visit starts with a blank transparent 16×16 item. Drop a PNG or WebP anywhere over the editor or use **Import image**. Choose PNG or WebP beside the export button; the downloaded MIME type and filename extension match the selected format, with transparency preserved.

Work is automatically stored in the browser and restored after refreshing the page, closing the browser, or restarting the web server. Use **New** to start another blank 16×16 item; the previous canvas remains available through undo until the page is closed.

## JSON project files

The browser autosave survives until someone clears the site's storage. **Export JSON** downloads the entire working file — canvas pixels, filename, colour, pencil size, variation, export format, and swatches — as a versioned JSON project file (a `<name>.json` whose `format` field is `blocksmith-item` and whose `version` is `1`). **Import JSON** opens such a file (a PNG/WebP or JSON file can also be dropped straight onto the editor); you are asked to confirm, the imported project takes over the canvas, and your previous work stays one `Ctrl/Cmd+Z` away. Importing a file that is not JSON, belongs to the other editor ("animated sprite"), or uses an unsupported version shows an error and leaves the current work untouched. The animated sprite editor works identically: its JSON projects use `format: "blocksmith-animation"` and additionally carry the full sheet, body/light layers, current frame, and frame timing.

The sidebar includes a live Minecraft inventory preview built at the exact GUI ratio: an 18×18 slot cell containing a 16×16 item, enlarged with integer nearest-neighbour scaling.

The variable pencil has a 0–100% colour-strength control. It randomly draws lighter and darker versions of the selected colour without changing its hue.

Shortcuts: `B` pencil, `V` variable pencil, `E` eraser, `I` colour picker, `Ctrl/Cmd+Z` undo, and `Ctrl/Cmd+Shift+Z` redo. Right-click and drag temporarily erases without changing tools.

Hold `Alt` while dragging to preview and draw a straight line. `Ctrl+Shift+left-click` fills the connected area under the pointer with the current colour; `Ctrl+Shift+right-click` erases that connected area. Pixels of another colour act as walls, so outlined regions do not leak into one another.

## Animated sprites

Open the **Animated sprite** tab to edit Minecraft-style vertical sprite sheets frame by frame. It provides live playback in the inventory slot, frame add/duplicate/delete controls, game-tick timing, and browser autosave.

The supplied CC:Tweaked 1.120.0 assets are included under `assets/computercraft/`. **Load supplied preset** opens the real `pocket_computer_blink.png` two-frame sheet, sets its eight-tick timing, and composites `pocket_computer_advanced.png` plus `pocket_computer_light.png` in the preview exactly as the blinking model specifies.

Use the timeline's **Edit layer** controls to switch between the animated screen frames, Advanced body (the yellow casing), and light overlay. All three are editable and autosaved. The animated screen exports as the vertical sheet; the two shared CC layers each have a dedicated PNG export button with the resource filename expected by CC:Tweaked.

**Export pack ZIP** creates a ready-to-install Minecraft 1.21.1 resource pack containing `pack.mcmeta`, a generated pack icon, all required CC:Tweaked item models and unchanged supporting textures, the edited vertical blink sheet, generated animation metadata, edited body, and edited light overlay. Place the downloaded ZIP directly in Minecraft's `resourcepacks` folder. Individual sheet, metadata, body, and light exports remain available too.
