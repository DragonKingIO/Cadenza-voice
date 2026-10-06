# Screenshot and text recognition

Start from the menu bar, **Settings → Shortcuts → Screenshot**, or a shortcut you record yourself. Nothing is assigned by default; the recorder accepts almost any combination and suggests free ones.

Naming: **Settings → Speech** is the voice-input engine (speech to text). **Settings → Text Recognition** is the screenshot OCR engine (image to text). They are separate pages with separate engines and consent.

## What it does

1. Takes a frozen picture of every screen (ScreenCaptureKit; needs Screen Recording permission) and dims it.
2. Drag an area, or click a window to select it. Corner marks and edge bars resize it; dragging inside moves it. Shift keeps a square / locks the aspect ratio. A loupe shows pixel colour: **C** copies it (Shift switches HEX / RGB).
3. **Tool strip** (vertical, beside the selection, two columns): rectangle `R`, ellipse `O`, arrow `A`, pen `P`, highlighter `H`, number marker `N`, text `T`, mosaic `M`, blur `B`, eraser `E`; undo / redo; delete when a mark is selected. Marks stay editable: select, move, resize, restyle, delete. Up to 100 undo steps.
4. **Options capsule** (below the action bar, appears for the chosen tool): fill or outline, arrow style, text style, three thickness steps drawn as glyphs, and **eight colour swatches** (red, orange, yellow, green, blue, purple, black, white). It only shows the options that tool uses.
5. **Action capsule** (below the selection, with words): *Recognize Text*, *Pin*, *Save*, and the main action *Copy*, plus close.
6. Esc leaves; Return or ⌘C copies; ⌘S saves; ⌘Z / ⇧⌘Z undo / redo; right-click clears the selection.

More ways, from the menu: full screen, delayed (3 / 5 / 10 s), repeat last area, and *Screenshot and copy text* (optional second shortcut, no selection UI beyond the area).

### Recognition

*Recognize Text* shows each recognized line over the picture like selectable text: click lines, ⌘A selects all, *Copy* copies the selection. QR and bar codes found in the area are listed with Copy / Open. *Open window* shows the full result.

### Pins

Pin floats the picture above other windows. Scroll zooms, ⌥+scroll changes opacity, rotate by 90°, click-through, and a hover strip offers close and recognition on the pin. The menu can close all pins or hide / show them.

## Recognition engines

`OCREngine` is the seam; `OCRRouter` picks one and handles consent, credentials, reachability and fallback.

| Engine | Where it runs | Needs |
|---|---|---|
| Apple Vision (default) | this Mac, offline | nothing |
| Baidu AI Cloud OCR | `aip.baidubce.com` | API Key + Secret Key; optional high-accuracy mode |
| Tencent Cloud OCR | `ocr.tencentcloudapi.com` | Secret ID + Secret Key + region (TC3-HMAC-SHA256 signing) |
| Google Cloud Vision | `vision.googleapis.com` | API Key (sent in a header) |

An online engine is used only when the keys are saved (macOS Keychain, `ocr.<provider>.<field>`) **and** the per-provider upload switch is on. *Test connection* is click-only and sends one small test image. If the service fails, there is no network, or upload is not allowed, **Fall back to this Mac** (on by default) recognizes with Apple Vision and the screenshot view says why. See `PRIVACY.md`.

## Design is our own

The layout, icons and wording are original to this project and deliberately differ from other screenshot tools:

- Two to three floating parts instead of one long icon row: a tool strip, an options capsule, and a labelled action capsule.
- Primary action is a worded **Copy** button, not a tick/cross pair.
- Selection handles are L-shaped corner marks and edge bars, drawn in the system accent colour.
- 39 icons drawn from scratch (`resources/shot-*.svg`, 24×24, single-colour, template-tinted). No icon is copied or traced.
- The colour row is eight plain swatches with a soft highlight; there is no colour wheel.
- Features we have not built (emoji stickers, translate, long screenshot, share) are not shown.

When adding features keep it that way: design from our own concept, never from another app's artwork.

## Code map

| File | Role |
|---|---|
| `ScreenshotModel.swift` | Settings, selection geometry (pure) |
| `ScreenshotAnnotations.swift` | Tools, mark objects, colours, undo history |
| `ScreenshotRenderer.swift` | One drawing path for on-screen preview and export; mosaic / blur effects; PNG |
| `ScreenshotCapture.swift` | Permission, ScreenCaptureKit capture, window list, global hotkeys |
| `ScreenshotCanvas.swift` | Per-screen overlay: selection, drawing, text editing, recognition overlay |
| `ScreenshotLoupe.swift` | Pixel loupe and colour copy |
| `ScreenshotToolbar.swift` | Tool strip, options capsule, action capsule, icon loader |
| `ScreenshotController.swift` | Session: capture → overlay → actions |
| `ScreenshotOutputs.swift` | Copy, save, recognized-text window |
| `ScreenshotPins.swift` | Pin windows |
| `ScreenshotOCR.swift` | OCR engines, router, QR detection, reading order |
| `OCRSettingsView.swift` | Settings → Text Recognition page and provider sheet |
| `ScreenshotSettingsView.swift` | Shortcut rows and recorder |
| `ScreenshotFixtures.swift` | Self-tests and offscreen preview |

## Tests

```bash
Yansui --selftest-screenshot                         # 250 checks: geometry, pixels, annotations, history, OCR parsing and signing, routing, pins, icons, hotkeys, menu
Yansui --preview-screenshot-output=out.png [--preview-screenshot-tool=rectangle] [--preview-screenshot-dark] [--preview-screenshot-recognition]
Yansui --preview-screenshot-icons=icons.png [--preview-screenshot-dark]
```
The previews draw a synthetic desktop offscreen; they open no window and capture nothing. Cloud engines are tested against recorded request / response shapes, not live accounts (the Tencent signature is checked against an independent implementation).

## Not yet verified

Real capture on a Mac with the permission granted, global shortcuts on a real keyboard, multi-display behaviour, in-canvas text typing, the save panel, pinned windows, and live calls to Baidu, Tencent and Google with real accounts. These need a person at the machine.
