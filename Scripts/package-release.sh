#!/usr/bin/env bash
# Build, sign, validate, and package a universal Screenlogger release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT/build/releases"
PRODUCTS=""
EXPECTED_TAG=""
REPLACE=0
SIGNING_MODE="ad-hoc"
SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
SIGNING_TEAM_ID="${DEVELOPER_ID_TEAM_ID:-}"
NOTARY_PROFILE="${SCREENLOGGER_NOTARY_PROFILE:-}"
NOTARY_KEY_PATH="${SCREENLOGGER_NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${SCREENLOGGER_NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${SCREENLOGGER_NOTARY_ISSUER_ID:-}"

usage() {
  cat <<'USAGE'
Usage: Scripts/package-release.sh [options]

Options:
  --products DIR       Package existing universal Release products instead of building.
  --output DIR         Write release assets here (default: build/releases).
  --expected-tag TAG   Require TAG to equal v<app marketing version>.
  --signing MODE       Use ad-hoc or developer-id signing (default: ad-hoc).
  --identity NAME      Developer ID Application identity for production signing.
  --team-id ID         Require this Developer ID Team ID in every signature.
  --notary-profile ID  Use a local notarytool Keychain credential profile.
  --notary-key PATH    Use an App Store Connect API private key.
  --notary-key-id ID   App Store Connect API key ID.
  --notary-issuer ID   App Store Connect API issuer ID.
  --replace            Replace exact same-version assets already in the output directory.
  -h, --help           Show this help.

Developer ID mode signs every nested executable with Hardened Runtime and a
secure timestamp, notarizes and staples the app and DMG, and notarizes the
technical ZIP. Packaging never publishes or replaces an installed application.
USAGE
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
    --products)
      require_value "$1" "${2:-}"
      PRODUCTS="$2"
      shift 2
      ;;
    --output)
      require_value "$1" "${2:-}"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --expected-tag)
      require_value "$1" "${2:-}"
      EXPECTED_TAG="$2"
      shift 2
      ;;
    --signing)
      require_value "$1" "${2:-}"
      SIGNING_MODE="$2"
      shift 2
      ;;
    --identity)
      require_value "$1" "${2:-}"
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --team-id)
      require_value "$1" "${2:-}"
      SIGNING_TEAM_ID="$2"
      shift 2
      ;;
    --notary-profile)
      require_value "$1" "${2:-}"
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --notary-key)
      require_value "$1" "${2:-}"
      NOTARY_KEY_PATH="$2"
      shift 2
      ;;
    --notary-key-id)
      require_value "$1" "${2:-}"
      NOTARY_KEY_ID="$2"
      shift 2
      ;;
    --notary-issuer)
      require_value "$1" "${2:-}"
      NOTARY_ISSUER_ID="$2"
      shift 2
      ;;
    --replace)
      REPLACE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$SIGNING_MODE" != "ad-hoc" && "$SIGNING_MODE" != "developer-id" ]]; then
  echo "error: --signing must be ad-hoc or developer-id" >&2
  exit 2
fi
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "error: Developer ID mode requires --identity" >&2
    exit 2
  fi
  if [[ -n "$NOTARY_PROFILE" ]]; then
    if [[ -n "$NOTARY_KEY_PATH" || -n "$NOTARY_KEY_ID" || -n "$NOTARY_ISSUER_ID" ]]; then
      echo "error: choose a notary Keychain profile or API key authentication" >&2
      exit 2
    fi
  elif [[ -z "$NOTARY_KEY_PATH" || -z "$NOTARY_KEY_ID" || -z "$NOTARY_ISSUER_ID" ]]; then
    echo "error: Developer ID mode requires complete notarytool authentication" >&2
    exit 2
  fi
fi

if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$ROOT/$OUTPUT_DIR"
fi
if [[ "$OUTPUT_DIR" == "/" || "$OUTPUT_DIR" == *$'\n'* ]]; then
  echo "error: output directory must be a non-root path without newlines" >&2
  exit 1
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if [[ -z "${DEVELOPER_DIR:-}" || ! -d "$DEVELOPER_DIR" ]]; then
  echo "error: a complete Xcode installation is required" >&2
  exit 1
fi

required_commands=(codesign ditto find hdiutil lipo otool plutil shasum stat xcodebuild)
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  required_commands+=(security spctl xcrun)
fi
for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: required tool is unavailable: $command_name" >&2
    exit 1
  fi
done

SOURCE_EPOCH="${SOURCE_DATE_EPOCH:-}"
if [[ -z "$SOURCE_EPOCH" ]] && command -v git >/dev/null 2>&1; then
  SOURCE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || true)"
fi
if [[ ! "$SOURCE_EPOCH" =~ ^[0-9]+$ ]]; then
  echo "error: SOURCE_DATE_EPOCH must be an integer (or package from a Git checkout)" >&2
  exit 1
fi
export SOURCE_DATE_EPOCH="$SOURCE_EPOCH"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/screenlogger-package.XXXXXX")"
DMG_VERIFY_MOUNT=""
cleanup_package_work() {
  if [[ -n "$DMG_VERIFY_MOUNT" ]]; then
    /usr/bin/hdiutil detach "$DMG_VERIFY_MOUNT" -force >/dev/null 2>&1 || true
  fi
  rm -rf -- "$WORK_ROOT"
}
trap cleanup_package_work EXIT INT TERM

if [[ -z "$PRODUCTS" ]]; then
  "$ROOT/Scripts/check-repository.sh"
  "$ROOT/Scripts/check-source-safety.sh"
  "$ROOT/Scripts/xcodegen.sh" generate

  DERIVED_DATA="$WORK_ROOT/DerivedData"
  xcodebuild \
    -project "$ROOT/Screenlog.xcodeproj" \
    -scheme Screenlog \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build
  PRODUCTS="$DERIVED_DATA/Build/Products/Release"
elif [[ "$PRODUCTS" != /* ]]; then
  PRODUCTS="$ROOT/$PRODUCTS"
fi

if [[ ! -d "$PRODUCTS" ]]; then
  echo "error: Release products directory not found: $PRODUCTS" >&2
  exit 1
fi
PRODUCTS="$(cd "$PRODUCTS" && pwd -P)"

VERSION_VERIFICATION_ARGS=(--products "$PRODUCTS")
if [[ -n "$EXPECTED_TAG" ]]; then
  VERSION_VERIFICATION_ARGS+=(--tag "$EXPECTED_TAG")
fi
"$ROOT/Scripts/verify-version.sh" "${VERSION_VERIFICATION_ARGS[@]}"
"$ROOT/Scripts/test-release-verification.sh" "$PRODUCTS"

APP="$PRODUCTS/Screenlogger.app"
CLI="$PRODUCTS/screenlog"
FRAMEWORK="$APP/Contents/Frameworks/ScreenlogCore.framework"
APP_PLIST="$APP/Contents/Info.plist"
SEMANTIC_WORKER="$APP/Contents/MacOS/screenlog-semantic-worker"
for required_path in "$APP" "$CLI" "$FRAMEWORK" "$APP_PLIST" "$SEMANTIC_WORKER"; do
  if [[ ! -e "$required_path" ]]; then
    echo "error: required Release product is missing: $required_path" >&2
    exit 1
  fi
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST")"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PLIST")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: app marketing version is not release-safe: $VERSION" >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "error: app build number is not a positive integer: $BUILD_NUMBER" >&2
  exit 1
fi
if [[ -n "$EXPECTED_TAG" && "$EXPECTED_TAG" != "v$VERSION" ]]; then
  echo "error: release tag $EXPECTED_TAG does not match app version v$VERSION" >&2
  exit 1
fi

# Make repeated packaging of the same verified products stable. Build UUIDs are
# intentionally preserved; this only normalizes archive metadata to the tagged
# source commit rather than the machine's build time.
ARCHIVE_TIMESTAMP="$(/bin/date -r "$SOURCE_EPOCH" '+%Y%m%d%H%M.%S')"
normalize_tree_timestamps() {
  local tree="$1"
  /usr/bin/find -s "$tree" -depth -exec /usr/bin/touch -h -t "$ARCHIVE_TIMESTAMP" {} +
}

notarize_artifact() {
  SCREENLOGGER_NOTARY_PROFILE="$NOTARY_PROFILE" \
    SCREENLOGGER_NOTARY_KEY_PATH="$NOTARY_KEY_PATH" \
    SCREENLOGGER_NOTARY_KEY_ID="$NOTARY_KEY_ID" \
    SCREENLOGGER_NOTARY_ISSUER_ID="$NOTARY_ISSUER_ID" \
    "$ROOT/Scripts/notarize-release-artifact.sh" "$1"
}

PACKAGE_NAME="Screenlogger-v$VERSION-macos-universal"
STAGE="$WORK_ROOT/$PACKAGE_NAME"
mkdir -p "$STAGE/CLI/skill"
/usr/bin/ditto "$APP" "$STAGE/Screenlogger.app"
/usr/bin/install -m 755 "$CLI" "$STAGE/CLI/screenlog"
/usr/bin/ditto "$FRAMEWORK" "$STAGE/CLI/ScreenlogCore.framework"
/usr/bin/ditto \
  "$ROOT/Resources/skill/screenlog-cli-skill" \
  "$STAGE/CLI/skill/screenlog-cli-skill"
/usr/bin/install -m 644 "$ROOT/Packaging/INSTALL.md" "$STAGE/INSTALL.md"
/usr/bin/install -m 644 "$ROOT/LICENSE" "$STAGE/LICENSE"
/usr/bin/install -m 644 "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/THIRD_PARTY_NOTICES.md"

# Xcode's CODE_SIGNING_ALLOWED=NO build leaves linker-generated placeholder
# signatures. Replace them inside-out in the disposable release stage.
RELEASE_CHECK_MODE=(--ad-hoc)
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  SIGNING_ARGUMENTS=(--identity "$SIGNING_IDENTITY")
  if [[ -n "$SIGNING_TEAM_ID" ]]; then
    SIGNING_ARGUMENTS+=(--team-id "$SIGNING_TEAM_ID")
  fi
  "$ROOT/Scripts/sign-release-developer-id.sh" \
    "${SIGNING_ARGUMENTS[@]}" \
    "$STAGE/Screenlogger.app" \
    "$STAGE/CLI/screenlog"
  RELEASE_CHECK_MODE=(--developer-id)
else
  "$ROOT/Scripts/sign-release-adhoc.sh" \
    "$STAGE/Screenlogger.app" \
    "$STAGE/CLI/screenlog"
fi

"$ROOT/Scripts/check-release.sh" "${RELEASE_CHECK_MODE[@]}" \
  "$STAGE/Screenlogger.app" \
  "$STAGE/CLI/screenlog"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  # Staple the app itself before placing it in either distribution container.
  # This preserves offline Gatekeeper validation after a user copies it out.
  APP_NOTARY_ARCHIVE="$WORK_ROOT/Screenlogger-v$VERSION-notary.zip"
  /usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
    "$STAGE/Screenlogger.app" "$APP_NOTARY_ARCHIVE"
  notarize_artifact "$APP_NOTARY_ARCHIVE"
  xcrun stapler staple "$STAGE/Screenlogger.app"
  xcrun stapler validate "$STAGE/Screenlogger.app"
  RELEASE_CHECK_MODE=(--signing)
  "$ROOT/Scripts/check-release.sh" "${RELEASE_CHECK_MODE[@]}" \
    "$STAGE/Screenlogger.app" \
    "$STAGE/CLI/screenlog"
fi

sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

PACKAGE_MANIFEST_PLIST="$WORK_ROOT/package-manifest.plist"
/usr/bin/plutil -create xml1 "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert schemaVersion -integer 2 "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert product -string Screenlogger "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert version -string "$VERSION" "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert build -string "$BUILD_NUMBER" "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert minimumMacOS -string "$MINIMUM_MACOS" "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert architectures -json '["arm64","x86_64"]' "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert semanticArchitectures -json '["arm64"]' "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert signing -string "$SIGNING_MODE" "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert notarized -bool "$([[ "$SIGNING_MODE" == "developer-id" ]] && echo true || echo false)" \
  "$PACKAGE_MANIFEST_PLIST"
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  PACKAGE_TEAM_ID="$(
    /usr/bin/codesign -dvvv "$STAGE/Screenlogger.app" 2>&1 \
      | /usr/bin/awk -F= '/^TeamIdentifier=/{team_id=$2} END{print team_id}'
  )"
  /usr/bin/plutil -insert teamID -string "$PACKAGE_TEAM_ID" "$PACKAGE_MANIFEST_PLIST"
fi
/usr/bin/plutil -insert sourceDateEpoch -integer "$SOURCE_EPOCH" "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert appExecutableSHA256 -string \
  "$(sha256 "$STAGE/Screenlogger.app/Contents/MacOS/Screenlogger")" \
  "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert bundledCLISHA256 -string \
  "$(sha256 "$STAGE/Screenlogger.app/Contents/MacOS/screenlog")" \
  "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert semanticWorkerSHA256 -string \
  "$(sha256 "$STAGE/Screenlogger.app/Contents/MacOS/screenlog-semantic-worker")" \
  "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert standaloneCLISHA256 -string \
  "$(sha256 "$STAGE/CLI/screenlog")" \
  "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -insert assistantSkillSHA256 -string \
  "$(sha256 "$STAGE/CLI/skill/screenlog-cli-skill/SKILL.md")" \
  "$PACKAGE_MANIFEST_PLIST"
/usr/bin/plutil -convert json -o "$STAGE/package-manifest.json" "$PACKAGE_MANIFEST_PLIST"

unset DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
  DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH || true
if [[ "$("$STAGE/CLI/screenlog" --version)" != "$VERSION" ]]; then
  echo "error: staged CLI version does not match app version $VERSION" >&2
  exit 1
fi

# Reuse the existing destructive-lifecycle regression only inside a disposable
# product tree assembled from the exact staged bytes.
LIFECYCLE_PRODUCTS="$WORK_ROOT/lifecycle-products"
mkdir -p "$LIFECYCLE_PRODUCTS"
/usr/bin/ditto "$STAGE/Screenlogger.app" "$LIFECYCLE_PRODUCTS/Screenlogger.app"
/usr/bin/install -m 755 "$STAGE/CLI/screenlog" "$LIFECYCLE_PRODUCTS/screenlog"
/usr/bin/ditto \
  "$STAGE/CLI/ScreenlogCore.framework" \
  "$LIFECYCLE_PRODUCTS/ScreenlogCore.framework"
"$ROOT/Scripts/test-install-lifecycle.sh" "$LIFECYCLE_PRODUCTS"

ARCHIVE_TMP="$WORK_ROOT/$PACKAGE_NAME.zip"
# Validation reads update access times on common macOS volumes. Normalize at
# the last possible moment because ditto records both access and modification
# timestamps in its ZIP metadata.
normalize_tree_timestamps "$STAGE"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
  "$STAGE" "$ARCHIVE_TMP"

# Validate the extracted archive, not only the pre-archive staging directory.
EXTRACT_ROOT="$WORK_ROOT/extracted"
mkdir -p "$EXTRACT_ROOT"
/usr/bin/ditto -x -k "$ARCHIVE_TMP" "$EXTRACT_ROOT"
EXTRACTED="$EXTRACT_ROOT/$PACKAGE_NAME"
"$ROOT/Scripts/check-release.sh" "${RELEASE_CHECK_MODE[@]}" \
  "$EXTRACTED/Screenlogger.app" \
  "$EXTRACTED/CLI/screenlog"
if [[ "$("$EXTRACTED/CLI/screenlog" --version)" != "$VERSION" ]]; then
  echo "error: extracted CLI version does not match app version $VERSION" >&2
  exit 1
fi

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  # ZIPs cannot carry a stapled container ticket. Submitting the complete
  # technical archive gives its standalone CLI and framework online tickets.
  notarize_artifact "$ARCHIVE_TMP"
fi

ARCHIVE_SHA256="$(sha256 "$ARCHIVE_TMP")"
ARCHIVE_SIZE="$(/usr/bin/stat -f '%z' "$ARCHIVE_TMP")"
ARCHIVE_CHECKSUM_TMP="$WORK_ROOT/$PACKAGE_NAME.zip.sha256"
printf '%s  %s\n' "$ARCHIVE_SHA256" "$PACKAGE_NAME.zip" > "$ARCHIVE_CHECKSUM_TMP"

# The ZIP remains a complete technical archive. The DMG is the primary macOS
# installation surface and contains the exact same verified app bytes.
DMG_TMP="$WORK_ROOT/$PACKAGE_NAME.dmg"
"$ROOT/Scripts/create-dmg.sh" \
  --app "$STAGE/Screenlogger.app" \
  --output "$DMG_TMP" \
  --volume-name "Screenlogger $VERSION"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  /usr/bin/codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --timestamp \
    "$DMG_TMP"
  /usr/bin/codesign --verify --strict --verbose=2 "$DMG_TMP"
  notarize_artifact "$DMG_TMP"
  xcrun stapler staple "$DMG_TMP"
  xcrun stapler validate "$DMG_TMP"
  /usr/bin/codesign --verify --strict --verbose=2 "$DMG_TMP"
  if ! spctl --assess --type open --context context:primary-signature \
    --verbose=4 "$DMG_TMP" >/dev/null 2>&1; then
    echo "error: Gatekeeper rejected the notarized DMG" >&2
    exit 1
  fi
fi

DMG_VERIFY_MOUNT="$WORK_ROOT/dmg-verify"
mkdir -p "$DMG_VERIFY_MOUNT"
/usr/bin/hdiutil attach \
  -readonly \
  -noverify \
  -nobrowse \
  -owners off \
  -mountpoint "$DMG_VERIFY_MOUNT" \
  "$DMG_TMP" >/dev/null
"$ROOT/Scripts/check-release.sh" "${RELEASE_CHECK_MODE[@]}" \
  "$DMG_VERIFY_MOUNT/Screenlogger.app" \
  "$EXTRACTED/CLI/screenlog"
if [[ "$(sha256 "$DMG_VERIFY_MOUNT/Screenlogger.app/Contents/MacOS/Screenlogger")" \
  != "$(sha256 "$STAGE/Screenlogger.app/Contents/MacOS/Screenlogger")" ]]; then
  echo "error: disk image app executable does not match the verified staged app" >&2
  exit 1
fi
/usr/bin/hdiutil detach "$DMG_VERIFY_MOUNT" >/dev/null
DMG_VERIFY_MOUNT=""

DMG_SHA256="$(sha256 "$DMG_TMP")"
DMG_SIZE="$(/usr/bin/stat -f '%z' "$DMG_TMP")"
DMG_CHECKSUM_TMP="$WORK_ROOT/$PACKAGE_NAME.dmg.sha256"
printf '%s  %s\n' "$DMG_SHA256" "$PACKAGE_NAME.dmg" > "$DMG_CHECKSUM_TMP"

RELEASE_MANIFEST_PLIST="$WORK_ROOT/release-manifest.plist"
RELEASE_MANIFEST_TMP="$WORK_ROOT/$PACKAGE_NAME.json"
/usr/bin/plutil -create xml1 "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert schemaVersion -integer 3 "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert product -string Screenlogger "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert version -string "$VERSION" "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert build -string "$BUILD_NUMBER" "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert minimumMacOS -string "$MINIMUM_MACOS" "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert architectures -json '["arm64","x86_64"]' "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert semanticArchitectures -json '["arm64"]' "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert signing -string "$SIGNING_MODE" "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert notarized -bool "$([[ "$SIGNING_MODE" == "developer-id" ]] && echo true || echo false)" \
  "$RELEASE_MANIFEST_PLIST"
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  /usr/bin/plutil -insert teamID -string "$PACKAGE_TEAM_ID" "$RELEASE_MANIFEST_PLIST"
fi
/usr/bin/plutil -insert sourceDateEpoch -integer "$SOURCE_EPOCH" "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert assetName -string "$PACKAGE_NAME.dmg" "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert assetBytes -integer "$DMG_SIZE" "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert assetSHA256 -string "$DMG_SHA256" "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert archiveName -string "$PACKAGE_NAME.zip" "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert archiveBytes -integer "$ARCHIVE_SIZE" "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert archiveSHA256 -string "$ARCHIVE_SHA256" "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -insert packageManifestSHA256 -string \
  "$(sha256 "$STAGE/package-manifest.json")" \
  "$RELEASE_MANIFEST_PLIST"
/usr/bin/plutil -convert json -o "$RELEASE_MANIFEST_TMP" "$RELEASE_MANIFEST_PLIST"

DSYM_ARCHIVE_TMP=""
DSYM_STAGE="$WORK_ROOT/$PACKAGE_NAME-dSYMs"
for dsym_name in \
  Screenlogger.app.dSYM \
  screenlog.dSYM \
  screenlog-semantic-worker.dSYM \
  ScreenlogCore.framework.dSYM; do
  if [[ -d "$PRODUCTS/$dsym_name" ]]; then
    mkdir -p "$DSYM_STAGE"
    /usr/bin/ditto "$PRODUCTS/$dsym_name" "$DSYM_STAGE/$dsym_name"
  fi
done
if [[ -d "$DSYM_STAGE" ]]; then
  normalize_tree_timestamps "$DSYM_STAGE"
  DSYM_ARCHIVE_TMP="$WORK_ROOT/$PACKAGE_NAME-dSYMs.zip"
  /usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
    "$DSYM_STAGE" "$DSYM_ARCHIVE_TMP"
fi

OUTPUTS=(
  "$OUTPUT_DIR/$PACKAGE_NAME.dmg"
  "$OUTPUT_DIR/$PACKAGE_NAME.dmg.sha256"
  "$OUTPUT_DIR/$PACKAGE_NAME.zip"
  "$OUTPUT_DIR/$PACKAGE_NAME.zip.sha256"
  "$OUTPUT_DIR/$PACKAGE_NAME.json"
)
if [[ -n "$DSYM_ARCHIVE_TMP" ]]; then
  OUTPUTS+=("$OUTPUT_DIR/$PACKAGE_NAME-dSYMs.zip")
fi
if (( REPLACE == 0 )); then
  for output_path in "${OUTPUTS[@]}"; do
    if [[ -e "$output_path" ]]; then
      echo "error: release asset already exists (use --replace deliberately): $output_path" >&2
      exit 1
    fi
  done
fi

/bin/mv -f "$DMG_TMP" "$OUTPUT_DIR/$PACKAGE_NAME.dmg"
/bin/mv -f "$DMG_CHECKSUM_TMP" "$OUTPUT_DIR/$PACKAGE_NAME.dmg.sha256"
/bin/mv -f "$ARCHIVE_TMP" "$OUTPUT_DIR/$PACKAGE_NAME.zip"
/bin/mv -f "$ARCHIVE_CHECKSUM_TMP" "$OUTPUT_DIR/$PACKAGE_NAME.zip.sha256"
/bin/mv -f "$RELEASE_MANIFEST_TMP" "$OUTPUT_DIR/$PACKAGE_NAME.json"
if [[ -n "$DSYM_ARCHIVE_TMP" ]]; then
  /bin/mv -f "$DSYM_ARCHIVE_TMP" "$OUTPUT_DIR/$PACKAGE_NAME-dSYMs.zip"
fi

echo "release package verified"
echo "version: $VERSION ($BUILD_NUMBER)"
echo "signing: $SIGNING_MODE"
echo "installer: $OUTPUT_DIR/$PACKAGE_NAME.dmg"
echo "installer sha256: $DMG_SHA256"
echo "archive: $OUTPUT_DIR/$PACKAGE_NAME.zip"
echo "archive sha256: $ARCHIVE_SHA256"
echo "manifest: $OUTPUT_DIR/$PACKAGE_NAME.json"
if [[ -n "$DSYM_ARCHIVE_TMP" ]]; then
  echo "symbols: $OUTPUT_DIR/$PACKAGE_NAME-dSYMs.zip"
fi
