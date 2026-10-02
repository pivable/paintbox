# Known issues

Paintbox has been through a ten-lens code review and three rounds of fixing, and it carries 192
self-tests that assert real pixels. These are what a final **completeness critic** found
afterwards — an agent whose only job was to find what the review itself had missed.

**Three of them were fixed before publication** and are struck through below. The rest are open,
and are listed here rather than left for you to discover.


- ~~**Save As can point two windows at one file — the exact data loss Open guards against**~~ *(data-loss)*  **Fixed before release.**

- ~~**--cutout always writes PNG bytes whatever the output is named — including the README's own loop**~~ *(wrong-output)*  **Fixed before release.**

- **Changing the font while a text box is open changes what gets drawn but not what you see** *(wrong-output)*

- **A mistyped CLI flag silently launches the GUI instead of reporting usage** *(ux)*

- ~~**Three README claims describe code that no longer exists**~~ *(tidy)*  **Fixed before release.**

- **Every window opens dead-centre, so opening several files looks like opening one** *(ux)*

- **An image dragged from a browser or Photos is refused; only file drops work** *(ux)*

- **"Save a Copy…" is a Save As: the window ends up editing the copy** *(ux)*

- **Remove Background silently ignores an active selection while its menu neighbours honour one** *(ux)*


## The three that were fixed, and why those three

Two blocked a release. One was data loss: Save As could point two windows at the same file,
which is exactly the hazard that Open already guarded against. The other was wrong output in
something this README tells you to run: the headless `--cutout` wrote PNG bytes whatever you
named the output, so the documented batch loop produced mislabelled files.

The third was the documentation: the README described code that had since changed. It gave a
stale self-test count, said zoom is anchored at the scroll origin (it has held the visible
centre since the polish pass) and that filters always run over the whole canvas (only the
selection's box is rendered now). A fourth stale claim, about Crop to Selection, was corrected
with them. The detail is in `REVIEW-BACKLOG.md`.

The rest are interface and tidiness. They are real, and none of them loses your work.

## Reporting anything else

Open an issue. If you can say what you did, what you expected and what happened, that is
enough — the self-test suite is good at turning a clear report into a regression test.
