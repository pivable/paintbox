#!/bin/bash
#
# Build.command — double-click this in Finder to build Paintbox and open it.
#
# WHY A .command FILE AT ALL. Finder will run a `.command` in Terminal when you
# double-click it, which a plain `.sh` will not: that one opens in a text editor
# instead. Same script, different extension, entirely different behaviour.
#
# WHAT THIS DOES NOT SOLVE, AND IT IS WORTH BEING PLAIN ABOUT IT. If you
# DOWNLOADED this file, macOS attached a quarantine flag to it, and double-
# clicking will be refused the first time with a message about an unidentified
# developer — exactly as it would for the app itself. A script is not a loophole.
# It works immediately if you got this by `git clone`, or after you have cleared
# the flag once. The line to clear it is printed at the bottom of this file.
#
# It is still worth shipping, because the git-clone route is the one a developer
# takes, and for them this is genuinely one double-click.

set -euo pipefail

# Finder runs a .command from the user's home directory, not from where the file
# lives, so every relative path would otherwise be wrong.
cd "$(dirname "$0")"

printf '\n  Building Paintbox in %s\n\n' "$(pwd)"

if ! command -v swiftc >/dev/null 2>&1; then
    cat <<'MISSING'
  Apple's command line tools are not installed, so there is no Swift compiler.

  Run this, let it finish, then double-click Build.command again:

      xcode-select --install

  Xcode itself is NOT needed. This project has no Xcode project and does not use
  xcodebuild.

MISSING
    echo "  Press Return to close this window."
    read -r _
    exit 1
fi

if ! ./build.sh; then
    echo
    echo "  The build failed. The output above says why."
    echo "  The usual causes are macOS older than 14, or an SDK too old for the"
    echo "  Vision call that Remove Background uses."
    echo
    echo "  Press Return to close this window."
    read -r _
    exit 1
fi

echo
echo "  Checking it actually works before opening it..."
if ./Paintbox.app/Contents/MacOS/Paintbox --selftest >/tmp/paintbox-selftest.log 2>&1; then
    tail -1 /tmp/paintbox-selftest.log | sed 's/^/  /'
else
    echo "  THE SELF-TEST FAILED. Not opening the app."
    echo "  The full log is at /tmp/paintbox-selftest.log"
    echo
    echo "  Press Return to close this window."
    read -r _
    exit 1
fi

echo
echo "  Opening Paintbox. An app you built yourself carries no quarantine flag,"
echo "  so macOS does not challenge it."
echo
open Paintbox.app

echo "  Done. You can close this window."
