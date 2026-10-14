#!/usr/bin/env bash
# Apply complete Developer ID signatures to staged release artifacts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/Config/Screenlog.entitlements"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
EXPECTED_TEAM_ID="${DEVELOPER_ID_TEAM_ID:-}"
POSITIONAL=()

usage() {
  cat <<EOF
Usage: $0 [--identity NAME_OR_SHA1] [--team-id ID] Screenlogger.app screenlog

Signs Sparkle's helpers, the app's embedded framework and CLI, the outer app,
and the standalone CLI/framework pair with Developer ID Application. Every
Mach-O signature uses a secure timestamp and Hardened Runtime.
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    echo "error: $option requires a value" >&2
    exit 2
  fi
}

while (( $# > 0 )); do
  case "$1" in
    --identity)
      require_value "$1" "${2:-}"
      IDENTITY="$2"
      shift 2
      ;;
    --team-id)
      require_value "$1" "${2:-}"
      EXPECTED_TEAM_ID="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while (( $# > 0 )); do
        POSITIONAL+=("$1")
        shift
      done
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ -z "$IDENTITY" ]]; then
  echo "error: pass --identity or set DEVELOPER_ID_APPLICATION" >&2
  exit 2
fi
if (( ${#POSITIONAL[@]} != 2 )); then
  usage >&2
  exit 2
fi

APP="${POSITIONAL[0]}"
CLI="${POSITIONAL[1]}"
CLI_DIRECTORY="$(dirname "$CLI")"
APP_FRAMEWORK="$APP/Contents/Frameworks/ScreenlogCore.framework"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/Current"
SPARKLE_UPDATER="$SPARKLE_VERSION/Updater.app"
SPARKLE_DOWNLOADER="$SPARKLE_VERSION/XPCServices/Downloader.xpc"
SPARKLE_INSTALLER="$SPARKLE_VERSION/XPCServices/Installer.xpc"
SPARKLE_AUTOUPDATE="$SPARKLE_VERSION/Autoupdate"
BUNDLED_CLI="$APP/Contents/MacOS/screenlog"
SEMANTIC_WORKER="$APP/Contents/MacOS/screenlog-semantic-worker"
CLI_FRAMEWORK="$CLI_DIRECTORY/ScreenlogCore.framework"
DEVELOPMENT_DYLIB="$APP/Contents/MacOS/Screenlogger.debug.dylib"
PREVIEW_DYLIB="$APP/Contents/MacOS/__preview.dylib"

if ! command -v codesign >/dev/null 2>&1; then
  echo "error: required signing tool is unavailable: codesign" >&2
  exit 1
fi
IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)"
IDENTITY_MATCH="\"$IDENTITY\""
if [[ "$IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
  IDENTITY_MATCH=" $IDENTITY \"Developer ID Application:"
fi
if ! printf '%s\n' "$IDENTITIES" | /usr/bin/grep -Fiq "$IDENTITY_MATCH"; then
  echo "error: Developer ID signing identity is unavailable: $IDENTITY" >&2
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
require_directory "$SPARKLE_UPDATER" "Sparkle updater"
require_directory "$SPARKLE_DOWNLOADER" "Sparkle downloader service"
require_directory "$SPARKLE_INSTALLER" "Sparkle installer service"
require_executable "$SPARKLE_AUTOUPDATE" "Sparkle autoupdate tool"
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
    --sign "$IDENTITY" \
    --timestamp \
    --options runtime \
    --identifier "$identifier" \
    "$path"
}

sign_sparkle_artifact() {
  local path="$1"
  local identifier="$2"
  # Sparkle's helpers require their upstream identifiers and entitlements, but
  # must share the host app's Developer ID team for their XPC policy checks.
  /usr/bin/codesign \
    --force \
    --sign "$IDENTITY" \
    --timestamp \
    --options runtime \
    --identifier "$identifier" \
    --preserve-metadata=entitlements \
    "$path"
}

# Sign all nested code before the bundle that seals it.
sign_sparkle_artifact "$SPARKLE_UPDATER" \
  "org.sparkle-project.Sparkle.Updater"
sign_sparkle_artifact "$SPARKLE_DOWNLOADER" \
  "org.sparkle-project.DownloaderService"
sign_sparkle_artifact "$SPARKLE_INSTALLER" \
  "org.sparkle-project.InstallerLauncher"
sign_sparkle_artifact "$SPARKLE_AUTOUPDATE" \
  "org.sparkle-project.Sparkle.Autoupdate"
sign_sparkle_artifact "$SPARKLE_VERSION" \
  "org.sparkle-project.Sparkle"
sign_artifact "$APP_FRAMEWORK" "dev.screenlog.core"
sign_artifact "$BUNDLED_CLI" "dev.screenlog.cli"
sign_artifact "$SEMANTIC_WORKER" "dev.screenlog.semantic-worker"
# Debug builds use install-name indirection through these two dylibs. They are
# absent from release archives, but signing them when present keeps a locally
# staged Developer ID build launchable under library validation.
if [[ -f "$DEVELOPMENT_DYLIB" && ! -L "$DEVELOPMENT_DYLIB" ]]; then
  sign_artifact "$DEVELOPMENT_DYLIB" "dev.screenlog.app.debug"
fi
if [[ -f "$PREVIEW_DYLIB" && ! -L "$PREVIEW_DYLIB" ]]; then
  sign_artifact "$PREVIEW_DYLIB" "dev.screenlog.app.preview"
fi
/usr/bin/codesign \
  --force \
  --sign "$IDENTITY" \
  --timestamp \
  --options runtime \
  --identifier "dev.screenlog.app" \
  --entitlements "$ENTITLEMENTS" \
  --generate-entitlement-der \
  "$APP"

# The technical archive also contains an independently usable CLI pair.
sign_artifact "$CLI_FRAMEWORK" "dev.screenlog.core"
sign_artifact "$CLI" "dev.screenlog.cli"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$CLI_FRAMEWORK"
/usr/bin/codesign --verify --strict --verbose=2 "$CLI"

team_id_for() {
  /usr/bin/codesign -dvvv "$1" 2>&1 \
    | /usr/bin/awk -F= '/^TeamIdentifier=/{team_id=$2} END{print team_id}'
}

APP_TEAM_ID="$(team_id_for "$APP")"
if [[ -z "$APP_TEAM_ID" || "$APP_TEAM_ID" == "not set" ]]; then
  echo "error: Developer ID signature did not provide a Team ID" >&2
  exit 1
fi
if [[ -n "$EXPECTED_TEAM_ID" && "$APP_TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
  echo "error: signed Team ID $APP_TEAM_ID does not match expected $EXPECTED_TEAM_ID" >&2
  exit 1
fi

for artifact in \
  "$SPARKLE_UPDATER" \
  "$SPARKLE_DOWNLOADER" \
  "$SPARKLE_INSTALLER" \
  "$SPARKLE_AUTOUPDATE" \
  "$SPARKLE_VERSION" \
  "$APP_FRAMEWORK" \
  "$BUNDLED_CLI" \
  "$SEMANTIC_WORKER" \
  "$CLI_FRAMEWORK" \
  "$CLI"; do
  artifact_team_id="$(team_id_for "$artifact")"
  if [[ "$artifact_team_id" != "$APP_TEAM_ID" ]]; then
    echo "error: nested signature Team ID mismatch: $artifact" >&2
    exit 1
  fi
done

for artifact in "$DEVELOPMENT_DYLIB" "$PREVIEW_DYLIB"; do
  [[ -f "$artifact" && ! -L "$artifact" ]] || continue
  artifact_team_id="$(team_id_for "$artifact")"
  if [[ "$artifact_team_id" != "$APP_TEAM_ID" ]]; then
    echo "error: nested signature Team ID mismatch: $artifact" >&2
    exit 1
  fi
done

echo "complete Developer ID release signatures applied for Team ID $APP_TEAM_ID"
