#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash "$ROOT/Scripts/check-repository.sh"
bash "$ROOT/Scripts/check-source-safety.sh"

# Prefer full Xcode.app toolchain (not bare CLT) when present.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
else
  export DEVELOPER_DIR
fi

if [[ -n "${DEVELOPER_DIR:-}" && ! -d "$DEVELOPER_DIR" ]]; then
  echo "error: DEVELOPER_DIR is set but missing: $DEVELOPER_DIR" >&2
  exit 1
fi

echo "xcodegen: pinned project generation"
"$ROOT/Scripts/xcodegen.sh" generate

xcodebuild -project Screenlog.xcodeproj -scheme Screenlog \
  -configuration Debug \
  -derivedDataPath "$ROOT/build/DerivedData" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES \
  build

PRODUCTS="$ROOT/build/DerivedData/Build/Products/Debug"
APP="$PRODUCTS/Screenlogger.app"
CLI="$PRODUCTS/screenlog"
BUNDLED_CLI="$APP/Contents/MacOS/screenlog"
FW="$PRODUCTS/ScreenlogCore.framework"

echo "App:  $APP"
echo "CLI:  $CLI"
echo "FW:   $FW"

# --- post-build dyld sanity (no DYLD_* hacks) ---
if [[ ! -x "$CLI" ]]; then
  echo "error: CLI missing at $CLI" >&2
  exit 1
fi
if [[ ! -x "$BUNDLED_CLI" ]]; then
  echo "error: installable CLI missing from app at $BUNDLED_CLI" >&2
  exit 1
fi
if [[ ! -d "$FW" ]]; then
  echo "error: framework missing at $FW" >&2
  exit 1
fi

# Prove the app carries the canonical assistant skill at its production path,
# and that its bundled CLI discovers that copy without a checkout fallback.
"$ROOT/Scripts/verify-app-skill.sh" "$APP" --exercise-discovery

# Ensure CLI can find framework at @executable_path (same products dir).
if [[ ! -d "$PRODUCTS/Frameworks/ScreenlogCore.framework" ]]; then
  mkdir -p "$PRODUCTS/Frameworks"
  rsync -a --delete "$FW/" "$PRODUCTS/Frameworks/ScreenlogCore.framework/"
fi

ID_FW="$(otool -D "$FW/ScreenlogCore" 2>/dev/null | tail -1 || true)"
echo "framework id: $ID_FW"
if ! echo "$ID_FW" | grep -q '@rpath'; then
  echo "error: ScreenlogCore install name is not @rpath (got: $ID_FW)" >&2
  echo "hint: set DYLIB_INSTALL_NAME_BASE=@rpath on ScreenlogCore and regenerate" >&2
  exit 1
fi

APP_LINK="$(otool -L "$APP/Contents/MacOS/Screenlogger" | grep ScreenlogCore || true)"
CLI_LINK="$(otool -L "$CLI" | grep ScreenlogCore || true)"
echo "app links: $APP_LINK"
echo "cli links: $CLI_LINK"
if echo "$APP_LINK$CLI_LINK" | grep -q '/Library/Frameworks/ScreenlogCore'; then
  echo "error: product still links absolute /Library/Frameworks install name" >&2
  exit 1
fi

# Smoke: CLI must load without DYLD_LIBRARY_PATH / DYLD_FRAMEWORK_PATH.
unset DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH || true
if ! "$CLI" --version >/dev/null; then
  echo "error: screenlog --version failed to load (dyld / runtime)" >&2
  exit 1
fi
if ! "$BUNDLED_CLI" --version >/dev/null; then
  echo "error: bundled screenlog --version failed to load (dyld / runtime)" >&2
  exit 1
fi
echo "cli --version: $("$CLI" --version)"

# Detect dyld hard-fail without opening or migrating the user's Library or
# preferences. This is the DEBUG-only routed test boundary used by UI tests.
set +e
SMOKE_OUT="$(
  set -e
  token="$(/usr/bin/uuidgen)"
  smoke_tmp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
  smoke_parent="${smoke_tmp%/}/screenlogger-ui-tests"
  smoke_root="$smoke_parent/$token"
  [[ ! -L "$smoke_parent" ]] || exit 1
  mkdir -p "$smoke_parent"
  mkdir -m 700 "$smoke_root"
  pid=""
  cleanup_smoke() {
    if [[ -n "$pid" ]]; then
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -rf -- "$smoke_root"
  }
  trap cleanup_smoke EXIT
  trap 'exit 130' INT TERM
  mkdir -m 700 "$smoke_root/home"
  TMPDIR="$smoke_tmp" \
    SCREENLOG_UI_TEST_PREFERENCES_MODE=isolated-v1 \
    SCREENLOG_UI_TEST_PREFERENCES_SUITE="dev.screenlog.ui-tests.$token" \
    SCREENLOG_DATA_DIR="$smoke_root" \
    CFFIXED_USER_HOME="$smoke_root/home" \
    SCREENLOG_SEMANTIC_MODELS_DIR="$smoke_root/models" \
    "$APP/Contents/MacOS/Screenlogger" --screenlogger-ui-test-token "$token" >/dev/null 2>&1 &
  pid=$!
  set +e
  sleep 0.6
  if kill -0 "$pid" 2>/dev/null; then
    echo "alive=1"
    kill -TERM "$pid" 2>/dev/null
    sleep 0.2
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  else
    wait "$pid" 2>/dev/null
    code=$?
    echo "alive=0 exit=$code"
  fi
  pid=""
)"
set -e
if echo "$SMOKE_OUT" | grep -qiE 'dyld\[|Library not loaded|image not found'; then
  echo "error: Screenlogger.app failed dyld load:" >&2
  echo "$SMOKE_OUT" >&2
  exit 1
fi
# If process never stayed up, still OK when exit is not dyld (e.g. single-instance).
echo "app launch smoke: $SMOKE_OUT"
echo "build verified"

# Unit tests (opt out with SKIP_TESTS=1 for fast iteration).
if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
  echo "swift test..."
  if ! swift test --package-path "$ROOT"; then
    echo "error: swift test failed" >&2
    exit 1
  fi
  echo "swift test: passed"
else
  echo "swift test: skipped (SKIP_TESTS=1)"
fi

# Stage the assistant skill next to CLI products for lifecycle discovery
SKILL_SRC="$ROOT/Resources/skill/screenlog-cli-skill/SKILL.md"
if [[ -f "$SKILL_SRC" ]]; then
  mkdir -p "$PRODUCTS/skill/screenlog-cli-skill"
  cp -f "$SKILL_SRC" "$PRODUCTS/skill/screenlog-cli-skill/SKILL.md"
  echo "skill: $PRODUCTS/skill/screenlog-cli-skill/SKILL.md"
fi
