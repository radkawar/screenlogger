#!/usr/bin/env bash
# Install Screenlogger.app + screenlog CLI for local use (unsigned / no notarization).
#
# Defaults:
#   App: ~/Applications/Screenlogger.app
#   CLI: ~/.local/bin/screenlog
#   Framework: next to CLI (@executable_path)
#
# Overrides:
#   SCREENLOG_PREFIX   app install dir (default: ~/Applications)
#   SCREENLOG_BIN      CLI install dir (default: ~/.local/bin)
#   SCREENLOG_CONFIG   Xcode configuration (default: Debug)
#   SCREENLOG_PRODUCTS prebuilt products dir (tests/managed local installs)
#   SCREENLOG_HOME     home used for defaults and data-path messaging
#   DEVELOPER_DIR      Xcode toolchain (auto-detected when unset)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=Scripts/lib/install-lifecycle.sh
source "$ROOT/Scripts/lib/install-lifecycle.sh"

USER_HOME="${SCREENLOG_HOME:-$HOME}"
if [[ "$USER_HOME" != /* || "$USER_HOME" == "/" || "$USER_HOME" == *$'\n'* || ! -d "$USER_HOME" ]]; then
  echo "error: SCREENLOG_HOME must identify an existing, absolute, non-root directory" >&2
  exit 1
fi
USER_HOME="$(cd "$USER_HOME" && pwd -P)"
PREFIX="${SCREENLOG_PREFIX:-$USER_HOME/Applications}"
BIN_DIR="${SCREENLOG_BIN:-$USER_HOME/.local/bin}"
CONFIG="${SCREENLOG_CONFIG:-Debug}"

if ! sl_validate_install_roots "$PREFIX" "$BIN_DIR"; then
  echo "error: install destinations must be absolute, non-root paths without newlines or dot-segments" >&2
  exit 1
fi

# Resolve physical roots before composing any artifact destination. A symlinked
# root may be used, but ownership receipts always record the actual target.
PREFIX="$(sl_prepare_install_root "$PREFIX")" || {
  echo "error: app install root does not resolve to a safe non-root directory" >&2
  exit 1
}
BIN_DIR="$(sl_prepare_install_root "$BIN_DIR")" || {
  echo "error: CLI install root does not resolve to a safe non-root directory" >&2
  exit 1
}
if ! sl_validate_install_roots "$PREFIX" "$BIN_DIR"; then
  echo "error: resolved install destinations are not safe non-root directories" >&2
  exit 1
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ -n "${SCREENLOG_PRODUCTS:-}" ]]; then
  PRODUCTS="$SCREENLOG_PRODUCTS"
  echo "==> Using prebuilt products to $PRODUCTS"
else
  echo "==> Building ($CONFIG)..."
  if [[ "$CONFIG" == "Debug" ]]; then
    "$ROOT/Scripts/build.sh"
  else
    # Release path: same as build.sh but configuration override.
    if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
      export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
    "$ROOT/Scripts/xcodegen.sh" generate
    xcodebuild -project Screenlog.xcodeproj -scheme Screenlog \
      -configuration "$CONFIG" \
      -derivedDataPath "$ROOT/build/DerivedData" \
      -destination 'platform=macOS,arch=arm64' \
      CODE_SIGNING_ALLOWED=NO \
      ONLY_ACTIVE_ARCH=YES \
      build
  fi
  PRODUCTS="$ROOT/build/DerivedData/Build/Products/$CONFIG"
fi

APP_SRC="$PRODUCTS/Screenlogger.app"
CLI_SRC="$PRODUCTS/screenlog"
FW_PRODUCT="$PRODUCTS/ScreenlogCore.framework"
FW_SRC="$APP_SRC/Contents/Frameworks/ScreenlogCore.framework"

if [[ ! -d "$APP_SRC" || ! -x "$CLI_SRC" || ! -d "$FW_PRODUCT" || ! -d "$FW_SRC" ]]; then
  echo "error: build products missing under $PRODUCTS" >&2
  echo "  expected: Screenlogger.app with embedded framework, screenlog, ScreenlogCore.framework" >&2
  exit 1
fi

# --- Framework install name must be @rpath (no absolute /Library/Frameworks) ---
ID="$(otool -D "$FW_SRC/ScreenlogCore" 2>/dev/null | tail -1 || true)"
if ! echo "$ID" | grep -q '@rpath'; then
  echo "error: ScreenlogCore install name is not @rpath: $ID" >&2
  echo "hint: DYLIB_INSTALL_NAME_BASE=@rpath on ScreenlogCore; regenerate project" >&2
  exit 1
fi

APP_LINK="$(otool -L "$APP_SRC/Contents/MacOS/Screenlogger" 2>/dev/null | grep ScreenlogCore || true)"
CLI_LINK="$(otool -L "$CLI_SRC" 2>/dev/null | grep ScreenlogCore || true)"
if echo "$APP_LINK$CLI_LINK" | grep -q '/Library/Frameworks/ScreenlogCore'; then
  echo "error: product still links absolute /Library/Frameworks install name" >&2
  exit 1
fi

APP_DST="$PREFIX/Screenlogger.app"
CLI_DST="$BIN_DIR/screenlog"
FW_DST="$BIN_DIR/ScreenlogCore.framework"
RECEIPT_DST="$PREFIX/$SL_RECEIPT_NAME"
CLI_SKILL_DST="$BIN_DIR/skill/$SL_CLI_SKILL_NAME"
CLI_RECEIPT_DST="$BIN_DIR/$SL_CLI_RECEIPT_NAME"

if ! sl_app_recognized "$APP_SRC"; then
  echo "error: source app identity is not dev.screenlog.app / Screenlogger" >&2
  exit 1
fi
if ! sl_cli_pair_recognized "$CLI_SRC" "$FW_SRC"; then
  echo "error: source CLI/framework pair does not satisfy the Screenlogger ownership contract" >&2
  exit 1
fi

# The app and Command Setup have independent authenticated ownership receipts.
# Command Setup can legitimately update the CLI after this app was installed.
# Never overwrite receiptless or ambiguous conflicts, even if product-shaped.
if sl_node_exists "$RECEIPT_DST"; then
  if ! sl_app_receipt_matches "$RECEIPT_DST" "$APP_DST" "$CLI_DST" "$FW_DST"; then
    echo "error: existing local-install receipt or app was modified; preserving all destinations" >&2
    exit 1
  fi
else
  if sl_node_exists "$APP_DST" || sl_node_exists "$CLI_DST" || sl_node_exists "$FW_DST"; then
    echo "error: existing app or command files have no current install receipt; preserving all destinations" >&2
    exit 1
  fi
fi

# The app's Command Setup uses a second, content-authenticated receipt for the
# CLI/framework/skill trio. Validate it independently before replacing any of
# those nodes; partial or modified development installs require explicit
# cleanup rather than a permanent compatibility path before the first release.
CLI_INSTALL_EXISTS=0
if sl_node_exists "$CLI_DST" || sl_node_exists "$FW_DST" \
  || sl_node_exists "$CLI_SKILL_DST" || sl_node_exists "$CLI_RECEIPT_DST"; then
  CLI_INSTALL_EXISTS=1
fi
if [[ "$CLI_INSTALL_EXISTS" -eq 1 ]]; then
  if ! sl_cli_receipt_matches "$CLI_RECEIPT_DST" "$CLI_DST" "$FW_DST" "$CLI_SKILL_DST"; then
    echo "error: existing Command Setup receipt or skill was modified; preserving all destinations" >&2
    exit 1
  fi
fi

TRANSACTION_ID="$$-${RANDOM:-0}"
APP_STAGE_ROOT="$PREFIX/.screenlogger-install-$TRANSACTION_ID"
BIN_STAGE_ROOT="$BIN_DIR/.screenlogger-install-$TRANSACTION_ID"
APP_BACKUP_ROOT="$PREFIX/.screenlogger-backup-$TRANSACTION_ID"
BIN_BACKUP_ROOT="$BIN_DIR/.screenlogger-backup-$TRANSACTION_ID"
APP_STAGE="$APP_STAGE_ROOT/Screenlogger.app"
CLI_STAGE="$BIN_STAGE_ROOT/screenlog"
FW_STAGE="$BIN_STAGE_ROOT/ScreenlogCore.framework"
RECEIPT_STAGE="$APP_STAGE_ROOT/$SL_RECEIPT_NAME"
CLI_SKILL_STAGE="$BIN_STAGE_ROOT/skill/$SL_CLI_SKILL_NAME"
CLI_RECEIPT_STAGE="$BIN_STAGE_ROOT/$SL_CLI_RECEIPT_NAME"
CLI_SKILL_BACKUP="$BIN_BACKUP_ROOT/skill/$SL_CLI_SKILL_NAME"
CLI_RECEIPT_BACKUP="$BIN_BACKUP_ROOT/$SL_CLI_RECEIPT_NAME"
PUBLISHED_APP=0
PUBLISHED_CLI=0
PUBLISHED_FW=0
PUBLISHED_RECEIPT=0
PUBLISHED_CLI_SKILL=0
PUBLISHED_CLI_RECEIPT=0
COMMITTED=0

rollback_install() {
  local status=$?
  if [[ "$COMMITTED" -ne 1 ]]; then
    [[ "$PUBLISHED_RECEIPT" -eq 1 ]] && rm -f "$RECEIPT_DST"
    [[ "$PUBLISHED_CLI_RECEIPT" -eq 1 ]] && rm -f "$CLI_RECEIPT_DST"
    [[ "$PUBLISHED_CLI" -eq 1 ]] && rm -f "$CLI_DST"
    [[ "$PUBLISHED_CLI_SKILL" -eq 1 ]] && rm -rf "$CLI_SKILL_DST"
    [[ "$PUBLISHED_FW" -eq 1 ]] && rm -rf "$FW_DST"
    [[ "$PUBLISHED_APP" -eq 1 ]] && rm -rf "$APP_DST"
    [[ -e "$APP_BACKUP_ROOT/Screenlogger.app" ]] && mv "$APP_BACKUP_ROOT/Screenlogger.app" "$APP_DST"
    [[ -e "$APP_BACKUP_ROOT/$SL_RECEIPT_NAME" ]] && mv "$APP_BACKUP_ROOT/$SL_RECEIPT_NAME" "$RECEIPT_DST"
    [[ -e "$BIN_BACKUP_ROOT/screenlog" ]] && mv "$BIN_BACKUP_ROOT/screenlog" "$CLI_DST"
    [[ -e "$BIN_BACKUP_ROOT/ScreenlogCore.framework" ]] && mv "$BIN_BACKUP_ROOT/ScreenlogCore.framework" "$FW_DST"
    [[ -e "$CLI_SKILL_BACKUP" ]] && {
      mkdir -p "$(dirname "$CLI_SKILL_DST")"
      mv "$CLI_SKILL_BACKUP" "$CLI_SKILL_DST"
    }
    [[ -e "$CLI_RECEIPT_BACKUP" ]] && mv "$CLI_RECEIPT_BACKUP" "$CLI_RECEIPT_DST"
  fi
  rm -rf "$APP_STAGE_ROOT" "$BIN_STAGE_ROOT" "$APP_BACKUP_ROOT" "$BIN_BACKUP_ROOT"
  return "$status"
}
trap rollback_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$APP_STAGE_ROOT" "$BIN_STAGE_ROOT" "$APP_BACKUP_ROOT" "$BIN_BACKUP_ROOT"
ditto "$APP_SRC" "$APP_STAGE"
ditto "$FW_SRC" "$FW_STAGE"
install -m 755 "$CLI_SRC" "$CLI_STAGE"

# Bundle the agent skill into the application resources.
SKILL_SRC="$ROOT/Resources/skill/$SL_CLI_SKILL_NAME"
APP_SKILL_STAGE="$APP_STAGE/Contents/Resources/skill/$SL_CLI_SKILL_NAME"
if [[ ! -f "$SKILL_SRC/SKILL.md" ]]; then
  echo "error: Screenlogger assistant skill is missing from the checkout" >&2
  exit 1
fi
mkdir -p "$APP_SKILL_STAGE" "$CLI_SKILL_STAGE"
ditto "$SKILL_SRC" "$APP_SKILL_STAGE"
ditto "$SKILL_SRC" "$CLI_SKILL_STAGE"

if ! sl_app_recognized "$APP_STAGE" || ! sl_cli_pair_recognized "$CLI_STAGE" "$FW_STAGE"; then
  echo "error: staged products failed identity validation" >&2
  exit 1
fi
if ! sl_screenlogger_skill_recognized "$CLI_SKILL_STAGE"; then
  echo "error: staged Screenlogger assistant skill failed identity validation" >&2
  exit 1
fi
unset DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH || true
if ! VER="$("$CLI_STAGE" --version 2>&1)"; then
  echo "error: staged CLI launch check failed" >&2
  echo "$VER" >&2
  exit 1
fi
sl_write_receipt "$RECEIPT_STAGE" "$APP_STAGE" "$CLI_STAGE" "$FW_STAGE" "$APP_DST" "$CLI_DST" "$FW_DST"
sl_write_cli_receipt "$CLI_RECEIPT_STAGE" "$CLI_STAGE" "$FW_STAGE" "$CLI_SKILL_STAGE"

echo "==> Publishing verified app and command"
sl_node_exists "$APP_DST" && mv "$APP_DST" "$APP_BACKUP_ROOT/Screenlogger.app"
sl_node_exists "$RECEIPT_DST" && mv "$RECEIPT_DST" "$APP_BACKUP_ROOT/$SL_RECEIPT_NAME"
sl_node_exists "$CLI_DST" && mv "$CLI_DST" "$BIN_BACKUP_ROOT/screenlog"
sl_node_exists "$FW_DST" && mv "$FW_DST" "$BIN_BACKUP_ROOT/ScreenlogCore.framework"
if sl_node_exists "$CLI_SKILL_DST"; then
  mkdir -p "$(dirname "$CLI_SKILL_BACKUP")"
  mv "$CLI_SKILL_DST" "$CLI_SKILL_BACKUP"
fi
sl_node_exists "$CLI_RECEIPT_DST" && mv "$CLI_RECEIPT_DST" "$CLI_RECEIPT_BACKUP"
mv "$APP_STAGE" "$APP_DST"; PUBLISHED_APP=1
if [[ "${SCREENLOG_INSTALL_TEST_FAILURE_POINT:-}" == "after-app" ]]; then
  echo "error: injected install failure after app publication" >&2
  exit 97
fi
mv "$FW_STAGE" "$FW_DST"; PUBLISHED_FW=1
mkdir -p "$(dirname "$CLI_SKILL_DST")"
mv "$CLI_SKILL_STAGE" "$CLI_SKILL_DST"; PUBLISHED_CLI_SKILL=1
mv "$CLI_STAGE" "$CLI_DST"; PUBLISHED_CLI=1
mv "$CLI_RECEIPT_STAGE" "$CLI_RECEIPT_DST"; PUBLISHED_CLI_RECEIPT=1
mv "$RECEIPT_STAGE" "$RECEIPT_DST"; PUBLISHED_RECEIPT=1
if ! sl_receipt_matches "$RECEIPT_DST" "$APP_DST" "$CLI_DST" "$FW_DST"; then
  echo "error: published artifacts failed receipt verification; restoring previous installation" >&2
  exit 1
fi
if ! sl_cli_receipt_matches "$CLI_RECEIPT_DST" "$CLI_DST" "$FW_DST" "$CLI_SKILL_DST"; then
  echo "error: published Command Setup artifacts failed receipt verification; restoring previous installation" >&2
  exit 1
fi
# Clear quarantine so first launch is less friction (unsigned local build).
if command -v xattr >/dev/null 2>&1; then
  echo "==> Clearing quarantine attributes..."
  xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$CLI_DST" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$FW_DST" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$CLI_SKILL_DST" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$CLI_RECEIPT_DST" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$RECEIPT_DST" 2>/dev/null || true
fi

echo "==> Verifying..."

if ! VER="$("$CLI_DST" --version 2>&1)"; then
  echo "error: $CLI_DST --version failed (dyld / runtime)" >&2
  echo "$VER" >&2
  exit 1
fi
echo "cli --version: $VER"
COMMITTED=1

echo "app identity: verified (launch remains an explicit user action)"

# PATH hint
PATH_OK=0
case ":$PATH:" in
  *":$BIN_DIR:"*) PATH_OK=1 ;;
esac

cat <<EOF

Installed.
  App:  $APP_DST
  CLI:  $CLI_DST
  Skill bundle: $APP_DST/Contents/Resources/skill/$SL_CLI_SKILL_NAME
  Command skill: $CLI_SKILL_DST

Next:
  open "$APP_DST"
  # ensure CLI is on PATH:
EOF

if [[ "$PATH_OK" -eq 1 ]]; then
  echo "  # $BIN_DIR is already on your PATH"
else
  cat <<EOF
  # add to shell config if needed:
  #   fish:  fish_add_path $BIN_DIR
  #   zsh:   export PATH="$BIN_DIR:\$PATH"
EOF
fi

cat <<EOF

First run:
  1. open "$APP_DST"   (if macOS complains about an unknown developer: Control-click and choose Open)
  2. Open Setup from the menu bar icon and allow Screen Recording
     deep link: open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
  3. Start recording, then: screenlog search "something you saw"

Assistant skill (optional):
  screenlog skill install all

Uninstall:
  ./Scripts/uninstall.sh

Data stays in: $USER_HOME/Library/Application Support/dev.screenlog/
EOF
