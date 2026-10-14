#!/usr/bin/env bash
# Isolated local install/upgrade/uninstall smoke. Never targets the real home.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCTS="${1:-$ROOT/build/DerivedData/Build/Products/Debug}"
[[ -d "$PRODUCTS/Screenlogger.app" && -x "$PRODUCTS/screenlog" && -d "$PRODUCTS/ScreenlogCore.framework" ]] || {
  echo "error: pass a products directory containing Screenlogger.app, screenlog, and ScreenlogCore.framework" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/screenlogger-lifecycle.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Path validation refuses traversal before creating roots and rejects a
# lexically non-root path whose physical target is the filesystem root.
if SCREENLOG_HOME="$TEST_ROOT" \
  SCREENLOG_PREFIX="$TEST_ROOT/scope/../escape" \
  SCREENLOG_BIN="$TEST_ROOT/bin" \
  SCREENLOG_PRODUCTS="$PRODUCTS" \
  "$ROOT/Scripts/install.sh" >/dev/null 2>&1; then
  echo "error: install accepted a destination containing dot-segments" >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/escape/Screenlogger.app" ]]
/bin/ln -s / "$TEST_ROOT/root-link"
# shellcheck source=Scripts/lib/install-lifecycle.sh
source "$ROOT/Scripts/lib/install-lifecycle.sh"
if sl_prepare_install_root "$TEST_ROOT/root-link" >/dev/null 2>&1; then
  echo "error: install root resolving to / was accepted" >&2
  exit 1
fi

install_into() {
  local home="$1"
  mkdir -p "$home"
  SCREENLOG_HOME="$home" \
    SCREENLOG_PREFIX="$home/Applications" \
    SCREENLOG_BIN="$home/.local/bin" \
    SCREENLOG_PRODUCTS="$PRODUCTS" \
    "$ROOT/Scripts/install.sh" >/dev/null
}

uninstall_from() {
  local home="$1"
  shift
  SCREENLOG_HOME="$home" \
    SCREENLOG_PREFIX="$home/Applications" \
    SCREENLOG_BIN="$home/.local/bin" \
    "$ROOT/Scripts/uninstall.sh" "$@" >/dev/null
}

# Valid install to authenticated uninstall preserves data and unrelated files.
HOME_ONE="$TEST_ROOT/valid"
mkdir -p "$HOME_ONE/Library/Application Support/dev.screenlog" "$HOME_ONE/.local/bin"
printf 'library sentinel' > "$HOME_ONE/Library/Application Support/dev.screenlog/keep.txt"
printf 'unrelated' > "$HOME_ONE/.local/bin/other-tool"
install_into "$HOME_ONE"
[[ -d "$HOME_ONE/Applications/Screenlogger.app" ]]
[[ -x "$HOME_ONE/.local/bin/screenlog" ]]
[[ -f "$HOME_ONE/Applications/.screenlogger-local-install.plist" ]]
[[ -f "$HOME_ONE/.local/bin/$SL_CLI_RECEIPT_NAME" ]]
[[ -f "$HOME_ONE/.local/bin/skill/$SL_CLI_SKILL_NAME/SKILL.md" ]]
sl_cli_receipt_matches \
  "$HOME_ONE/.local/bin/$SL_CLI_RECEIPT_NAME" \
  "$HOME_ONE/.local/bin/screenlog" \
  "$HOME_ONE/.local/bin/ScreenlogCore.framework" \
  "$HOME_ONE/.local/bin/skill/$SL_CLI_SKILL_NAME"
# A receipt-authenticated reinstall follows the same upgrade transaction and
# leaves unrelated/data nodes in place.
install_into "$HOME_ONE"
sl_cli_receipt_matches \
  "$HOME_ONE/.local/bin/$SL_CLI_RECEIPT_NAME" \
  "$HOME_ONE/.local/bin/screenlog" \
  "$HOME_ONE/.local/bin/ScreenlogCore.framework" \
  "$HOME_ONE/.local/bin/skill/$SL_CLI_SKILL_NAME"
[[ "$(< "$HOME_ONE/Library/Application Support/dev.screenlog/keep.txt")" == "library sentinel" ]]
[[ "$(< "$HOME_ONE/.local/bin/other-tool")" == "unrelated" ]]

# Command Setup can publish a newer authenticated command without replacing the
# app. Its independently updated receipt must permit the next app upgrade.
printf '\n' >> "$HOME_ONE/.local/bin/screenlog"
sl_write_cli_receipt "$HOME_ONE/.local/bin/$SL_CLI_RECEIPT_NAME" \
  "$HOME_ONE/.local/bin/screenlog" "$HOME_ONE/.local/bin/ScreenlogCore.framework" \
  "$HOME_ONE/.local/bin/skill/$SL_CLI_SKILL_NAME"
install_into "$HOME_ONE"
sl_receipt_matches "$HOME_ONE/Applications/$SL_RECEIPT_NAME" \
  "$HOME_ONE/Applications/Screenlogger.app" "$HOME_ONE/.local/bin/screenlog" \
  "$HOME_ONE/.local/bin/ScreenlogCore.framework"
uninstall_from "$HOME_ONE"
[[ ! -e "$HOME_ONE/Applications/Screenlogger.app" ]]
[[ ! -e "$HOME_ONE/.local/bin/screenlog" ]]
[[ ! -e "$HOME_ONE/.local/bin/ScreenlogCore.framework" ]]
[[ ! -e "$HOME_ONE/.local/bin/$SL_CLI_RECEIPT_NAME" ]]
[[ ! -e "$HOME_ONE/.local/bin/skill/$SL_CLI_SKILL_NAME" ]]
[[ ! -e "$HOME_ONE/Applications/.screenlogger-local-install.plist" ]]
[[ "$(< "$HOME_ONE/Library/Application Support/dev.screenlog/keep.txt")" == "library sentinel" ]]
[[ "$(< "$HOME_ONE/.local/bin/other-tool")" == "unrelated" ]]

# Modified receipt-backed artifacts fail closed for both upgrade and uninstall.
HOME_TWO="$TEST_ROOT/modified"
mkdir -p "$HOME_TWO/Library/Application Support/dev.screenlog"
printf 'preserve data' > "$HOME_TWO/Library/Application Support/dev.screenlog/keep.txt"
install_into "$HOME_TWO"
printf 'tampered' >> "$HOME_TWO/.local/bin/screenlog"
BEFORE="$(/usr/bin/shasum -a 256 "$HOME_TWO/.local/bin/screenlog" | /usr/bin/awk '{print $1}')"
if install_into "$HOME_TWO" 2>/dev/null; then
  echo "error: modified authenticated installation was overwritten" >&2
  exit 1
fi
[[ "$BEFORE" == "$(/usr/bin/shasum -a 256 "$HOME_TWO/.local/bin/screenlog" | /usr/bin/awk '{print $1}')" ]]
uninstall_from "$HOME_TWO" 2>/dev/null
[[ -d "$HOME_TWO/Applications/Screenlogger.app" ]]
[[ -f "$HOME_TWO/.local/bin/screenlog" ]]
[[ "$(< "$HOME_TWO/Library/Application Support/dev.screenlog/keep.txt")" == "preserve data" ]]

# Unowned exact-name conflicts are preserved byte-for-byte.
HOME_THREE="$TEST_ROOT/conflict"
mkdir -p "$HOME_THREE/Applications/Screenlogger.app" "$HOME_THREE/.local/bin"
printf 'not our app' > "$HOME_THREE/Applications/Screenlogger.app/keep.txt"
printf 'not our command' > "$HOME_THREE/.local/bin/screenlog"
if install_into "$HOME_THREE" 2>/dev/null; then
  echo "error: unowned destination conflict was overwritten" >&2
  exit 1
fi
[[ "$(< "$HOME_THREE/Applications/Screenlogger.app/keep.txt")" == "not our app" ]]
[[ "$(< "$HOME_THREE/.local/bin/screenlog")" == "not our command" ]]

# Product-shaped files from an unshipped development build are still
# receiptless and must not be adopted or replaced.
HOME_RECEIPTLESS="$TEST_ROOT/receiptless-product"
mkdir -p "$HOME_RECEIPTLESS/Applications" "$HOME_RECEIPTLESS/.local/bin"
/usr/bin/ditto "$PRODUCTS/Screenlogger.app" "$HOME_RECEIPTLESS/Applications/Screenlogger.app"
/usr/bin/install -m 755 "$PRODUCTS/screenlog" "$HOME_RECEIPTLESS/.local/bin/screenlog"
/usr/bin/ditto "$PRODUCTS/ScreenlogCore.framework" "$HOME_RECEIPTLESS/.local/bin/ScreenlogCore.framework"
RECEIPTLESS_APP_BEFORE="$(/usr/bin/shasum -a 256 "$HOME_RECEIPTLESS/Applications/Screenlogger.app/Contents/MacOS/Screenlogger" | /usr/bin/awk '{print $1}')"
RECEIPTLESS_CLI_BEFORE="$(/usr/bin/shasum -a 256 "$HOME_RECEIPTLESS/.local/bin/screenlog" | /usr/bin/awk '{print $1}')"
if install_into "$HOME_RECEIPTLESS" 2>/dev/null; then
  echo "error: receiptless development artifacts were adopted" >&2
  exit 1
fi
[[ "$RECEIPTLESS_APP_BEFORE" == "$(/usr/bin/shasum -a 256 "$HOME_RECEIPTLESS/Applications/Screenlogger.app/Contents/MacOS/Screenlogger" | /usr/bin/awk '{print $1}')" ]]
[[ "$RECEIPTLESS_CLI_BEFORE" == "$(/usr/bin/shasum -a 256 "$HOME_RECEIPTLESS/.local/bin/screenlog" | /usr/bin/awk '{print $1}')" ]]
[[ ! -e "$HOME_RECEIPTLESS/Applications/.screenlogger-local-install.plist" ]]
[[ ! -e "$HOME_RECEIPTLESS/.local/bin/$SL_CLI_RECEIPT_NAME" ]]

# A changed receipt-backed skill remains
# preserved for review instead of being silently overwritten.
HOME_CHANGED_SKILL="$TEST_ROOT/changed-command-skill"
install_into "$HOME_CHANGED_SKILL"
printf '\nchanged outside Screenlogger\n' \
  >> "$HOME_CHANGED_SKILL/.local/bin/skill/$SL_CLI_SKILL_NAME/SKILL.md"
CHANGED_SKILL_BEFORE="$(/usr/bin/shasum -a 256 "$HOME_CHANGED_SKILL/.local/bin/skill/$SL_CLI_SKILL_NAME/SKILL.md" | /usr/bin/awk '{print $1}')"
if install_into "$HOME_CHANGED_SKILL" 2>/dev/null; then
  echo "error: modified Command Setup skill was overwritten" >&2
  exit 1
fi
[[ "$CHANGED_SKILL_BEFORE" == "$(/usr/bin/shasum -a 256 "$HOME_CHANGED_SKILL/.local/bin/skill/$SL_CLI_SKILL_NAME/SKILL.md" | /usr/bin/awk '{print $1}')" ]]

# A failure after publication starts restores the prior complete generation.
HOME_ROLLBACK="$TEST_ROOT/rollback"
mkdir -p "$HOME_ROLLBACK/Library/Application Support/dev.screenlog"
printf 'rollback data' > "$HOME_ROLLBACK/Library/Application Support/dev.screenlog/keep.txt"
install_into "$HOME_ROLLBACK"
APP_BEFORE="$(/usr/bin/shasum -a 256 "$HOME_ROLLBACK/Applications/Screenlogger.app/Contents/MacOS/Screenlogger" | /usr/bin/awk '{print $1}')"
CLI_BEFORE="$(/usr/bin/shasum -a 256 "$HOME_ROLLBACK/.local/bin/screenlog" | /usr/bin/awk '{print $1}')"
RECEIPT_BEFORE="$(/usr/bin/shasum -a 256 "$HOME_ROLLBACK/Applications/.screenlogger-local-install.plist" | /usr/bin/awk '{print $1}')"
CLI_RECEIPT_BEFORE="$(/usr/bin/shasum -a 256 "$HOME_ROLLBACK/.local/bin/$SL_CLI_RECEIPT_NAME" | /usr/bin/awk '{print $1}')"
CLI_SKILL_BEFORE="$(/usr/bin/shasum -a 256 "$HOME_ROLLBACK/.local/bin/skill/$SL_CLI_SKILL_NAME/SKILL.md" | /usr/bin/awk '{print $1}')"
if SCREENLOG_HOME="$HOME_ROLLBACK" \
  SCREENLOG_PREFIX="$HOME_ROLLBACK/Applications" \
  SCREENLOG_BIN="$HOME_ROLLBACK/.local/bin" \
  SCREENLOG_PRODUCTS="$PRODUCTS" \
  SCREENLOG_INSTALL_TEST_FAILURE_POINT="after-app" \
  "$ROOT/Scripts/install.sh" >/dev/null 2>&1; then
  echo "error: injected publication failure unexpectedly succeeded" >&2
  exit 1
fi
[[ "$APP_BEFORE" == "$(/usr/bin/shasum -a 256 "$HOME_ROLLBACK/Applications/Screenlogger.app/Contents/MacOS/Screenlogger" | /usr/bin/awk '{print $1}')" ]]
[[ "$CLI_BEFORE" == "$(/usr/bin/shasum -a 256 "$HOME_ROLLBACK/.local/bin/screenlog" | /usr/bin/awk '{print $1}')" ]]
[[ "$RECEIPT_BEFORE" == "$(/usr/bin/shasum -a 256 "$HOME_ROLLBACK/Applications/.screenlogger-local-install.plist" | /usr/bin/awk '{print $1}')" ]]
[[ "$CLI_RECEIPT_BEFORE" == "$(/usr/bin/shasum -a 256 "$HOME_ROLLBACK/.local/bin/$SL_CLI_RECEIPT_NAME" | /usr/bin/awk '{print $1}')" ]]
[[ "$CLI_SKILL_BEFORE" == "$(/usr/bin/shasum -a 256 "$HOME_ROLLBACK/.local/bin/skill/$SL_CLI_SKILL_NAME/SKILL.md" | /usr/bin/awk '{print $1}')" ]]
[[ "$(< "$HOME_ROLLBACK/Library/Application Support/dev.screenlog/keep.txt")" == "rollback data" ]]

# Data removal remains separately explicit.
HOME_FOUR="$TEST_ROOT/purge"
mkdir -p "$HOME_FOUR/Library/Application Support/dev.screenlog"
printf 'delete only when asked' > "$HOME_FOUR/Library/Application Support/dev.screenlog/data"
install_into "$HOME_FOUR"
uninstall_from "$HOME_FOUR" --purge-data
[[ ! -e "$HOME_FOUR/Library/Application Support/dev.screenlog" ]]

# An uninstall with no installation is a no-op and creates no install roots.
HOME_FIVE="$TEST_ROOT/missing"
mkdir -p "$HOME_FIVE"
uninstall_from "$HOME_FIVE"
[[ ! -e "$HOME_FIVE/Applications" ]]
[[ ! -e "$HOME_FIVE/.local" ]]

echo "install lifecycle smoke: passed"
