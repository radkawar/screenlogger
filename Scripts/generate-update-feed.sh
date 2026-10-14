#!/usr/bin/env bash
# Generate and verify Screenlogger's signed Sparkle appcast.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE=""
OUTPUT=""
RELEASE_TAG=""
SPARKLE_VERSION="2.9.5"
SPARKLE_ARCHIVE_SHA256="34b9b2071f3de0012eca3faa3a9290bb94e62131e9a74f6dc91514a000097a6c"
SPARKLE_ARCHIVE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip"

usage() {
  cat <<'USAGE'
Usage: Scripts/generate-update-feed.sh --archive DMG --output XML --tag TAG

The Sparkle private key is read from SPARKLE_ED_PRIVATE_KEY in CI. When that
variable is absent, the local Keychain account named screenlogger is used.
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
    --archive)
      require_value "$1" "${2:-}"
      ARCHIVE="$2"
      shift 2
      ;;
    --output)
      require_value "$1" "${2:-}"
      OUTPUT="$2"
      shift 2
      ;;
    --tag)
      require_value "$1" "${2:-}"
      RELEASE_TAG="$2"
      shift 2
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

if [[ -z "$ARCHIVE" || -z "$OUTPUT" || -z "$RELEASE_TAG" ]]; then
  usage >&2
  exit 2
fi
if [[ ! "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: tag must use vMAJOR.MINOR.PATCH" >&2
  exit 1
fi
if [[ "$ARCHIVE" != /* ]]; then
  ARCHIVE="$ROOT/$ARCHIVE"
fi
if [[ ! -f "$ARCHIVE" || -L "$ARCHIVE" || "$ARCHIVE" != *.dmg ]]; then
  echo "error: archive must be a regular DMG" >&2
  exit 1
fi
if [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$ROOT/$OUTPUT"
fi
if [[ "$OUTPUT" != *.xml || "$OUTPUT" == *$'\n'* ]]; then
  echo "error: output must be an XML path without newlines" >&2
  exit 1
fi

for command_name in codesign curl ditto hdiutil plutil shasum spctl xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: required tool is unavailable: $command_name" >&2
    exit 1
  fi
done

# Never turn engineering/ad-hoc output into a trusted update. Check the final
# stapled container before using the update signing key.
/usr/bin/codesign --verify --strict --verbose=2 "$ARCHIVE"
xcrun stapler validate "$ARCHIVE"
/usr/sbin/spctl --assess --type open --context context:primary-signature "$ARCHIVE"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/screenlogger-appcast.XXXXXX")"
MOUNT_POINT="$WORK_ROOT/mount"
MOUNTED=0
cleanup_update_feed() {
  if (( MOUNTED == 1 )); then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  /bin/rm -rf -- "$WORK_ROOT"
}
trap cleanup_update_feed EXIT INT TERM

mkdir -p "$MOUNT_POINT" "$WORK_ROOT/archives" "$WORK_ROOT/sparkle"
/usr/bin/hdiutil attach \
  -readonly \
  -noverify \
  -nobrowse \
  -owners off \
  -mountpoint "$MOUNT_POINT" \
  "$ARCHIVE" >/dev/null
MOUNTED=1

APP_INFO="$MOUNT_POINT/Screenlogger.app/Contents/Info.plist"
if [[ ! -f "$APP_INFO" ]]; then
  echo "error: DMG does not contain Screenlogger.app" >&2
  exit 1
fi
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP_INFO")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP_INFO")"
FEED_URL="$(/usr/bin/plutil -extract SUFeedURL raw -o - "$APP_INFO")"
PUBLIC_KEY="$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$APP_INFO")"
VERIFY_BEFORE_EXTRACTION="$(/usr/bin/plutil -extract SUVerifyUpdateBeforeExtraction raw -o - "$APP_INFO")"
REQUIRE_SIGNED_FEED="$(/usr/bin/plutil -extract SURequireSignedFeed raw -o - "$APP_INFO")"

if [[ "$RELEASE_TAG" != "v$VERSION" ]]; then
  echo "error: release tag $RELEASE_TAG does not match DMG version v$VERSION" >&2
  exit 1
fi
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "error: app build number is not an integer" >&2
  exit 1
fi
if [[ "$FEED_URL" != "https://radkawar.github.io/screenlogger/appcast.xml" ]]; then
  echo "error: app contains an unexpected update feed URL" >&2
  exit 1
fi
if [[ "$PUBLIC_KEY" != "Bjy/ZcViaUi1FZ3Cl5tahdNK9EOfa2k9sEtIE1Bg1ts=" ]]; then
  echo "error: app contains an unexpected update signing key" >&2
  exit 1
fi
if [[ "$VERIFY_BEFORE_EXTRACTION" != "true" || "$REQUIRE_SIGNED_FEED" != "true" ]]; then
  echo "error: app does not require signed pre-extraction update verification" >&2
  exit 1
fi

APP="$MOUNT_POINT/Screenlogger.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
APP_SIGNATURE_DETAILS="$(/usr/bin/codesign -dvvv "$APP" 2>&1)"
if ! /usr/bin/grep -q '^Authority=Developer ID Application:' <<<"$APP_SIGNATURE_DETAILS" \
  || ! /usr/bin/grep -q '^TeamIdentifier=3UX5N7Y8TY$' <<<"$APP_SIGNATURE_DETAILS"; then
  echo "error: update app must use Screenlogger's Developer ID team" >&2
  exit 1
fi
xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute "$APP"

/usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=0

SPARKLE_ARCHIVE="$WORK_ROOT/Sparkle.zip"
/usr/bin/curl --fail --location --silent --show-error \
  "$SPARKLE_ARCHIVE_URL" \
  --output "$SPARKLE_ARCHIVE"
ACTUAL_SPARKLE_SHA256="$(/usr/bin/shasum -a 256 "$SPARKLE_ARCHIVE" | /usr/bin/awk '{print $1}')"
if [[ "$ACTUAL_SPARKLE_SHA256" != "$SPARKLE_ARCHIVE_SHA256" ]]; then
  echo "error: Sparkle tool archive checksum mismatch" >&2
  exit 1
fi
/usr/bin/ditto -x -k "$SPARKLE_ARCHIVE" "$WORK_ROOT/sparkle"

GENERATE_APPCAST="$WORK_ROOT/sparkle/bin/generate_appcast"
SIGN_UPDATE="$WORK_ROOT/sparkle/bin/sign_update"
if [[ ! -x "$GENERATE_APPCAST" || ! -x "$SIGN_UPDATE" ]]; then
  echo "error: verified Sparkle archive is missing update tools" >&2
  exit 1
fi

ARCHIVE_NAME="$(basename "$ARCHIVE")"
/usr/bin/ditto "$ARCHIVE" "$WORK_ROOT/archives/$ARCHIVE_NAME"
mkdir -p "$(dirname "$OUTPUT")"

generate_with_keychain() {
  "$GENERATE_APPCAST" \
    --account screenlogger \
    --download-url-prefix "https://github.com/radkawar/screenlogger/releases/download/$RELEASE_TAG/" \
    --link "https://github.com/radkawar/screenlogger/releases/tag/$RELEASE_TAG" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    -o "$OUTPUT" \
    "$WORK_ROOT/archives"
  "$SIGN_UPDATE" --account screenlogger --verify "$OUTPUT"
}

generate_with_secret() {
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$GENERATE_APPCAST" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/radkawar/screenlogger/releases/download/$RELEASE_TAG/" \
    --link "https://github.com/radkawar/screenlogger/releases/tag/$RELEASE_TAG" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    -o "$OUTPUT" \
    "$WORK_ROOT/archives"
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" \
    --ed-key-file - \
    --verify \
    "$OUTPUT"
}

if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  generate_with_secret
else
  generate_with_keychain
fi

if ! /usr/bin/grep -Fq "sparkle:edSignature=" "$OUTPUT" \
  || ! /usr/bin/grep -Fq "<!-- sparkle-signatures:" "$OUTPUT" \
  || ! /usr/bin/grep -Fq "edSignature:" "$OUTPUT" \
  || ! /usr/bin/grep -Fq "<sparkle:version>$BUILD</sparkle:version>" "$OUTPUT" \
  || ! /usr/bin/grep -Fq "/releases/download/$RELEASE_TAG/$ARCHIVE_NAME" "$OUTPUT"; then
  echo "error: generated appcast is missing a required signature, build, or release URL" >&2
  exit 1
fi

echo "signed update feed verified"
echo "version: $VERSION ($BUILD)"
echo "feed: $OUTPUT"
