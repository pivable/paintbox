# Paintbox — the review backlog

**STATUS: the review is closed. 192 self-tests pass, the build is clean.**

A ten-lens review on 2026-09-21 found 92 defects; 87 survived three independent skeptics each.
Three fixing passes have now run, and an independent prover rebuilt from clean, re-ran the
tests, looked at the rendered interface and audited for tests weakened to make something pass.

| | |
|---|---|
| Tests before the review | 55 |
| Tests now | **192, all passing** |
| Findings fixed | all 87 confirmed, across three passes |
| Not a real defect | 1 |
| Restatements of another finding | 1 |

**The prover checked the tally was not inflated**: 211 assertion sites against 189 distinct
printed names, with the difference accounted for by interpolated names and failure-branch
assertions, each of which has a positive counterpart that did print. No test was deleted,
loosened or renamed to make anything pass.

**Three interface defects were confirmed fixed by looking, not by arithmetic.** The truncated
"Out…" segment now reads Line, Fill, Both. The palette is complete with slack below it. The
zoom buttons are on the toolbar rather than hidden in an overflow menu.

## What is still open

The completeness critic — whose only job was to find what ten lenses and three fixing passes
all missed — found nine things. They are in `review-findings-critic.json`.

**Three are now fixed** (2026-09-23), the two that blocked a release and the documentation one:

- **Save As can point two windows at one file.** It now runs the same lookup Open runs and
  refuses, naming the window in the way. `PaintWindowController.saveAs(to:format:quality:)`.
- **`--cutout` always wrote PNG bytes.** The format now comes from the output's extension,
  through `SaveFormat` — the save panel's own table — with a format that cannot hold
  transparency matted as ⌘S mattes it and an unknown extension refused. `CutoutCommand`.
- **Three README claims described code that no longer exists**: the self-test count, the
  "zoom is anchored at the scroll origin" rough edge (⌘+ has held the visible centre since
  the polish pass) and "filters always run over the whole canvas" (only the selection's box
  is rendered now). A fourth, "Crop to Selection crops to the bounding box", was also stale:
  the pixels inside that box the mask does not cover are knocked out.

**The remaining six are not fixed.** They are interface and tidiness: the font panel not
repainting an open text box, a mistyped CLI flag launching the GUI instead of printing usage,
every window opening dead-centre, a dragged image (as opposed to a dragged file) being
refused, "Save a Copy…" leaving the window editing the copy, and Remove Background ignoring
an active selection while its menu neighbours honour one.

## History

The first run cost 18.2M tokens, 17 of which were the ten lenses and 276 skeptics. It stopped
on a session limit with two severity groups fixed. A resume then re-ran the verification
instead of replaying it from cache, and an API outage killed 246 of 290 agents — 2.3M tokens
for nothing. The lesson is in this folder: findings live in files here, not inside a workflow's
memory, and the two fixing runs that followed read them from disk.
