#!/usr/bin/env bash
# Shared ownership contract for the local, unsigned Screenlogger installer.
# This file is sourced by install.sh, uninstall.sh, and isolated smoke tests.

SL_RECEIPT_PRODUCT="dev.screenlog.local-install"
SL_RECEIPT_VERSION="1"
# shellcheck disable=SC2034 # Public constant consumed by sourcing scripts.
SL_RECEIPT_NAME=".screenlogger-local-install.plist"
# shellcheck disable=SC2034 # Public constant consumed by installer scripts.
SL_CLI_RECEIPT_NAME=".screenlog-cli-install.json"
SL_CLI_RECEIPT_PRODUCT="dev.screenlog.cli"
SL_CLI_RECEIPT_VERSION="2"
SL_CLI_SKILL_NAME="screenlog-cli-skill"

sl_node_exists() {
  [[ -e "$1" || -L "$1" ]]
}

sl_regular_file() {
  [[ -f "$1" && ! -L "$1" ]]
}

sl_directory() {
  [[ -d "$1" && ! -L "$1" ]]
}

sl_sha256() {
  sl_regular_file "$1" || return 1
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

# Matches CLIArtifactInstallationService's bounded artifact identity format.
# File identities include a type prefix. Directory identities include every
# descendant's relative path, node type, symlink target, and regular-file bytes
# in bytewise path order. Keep this format synchronized with the Swift service.
sl_cli_artifact_sha256() {
  local artifact="$1"
  if [[ -L "$artifact" ]]; then
    {
      printf 'link\0'
      printf '%s' "$(/usr/bin/readlink "$artifact")"
    } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
  elif [[ -f "$artifact" ]]; then
    {
      printf 'file\0'
      /bin/cat "$artifact"
    } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
  elif [[ -d "$artifact" ]]; then
    (
      printf 'directory\0'
      cd "$artifact" || exit 1
      /usr/bin/find . -mindepth 1 -print0 \
        | LC_ALL=C /usr/bin/sort -z \
        | while IFS= read -r -d '' entry; do
            local relative="${entry#./}"
            printf '%s\0' "$relative"
            if [[ -L "$entry" ]]; then
              printf 'link\0'
              printf '%s' "$(/usr/bin/readlink "$entry")"
            elif [[ -f "$entry" ]]; then
              printf 'file\0'
              /bin/cat "$entry"
            elif [[ -d "$entry" ]]; then
              printf 'directory\0'
            else
              exit 1
            fi
            printf '\0'
          done
    ) | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
  else
    return 1
  fi
}

sl_screenlogger_skill_recognized() {
  local skill="$1"
  local manifest="$skill/SKILL.md"
  local byte_count
  sl_directory "$skill" && sl_regular_file "$manifest" || return 1
  [[ "$(/usr/bin/find "$skill" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "1" ]] \
    || return 1
  byte_count="$(/usr/bin/wc -c < "$manifest" 2>/dev/null)" || return 1
  [[ "$byte_count" -gt 0 && "$byte_count" -le 262144 ]] || return 1
  /usr/bin/head -n 12 "$manifest" | /usr/bin/awk -v expected="name: $SL_CLI_SKILL_NAME" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == expected) found = 1
    }
    END { exit(found ? 0 : 1) }
  '
}

sl_cli_receipt_claims_screenlogger() {
  local receipt="$1"
  local byte_count
  sl_regular_file "$receipt" || return 1
  byte_count="$(/usr/bin/wc -c < "$receipt" 2>/dev/null)" || return 1
  [[ "$byte_count" -gt 0 && "$byte_count" -le 65536 ]] || return 1
  [[ "$(sl_plist_value "$receipt" productIdentifier || true)" == "$SL_CLI_RECEIPT_PRODUCT" ]] \
    && [[ "$(sl_plist_value "$receipt" schemaVersion || true)" == "$SL_CLI_RECEIPT_VERSION" ]]
}

sl_cli_receipt_matches() {
  local receipt="$1"
  local cli="$2"
  local framework="$3"
  local skill="$4"
  sl_cli_receipt_claims_screenlogger "$receipt" \
    && sl_cli_pair_recognized "$cli" "$framework" \
    && sl_screenlogger_skill_recognized "$skill" \
    && [[ "$(sl_plist_value "$receipt" executableSHA256 || true)" == "$(sl_cli_artifact_sha256 "$cli")" ]] \
    && [[ "$(sl_plist_value "$receipt" frameworkSHA256 || true)" == "$(sl_cli_artifact_sha256 "$framework")" ]] \
    && [[ "$(sl_plist_value "$receipt" skillSHA256 || true)" == "$(sl_cli_artifact_sha256 "$skill")" ]]
}

sl_write_cli_receipt() {
  local receipt="$1"
  local cli="$2"
  local framework="$3"
  local skill="$4"
  sl_cli_pair_recognized "$cli" "$framework" \
    && sl_screenlogger_skill_recognized "$skill" || return 1
  /usr/bin/plutil -create xml1 "$receipt"
  /usr/bin/plutil -insert productIdentifier -string "$SL_CLI_RECEIPT_PRODUCT" "$receipt"
  /usr/bin/plutil -insert schemaVersion -integer "$SL_CLI_RECEIPT_VERSION" "$receipt"
  /usr/bin/plutil -insert executableSHA256 -string "$(sl_cli_artifact_sha256 "$cli")" "$receipt"
  /usr/bin/plutil -insert frameworkSHA256 -string "$(sl_cli_artifact_sha256 "$framework")" "$receipt"
  /usr/bin/plutil -insert skillSHA256 -string "$(sl_cli_artifact_sha256 "$skill")" "$receipt"
  /usr/bin/plutil -convert json "$receipt"
}

# Stable aggregate over every node, relative path, mode, symlink target, and
# regular-file digest. This makes a receipt fail closed if anything is added to
# or changed inside an owned app/framework directory.
sl_tree_sha256() {
  local root="$1"
  sl_directory "$root" || return 1
  (
    cd "$root" || exit 1
    /usr/bin/find -s . -print0 | while IFS= read -r -d '' entry; do
      if [[ -L "$entry" ]]; then
        printf 'link\0%s\0%s\0' "$entry" "$(/usr/bin/readlink "$entry")"
      elif [[ -f "$entry" ]]; then
        printf 'file\0%s\0%s\0%s\0' \
          "$entry" \
          "$(/usr/bin/stat -f '%Lp' "$entry")" \
          "$(sl_sha256 "$root/${entry#./}")"
      elif [[ -d "$entry" ]]; then
        printf 'directory\0%s\0%s\0' "$entry" "$(/usr/bin/stat -f '%Lp' "$entry")"
      else
        return 1
      fi
    done
  ) | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

sl_plist_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

sl_framework_info() {
  local framework="$1"
  if sl_regular_file "$framework/Versions/A/Resources/Info.plist"; then
    printf '%s\n' "$framework/Versions/A/Resources/Info.plist"
  elif sl_regular_file "$framework/Resources/Info.plist"; then
    printf '%s\n' "$framework/Resources/Info.plist"
  else
    return 1
  fi
}

sl_framework_executable() {
  local framework="$1"
  if sl_regular_file "$framework/Versions/A/ScreenlogCore"; then
    printf '%s\n' "$framework/Versions/A/ScreenlogCore"
  elif sl_regular_file "$framework/ScreenlogCore"; then
    printf '%s\n' "$framework/ScreenlogCore"
  else
    return 1
  fi
}

sl_app_recognized() {
  local app="$1"
  local info="$app/Contents/Info.plist"
  local executable="$app/Contents/MacOS/Screenlogger"
  sl_directory "$app" && sl_regular_file "$info" && sl_regular_file "$executable" \
    && [[ "$(sl_plist_value "$info" CFBundleIdentifier || true)" == "dev.screenlog.app" ]] \
    && [[ "$(sl_plist_value "$info" CFBundleExecutable || true)" == "Screenlogger" ]]
}

sl_framework_recognized() {
  local framework="$1"
  local info
  local executable
  sl_directory "$framework" || return 1
  info="$(sl_framework_info "$framework")" || return 1
  executable="$(sl_framework_executable "$framework")" || return 1
  [[ "$(sl_plist_value "$info" CFBundleIdentifier || true)" == "dev.screenlog.core" ]] \
    && [[ "$(sl_plist_value "$info" CFBundleExecutable || true)" == "ScreenlogCore" ]] \
    && sl_regular_file "$executable"
}

sl_cli_pair_recognized() {
  local cli="$1"
  local framework="$2"
  sl_regular_file "$cli" && [[ -x "$cli" ]] && sl_framework_recognized "$framework" \
    && /usr/bin/otool -L "$cli" 2>/dev/null \
      | /usr/bin/grep -Fq '@rpath/ScreenlogCore.framework/Versions/A/ScreenlogCore'
}

sl_app_receipt_matches() {
  local receipt="$1" app="$2" cli="$3" framework="$4"
  local byte_count
  sl_regular_file "$receipt" || return 1
  byte_count="$(/usr/bin/wc -c < "$receipt" 2>/dev/null)" || return 1
  [[ "$byte_count" -gt 0 && "$byte_count" -le 65536 ]] || return 1
  sl_app_recognized "$app" || return 1
  [[ "$(sl_plist_value "$receipt" productIdentifier || true)" == "$SL_RECEIPT_PRODUCT" ]] \
    && [[ "$(sl_plist_value "$receipt" schemaVersion || true)" == "$SL_RECEIPT_VERSION" ]] \
    && [[ "$(sl_plist_value "$receipt" appPath || true)" == "$app" ]] \
    && [[ "$(sl_plist_value "$receipt" cliPath || true)" == "$cli" ]] \
    && [[ "$(sl_plist_value "$receipt" frameworkPath || true)" == "$framework" ]] \
    && [[ "$(sl_plist_value "$receipt" appExecutableSHA256 || true)" == "$(sl_sha256 "$app/Contents/MacOS/Screenlogger")" ]] \
    && [[ "$(sl_plist_value "$receipt" appInfoSHA256 || true)" == "$(sl_sha256 "$app/Contents/Info.plist")" ]] \
    && [[ "$(sl_plist_value "$receipt" appTreeSHA256 || true)" == "$(sl_tree_sha256 "$app")" ]]
}

sl_receipt_matches() {
  local receipt="$1" app="$2" cli="$3" framework="$4"
  local framework_executable
  sl_app_receipt_matches "$receipt" "$app" "$cli" "$framework" || return 1
  sl_cli_pair_recognized "$cli" "$framework" || return 1
  framework_executable="$(sl_framework_executable "$framework")" || return 1
  [[ "$(sl_plist_value "$receipt" cliSHA256 || true)" == "$(sl_sha256 "$cli")" ]] \
    && [[ "$(sl_plist_value "$receipt" frameworkExecutableSHA256 || true)" == "$(sl_sha256 "$framework_executable")" ]] \
    && [[ "$(sl_plist_value "$receipt" frameworkTreeSHA256 || true)" == "$(sl_tree_sha256 "$framework")" ]]
}

sl_write_receipt() {
  local receipt="$1"
  local app="$2"
  local cli="$3"
  local framework="$4"
  local recorded_app="${5:-$app}"
  local recorded_cli="${6:-$cli}"
  local recorded_framework="${7:-$framework}"
  local framework_executable
  framework_executable="$(sl_framework_executable "$framework")" || return 1
  /usr/bin/plutil -create xml1 "$receipt"
  /usr/bin/plutil -insert productIdentifier -string "$SL_RECEIPT_PRODUCT" "$receipt"
  /usr/bin/plutil -insert schemaVersion -integer "$SL_RECEIPT_VERSION" "$receipt"
  /usr/bin/plutil -insert appPath -string "$recorded_app" "$receipt"
  /usr/bin/plutil -insert cliPath -string "$recorded_cli" "$receipt"
  /usr/bin/plutil -insert frameworkPath -string "$recorded_framework" "$receipt"
  /usr/bin/plutil -insert appExecutableSHA256 -string "$(sl_sha256 "$app/Contents/MacOS/Screenlogger")" "$receipt"
  /usr/bin/plutil -insert appInfoSHA256 -string "$(sl_sha256 "$app/Contents/Info.plist")" "$receipt"
  /usr/bin/plutil -insert appTreeSHA256 -string "$(sl_tree_sha256 "$app")" "$receipt"
  /usr/bin/plutil -insert cliSHA256 -string "$(sl_sha256 "$cli")" "$receipt"
  /usr/bin/plutil -insert frameworkExecutableSHA256 -string "$(sl_sha256 "$framework_executable")" "$receipt"
  /usr/bin/plutil -insert frameworkTreeSHA256 -string "$(sl_tree_sha256 "$framework")" "$receipt"
}

sl_validate_install_root() {
  local root="$1"
  [[ "$root" == /* && "$root" != "/" && "$root" != *$'\n'* ]] || return 1
  # Refuse lexical traversal instead of letting normalization silently change
  # the caller's requested ownership boundary.
  case "/${root#/}/" in
    */./*|*/../*) return 1 ;;
  esac
}

sl_validate_install_roots() {
  sl_validate_install_root "$1" && sl_validate_install_root "$2"
}

# Create a declared install root, resolve any existing symlink components, and
# validate the physical destination before callers append product names. This
# prevents a lexically safe path such as /tmp/link from becoming /Screenlogger.app
# when link resolves to the filesystem root.
sl_prepare_install_root() {
  local requested="$1"
  local canonical
  sl_validate_install_root "$requested" || return 1
  /bin/mkdir -p -- "$requested" || return 1
  canonical="$(cd "$requested" && pwd -P)" || return 1
  sl_validate_install_root "$canonical" || return 1
  printf '%s\n' "$canonical"
}

# Resolve an uninstall root without creating it. A missing root cannot contain
# an installed artifact, and uninstall should never leave new directories
# behind merely because there was nothing to remove.
sl_resolve_install_root() {
  local requested="$1"
  local canonical
  sl_validate_install_root "$requested" || return 1
  if [[ ! -d "$requested" ]]; then
    printf '%s\n' "$requested"
    return 0
  fi
  canonical="$(cd "$requested" && pwd -P)" || return 1
  sl_validate_install_root "$canonical" || return 1
  printf '%s\n' "$canonical"
}
