# CC:Tweaked pocket-computer item assets

Extracted from:

- `cc-tweaked-1.21.1-forge-1.120.0.jar`
- CC:Tweaked version `1.120.0` for Minecraft `1.21.1`

## License

CC:Tweaked is licensed under the Mozilla Public License 2.0 (MPL-2.0). All files under `assets/computercraft/` are distributed under that license; the full license text is included in [`LICENSE-MPL.txt`](../LICENSE-MPL.txt). The files are used unmodified, except where this editor edits them (edited copies remain subject to MPL-2.0, including its file-level licensing requirements).

The files retain their original resource-pack paths under `assets/computercraft/`, so this folder can also be used as a reference when making a resource pack.

## How the item is assembled

Minecraft's generated item model composites several transparent textures in layer order. CC:Tweaked does not store every visual state as one complete image:

- `pocket_computer_frame.png` — the common frame/base layer used while the computer is off.
- `pocket_computer_advanced.png` — the Advanced Pocket Computer body artwork.
- `pocket_computer_on.png` — the powered-screen layer.
- `pocket_computer_blink.png` — the blinking-screen layer. This is a 16×32 sprite sheet containing two 16×16 animation frames.
- `pocket_computer_light.png` — the powered indicator/highlight overlay.
- `pocket_computer_colour.png` — the tintable body mask used when a pocket computer has a custom colour. It is included because the main model references the coloured variants.

The black phone/iPad appearance made by CC: App is not another texture. The mod sets the pocket computer's item colour, causing CC:Tweaked's tintable coloured model to be rendered black.

## How the animation works

`pocket_computer_advanced.json` contains model overrides driven by two CC:Tweaked item properties:

- `computercraft:state = 0` selects the off model.
- `computercraft:state = 1` selects `pocket_computer_advanced_on.json`.
- `computercraft:state = 2` selects `pocket_computer_advanced_blinking.json`.
- `computercraft:coloured = 1` selects the equivalent tintable `pocket_computer_colour*.json` models.

The on model layers `pocket_computer_on.png`, the computer body, and `pocket_computer_light.png`. The blinking model replaces the on-screen layer with `pocket_computer_blink.png`.

The adjacent `pocket_computer_blink.png.mcmeta` tells Minecraft to animate the two vertically stacked frames:

```json
{
  "animation": {
    "frametime": 8,
    "frames": [0, 1]
  }
}
```

At 20 game ticks per second, each frame lasts 0.4 seconds, producing a complete blink cycle every 0.8 seconds. CC:Tweaked's client code changes the `state` property according to the computer/item state; Minecraft's model override and texture animation systems do the actual selection, compositing, and blinking.

## Included files

### Textures

- `assets/computercraft/textures/item/pocket_computer_advanced.png`
- `assets/computercraft/textures/item/pocket_computer_frame.png`
- `assets/computercraft/textures/item/pocket_computer_on.png`
- `assets/computercraft/textures/item/pocket_computer_blink.png`
- `assets/computercraft/textures/item/pocket_computer_blink.png.mcmeta`
- `assets/computercraft/textures/item/pocket_computer_light.png`
- `assets/computercraft/textures/item/pocket_computer_colour.png`

### Models

- `assets/computercraft/models/item/pocket_computer_advanced.json`
- `assets/computercraft/models/item/pocket_computer_advanced_on.json`
- `assets/computercraft/models/item/pocket_computer_advanced_blinking.json`
- `assets/computercraft/models/item/pocket_computer_colour.json`
- `assets/computercraft/models/item/pocket_computer_colour_on.json`
- `assets/computercraft/models/item/pocket_computer_colour_blinking.json`
