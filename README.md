# Paintbox

A free, native macOS paint and image editor in the spirit of MS Paint. AppKit, one
custom canvas view, no SwiftUI, no Xcode project.

It exists so that blurring a name out of a screenshot, making a logo's white box
transparent, or pasting a cut-out subject onto another picture does not mean installing
GIMP. The point of it being native rather than a web page is **Remove Background**:
Vision's subject lifter runs on the machine, with no network call and no API bill.

```
./build.sh          # compiles, assembles Paintbox.app, ad-hoc signs it
open Paintbox.app
```

## Building

There is no Xcode on this machine, only the Command Line Tools, so there is no
`.xcodeproj` and no `xcodebuild`. `build.sh` calls `swiftc` directly, writes
`Contents/Info.plist` by hand, and ad-hoc signs the bundle with `codesign --force --sign -`.
It is the single command that produces a runnable app. Target is `arm64-apple-macos14.0`
(macOS 14 is the floor because that is where `VNGenerateForegroundInstanceMaskRequest`
appears).

Two hidden arguments exist for checking the build without a human at the screen:

```
./Paintbox.app/Contents/MacOS/Paintbox --selftest
./Paintbox.app/Contents/MacOS/Paintbox --screenshot /tmp/shot.png
```

`--selftest` opens a generated test picture, runs every image operation in turn, checks
the pixel dimensions, the corner colours and the alpha after each one, unwinds the whole
stack with undo and compares checksums, then exercises the drawing tools, the selection
mask, the filters and every file writer. It counts the pixels that changed *outside* a
selection after a masked operation and insists the answer is zero. Later groups cover the
ways the app could be made to fall over rather than draw — absurd sizes, non-finite
angles, an undo stack with no ceiling, an intricate selection outline, a panel left
pointing at a closed window — and the ways it could throw work away or mislabel it
quietly: two windows aimed at one file, a ⌘S that would change a file's format under you,
a `--cutout` that wrote bytes its output was not named for. It prints a `PASS`/`FAIL` line
per check — 192 of them — and exits non-zero on any failure.
`--screenshot` builds the real window, draws into it, and writes what AppKit renders to a
PNG, so you can see the interface without screen-recording permission.

## What it does

**Files** — New (asks for a size, default 1024×768, white), New from Clipboard, Open
(PNG, JPEG, TIFF, HEIC, GIF, WebP — first frame), Save, Save As. The title bar shows the
filename and the dirty dot; closing a window *and quitting the app* both ask before
throwing unsaved changes away. Open an animated GIF and the status bar says "frame 1 of
N", and saving over it asks before it keeps that one frame and drops the rest — Paintbox
edits one frame, and that is not something to find out afterwards.

**One file, one window.** Opening a picture that is already open raises its window rather
than forking a second document onto the same path, and Save As refuses a file another
window is editing and says which one. Every save writes the whole picture, so two windows
on one file means whichever saves last wins and neither is told.

**A file Paintbox can read but not write is never overwritten.** The Open panel admits
everything ImageIO reads, which is a longer list than the seven formats below: .webp,
.psd, .dng and friends. ⌘S on one of those opens the Save As panel and says why, instead
of writing PNG bytes into a file the rest of the system still believes is a WebP.

**Save As writes seven formats**: PNG, JPEG, HEIC, AVIF, TIFF, GIF and BMP, with a
quality slider that wakes up for the three lossy ones. All but JPEG keep transparency;
JPEG is flattened onto the background swatch first, and GIF's transparency is on/off
rather than graded. **WebP is deliberately not offered.** macOS *reads* WebP perfectly
well, so a .webp opens here like anything else, but Apple ships no WebP writer —
`CGImageDestinationCopyTypeIdentifiers()` does not list it — and writing a PNG while
calling it a WebP would be worse than saying no. The format list is re-checked at launch,
so a writer that disappears in a future macOS drops out of the menu rather than failing
at the save panel.

**Tools**, down the left, each with a single-key shortcut:

| Key | Tool | Notes |
|---|---|---|
| `P` | Pencil | exactly one pixel, never antialiased (integer Bresenham) |
| `B` | Brush | soft round stamp, size slider 1–96 px |
| `E` | Eraser | **erases to transparent.** Right-click erases to the background colour instead |
| `L` | Line | Shift snaps to 45° |
| `R` | Rectangle | outline / filled / both |
| `O` | Ellipse | outline / filled / both; Shift makes a circle |
| `F` | Paint bucket | tolerance slider 0–255, per channel including alpha |
| `I` | Eyedropper | right-click picks into the background swatch |
| `T` | Text | click, type in place, Return commits, Escape cancels; ⌘T for the font panel |
| `S` | Rectangular selection | Shift makes it square; marching ants |
| `A` | Arrow | a line with a head on it; shares the line tool's drag, width and Shift-45° |
| `W` | Magic wand | selects by colour, own tolerance slider; **Option-click** selects every matching pixel in the picture rather than only the contiguous blob |

Foreground and background swatches with a twenty-colour standard palette and the system
colour picker. **Right-click (or Control-click) draws with the background colour** —
for the two shape tools that also swaps which colour fills and which outlines.

**Image operations**, all on the menu bar and most of them on the toolbar as well (the
two quarter turns are there; 180° and Rotate by Angle are menu-only):

- Crop to Selection
- **Resize Image…** — resamples the picture. Pixels or percent, with an aspect-ratio lock.
- **Canvas Size…** — changes the paper without scaling the picture. Nine-position anchor,
  new area filled with the background colour. The two are labelled
  "Resize Image… (scales the picture)" and "Canvas Size… (changes the paper)" in the menu
  precisely because people confuse them.
- Flip horizontal, flip vertical
- Rotate 90° clockwise, 90° anticlockwise, 180°, and **rotate by an arbitrary angle**
  (the canvas grows to fit, new corners transparent)
- **Trim to Content** — crops away a uniform or transparent border. The natural step
  after a cut-out. It reads the top-left pixel as the background colour, with a small
  tolerance so a JPEG's noisy "white" still counts as one colour; if that corner is
  transparent it trims on alpha alone.
- **Remove Background** — Vision `VNGenerateForegroundInstanceMaskRequest`, on device.
  Produces real transparency, and it undoes like anything else.

**Editing the pixels**, all on the selection if there is one and on the whole picture if
there is not. The *destructive* verbs are the other way round: Crop, Cut, Delete
Selection and Fill Selection with Background all need a selection and grey out without
one, because "apply to everything" and "erase everything" are not the same offer. Select
All is how you ask for the whole picture:

- **Blur…** and **Pixelate…** — each a slider with a live preview. Redacting a name or a
  face out of a screenshot before sending it is the single most common reason an ordinary
  person opens an image editor, and this is that.
- **Adjustments…** — brightness, contrast and saturation on three sliders with a live
  preview, applied on OK as one undoable step (`CIColorControls`).
- **Grayscale** and **Invert Colours** — one filter each, no dialog.

Blur, Pixelate, Adjustments and Trim to Content are on the toolbar as well as the menu;
Grayscale and Invert are menu-only.

The preview in those dialogs is of the **selection**, not of the whole picture, and it
runs the same closure the real filter runs, at a scale factor: previewing a whole
screenshot while you blur one name in it would tell you nothing, and a preview computed
by a second code path would be a preview you cannot trust.

**Selection** is a **mask**, one byte per canvas pixel, not a rectangle. The rectangular
selection tool simply fills a rect in it. That is what makes an irregular magic-wand
selection possible at all, and what lets a blur be confined to a blob rather than a box.
The marching ants trace the mask's real boundary: they follow a wanded brush stroke round
its outline, not round its bounding box. Copy through an irregular selection gives you a
cut-out, not the bounding box.

The ants trace only the part of the mask that is on screen, cache the result until the
selection or the zoom changes, and give up if the outline runs past forty thousand
segments — which a wand over a grainy sky genuinely does, at three million segments and
half a gigabyte. Such a selection is shown as a **tint over the selected pixels** instead,
drawn through the mask itself in one image draw, with a plain box round its extent; the
ants animation switches off while it is up, because a tint has no dashes to march.

**Paste floats.** Pasted content — from the clipboard or from a file dropped onto the
canvas — arrives as a floating item above the picture. Drag it to move it, drag a corner
to scale it, hold Shift to keep its shape. It lands when you click away, press Return, or
start any other operation; Escape throws it away. The whole thing — move, scale and
stamp — is one undo step, because nothing is written to the bitmap until it commits.
Something bigger than the canvas is scaled down to fit on arrival, so its handles are
never out of reach; scaling always resamples from the original pixels, so dragging a
corner back out gets the detail back. Cutting a subject out is useless if you cannot then
put it somewhere.

**Undo/redo** is multi-level through `NSUndoManager` and covers every one of the above,
including the operations that change the canvas size. It works by snapshotting the whole
bitmap per step (3 MB for a 1024×768 canvas), which is why undo restores byte for byte
rather than approximately. Because a step costs a whole canvas, the number of steps is
budgeted in **bytes** rather than fixed: about half a gigabyte, which is sixty steps on a
1024×768 canvas and six on a 24-megapixel photograph, recalculated whenever the canvas
size changes and thrown away when the window closes.

**Zoom** to fit (⌘9), 100% (⌘0), in (⌘+), out (⌘−). Transparent areas sit on a
checkerboard.

## Keyboard shortcuts

| | |
|---|---|
| ⌘N / ⇧⌘N | New… / New from Clipboard |
| ⌘O / ⌘S / ⇧⌘S / ⌘W | Open, Save, Save As, Close |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌘X / ⌘C | Cut, Copy (the selection, or the whole picture if nothing is selected) |
| ⌘V | Paste — arrives floating; drag it, then Return |
| ⌘A / ⌘D / ⌫ | Select All, Deselect, clear the selection to transparent |
| ⌘⌫ | Fill the selection with the background colour |
| ↩ / ⎋ | Place the floating paste / throw it away (⎋ also deselects) |
| ⌘K / ⇧⌘K | Crop to Selection / Trim to Content |
| ⌘R / ⇧⌘R | Resize Image… / Canvas Size… |
| ⌃⌘H / ⌃⌘V | Flip horizontal / vertical |
| ⌘] / ⌘[ / ⇧⌘] | Rotate 90° CW / 90° ACW / 180° |
| ⌃⌘R | Rotate by Angle… |
| ⇧⌘B | Remove Background |
| ⇧⌘L / ⇧⌘P | Blur… / Pixelate… |
| ⇧⌘A | Adjustments… (brightness, contrast, saturation) |
| ⌃⌘G / ⌃⌘I | Grayscale / Invert Colours |
| ⌘+ ⌘− ⌘0 ⌘9 | Zoom in, out, 100%, fit |
| ⌘1 / ⌘2 / ⇧⌘X | Foreground colour, background colour, swap them |
| ⌘T | Font… (for the text tool) |
| P B E L A R O F I T S W | Pick a tool (suppressed while you are typing) |

## Retina and alpha

The document is a plain `CGBitmapContext` in pixels — RGBA8, premultiplied-last, sRGB —
and it is the only source of truth. The view never owns the pixels, so the backing scale
of the screen cannot leak into an export: saving always writes the bitmap at its real
pixel size regardless of zoom or which display the window is on. At zoom ≥ 100% the
canvas draws with interpolation off, so on a Retina screen one image pixel is a crisp
block rather than a blur. Every loaded file is normalised into that one format on open,
so alpha survives load → rotate → save; the self-test checks exactly that.

JPEG has no alpha, so saving as JPEG flattens the picture onto the **background swatch
colour** first. Every other format Paintbox writes keeps transparency, and the self-test
round-trips each one and reads the alpha back to prove it.

**Blur is the place alpha usually gets lost, so it is worth saying how it is done here.**
The naive way to blur a selection is to crop it out, blur the crop, and paste it back.
That is wrong at every edge: a Gaussian run over a cropped tile has nothing to sample
beyond the tile, so it mixes in transparent black and leaves a dark, soft halo exactly
where you wanted a clean boundary. Paintbox never crops before filtering. The filter is
defined over the whole canvas — clamped at the canvas edge, so the picture's own border
does not bleed either — and CoreImage is then asked for only the selection's rectangle out
of that graph, which it renders by pulling whatever source pixels it needs from beyond the
edges of that rectangle. Only then are the filtered pixels copied back **through the mask**.
Pixels outside the selection are not recomputed and found to be unchanged; they are
literally never written. The self-test checks that count is zero.

## Deliberately not built

- **No app icon.** The bundle has no `.icns`; it shows the generic app icon in the Dock.
- **No lasso.** Selection is a mask, but the only ways to fill it are the rectangle tool,
  Select All and the magic wand. There is no freehand or polygon selection tool, and no
  feathering: the mask is hard-edged 0 or 255 everywhere, though the compositing maths
  already handles in-between values for whenever that changes.
- **The selection itself cannot be dragged.** A *floating paste* can be moved and scaled;
  an existing selection of the picture cannot be picked up and moved in place. Cut, then
  paste, is the way round it.
- **No layers.** One bitmap, like MS Paint. The floating paste is not a layer: there is
  exactly one, it has no blend mode or opacity, and anything else you do commits it.
- **No gradients, no curves/bezier tool, no polygon, no airbrush, no clone stamp.**
- **No WebP export**, for the reason above: macOS has no writer. It still reads them,
  and ⌘S on one diverts to Save As rather than quietly changing the format under you.
- **Animated GIFs are edited one frame at a time.** Opening one loads frame 1, the
  status bar says "frame 1 of N", and saving over the original asks before it keeps
  that frame and drops the rest. There is no frame timeline and no multi-frame writer.
- **Undo is whole-image snapshots**, not tile deltas, so on a very large canvas the
  history is capped at six steps by the memory budget rather than by anything you did.
- **No sandbox, no notarisation, no hardened runtime.** Ad-hoc signed only, so it runs on
  this machine; Gatekeeper will object if it is copied to another one.
- **No preferences, no autosave, no document versions**, no `NSDocument` — window
  management is hand-rolled, one document per window.
- **No printing.**

## Known rough edges

- **A filter renders the selection's bounding box**, not its exact shape. The filter's
  *maths* is still defined over the whole canvas, which is what stops the edge bleeding
  (see *Retina and alpha* above), but only the box is rendered — so a thin diagonal selection
  costs the whole rectangle around it, and a wand selection scattered over a photograph
  costs very nearly the photograph.
- **Crop to Selection leaves a rectangular canvas.** A bitmap cannot be a non-rectangle,
  so cropping to an irregular selection gives you the mask's bounding box — with
  everything inside that box the mask did not cover knocked out to transparent, so the
  shape you selected is the shape you keep.
- **The magic wand has no anti-aliasing and no feather**, so wanding a soft-edged
  JPEG logo at a low tolerance leaves a fringe of half-matching pixels behind. Raising
  the tolerance takes more of the fringe and eventually more of the logo.
- **Trim to Content judges the background by the top-left pixel.** A picture whose
  top-left corner is part of the subject will not trim usefully.
- **Zoom has no gesture and no scroll-wheel zoom.** ⌘+ and ⌘− hold the centre of what is
  on screen, so zooming in on a large picture magnifies what you were looking at rather
  than jumping; `setZoom(_:keeping:)` can hold any point instead, but nothing yet hands it
  the pointer, because there is no pinch or ⌥-scroll handler to hand it one.
- **Pictures are capped at 20000 pixels a side and 100 megapixels.** Resize and Canvas
  Size refuse anything larger and say what was asked for, rather than accepting a typed
  "5000%" and taking the machine down with it: CoreGraphics maps a bitmap lazily, so a
  three-terabyte canvas allocates without complaint and only dies when it is drawn.
- **The palette uses hand-computed frames**, not Auto Layout. It is a fixed 156 pt column
  inside a scroll view; it will not reflow, only scroll, in a short window. With twelve
  tools and four sliders it now needs about 700 pt of height before it starts scrolling.
- **Open Recent** relies on AppKit's private `_setMenuName:` to wire the submenu, since
  there is no nib to do it. The call is guarded, so at worst the submenu stays empty.
- **Arbitrary-angle rotation resamples**, so turning 15° five times is visibly softer than
  turning 75° once. The quarter turns are lossless.
- **Remove Background depends on Vision finding a subject.** If it finds none you get a
  plain message and nothing changes; it is not a general "delete everything that colour"
  tool.

## Background removal from the terminal

```
./Paintbox.app/Contents/MacOS/Paintbox --cutout in.png out.png
```

Runs the same subject-lifting the menu item runs, with no window, and prints what changed:

```
cutout 1080x1350 -> out.png (PNG)
  corner alpha 255 -> 0
```

The corner reading is the point. It distinguishes *"Vision found a subject and cut it out"* from
*"Vision found nothing and the file came out unchanged"*, which otherwise look identical to a
script. Exit codes: **0** cut out, **3** a file was written but the corner is still opaque,
**4** no subject found, **2** the input could not be read, **5** the output name is not a format
Paintbox can write, **6** the writer failed.

**The output format comes from the output's name**, through the same table the Save As panel
offers: `.png .jpg .heic .avif .tiff .gif .bmp`. Anything else is refused, with the list, rather
than written as a PNG under a name that promises something else. Name it `.jpg` and you get a
real JPEG — which has no alpha channel, so the cut-out is flattened onto white and the point of
cutting it out is gone. **Name the output `.png`** unless you have a reason not to.

So a folder can be done in a loop — note the output extension, not the input's:

```
for f in *.jpg; do Paintbox.app/Contents/MacOS/Paintbox --cutout "$f" "cut-${f%.*}.png"; done
```

It runs entirely on this Mac. Nothing is uploaded, there is no API key and there is no per-image
cost, because the model is Apple's and it ships with the operating system.
