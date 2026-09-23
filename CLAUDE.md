# Paintbox: working on it

**Read this before changing anything here.** `README.md` is for people who use the app; this is
for whoever works on it. It is deliberately short, and every line in it is something that has
already cost somebody an hour.

**What it is:** a native macOS drawing and image-editing app, in the spirit of MS Paint, whose
one genuinely differentiated feature is background removal that runs on the machine. Free,
MIT, public at **github.com/pivable/paintbox** since 2026-09-23.

---

## The environment, which is not what you expect

**Xcode is NOT installed on this Mac, and the project does not want it.** There is no
`.xcodeproj`, no `xcodebuild`, no Swift package. `swiftc` compiles `Sources/*.swift` straight
into a bundle that `build.sh` assembles by hand and ad-hoc signs.

```
./build.sh                  # the ONLY build command
./build.sh --universal      # Intel as well as Apple Silicon — use for anything you hand out
./build.sh --package        # also produce Paintbox.zip and print the recipient's instructions
```

AppKit, not SwiftUI. That was chosen because this is a pixel editor with a custom canvas view,
and a declarative layer fights you for no gain.

## Prove it works before you believe it

```
./Paintbox.app/Contents/MacOS/Paintbox --selftest
```

**192 checks, exit 0. Never let that number go down.** They assert real pixels rather than that
the code ran: that right-angle rotation is lossless, that alpha survives all seven save
formats, that a blur leaves every pixel outside the selection untouched, that undo restores
byte for byte, and that background removal actually finds a subject.

Two more entry points, and both matter because `screencapture` returns black on this machine:

```
--screenshot out.png        # renders the real window's view tree to a PNG. This is how you SEE it.
--cutout in.jpg out.png     # background removal, headless, format from the output extension
```

**A green suite is not the running system.** Every mouse interaction — the drawing tools, the
shift constraints, the floating-paste handles, the dialogs — is verified only by code. When you
change any of it, take a screenshot and look.

## House style

- **Comments explain WHY, never what.** Match the surrounding files; they are the specification.
- **Add a self-test with every fix**, in the style of `Sources/SelfTest.swift`, asserting real
  pixels or real state. A fix with no test regresses silently and we have watched it happen.
- Several files, no monolith. `Sources/` is already split by concern.
- **Never weaken a test to make something pass.** A prover agent specifically hunts for loosened
  assertions, deleted tests and removed guards, and it will find it.

## Traps this project has already fallen into

Each of these was a real bug here, and each is the kind that looks fine until it doesn't.

- **The selection is a per-pixel MASK, not a rectangle.** It has to be, for the magic wand and
  for filtering an irregular region. Anything that quietly uses the bounding box instead is
  probably wrong — except Crop, which genuinely cannot be non-rectangular.
- **Coordinate systems disagree.** AppKit views and CGContext are bottom-left origin; image rows
  are top-left. Every conversion is a chance for an upside-down result or an off-by-one. Paste
  landed upside down once for exactly this reason.
- **Retina.** Get the backing scale wrong and every export is blurry or half size.
- **Premultiplied alpha.** The canonical bitmap is RGBA8 premultiplied-last in sRGB. Filtering
  premultiplied data as though it were straight darkens semi-transparent edges.
- **`CIPixellate`'s centre parameter is a block CORNER, not a centre.** That put the grid ten
  pixels out.
- **Filters must run over a padded region, never a cropped one.** Cropping first is what makes
  a blur bleed transparency in from outside the selection.
- **Brush spacing belongs to the STROKE, not to the mouse event.** Restarting it per event made
  the same drag up to 138 alpha levels harder when delivered as many small events, which is an
  ordinary slow drag or any drag at zoom.
- **A `dev.host` style config copied from elsewhere can drop the port** and silently break
  anything that builds a URL.

## How people install it, and why it is shaped that way

```
curl -fsSL https://raw.githubusercontent.com/pivable/paintbox/main/install.sh | bash
```

That fetches the source, builds it on the user's own machine, runs the tests, and only then
installs. **The reason is Gatekeeper.** Anything downloaded through a browser is quarantined,
and this app is ad-hoc signed rather than notarised, so macOS refuses it — and since Sequoia the
right-click-to-open shortcut is gone, leaving System Settings. A `.command` script is not a
loophole; it gets quarantined too, which was tested.

**An app built on the machine that will run it is never quarantined at all.** That is the whole
trick, and it costs nothing. The alternative is the Apple Developer Program at 99 USD a year,
which would let a plain download just work. Nothing in the code changes either way.

`Build.command` is double-clickable for anyone who cloned the repository, where there is no
quarantine flag to fight.

## Where things are written down

| | |
|---|---|
| `README.md` | For users: what it does, shortcuts, rough edges. Keep it TRUE — three claims in it were false once and that is how you lose trust on a first impression. |
| `KNOWN-ISSUES.md` | **The six open bugs.** Published deliberately rather than hidden. Start here. |
| `REVIEW-BACKLOG.md` | How the review was run and what it cost. History, not a to-do list. |
| this file | How to work on it. |

## What to pick up next

The six in `KNOWN-ISSUES.md`. Two are more than polish:

- **"Save a Copy…" is really a Save As**, so the window ends up editing the copy and the
  original is quietly abandoned.
- **Remove Background ignores an active selection** while Blur, Pixelate and Adjustments all
  honour one. That is an inconsistency in what the selection means, not a missing feature.

After those, the honest list of what this app still is not is in `README.md` under *Deliberately
not built* and *Known rough edges* — most usefully: the selection cannot be picked up and moved,
there is no feathering, and there are no layers beyond a single floating item.
