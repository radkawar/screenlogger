#!/usr/bin/env bash
# Verify an existing Screenlogger release layout without modifying it.
#
# Default mode remains the historical Developer ID/notarization check. Release
# automation uses --ad-hoc to verify its complete local signatures explicitly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_PRODUCTS="$ROOT/build/DerivedData/Build/Products/Release"
MODE="signing"
POSITIONAL=()
FAILURES=0

usage() {
  cat <<EOF
Usage: $0 [--structure|--ad-hoc|--developer-id|--signing] [Screenlogger.app] [screenlog]

Modes:
  --structure  Verify release structure, identity, resources,
               versions, universal architectures, linkage, and CLI launch.
  --ad-hoc     Run --structure, then require complete ad-hoc signatures with
               stable identifiers, bound bundle metadata, sealed resources,
               and consistent universal slices.
  --developer-id
               Run --structure, then require complete Developer ID signatures,
               secure timestamps, Hardened Runtime, and one consistent Team ID.
  --signing    Run --developer-id, then require Gatekeeper acceptance and a
               stapled notarization ticket on the app.

With no mode, --signing is used for compatibility with earlier invocations.
The standalone CLI must have ScreenlogCore.framework and skill/ beside it.
EOF
}

fail() {
  echo "error: $*" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "ok: $*"
}

usage_error() {
  echo "error: $*" >&2
  usage >&2
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --structure|--structural|--unsigned)
      MODE="structure"
      ;;
    --ad-hoc|--adhoc)
      MODE="ad-hoc"
      ;;
    --developer-id|--developerid)
      MODE="developer-id"
      ;;
    --signing|--signed|--strict)
      MODE="signing"
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
      usage_error "unknown option: $1"
      ;;
    *)
      POSITIONAL+=("$1")
      ;;
  esac
  shift
done

if (( ${#POSITIONAL[@]} > 2 )); then
  usage_error "expected at most an app path and a CLI path"
fi

APP_PATH="${POSITIONAL[0]:-$DEFAULT_PRODUCTS/Screenlogger.app}"
if (( ${#POSITIONAL[@]} >= 2 )); then
  CLI_PATH="${POSITIONAL[1]}"
elif (( ${#POSITIONAL[@]} == 1 )); then
  CLI_PATH="$(dirname "$APP_PATH")/screenlog"
else
  CLI_PATH="$DEFAULT_PRODUCTS/screenlog"
fi

CLI_DIRECTORY="$(dirname "$CLI_PATH")"
CLI_FRAMEWORK="$CLI_DIRECTORY/ScreenlogCore.framework"
STANDALONE_SKILL="$CLI_DIRECTORY/skill/screenlog-cli-skill/SKILL.md"
APP_INFO="$APP_PATH/Contents/Info.plist"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Screenlogger"
BUNDLED_CLI="$APP_PATH/Contents/MacOS/screenlog"
APP_FRAMEWORK="$APP_PATH/Contents/Frameworks/ScreenlogCore.framework"
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/Current"
SPARKLE_INFO="$SPARKLE_VERSION/Resources/Info.plist"
SPARKLE_EXECUTABLE="$SPARKLE_VERSION/Sparkle"
SPARKLE_AUTOUPDATE="$SPARKLE_VERSION/Autoupdate"
SPARKLE_UPDATER="$SPARKLE_VERSION/Updater.app"
SPARKLE_DOWNLOADER="$SPARKLE_VERSION/XPCServices/Downloader.xpc"
SPARKLE_INSTALLER="$SPARKLE_VERSION/XPCServices/Installer.xpc"
SPARKLE_UPDATER_EXECUTABLE="$SPARKLE_UPDATER/Contents/MacOS/Updater"
SPARKLE_DOWNLOADER_EXECUTABLE="$SPARKLE_DOWNLOADER/Contents/MacOS/Downloader"
SPARKLE_INSTALLER_EXECUTABLE="$SPARKLE_INSTALLER/Contents/MacOS/Installer"
APP_FRAMEWORK_EXECUTABLE="$APP_FRAMEWORK/Versions/A/ScreenlogCore"
CLI_FRAMEWORK_EXECUTABLE="$CLI_FRAMEWORK/Versions/A/ScreenlogCore"
APP_FRAMEWORK_INFO="$APP_FRAMEWORK/Versions/A/Resources/Info.plist"
CLI_FRAMEWORK_INFO="$CLI_FRAMEWORK/Versions/A/Resources/Info.plist"

required_structure_commands=(awk cmp ditto env grep lipo mktemp otool plutil shasum tail)
for command_name in "${required_structure_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "required structural verification tool is unavailable: $command_name"
  fi
done

require_directory() {
  local path="$1"
  local label="$2"
  if [[ ! -d "$path" || -L "$path" ]]; then
    fail "$label is missing, linked, or not a directory: $path"
    return 1
  fi
  return 0
}

require_regular_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" || -L "$path" ]]; then
    fail "$label is missing, linked, or not a regular file: $path"
    return 1
  fi
  return 0
}

require_executable() {
  local path="$1"
  local label="$2"
  if ! require_regular_file "$path" "$label"; then
    return 1
  fi
  if [[ ! -x "$path" ]]; then
    fail "$label is not executable: $path"
    return 1
  fi
  pass "$label is a regular executable"
  return 0
}

plist_value() {
  local plist="$1"
  local key="$2"
  plutil -extract "$key" raw -o - "$plist" 2>/dev/null
}

check_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual="$(plist_value "$plist" "$key" || true)"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected '$expected', found '${actual:-missing}')"
  fi
}

check_universal_binary() {
  local binary="$1"
  local label="$2"
  local architectures
  local architecture_count
  architectures="$(lipo -archs "$binary" 2>/dev/null || true)"
  architecture_count="$(printf '%s\n' "$architectures" | awk '{print NF}')"
  if [[ " $architectures " == *" arm64 "* \
    && " $architectures " == *" x86_64 "* \
    && "$architecture_count" == "2" ]]; then
    pass "$label is universal (arm64 x86_64)"
  else
    fail "$label must contain exactly arm64 and x86_64 (found: ${architectures:-unreadable})"
  fi
}

check_framework_identity() {
  local framework="$1"
  local info="$2"
  local executable="$3"
  local label="$4"
  local install_name

  check_plist_value "$info" "CFBundleIdentifier" "dev.screenlog.core" "$label bundle identity"
  check_plist_value "$info" "CFBundlePackageType" "FMWK" "$label package type"
  check_plist_value "$info" "CFBundleExecutable" "ScreenlogCore" "$label executable identity"

  install_name="$(otool -D "$executable" 2>/dev/null | tail -1 || true)"
  if [[ "$install_name" == "@rpath/ScreenlogCore.framework/Versions/A/ScreenlogCore" ]]; then
    pass "$label has a relocatable install name"
  else
    fail "$label install name is not relocatable: ${install_name:-missing}"
  fi

  if [[ ! -d "$framework/Versions/A" || ! -L "$framework/Versions/Current" ]]; then
    fail "$label does not use the expected versioned framework layout"
  else
    pass "$label has the expected versioned framework layout"
  fi
}

check_relocatable_link() {
  local executable="$1"
  local label="$2"
  local links
  links="$(otool -L "$executable" 2>/dev/null || true)"
  if grep -q '@rpath/ScreenlogCore.framework/Versions/A/ScreenlogCore' <<<"$links"; then
    pass "$label uses relocatable ScreenlogCore linkage"
  else
    fail "$label is missing relocatable ScreenlogCore linkage"
  fi
  if grep -E '^[[:space:]]*/.*ScreenlogCore\.framework/' <<<"$links" >/dev/null; then
    fail "$label contains an absolute ScreenlogCore framework path"
  fi
}

run_cli_version() {
  local executable="$1"
  env \
    -u DYLD_LIBRARY_PATH \
    -u DYLD_FRAMEWORK_PATH \
    -u DYLD_FALLBACK_LIBRARY_PATH \
    -u DYLD_FALLBACK_FRAMEWORK_PATH \
    "$executable" --version 2>/dev/null
}

validate_structure_nodes() {
  require_directory "$APP_PATH" "app bundle" || true
  require_regular_file "$APP_INFO" "app Info.plist" || true
  require_directory "$APP_PATH/Contents/Resources" "app Resources" || true
  require_regular_file "$APP_PATH/Contents/Resources/Assets.car" "compiled app assets" || true
  require_regular_file "$APP_PATH/Contents/Resources/AppIcon.icns" "app icon" || true
  require_directory "$APP_FRAMEWORK" "embedded app framework" || true
  require_directory "$SPARKLE_FRAMEWORK" "embedded Sparkle framework" || true
  require_regular_file "$SPARKLE_INFO" "Sparkle Info.plist" || true
  require_executable "$SPARKLE_EXECUTABLE" "Sparkle executable" || true
  require_executable "$SPARKLE_AUTOUPDATE" "Sparkle autoupdate tool" || true
  require_directory "$SPARKLE_UPDATER" "Sparkle updater app" || true
  require_directory "$SPARKLE_DOWNLOADER" "Sparkle downloader service" || true
  require_directory "$SPARKLE_INSTALLER" "Sparkle installer service" || true
  require_executable "$SPARKLE_UPDATER_EXECUTABLE" "Sparkle updater executable" || true
  require_executable "$SPARKLE_DOWNLOADER_EXECUTABLE" \
    "Sparkle downloader executable" || true
  require_executable "$SPARKLE_INSTALLER_EXECUTABLE" \
    "Sparkle installer executable" || true
  require_directory "$CLI_FRAMEWORK" "standalone CLI framework" || true
  require_regular_file "$STANDALONE_SKILL" "standalone CLI assistant skill" || true

  require_executable "$APP_EXECUTABLE" "app executable" || true
  require_executable "$BUNDLED_CLI" "bundled CLI" || true
  require_executable "$APP_FRAMEWORK_EXECUTABLE" "embedded framework executable" || true
  require_executable "$CLI_PATH" "standalone CLI" || true
  require_executable "$CLI_FRAMEWORK_EXECUTABLE" "standalone framework executable" || true
}

if (( FAILURES == 0 )); then
  validate_structure_nodes
fi

# Do not feed missing paths into Mach-O and plist tools. The accumulated node
# errors above are already actionable and include the expected lifecycle layout.
if (( FAILURES > 0 )); then
  echo "release structure verification failed with $FAILURES issue(s)" >&2
  exit 1
fi

check_plist_value "$APP_INFO" "CFBundleIdentifier" "dev.screenlog.app" "app bundle identity"
check_plist_value "$APP_INFO" "CFBundlePackageType" "APPL" "app package type"
check_plist_value "$APP_INFO" "CFBundleExecutable" "Screenlogger" "app executable identity"
check_plist_value "$APP_INFO" "CFBundleName" "Screenlogger" "app product name"
check_plist_value \
  "$APP_INFO" \
  "SUFeedURL" \
  "https://radkawar.github.io/screenlogger/appcast.xml" \
  "signed update feed URL"
check_plist_value \
  "$APP_INFO" \
  "SUPublicEDKey" \
  "Bjy/ZcViaUi1FZ3Cl5tahdNK9EOfa2k9sEtIE1Bg1ts=" \
  "update signing public key"
check_plist_value \
  "$APP_INFO" \
  "SUVerifyUpdateBeforeExtraction" \
  "true" \
  "pre-extraction update verification"
check_plist_value \
  "$APP_INFO" \
  "SURequireSignedFeed" \
  "true" \
  "signed update feed requirement"
check_plist_value \
  "$SPARKLE_INFO" \
  "CFBundleIdentifier" \
  "org.sparkle-project.Sparkle" \
  "Sparkle bundle identity"
check_plist_value \
  "$SPARKLE_INFO" \
  "CFBundleShortVersionString" \
  "2.9.5" \
  "Sparkle version with macOS 26 update-cache fix"

APP_VERSION="$(plist_value "$APP_INFO" "CFBundleShortVersionString" || true)"
APP_BUILD="$(plist_value "$APP_INFO" "CFBundleVersion" || true)"
if [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  pass "app marketing version is valid: $APP_VERSION"
else
  fail "app marketing version is missing or invalid: ${APP_VERSION:-missing}"
fi
if [[ "$APP_BUILD" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  pass "app build version is valid: $APP_BUILD"
else
  fail "app build version is missing or invalid: ${APP_BUILD:-missing}"
fi

check_framework_identity \
  "$APP_FRAMEWORK" "$APP_FRAMEWORK_INFO" "$APP_FRAMEWORK_EXECUTABLE" \
  "embedded framework"
check_framework_identity \
  "$CLI_FRAMEWORK" "$CLI_FRAMEWORK_INFO" "$CLI_FRAMEWORK_EXECUTABLE" \
  "standalone framework"

for framework_info in "$APP_FRAMEWORK_INFO" "$CLI_FRAMEWORK_INFO"; do
  framework_build="$(plist_value "$framework_info" "CFBundleVersion" || true)"
  if [[ "$framework_build" == "$APP_BUILD" ]]; then
    pass "$(dirname "$framework_info") build agrees with app build $APP_BUILD"
  else
    fail "framework build '${framework_build:-missing}' does not agree with app build '$APP_BUILD'"
  fi

  framework_version="$(plist_value "$framework_info" "CFBundleShortVersionString" || true)"
  if [[ -n "$framework_version" && "$framework_version" != "$APP_VERSION" ]]; then
    fail "framework marketing version '$framework_version' does not agree with app '$APP_VERSION'"
  fi
done

check_universal_binary "$APP_EXECUTABLE" "app executable"
check_universal_binary "$BUNDLED_CLI" "bundled CLI"
check_universal_binary "$APP_FRAMEWORK_EXECUTABLE" "embedded framework executable"
check_universal_binary "$CLI_PATH" "standalone CLI"
check_universal_binary "$CLI_FRAMEWORK_EXECUTABLE" "standalone framework executable"

check_relocatable_link "$APP_EXECUTABLE" "app executable"
check_relocatable_link "$BUNDLED_CLI" "bundled CLI"
check_relocatable_link "$CLI_PATH" "standalone CLI"

BUNDLED_CLI_VERSION="$(run_cli_version "$BUNDLED_CLI" || true)"
STANDALONE_CLI_VERSION="$(run_cli_version "$CLI_PATH" || true)"
if [[ "$BUNDLED_CLI_VERSION" == "$APP_VERSION" ]]; then
  pass "bundled CLI version agrees with app: $APP_VERSION"
else
  fail "bundled CLI version '${BUNDLED_CLI_VERSION:-unavailable}' does not agree with app '$APP_VERSION'"
fi
if [[ "$STANDALONE_CLI_VERSION" == "$APP_VERSION" ]]; then
  pass "standalone CLI version agrees with app: $APP_VERSION"
else
  fail "standalone CLI version '${STANDALONE_CLI_VERSION:-unavailable}' does not agree with app '$APP_VERSION'"
fi

if "$ROOT/Scripts/verify-app-skill.sh" "$APP_PATH" --exercise-discovery; then
  pass "app-contained assistant skill and discovery contract"
else
  fail "app-contained assistant skill or discovery contract"
fi

CANONICAL_SKILL="$ROOT/Resources/skill/screenlog-cli-skill/SKILL.md"
if cmp -s "$CANONICAL_SKILL" "$STANDALONE_SKILL"; then
  pass "standalone CLI assistant skill matches the canonical resource"
else
  fail "standalone CLI assistant skill differs from the canonical resource"
fi

# Prove the standalone pair works using only the layout that release packaging
# and the receipt-backed local installer consume. This prevents a neighboring
# build product or DYLD environment variable from masking an incomplete pair.
CONTRACT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/screenlogger-release-structure.XXXXXX")"
cleanup_contract() {
  rm -rf -- "$CONTRACT_ROOT"
}
trap cleanup_contract EXIT INT TERM
ISOLATED_CLI_ROOT="$CONTRACT_ROOT/CLI"
ISOLATED_CLI="$ISOLATED_CLI_ROOT/screenlog"
ISOLATED_FRAMEWORK="$ISOLATED_CLI_ROOT/ScreenlogCore.framework"
ISOLATED_SKILL_ROOT="$ISOLATED_CLI_ROOT/skill/screenlog-cli-skill"
mkdir -p "$ISOLATED_CLI_ROOT/skill"
ditto "$CLI_PATH" "$ISOLATED_CLI"
ditto "$CLI_FRAMEWORK" "$ISOLATED_FRAMEWORK"
ditto "$(dirname "$STANDALONE_SKILL")" "$ISOLATED_SKILL_ROOT"

ISOLATED_VERSION="$(run_cli_version "$ISOLATED_CLI" || true)"
if [[ "$ISOLATED_VERSION" == "$APP_VERSION" ]]; then
  pass "isolated standalone CLI/framework layout launches without checkout paths"
else
  fail "isolated standalone CLI/framework layout did not launch with version $APP_VERSION"
fi

DISCOVERED_SKILLS="$CONTRACT_ROOT/discovered-skills"
WORKING_DIRECTORY="$CONTRACT_ROOT/work"
mkdir -p "$DISCOVERED_SKILLS" "$WORKING_DIRECTORY"
if (
  cd "$WORKING_DIRECTORY"
  env -u SCREENLOG_SKILL_DIR \
    SCREENLOG_DISABLE_CHECKOUT_SKILL_FALLBACK=1 \
    "$ISOLATED_CLI" skill install codex --directory "$DISCOVERED_SKILLS" >/dev/null
); then
  DISCOVERED_SKILL="$DISCOVERED_SKILLS/screenlog-cli-skill/SKILL.md"
  if [[ -f "$DISCOVERED_SKILL" && ! -L "$DISCOVERED_SKILL" ]] \
    && cmp -s "$CANONICAL_SKILL" "$DISCOVERED_SKILL"; then
    pass "isolated standalone CLI discovers its adjacent assistant skill"
  else
    fail "isolated standalone CLI installed an invalid assistant skill"
  fi
else
  fail "isolated standalone CLI could not discover its adjacent assistant skill"
fi

if (( FAILURES > 0 )); then
  echo "release structure verification failed with $FAILURES issue(s)" >&2
  exit 1
fi
echo "release structure verification passed"

if [[ "$MODE" == "structure" ]]; then
  exit 0
fi

if [[ "$MODE" == "ad-hoc" ]]; then
  if ! command -v codesign >/dev/null 2>&1; then
    fail "required ad-hoc signature verification tool is unavailable: codesign"
  fi
  if (( FAILURES > 0 )); then
    echo "release ad-hoc signature verification failed with $FAILURES issue(s)" >&2
    exit 1
  fi

  check_ad_hoc_signature() {
    local artifact="$1"
    local label="$2"
    local expected_identifier="$3"
    local requires_resource_seal="$4"
    local deep="$5"
    local architecture
    local details
    local verify_arguments=(--verify --strict)

    if [[ "$deep" == "1" ]]; then
      verify_arguments+=(--deep)
    fi
    if ! /usr/bin/codesign "${verify_arguments[@]}" --verbose=2 "$artifact" \
      >/dev/null 2>&1; then
      fail "$label has an invalid, incomplete, or missing code signature"
      return
    fi

    for architecture in arm64 x86_64; do
      if ! /usr/bin/codesign "${verify_arguments[@]}" \
        --arch "$architecture" \
        "$artifact" >/dev/null 2>&1; then
        fail "$label $architecture slice has an invalid code signature"
        continue
      fi

      details="$(/usr/bin/codesign -d --arch "$architecture" -vvv "$artifact" 2>&1 || true)"
      if ! grep -q "^Identifier=$expected_identifier$" <<<"$details"; then
        fail "$label $architecture slice has an unexpected identifier"
      fi
      if ! grep -q '^Signature=adhoc$' <<<"$details"; then
        fail "$label $architecture slice is not ad-hoc signed"
      fi
      if grep -Eq '^CodeDirectory .*flags=.*linker-signed' <<<"$details"; then
        fail "$label $architecture slice still has an incomplete linker signature"
      fi
      if [[ "$requires_resource_seal" == "1" ]]; then
        if ! grep -Eq '^Info\.plist entries=[1-9][0-9]*$' <<<"$details"; then
          fail "$label $architecture slice does not bind Info.plist"
        fi
        if ! grep -Eq '^Sealed Resources version=[1-9]' <<<"$details"; then
          fail "$label $architecture slice does not seal bundle resources"
        fi
      fi
    done

    pass "$label has complete ad-hoc signatures for arm64 and x86_64"
  }

  check_ad_hoc_signature "$APP_FRAMEWORK" "embedded framework" \
    "dev.screenlog.core" 1 0
  check_ad_hoc_signature "$BUNDLED_CLI" "bundled CLI" \
    "dev.screenlog.cli" 0 0
  check_ad_hoc_signature "$APP_PATH" "app" \
    "dev.screenlog.app" 1 1
  check_ad_hoc_signature "$CLI_FRAMEWORK" "standalone CLI framework" \
    "dev.screenlog.core" 1 0
  check_ad_hoc_signature "$CLI_PATH" "standalone CLI" \
    "dev.screenlog.cli" 0 0

  set +e
  APP_ENTITLEMENTS_RAW="$(/usr/bin/codesign -d --xml --entitlements - "$APP_PATH" 2>&1)"
  APP_ENTITLEMENTS_STATUS=$?
  set -e
  if (( APP_ENTITLEMENTS_STATUS != 0 )) || [[ "$APP_ENTITLEMENTS_RAW" != *"<?xml"* ]]; then
    fail "could not read the app's ad-hoc signed entitlements"
  else
    APP_ENTITLEMENTS_XML="<?xml${APP_ENTITLEMENTS_RAW#*<?xml}"
    SIGNED_ENTITLEMENTS_JSON="$(
      printf '%s' "$APP_ENTITLEMENTS_XML" \
        | /usr/bin/plutil -convert json -o - - 2>/dev/null \
        || true
    )"
    EXPECTED_ENTITLEMENTS_JSON="$(
      /usr/bin/plutil -convert json -o - "$ROOT/Config/Screenlog.entitlements" \
        2>/dev/null \
        || true
    )"
    if [[ -n "$SIGNED_ENTITLEMENTS_JSON" \
      && "$SIGNED_ENTITLEMENTS_JSON" == "$EXPECTED_ENTITLEMENTS_JSON" ]]; then
      pass "app ad-hoc signature contains the configured entitlement set"
    else
      fail "app ad-hoc signed entitlements differ from Config/Screenlog.entitlements"
    fi
  fi

  if (( FAILURES > 0 )); then
    echo "release ad-hoc signature verification failed with $FAILURES issue(s)" >&2
    exit 1
  fi
  echo "release ad-hoc signature verification passed"
  exit 0
fi

required_signing_commands=(codesign)
if [[ "$MODE" == "signing" ]]; then
  required_signing_commands+=(spctl xcrun)
fi
for command_name in "${required_signing_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "required signing verification tool is unavailable: $command_name"
  fi
done
if (( FAILURES > 0 )); then
  echo "release signing verification failed with $FAILURES issue(s)" >&2
  exit 1
fi

AUTOMATION_ENTITLEMENT="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.automation.apple-events' \
    "$ROOT/Config/Screenlog.entitlements" \
    2>/dev/null \
    || true
)"
if [[ "$AUTOMATION_ENTITLEMENT" == "true" ]]; then
  pass "configured release entitlements allow the Terminal handoff"
else
  fail "configured release entitlements do not allow the Terminal handoff"
fi

APP_SIGNATURE_DETAILS="$(codesign -dvvv "$APP_PATH" 2>&1 || true)"
EXPECTED_TEAM_ID="$({
  grep '^TeamIdentifier=' <<<"$APP_SIGNATURE_DETAILS" || true
} | awk -F= 'NR == 1 {print $2}')"
if [[ -z "$EXPECTED_TEAM_ID" || "$EXPECTED_TEAM_ID" == "not set" ]]; then
  fail "app signature has no Team ID"
elif [[ "$EXPECTED_TEAM_ID" != "3UX5N7Y8TY" ]]; then
  fail "app signature uses untrusted Team ID $EXPECTED_TEAM_ID"
fi

check_signature() {
  local artifact="$1"
  local label="$2"
  local expected_identifier="$3"
  local deep="$4"
  local architecture
  local details
  local verify_arguments=(--verify --strict)

  if [[ "$deep" == "1" ]]; then
    verify_arguments+=(--deep)
  fi
  if ! codesign "${verify_arguments[@]}" --verbose=2 "$artifact" >/dev/null 2>&1; then
    fail "$label has an invalid or missing code signature"
    return
  fi

  for architecture in arm64 x86_64; do
    if ! codesign "${verify_arguments[@]}" --arch "$architecture" "$artifact" \
      >/dev/null 2>&1; then
      fail "$label $architecture slice has an invalid code signature"
      continue
    fi
    details="$(codesign -d --arch "$architecture" -vvv "$artifact" 2>&1 || true)"
    if ! grep -q "^Identifier=$expected_identifier$" <<<"$details"; then
      fail "$label $architecture slice has an unexpected identifier"
    fi
    if ! grep -q '^Authority=Developer ID Application:' <<<"$details"; then
      fail "$label $architecture slice is not signed with Developer ID Application"
    fi
    if ! grep -q "^TeamIdentifier=$EXPECTED_TEAM_ID$" <<<"$details"; then
      fail "$label $architecture slice does not use Team ID $EXPECTED_TEAM_ID"
    fi
    if ! grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$details"; then
      fail "$label $architecture slice does not enable Hardened Runtime"
    fi
    if ! grep -q '^Timestamp=' <<<"$details"; then
      fail "$label $architecture slice has no secure signing timestamp"
    fi
  done

  pass "$label has complete Developer ID signatures for Team ID $EXPECTED_TEAM_ID"
}

check_signature "$SPARKLE_UPDATER" "Sparkle updater" \
  "org.sparkle-project.Sparkle.Updater" 1
check_signature "$SPARKLE_DOWNLOADER" "Sparkle downloader service" \
  "org.sparkle-project.DownloaderService" 1
check_signature "$SPARKLE_INSTALLER" "Sparkle installer service" \
  "org.sparkle-project.InstallerLauncher" 1
check_signature "$SPARKLE_AUTOUPDATE" "Sparkle autoupdate tool" \
  "org.sparkle-project.Sparkle.Autoupdate" 0
check_signature "$SPARKLE_VERSION" "Sparkle framework" \
  "org.sparkle-project.Sparkle" 1
check_signature "$APP_FRAMEWORK" "embedded framework" "dev.screenlog.core" 0
check_signature "$BUNDLED_CLI" "bundled CLI" "dev.screenlog.cli" 0
check_signature "$APP_PATH" "app" "dev.screenlog.app" 1
check_signature "$CLI_FRAMEWORK" "standalone CLI framework" "dev.screenlog.core" 0
check_signature "$CLI_PATH" "standalone CLI" "dev.screenlog.cli" 0

set +e
APP_ENTITLEMENTS_RAW="$(codesign -d --xml --entitlements - "$APP_PATH" 2>&1)"
APP_ENTITLEMENTS_STATUS=$?
set -e
if [[ "$APP_ENTITLEMENTS_RAW" == *"<?xml"* ]]; then
  # codesign writes status text and XML to stderr. Strip status before parsing.
  APP_ENTITLEMENTS_XML="<?xml${APP_ENTITLEMENTS_RAW#*<?xml}"
  if printf '%s' "$APP_ENTITLEMENTS_XML" | plutil -lint - >/dev/null; then
    pass "app signed entitlement set is parseable"
  else
    fail "could not parse the app's signed entitlements"
  fi
  SIGNED_ENTITLEMENTS_JSON="$(
    printf '%s' "$APP_ENTITLEMENTS_XML" \
      | plutil -convert json -o - - 2>/dev/null \
      || true
  )"
  EXPECTED_ENTITLEMENTS_JSON="$(
    plutil -convert json -o - "$ROOT/Config/Screenlog.entitlements" \
      2>/dev/null \
      || true
  )"
  if [[ -n "$SIGNED_ENTITLEMENTS_JSON" \
    && "$SIGNED_ENTITLEMENTS_JSON" == "$EXPECTED_ENTITLEMENTS_JSON" ]]; then
    pass "app Developer ID signature contains the configured entitlement set"
  else
    fail "app Developer ID entitlements differ from Config/Screenlog.entitlements"
  fi
  for forbidden_entitlement in \
    com.apple.security.cs.allow-jit \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.cs.disable-library-validation \
    com.apple.security.get-task-allow; do
    entitlement_key_path="${forbidden_entitlement//./\\.}"
    entitlement_value="$(
      printf '%s' "$APP_ENTITLEMENTS_XML" \
        | plutil -extract "$entitlement_key_path" raw -o - - 2>/dev/null \
        || true
    )"
    if [[ "$entitlement_value" == "true" ]]; then
      fail "app enables release-unsafe entitlement: $forbidden_entitlement"
    fi
  done
elif (( APP_ENTITLEMENTS_STATUS == 0 )); then
  pass "app has an empty signed entitlement set"
else
  fail "could not read the app's signed entitlements"
fi

if [[ "$MODE" == "developer-id" ]]; then
  if (( FAILURES > 0 )); then
    echo "release Developer ID signature verification failed with $FAILURES issue(s)" >&2
    exit 1
  fi
  echo "release Developer ID signature verification passed"
  exit 0
fi

if spctl --assess --type execute --verbose=4 "$APP_PATH" >/dev/null 2>&1; then
  pass "Gatekeeper accepts the app"
else
  fail "Gatekeeper rejected the app; verify Developer ID signing and notarization"
fi
if xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
  pass "app contains a valid stapled notarization ticket"
else
  fail "app has no valid stapled notarization ticket"
fi

if (( FAILURES > 0 )); then
  echo "release signing verification failed with $FAILURES issue(s)" >&2
  exit 1
fi

echo "release signing verification passed"
