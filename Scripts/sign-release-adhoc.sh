#!/usr/bin/env bash
# Apply deterministic, complete ad-hoc signatures to staged release artifacts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/Config/Screenlog.entitlements"

usage() {
  cat <<EOF
Usage: $0 Screenlogger.app screenlog

Signs the app's embedded framework and CLI before signing the outer app, then
signs the standalone CLI/framework pair. These local ad-hoc signatures bind
bundle metadata and resources but are not Developer ID signatures and are not
valid substitutes for notarization.
EOF
}

if (( $# != 2 )); then
  usage >&2
  exit 2
fi

APP="$1"
CLI="$2"
CLI_DIRECTORY="$(dirname "$CLI")"
APP_FRAMEWORK="$APP/Contents/Frameworks/ScreenlogCore.framework"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
BUNDLED_CLI="$APP/Contents/MacOS/screenlog"
SEMANTIC_WORKER="$APP/Contents/MacOS/screenlog-semantic-worker"
CLI_FRAMEWORK="$CLI_DIRECTORY/ScreenlogCore.framework"

if ! command -v codesign >/dev/null 2>&1; then
  echo "error: required signing tool is unavailable: codesign" >&2
  exit 1
fi

require_directory() {
  local path="$1"
  local label="$2"
  if [[ ! -d "$path" || -L "$path" ]]; then
    echo "error: $label is missing, linked, or not a directory: $path" >&2
    exit 1
  fi
}

require_executable() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" || -L "$path" || ! -x "$path" ]]; then
    echo "error: $label is missing, linked, or not a regular executable: $path" >&2
    exit 1
  fi
}

require_directory "$APP" "app bundle"
require_directory "$APP_FRAMEWORK" "embedded framework"
require_directory "$SPARKLE_FRAMEWORK" "embedded Sparkle framework"
require_executable "$BUNDLED_CLI" "bundled CLI"
require_executable "$SEMANTIC_WORKER" "semantic worker"
require_directory "$CLI_FRAMEWORK" "standalone CLI framework"
require_executable "$CLI" "standalone CLI"
if [[ ! -f "$ENTITLEMENTS" || -L "$ENTITLEMENTS" ]]; then
  echo "error: app entitlements are missing or linked: $ENTITLEMENTS" >&2
  exit 1
fi

sign_artifact() {
  local path="$1"
  local identifier="$2"
  /usr/bin/codesign \
    --force \
    --sign - \
    --timestamp=none \
    --identifier "$identifier" \
    "$path"
}

# Sign every nested artifact before the bundle that seals it. Explicit stable
# identifiers replace Xcode's incomplete linker-generated placeholder identity.
sign_artifact "$APP_FRAMEWORK" "dev.screenlog.core"
# Xcode's binary-package copy strips development headers from Sparkle. Seal the
# resulting framework version while retaining the upstream helper identifiers
# and entitlements that its updater processes require.
/usr/bin/codesign \
  --force \
  --sign - \
  --timestamp=none \
  --preserve-metadata=identifier,entitlements,flags \
  "$SPARKLE_FRAMEWORK/Versions/Current"
sign_artifact "$BUNDLED_CLI" "dev.screenlog.cli"
sign_artifact "$SEMANTIC_WORKER" "dev.screenlog.semantic-worker"
/usr/bin/codesign \
  --force \
  --sign - \
  --timestamp=none \
  --identifier "dev.screenlog.app" \
  --entitlements "$ENTITLEMENTS" \
  --generate-entitlement-der \
  "$APP"

# The technical archive also ships an independently usable CLI/framework pair.
sign_artifact "$CLI_FRAMEWORK" "dev.screenlog.core"
sign_artifact "$CLI" "dev.screenlog.cli"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$CLI_FRAMEWORK"
/usr/bin/codesign --verify --strict --verbose=2 "$CLI"

echo "complete ad-hoc release signatures applied"
