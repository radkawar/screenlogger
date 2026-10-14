#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPOSITORY_ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: repository check requires a Git work tree" >&2
  exit 1
fi

# Preserve upstream license notices verbatim, including their copyright symbols.
non_ascii="$(git grep -n -I -P '[^\x00-\x7F]' -- . ':!Resources/SemanticLicenses' || true)"
if [[ -n "$non_ascii" ]]; then
  echo "error: tracked text outside upstream license notices must be ASCII-only:" >&2
  echo "$non_ascii" >&2
  exit 1
fi

if ! cmp -s \
  Resources/skill/screenlog-cli-skill/SKILL.md \
  Sources/ScreenlogCLI/skill/screenlog-cli-skill/SKILL.md; then
  echo "error: assistant skill copies differ" >&2
  exit 1
fi

echo "repository hygiene: passed"
