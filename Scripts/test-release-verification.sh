#!/usr/bin/env bash
# Focused contracts for release structure and complete ad-hoc signing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCTS="${1:-$ROOT/build/DerivedData/Build/Products/Release}"
APP="$PRODUCTS/Screenlogger.app"
CLI="$PRODUCTS/screenlog"
FRAMEWORK="$PRODUCTS/ScreenlogCore.framework"
SKILL="$PRODUCTS/skill/screenlog-cli-skill"

if [[ ! -d "$APP" || ! -x "$CLI" || ! -d "$FRAMEWORK" || ! -f "$SKILL/SKILL.md" ]]; then
  echo "error: pass universal Release products with app, CLI, framework, and skill" >&2
  exit 1
fi

"$ROOT/Scripts/check-release.sh" --structure "$APP" "$CLI" >/dev/null

set +e
"$ROOT/Scripts/check-release.sh" --not-a-mode "$APP" "$CLI" >/dev/null 2>&1
UNKNOWN_MODE_STATUS=$?
set -e
if (( UNKNOWN_MODE_STATUS != 2 )); then
  echo "error: unknown release-verification mode exited $UNKNOWN_MODE_STATUS, expected 2" >&2
  exit 1
fi

CONTRACT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/screenlogger-release-test.XXXXXX")"
cleanup_contract() {
  rm -rf -- "$CONTRACT_ROOT"
}
trap cleanup_contract EXIT INT TERM

TEST_APP="$CONTRACT_ROOT/Screenlogger.app"
TEST_CLI_ROOT="$CONTRACT_ROOT/CLI"
TEST_CLI="$TEST_CLI_ROOT/screenlog"
mkdir -p "$TEST_CLI_ROOT/skill"
ditto "$APP" "$TEST_APP"
ditto "$CLI" "$TEST_CLI"
ditto "$FRAMEWORK" "$TEST_CLI_ROOT/ScreenlogCore.framework"
ditto "$SKILL" "$TEST_CLI_ROOT/skill/screenlog-cli-skill"

"$ROOT/Scripts/sign-release-adhoc.sh" "$TEST_APP" "$TEST_CLI" >/dev/null
"$ROOT/Scripts/check-release.sh" --ad-hoc "$TEST_APP" "$TEST_CLI" >/dev/null
/usr/bin/codesign --verify --deep --strict "$TEST_APP"
APP_SIGNATURE_DETAILS="$(/usr/bin/codesign -dvvv "$TEST_APP" 2>&1)"
if ! grep -q '^Identifier=dev\.screenlog\.app$' <<<"$APP_SIGNATURE_DETAILS" \
  || ! grep -Eq '^Info\.plist entries=[1-9][0-9]*$' <<<"$APP_SIGNATURE_DETAILS" \
  || ! grep -Eq '^Sealed Resources version=[1-9]' <<<"$APP_SIGNATURE_DETAILS"; then
  echo "error: complete app signature did not bind the expected identity and resources" >&2
  exit 1
fi

TAMPERED_APP="$CONTRACT_ROOT/Tampered.app"
ditto "$TEST_APP" "$TAMPERED_APP"
printf '\n' >> "$TAMPERED_APP/Contents/Resources/Assets.car"
if "$ROOT/Scripts/check-release.sh" --ad-hoc "$TAMPERED_APP" "$TEST_CLI" \
  >/dev/null 2>&1; then
  echo "error: ad-hoc verification accepted an app with a broken resource seal" >&2
  exit 1
fi

THIN_APP="$CONTRACT_ROOT/Thin.app"
ditto "$APP" "$THIN_APP"

APP_EXECUTABLE="$THIN_APP/Contents/MacOS/Screenlogger"
THIN_EXECUTABLE="$CONTRACT_ROOT/Screenlogger.arm64"
lipo "$APP_EXECUTABLE" -thin arm64 -output "$THIN_EXECUTABLE"
mv "$THIN_EXECUTABLE" "$APP_EXECUTABLE"
chmod 755 "$APP_EXECUTABLE"

if "$ROOT/Scripts/check-release.sh" --structure "$THIN_APP" "$TEST_CLI" >/dev/null 2>&1; then
  echo "error: structural verification accepted a single-architecture app" >&2
  exit 1
fi

# Optional model weights are not bundled, but the worker and compiled Metal
# runtime must be: otherwise a successful download still cannot enable search.
MISSING_WORKER_APP="$CONTRACT_ROOT/MissingWorker.app"
ditto "$APP" "$MISSING_WORKER_APP"
rm "$MISSING_WORKER_APP/Contents/MacOS/screenlog-semantic-worker"
if "$ROOT/Scripts/check-release.sh" --structure "$MISSING_WORKER_APP" "$TEST_CLI" >/dev/null 2>&1; then
  echo "error: structural verification accepted an app without its semantic worker" >&2
  exit 1
fi

MISSING_METAL_APP="$CONTRACT_ROOT/MissingMetal.app"
ditto "$APP" "$MISSING_METAL_APP"
rm -rf "$MISSING_METAL_APP/Contents/Resources/mlx-swift_Cmlx.bundle"
if "$ROOT/Scripts/check-release.sh" --structure "$MISSING_METAL_APP" "$TEST_CLI" >/dev/null 2>&1; then
  echo "error: structural verification accepted an app without its MLX Metal resources" >&2
  exit 1
fi

echo "release verification contracts: passed"
