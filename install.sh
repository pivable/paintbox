#!/bin/bash
#
# install.sh — the one command to give people.
#
#     curl -fsSL https://raw.githubusercontent.com/pivable/paintbox/main/install.sh | bash
#
# WHY THIS SHAPE, AND NOT A DOWNLOADED .app OR A DOUBLE-CLICKABLE SCRIPT.
#
# Everything macOS receives through a browser gets a quarantine flag, and
# Paintbox is ad-hoc signed rather than notarised by Apple, so Gatekeeper
# refuses it. Since macOS Sequoia the old right-click-to-open shortcut is gone,
# leaving System Settings > Privacy & Security > Open Anyway. That wall applies
# to a downloaded .app, to a downloaded .dmg, and — people are surprised by this
# — to a downloaded .command script too. A script is not a loophole.
#
# What DOES sidestep it, completely and legitimately: building on the machine
# that will run it. A locally built app is never quarantined, because it was
# never downloaded. So this script fetches the SOURCE, builds it here, runs the
# test suite, and only then installs. No warning, no Settings, no 99 dollars.
#
# The honest cost is that it needs Apple's command line tools, which is a free
# but multi-gigabyte download if they are absent. For someone who will not do
# that, the answer is notarisation, not a cleverer script.

set -euo pipefail

REPO="${PAINTBOX_REPO:-https://github.com/pivable/paintbox}"
BRANCH="${PAINTBOX_BRANCH:-main}"
DEST="${PAINTBOX_DEST:-/Applications}"

say() { printf '  %s\n' "$*"; }
die() { printf '\n  %s\n\n' "$*" >&2; exit 1; }

printf '\n  Paintbox\n\n'

# ── the two things that make this impossible, checked before anything is downloaded ──

[ "$(uname -s)" = "Darwin" ] || die "Paintbox is a macOS app. This is $(uname -s)."

major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || die "Needs macOS 14 or newer; this is $(sw_vers -productVersion).
  Remove Background uses a Vision capability that arrived in 14."

if ! command -v swiftc >/dev/null 2>&1; then
    die "Apple's command line tools are missing, so there is no Swift compiler.

  Run this, let it finish, then run the install command again:

      xcode-select --install

  Xcode itself is NOT needed — this project has no Xcode project."
fi

say "macOS $(sw_vers -productVersion), $(swiftc --version 2>/dev/null | head -1)"

# ── fetch ──

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say "Fetching the source..."
if command -v git >/dev/null 2>&1; then
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$WORK/paintbox" >/dev/null 2>&1 \
        || die "Could not clone $REPO"
else
    # No git: fall back to the tarball, which needs nothing extra.
    curl -fsSL "$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar xz -C "$WORK" \
        || die "Could not download $REPO"
    mv "$WORK"/paintbox-* "$WORK/paintbox"
fi

cd "$WORK/paintbox"

# ── build, and refuse to install something that does not pass its own tests ──

say "Building..."
./build.sh >/dev/null 2>&1 || { ./build.sh; die "The build failed; its output is above."; }

say "Checking it works..."
if ! ./Paintbox.app/Contents/MacOS/Paintbox --selftest >"$WORK/selftest.log" 2>&1; then
    cp "$WORK/selftest.log" /tmp/paintbox-selftest.log
    die "The self-test FAILED, so nothing was installed.
  The log is at /tmp/paintbox-selftest.log"
fi
say "$(tail -1 "$WORK/selftest.log")"

# ── install ──

if [ -e "$DEST/Paintbox.app" ]; then
    say "Replacing the copy already in $DEST"
    rm -rf "$DEST/Paintbox.app"
fi
cp -R Paintbox.app "$DEST/Paintbox.app" 2>/dev/null || die "Could not write to $DEST.
  Either run with a writable destination:  PAINTBOX_DEST=\"\$HOME/Applications\" ...
  or re-run the same command with sudo."

printf '\n  Installed to %s/Paintbox.app\n' "$DEST"
printf '  It opens straight away — an app built on this machine is never quarantined.\n\n'

open "$DEST/Paintbox.app" 2>/dev/null || true
