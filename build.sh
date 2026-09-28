#!/bin/bash
# Builds DockIt.app. Pass --install to copy it into /Applications and launch it.
#
# Environment (release.sh sets the first two):
#   RELEASE=1          keep the update feed in Info.plist; without it the feed is removed, so a
#                      local build never updates itself out from under its developer
#   VERSION, BUILD     stamp CFBundleShortVersionString / CFBundleVersion into the built bundle
#   CODESIGN_IDENTITY  signing identity; "Cmd-Tab Local" when unset, ad-hoc when that is absent
set -euo pipefail

cd "$(dirname "$0")"
APP="build/DockIt.app"

# A release is universal: macOS 26 still runs on some Intel Macs. A local build stays native, at
# half the compile time.
ARCH_ARGS=()
if [[ "${RELEASE:-0}" == "1" ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi
echo "==> Compiling"
# ${a[@]+...}: macOS ships bash 3.2, where an empty array under `set -u` is an error.
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/DockIt"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DockIt"
if [[ "${RELEASE:-0}" == "1" ]]; then
    ARCHS="$(lipo -archs "$APP/Contents/MacOS/DockIt")"
    if [[ " $ARCHS " != *" arm64 "* || " $ARCHS " != *" x86_64 "* ]]; then
        echo "==> ERROR: the release binary is '$ARCHS', not universal (arm64 and x86_64)" >&2
        exit 1
    fi
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM links Sparkle.framework but does nothing to put it inside a bundle assembled by hand, so
# without these steps the app launches and dies on its first Sparkle call with dyld's "Library not
# loaded". Copy the macOS slice in, point an rpath at it, and sign it before the app (below).
SPARKLE_XC="$(find .build/artifacts -type d -name 'Sparkle.xcframework' -print -quit)"
if [[ -z "$SPARKLE_XC" ]]; then
    echo "==> ERROR: Sparkle.xcframework not found — run 'swift package resolve' first" >&2
    exit 1
fi
SPARKLE_FW="$(find "$SPARKLE_XC" -maxdepth 2 -type d -name 'Sparkle.framework' -path '*macos*' -print -quit)"
echo "==> Embedding Sparkle"
mkdir -p "$APP/Contents/Frameworks"
# -R keeps the version symlinks a framework is made of; the signature fails without them.
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
# Only when missing: -add_rpath refuses a duplicate. grep without -q reads otool to the end, since
# under pipefail an early exit would fail the pipeline.
if ! otool -l "$APP/Contents/MacOS/DockIt" | grep -F -- '@executable_path/../Frameworks' >/dev/null; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/DockIt"
fi

if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
fi
# The tracked Info.plist carries the release feed. A local build must not follow it: it would see
# the published version as newer than the working tree and replace the build being tested.
if [[ "${RELEASE:-0}" != "1" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

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
    SIGN_AS="$IDENTITY"
else
    echo "==> Signing (ad-hoc — \"$IDENTITY\" not found; Accessibility resets on each build)"
    SIGN_AS="-"
fi
# Inside out, because an outer signature seals the inner ones: first the bare helper executables in
# Sparkle (Autoupdate), then its bundles deepest first (XPC services, Updater.app, the framework),
# then the app. Signed the other way round, the bundle passes a plain verify and fails --deep.
while IFS= read -r item; do
    codesign --force --sign "$SIGN_AS" "$item"
done < <(find "$APP/Contents/Frameworks" -type f -perm -u+x ! -path '*/Contents/MacOS/*' \
    -exec sh -c 'file -b "$1" | grep -q "Mach-O.*executable"' _ {} \; -print)
while IFS= read -r item; do
    codesign --force --sign "$SIGN_AS" "$item"
done < <(find "$APP/Contents/Frameworks" -depth \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' \) ! -type l -print)
codesign --force --sign "$SIGN_AS" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    # Copied beside the old copy first, so a failed copy leaves it installed; only the rename below
    # runs with no app in place. Not named *.app, so nothing registers the half-copied bundle. And
    # before DockIt is stopped: a copy that failed after the kill (disk full, no write access) left
    # the old copy installed but not running, and the macOS Dock hidden — no dock at all.
    STAGED="/Applications/.DockIt-installing"
    rm -rf "$STAGED"
    cp -R "$APP" "$STAGED"
    # SIGTERM, not `quit app`: a real quit restores the macOS Dock, and the relaunch below would
    # hide it again — two Dock restarts per install. Killed, DockIt leaves the Dock hidden and its
    # saved originals in place, and the new copy finds nothing to change.
    pkill -x DockIt 2>/dev/null || true
    for _ in $(seq 1 30); do
        pgrep -x DockIt >/dev/null 2>&1 || break
        sleep 0.1
    done
    pkill -9 -x DockIt 2>/dev/null || true
    rm -rf /Applications/DockIt.app
    mv "$STAGED" /Applications/DockIt.app
    open /Applications/DockIt.app
    echo "==> Launched."
fi
