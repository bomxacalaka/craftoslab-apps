# llama.lua

A dependency-free Lua port of Karpathy's `llama2.c`, suitable for CraftOS and CC:Tweaked.

This project contains the Lua inference implementation, the FP32 `stories260K` checkpoint, the 512-token tokenizer, and desktop CraftOS-PC launchers. The model is not quantized or reduced, and deterministic greedy output matches the upstream implementation.

## Contents

- `llama2.lua` — checkpoint loader, tokenizer, Transformer forward pass, and sampler.
- `models/` — the `stories260K` FP32 checkpoint and tokenizer.
- `run.sh`, `run.ps1`, and `run.cmd` — desktop CraftOS-PC launchers.
- `sync-to-minecraft.*` — optional deployment helpers for the separate CC: App mod.
- `cc-appstore.json` — the CC: App launch manifest copied by the sync helpers.

Note: the [`draw-ocr.lua`](../draw-ocr.lua/) app vendors a byte-identical copy of this project's `llama2.lua` and `models/` under its own `llama/` directory so it stays self-contained. When you update those files, refresh the vendored copy with `../draw-ocr.lua/tools/update-llama.sh`.

## Run with CraftOS-PC

```bash
./run.sh --backend standard --steps 200 --temperature 0
```

On Windows:

```powershell
.\run.ps1 -Backend standard -Steps 200 -Temperature 0
```

For a five-pass benchmark:

```bash
./run.sh --backend standard --steps 200 --temperature 0 --benchmark-runs 5
```

The optional accelerated backend expects a portable CraftOS-PC Accelerated installation under `tools/craftos-accelerated`.

`llama2.lua` also accepts `--stream-event NAME`. After prompt ingestion it queues that CraftOS event with each generated text piece and cooperatively yields, allowing a parent UI to repaint while inference continues. The combined Draw OCR UI uses this interface.

`--suggestions-output PATH` runs three next-word samples after one model load and writes one candidate per line. Each sample stops at its first generated whitespace boundary. With `--suggestions-event NAME`, candidate index and token pieces are also yielded as CraftOS events so Draw OCR can fill its clickable suggestion strip live.

## Run in Minecraft

The Minecraft integration lives in the `../../mod/cc-app` mod. Install that mod once, then sync this project after each edit:

```bash
./sync-to-minecraft.sh
```

On Windows:

```powershell
.\sync-to-minecraft.ps1
```

Both scripts automatically select the CurseForge profile named `CraftOS`. Override it when needed:

```bash
./sync-to-minecraft.sh --profile "/path/to/another/profile"
```

The script atomically replaces:

```text
<profile>/cc-apps/apps/llama-lua/
  app.json
  llama2.lua
  models/
    tok512.bin
    stories260K.bin
```

In Minecraft, open a CC:Tweaked computer, leave its shell at the `>` prompt, press **F8**, and choose **Llama**. If Auto reload is enabled, future syncs are picked up after the copy settles and the computer is back at the shell.

## Performance

On the original test setup, the optimized in-game Cobalt backend averaged **17.167 tokens/second** over five 200-token greedy runs, up from a measured **13.643 tokens/second** baseline. Actual speed depends on server tick load and computer hardware.

## Credits and license

The inference format, equations, tokenizer behavior, and bundled TinyStories assets come from [karpathy/llama2.c](https://github.com/karpathy/llama2.c). CC:Tweaked is developed by its respective contributors.

Project code is available under the MIT License. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
