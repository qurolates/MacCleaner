#!/usr/bin/env bash
# build.sh — build MacCleaner.app without Xcode.
#
# Steps:
#   1. cargo build --release      → mac-cleaner-core binary
#   2. swiftc swift-ui/main.swift → MacCleaner Mach-O executable
#   3. Assemble MacCleaner.app/Contents/{MacOS,Resources,Info.plist}
#
# Output: ./MacCleaner.app at the repo root.

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="$ROOT/mac-cleaner-core"
SWIFT_SRC="$ROOT/swift-ui/main.swift"
PLIST_SRC="$ROOT/build-assets/Info.plist"
ICON_SRC="$ROOT/MacCleaner.icns"

APP_NAME="MacCleaner"
APP_BUNDLE="$ROOT/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

# ─────────────────────────────────────────────────────────────
# Pretty logging
# ─────────────────────────────────────────────────────────────
log() { printf "\033[1;34m▸\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; }

# ─────────────────────────────────────────────────────────────
# Sanity checks
# ─────────────────────────────────────────────────────────────
command -v cargo  >/dev/null || { err "cargo not found (install Rust)"; exit 1; }
command -v swiftc >/dev/null || { err "swiftc not found (install Xcode CLT)"; exit 1; }
[ -f "$SWIFT_SRC" ] || { err "Swift source missing: $SWIFT_SRC"; exit 1; }
[ -f "$PLIST_SRC" ] || { err "Info.plist missing: $PLIST_SRC"; exit 1; }

# ─────────────────────────────────────────────────────────────
# 1. Build Rust core
# ─────────────────────────────────────────────────────────────
log "Building Rust core (release)…"
( cd "$RUST_DIR" && cargo build --release )
RUST_BIN="$RUST_DIR/target/release/mac-cleaner-core"
[ -f "$RUST_BIN" ] || { err "Rust binary not produced at $RUST_BIN"; exit 1; }
ok "Rust core built: $(du -h "$RUST_BIN" | awk '{print $1}')"

# ─────────────────────────────────────────────────────────────
# 2. Assemble .app skeleton
# ─────────────────────────────────────────────────────────────
log "Assembling $APP_NAME.app skeleton…"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# ─────────────────────────────────────────────────────────────
# 3. Copy Rust binary into Resources
# ─────────────────────────────────────────────────────────────
cp "$RUST_BIN" "$RES_DIR/mac-cleaner-core"
chmod +x "$RES_DIR/mac-cleaner-core"
ok "Bundled core → Contents/Resources/mac-cleaner-core"

# ─────────────────────────────────────────────────────────────
# 4. Compile SwiftUI front-end
# ─────────────────────────────────────────────────────────────
log "Compiling SwiftUI front-end…"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
swiftc \
    -O \
    -target x86_64-apple-macos13.0 \
    -sdk "$SDK_PATH" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    -framework UniformTypeIdentifiers \
    -parse-as-library \
    -o "$MACOS_DIR/$APP_NAME" \
    "$SWIFT_SRC"
chmod +x "$MACOS_DIR/$APP_NAME"
ok "Swift binary built: $MACOS_DIR/$APP_NAME"

# ─────────────────────────────────────────────────────────────
# 5. Drop Info.plist
# ─────────────────────────────────────────────────────────────
cp "$PLIST_SRC" "$CONTENTS/Info.plist"
ok "Info.plist installed"

# ─────────────────────────────────────────────────────────────
# 5b. Copy app icon
# ─────────────────────────────────────────────────────────────
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$CONTENTS/Resources/MacCleaner.icns"
    ok "App icon installed"
fi

# ─────────────────────────────────────────────────────────────
# 6. Ad-hoc codesign so Gatekeeper lets us launch it locally
# ─────────────────────────────────────────────────────────────
if command -v codesign >/dev/null; then
    log "Ad-hoc codesigning…"
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null \
        && ok "Ad-hoc signed" \
        || err "codesign failed (non-fatal; app may still run)"
fi

# ─────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────
echo
ok "Built $APP_BUNDLE"
echo "  Run with:   open \"$APP_BUNDLE\""
echo "  Or direct:  \"$MACOS_DIR/$APP_NAME\""
