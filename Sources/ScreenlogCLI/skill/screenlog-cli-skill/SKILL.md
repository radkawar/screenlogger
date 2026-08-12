---
name: screenlog-cli-skill
description: Search and reconstruct the user's past activity (screenshots, screen text, optional audio transcripts, app and domain usage) with the screenlog CLI. Use whenever the user references something they personally did, saw, heard, or read - "what did I do", "find that thing I saw", "what was said in that meeting", "how much time did I spend on X", "summarize my research on Y".
---

# Screenlogger CLI Skill

Screenlogger keeps a **local** database of the user's past activity on this Mac: screenshots captured on an interval with searchable screen text, application, domain, and window-title metadata. When the user opts into continuous on-device audio transcription, finalized transcript text is searchable too; Screenlogger does not retain audio. Screenlogger does not upload this Library or require a cloud account. If an external assistant runs `screenlog`, that assistant's own settings and privacy policy govern the query and command output it receives.

The CLI is `screenlog` (often installed at `~/.local/bin/screenlog`). **Screenlogger.app must be running** - the CLI is a thin client and never opens the database itself. `screenlog -h` and `screenlog <subcommand>` usage lines are the authoritative reference for flags; this file only says what each command is for. This skill needs a shell: if you cannot run `screenlog`, tell the user to ask from an AI coding agent (Claude Code, Codex, Cursor, Grok Build) instead of guessing at invocations.

If the app is not running you will get a connection error - open Screenlogger.app and retry. The on-disk Library lives under `~/Library/Application Support/dev.screenlog/` (override with `SCREENLOG_DATA_DIR` or `--data-dir`).

## Commands

### Search & query

- `screenlog search <QUERY> [--content all|screen|transcripts] [--limit N] [--json]` - search screen text and transcripts together by default; use `--content screen` for visible text only or `--content transcripts` for spoken content only. Supports the same `app:`, `site:`, `date:`, `since:`, and `before:` refinements as the Library.
- `screenlog query fts <QUERY> [--limit N] [--json]` - same search as `search` (lower-level alias)
- `screenlog query frame --id N | --at <iso-or-epoch> [--show-ocr]` - frame metadata; `--show-ocr` adds OCR text
- `screenlog query image --at ... | --id N [--out path] [--base64] [--json]` - export the screenshot (also available as top-level `screenlog image ...`)
- `screenlog query sample [--limit N] [--min-seg-len N]` - representative frames across activity segments
- `screenlog query ocrboxes --id N` - OCR boxes with pixel coordinates for a frame
- `screenlog query axtree --id N` - captured macOS accessibility tree for the frame (only if Accessibility was trusted when recording)

### Usage & inventory

- `screenlog usage time` - approximate total recorded screen time (from frame count)
- `screenlog usage top-applications [--limit N]` - rank apps by captured frames / time
- `screenlog usage top-domains [--limit N]` - rank web domains by captured frames / time
- `screenlog usage sessions [--gap MIN]` - continuous recording blocks split at gaps (default gap: 5 minutes)
- `screenlog list applications` - recorded apps (bundle ID + display name)
- `screenlog list domains` - recorded web domains

### Capture & maintenance

- `screenlog record start|stop|once` - control recording; `once` captures a single frame
- `screenlog status [--json]` / `screenlog stats` - live status and store counters; JSON includes stable health and issue codes
- `screenlog doctor [--json]` - socket, permissions, version, and connectivity diagnostics; JSON omits Library and socket paths
- `screenlog compact` - run video compaction of older stills
- `screenlog retention` - apply retention policy (age / storage)
- `screenlog ping` - check the app bridge is alive
- `screenlog image --at <iso-or-epoch> | --id N [--out path] [--base64] [--json]` - extract a still (same as `query image`)

Local tool access is read-only by default. `record start|stop|once`, `compact`,
and `retention` are rejected unless the user explicitly turns on
**Allow capture control and maintenance** in Screenlogger Settings under
Integrations. Never ask the user to enable that access unless their request
actually requires one of those actions, and never treat the setting as blanket
permission to run a mutating command.

### Assistant skill lifecycle

- `screenlog skill install [claude|cursor|codex|grok|openclaw|all]` - install this skill (default: all detected assistants)
- `screenlog skill status [claude|cursor|codex|grok|openclaw|all] [--json]` - verify content and registration; JSON uses stable path-free readiness/state/remediation codes
- `screenlog skill upgrade [claude|cursor|codex|grok|openclaw|all]` - replace stale content safely
- `screenlog skill remove [claude|cursor|codex|grok|openclaw|all]` - uninstall the skill and remove Screenlogger's OpenClaw registration
- `screenlog install-skill [target]` - compatibility alias for `screenlog skill install [target]`

These lifecycle commands do not require Screenlogger.app to be running. Use `--force` only when the user explicitly wants to replace or remove a conflicting path.

For automation, `skill status --json` exits 0 only when every selected target is
ready. It emits its schema-v1 JSON before exiting 1 for missing, stale, blocked,
unregistered, or inspection-failure states; invalid usage exits 2. Never infer
or request private integration paths-the JSON intentionally omits them.
Treat `select_target` and `install_or_open_assistant` as external prerequisites,
not as permission to run a Screenlogger install or force-replace anything.
For `review_targets`, follow each non-ready target's own remediation record.

Timestamps (`--at`): ISO-8601 in the machine's local timezone (e.g. `2026-01-15T09:30` or `2026-01-15T09:30:45`), or epoch seconds / milliseconds.

Output is compact by default; pass `--json` where supported for structured output.

## How to interpret the data (very important)

- Frames are screenshots of the whole interface the user was looking at. OCR is a strong but sometimes noisy signal - if something feels off, it might be misread letters or messy reading order.
- A result with `transcriptSource` set came from optional on-device transcription. `microphone` is the user's input; `computer` is audio played by the Mac. Transcript text can contain recognition mistakes, so confirm important claims with nearby results and context.
- Content visible in a frame was not necessarily *created* at capture time - look for embedded timestamps (message times, file dates) or infer timing from surrounding activity.
- Frames are recorded on a regular interval (roughly ~2 seconds when recording) and sorted chronologically. Use individual frames for facts; use samples and sessions to reconstruct workflows.
- More recent frames tend to have more up-to-date information.
- Empty or missing fields mean unknown (e.g. no domain when the focused app was not a browser, or no AX tree when Accessibility was off).

## Search strategy

1. Sanity-check the bridge: `screenlog doctor` or `screenlog ping` (app must be running).
2. Find relevant recording blocks: `screenlog usage sessions --gap <MIN>`.
3. Pick the right tool:
   - Overview of general activity: `screenlog usage top-applications` / `top-domains` / `time`
   - Understand a workflow: `screenlog query sample`
   - Find specific moments: `screenlog search "..."` (or `query fts`); refine the query when needed
   - Confirm leads: `screenlog query frame --id <ID> --show-ocr`, then `query image` / `query axtree` if useful
4. Reflect: accuracy vs efficiency, evidence quality, completeness; refine queries if necessary.

## Tips

- Prefer `screenlog search` over saying "FTS" to the user - the user sees results, not engine names. (`query fts` is the same search.)
- Output can get large: choose gap values, limits, and time bounds deliberately. `--gap 10` surfaces short breaks; larger gaps merge more activity into fewer sessions.
- Start with a small `--limit` and widen only if needed.
- Refine in one query when possible: `screenlog search 'invoice app:Safari site:example.com since:2026-07-01' --json`.
- For meeting or presentation speech, start with `screenlog search 'roadmap' --content transcripts --json`. For words visibly shown on screen, use `--content screen`. Omit `--content` when either kind of evidence is useful.
- Use `list applications` / `list domains` when you need exact filter values or names.

## Guardrails for the output

- Do NOT guess. Ground answers on explicit evidence from search/frame/image results. Be transparent if data is not found.
- Hide technical internals from the user (no SQLite/FTS5/XPC jargon unless they ask).
- Avoid dumping huge OCR blobs unless needed; prefer targeted search + a few frame confirmations.
- Never start or stop capture, capture once, compact, or apply retention unless the user specifically requested that action. Read-only history access remains the normal assistant mode.
- Screenlogger stores and queries the Library locally. Never imply Screenlogger cloud sync or remote database access, and do not promise that a third-party assistant is offline; its provider may process the query and CLI output.
