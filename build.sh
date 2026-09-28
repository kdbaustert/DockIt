#!/bin/bash
# Builds DockIt.app. Pass --install to copy it into /Applications and launch it.
#
# Environment:
#   CODESIGN_IDENTITY  signing identity; ad-hoc when unset
set -euo pipefail

cd "$(dirname "$0")"
APP="build/DockIt.app"

echo "==> Compiling"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/DockIt"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DockIt"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signed with a stable identity when one is present, as Cmd-Tab is — and with Cmd-Tab's own local
# certificate by default. macOS keys the Accessibility permission (which restoring minimized
# windows needs) to the app's designated requirement: with the same certificate every time it stays
# put and the permission survives a rebuild. Ad-hoc signing has no certificate, so the requirement
# falls back to the code hash, which changes every build. Sharing the certificate does not merge
# the two apps' permissions; the requirement names the bundle identifier too.
IDENTITY="${CODESIGN_IDENTITY:-Cmd-Tab Local}"
# No `grep -q`: under pipefail an early exit can SIGPIPE `security` and fail a build that has the
# identity over to the ad-hoc branch.
if security find-identity -v -p codesigning | grep -F -- "$IDENTITY" >/dev/null; then
    echo "==> Signing as \"$IDENTITY\""
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "==> Signing (ad-hoc — \"$IDENTITY\" not found; Accessibility resets on each build)"
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "==> Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    # SIGTERM, not `quit app`: a real quit restores the macOS Dock, and the relaunch below would
    # hide it again — two Dock restarts per install. Killed, DockIt leaves the Dock hidden and its
    # saved originals in place, and the new copy finds nothing to change.
    pkill -x DockIt 2>/dev/null || true
    for _ in $(seq 1 30); do
        pgrep -x DockIt >/dev/null 2>&1 || break
        sleep 0.1
    done
    pkill -9 -x DockIt 2>/dev/null || true
    # Copied beside the old copy first, so a failed copy leaves it installed; only the rename below
    # runs with no app in place. Not named *.app, so nothing registers the half-copied bundle.
    STAGED="/Applications/.DockIt-installing"
    rm -rf "$STAGED"
    cp -R "$APP" "$STAGED"
    rm -rf /Applications/DockIt.app
    mv "$STAGED" /Applications/DockIt.app
    open /Applications/DockIt.app
    echo "==> Launched."
fi
