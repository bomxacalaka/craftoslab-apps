# draw-ocr.lua

Draw a handwritten prompt directly in a CC:Tweaked computer, recognize it with a CNN, and send it to Llama 2 for local text generation entirely in Lua.

The two bundled models recognize A–Z and 0–9. Keeping letters and numbers in separate selectable modes prevents ambiguous pairs such as `O`/`0` and `I`/`1` from competing. EMNIST Letters combines uppercase and lowercase examples into the same class, so letter output is uppercase. Recognition is local: no HTTP, server mod, Python runtime, or external inference service is used in game.

## Run in Minecraft

Install the [`CC: App`](../../mod/cc-app/) mod, then sync this project:

```bash
./.dev/sync-to-minecraft.sh
```

On Windows:

```powershell
.\.dev\sync-to-minecraft.ps1
```

The scripts automatically select the CurseForge profile named `CraftOS` and deploy this project, including its vendored copy of the [`llama.lua`](../llama.lua/) runtime and TinyStories assets under `llama/`. Open a CC:Tweaked computer at its shell prompt, press **F8**, then select **OCR**.

## Controls

- Hold and drag the left mouse button to draw.
- Hold and drag the right mouse button to erase.
- If a color advanced monitor can fit at least 36x18 characters, Draw OCR automatically runs on it. It selects the largest half-step text scale that still fits the complete interface, so larger physical monitors use larger, more readable text. Tap or hold across the canvas to draw; nearby touch points are joined into smooth strokes.
- Monitors are hot-pluggable while the program is running. Adding a suitable monitor moves and redraws the UI there; removing it falls back to the computer; resizing it recalculates the layout and preserves the current drawing. If the resized monitor becomes too small, the program uses the computer until enough monitor blocks return.
- Tap **Touch: DRAW/ERASE** at the top of the monitor sidebar to change what canvas touches do. Monitor auto-recognition waits 0.4 seconds after the last touch so a stroke can be completed; computer mouse recognition remains immediate.
- Draw a wide sideways bar to append a space. The gesture may slope or wobble; it only needs to be much wider than it is tall.
- Draw a left arrow or `<` shape to remove the last character. Stepped and imperfect diagonal arms are accepted.
- **Auto: ON** recognizes immediately when the mouse is released. Each released stroke is treated as one complete letter.
- **Mode: abc/ABC/123** cycles lowercase letters, uppercase letters, and numbers without changing the recognized text or current ink. Lowercase is the default; both letter cases use the same case-merged CNN.
- **Recognize** classifies the drawing, appends its top letter to the text line, and clears the canvas.
- **Space**, **Backspace**, and **Clear text** edit the accumulated result.
- Press the green **SEND** button to use the accumulated text as Llama's prompt. The OCR model is released while Llama runs, then restored automatically. The canvas begins with the user's prompt and appends generated tokens live as Llama yields them; drawing again returns to OCR.
- Pausing for 0.8 seconds after any text edit asks Llama for three next-word suggestions; an unfinished prompt receives a temporary trailing space for prediction. Explicit **Space** presses refresh immediately. Suggestions stream into three clickable buttons above the text field as they are sampled. The candidates use greedy, balanced, and creative sampling; selecting one appends it plus a space and refreshes the next set.
- Keyboard shortcuts: `Enter` sends the prompt, `A` toggles automatic recognition, `M` switches ABC/123 mode, `R` recognizes, `C` clears the ink/output, and `Q` quits.

The status area shows the top two predictions and confidence scores.

## Llama generation

The vendored `stories260K` checkpoint is the compact TinyStories Llama 2 model from the sibling project. It is a text-continuation model rather than an instruction-tuned chat assistant: **SEND** asks it to continue what was written. Generation defaults to 160 total steps, temperature 0.8, top-p 0.9, and seed 1. These values are configurable in `cc-appstore.json`.

Generation runs locally without HTTP. Monitor peripherals are rescanned when it finishes, so removing or resizing a monitor during inference still restores the UI on the best available display.

Next-word suggestions reuse one Llama model load for all three candidates and stop each generation at the first word boundary. Suggestion sampling uses `(temperature, top-p)` values of `(0, 1)`, `(0.7, 0.9)`, and `(1.0, 0.8)` with distinct seeds.

## Model

The network is intentionally small:

```text
28x28 grayscale
  -> Conv 5x5, 16 channels + ReLU + 2x2 max pool
  -> Conv 3x3, 32 channels + ReLU + 2x2 max pool
  -> Linear 800 -> 96 + ReLU
  -> Linear 96 -> 26 letters or 10 digits
```

Batch normalization is folded into the convolution weights when exported. The custom binary stores little-endian FP32 values and is loaded with `string.unpack` by [`ocr.lua`](ocr.lua).

- Letter parameters: 84,474
- Letter model size: 337,928 bytes
- EMNIST Letters test accuracy: 94.49% overall; 97.88% for `O`
- Digit parameters: 82,922
- Digit model size: 331,720 bytes
- EMNIST Digits test accuracy: 99.69% overall; every digit is at least 99.58%
- Combined model size: 669,648 bytes (about 654 KiB)
- Required maximum: 10 MiB

The training set is the official 26-class, case-merged EMNIST Letters split described by [NIST](https://www.nist.gov/itl/products-and-services/emnist-dataset) and exposed through [Torchvision's EMNIST dataset](https://docs.pytorch.org/vision/main/generated/torchvision.datasets.EMNIST.html).

## Reproduce training

Python 3 with PyTorch, Torchvision, and NumPy is required:

```bash
python3 .dev/tools/train.py --split letters
python3 .dev/tools/train.py --split digits
python3 .dev/tools/verify_model.py --split letters
python3 .dev/tools/verify_model.py --split digits
```

Training downloads EMNIST into `.data/`, evaluates every epoch, folds batch normalization, and writes the selected model. Verification parses only the exported binary, evaluates it independently, and reports every symbol.

## Project layout

- `ocr.lua` — drawing UI, preprocessing, model loader, and CNN inference.
- `model/letters.bin` and `model/digits.bin` — trained models used in game.
- `llama/llama2.lua` and `llama/models/` — a vendored, byte-identical copy of the sibling [`llama.lua`](../llama.lua/) project (MIT; port of [karpathy/llama2.c](https://github.com/karpathy/llama2.c)). Keep it current with `.dev/tools/update-llama.sh`.
- `.dev/tools/train.py` — reproducible training and export pipeline.
- `.dev/tools/update-llama.sh` — refreshes the vendored `llama/` copy and its `SHA256SUMS` entries from the sibling project.
- `.dev/tools/verify_model.py` — exported-format and accuracy verification.
- `cc-appstore.json` — CC: App launch manifest.
- `.dev/sync-to-minecraft.*` — atomic deployment scripts (excluded from the store package).
