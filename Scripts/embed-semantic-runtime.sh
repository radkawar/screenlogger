#!/usr/bin/env bash
set -euo pipefail

# Package resource accessors search beside the helper and in the enclosing app's
# Resources directory. Copy bundles intact; never flatten their Metal resources.
APP="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
PRODUCTS="${BUILT_PRODUCTS_DIR:?}"
WORKER="$PRODUCTS/screenlog-semantic-worker"
[[ -x "$WORKER" ]] || { echo "error: native semantic worker is missing" >&2; exit 1; }
install -m 755 "$WORKER" "$APP/Contents/MacOS/screenlog-semantic-worker"
mkdir -p "$APP/Contents/Resources"
shopt -s nullglob
bundles=("$PRODUCTS"/*.bundle)
for bundle in "${bundles[@]}"; do
  case "$(basename "$bundle")" in
    mlx-swift_*|swift-transformers_*|swift-huggingface_*|swift-crypto_*)
      /usr/bin/ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
      ;;
  esac
done
# Xcode compiles the Cmlx target's .metal sources into this resource bundle.
METAL="$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
[[ -d "$METAL" ]] || { echo "error: MLX Metal resource bundle is missing; build with Xcode" >&2; exit 1; }
if [[ ! -f "$METAL/default.metallib" && ! -f "$METAL/Contents/Resources/default.metallib" ]]; then
  echo "error: the MLX bundle has no compiled default.metallib" >&2
  exit 1
fi
# The helper is nested code, not a script or an installable standalone CLI.
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES ]]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  [[ -n "$identity" ]] || identity=-
  args=(--force --sign "$identity" --identifier dev.screenlog.semantic-worker)
  [[ "${ENABLE_HARDENED_RUNTIME:-NO}" != YES ]] || args+=(--options runtime)
  [[ "$identity" != - ]] || args+=(--timestamp=none)
  /usr/bin/codesign "${args[@]}" "$APP/Contents/MacOS/screenlog-semantic-worker"
fi
