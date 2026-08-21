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

- `screenlog search <QUERY> [--content all|screen|transcripts] [--literal] [--dedupe-seconds N] [--limit N] [--json]` - search screen text and transcripts together by default. Supports `app:`, `site:`, `date:`, `since:`, and `before:`. `--literal` keeps adjacent tokenizer terms together; it is useful for punctuation-heavy versions but is not a byte-for-byte substring search. `--dedupe-seconds` is only a nearby repetition heuristic.
- `screenlog query fts <QUERY> [--limit N] [--json]` - same search as `search` (lower-level alias)
- `screenlog query frame --id N | --ids N,N,N | --at <iso-or-epoch> [--show-ocr] [--max-ocr-chars N] [--json]` - inspect one or several frames without shell loops; OCR is opt-in and bounded
- `screenlog query context --id N [--before N] [--after N] [--show-ocr] [--max-ocr-chars N] [--json]` - inspect adjacent captured moments around a lead
- `screenlog query image --at ... | --id N [--out path] [--base64] [--json]` - export the screenshot (also available as top-level `screenlog image ...`)
- `screenlog query sample [--since DATE|30d] [--before DATE] [--order oldest|newest] [--cursor DATE] [--limit N] [--min-seg-len N] [--show-ocr] [--max-ocr-chars N] [--json]` - bounded, evenly distributed segment samples; page using the emitted cursor
- `screenlog recent [--limit N] [--show-ocr] [--max-ocr-chars N] [--json]` - inspect the newest captured moments without sampling the full Library
- `screenlog query ocrboxes --id N` - OCR boxes with pixel coordinates for a frame
- `screenlog query axtree --id N` - captured macOS accessibility tree for the frame (only if Accessibility was trusted when recording)

### Usage & inventory

- `screenlog digest --since 30d --before DATE --json` - coverage, capture span, active days, apps, domains, sessions, and bounded evidence for assistant synthesis
- `screenlog usage coverage [--since DATE|30d] [--before DATE] [--gap MIN] [--json]` - observed range, active days, sessions, and threshold-defined breaks
- `screenlog usage time|top-applications|top-domains|sessions [--since DATE|30d] [--before DATE] [...]` - every usage command accepts the same half-open date bounds
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

Timestamps (`--at`, `--since`, `--before`): ISO-8601 in the machine's local timezone (e.g. `2026-01-15T09:30` or `2026-01-15T09:30:45`), or epoch seconds / milliseconds. Activity bounds also accept durations before now such as `30d`, `12h`, and `2w`.

Output is compact by default; pass `--json` where supported for structured output.

## How to interpret the data (very important)

- Frames are screenshots of the whole interface the user was looking at. OCR is a strong but sometimes noisy signal - if something feels off, it might be misread letters or messy reading order.
- A result with `transcriptSource` set came from optional on-device transcription. `microphone` is the user's input; `computer` is audio played by the Mac. Transcript text can contain recognition mistakes, so confirm important claims with nearby results and context.
- Content visible in a frame was not necessarily *created* at capture time - look for embedded timestamps (message times, file dates) or infer timing from surrounding activity.
- Capture cadence varies with settings, power state, and unchanged-screen heartbeats. Moment counts are not seconds. Capture span is session wall-clock span, not active attention or project time.
- Sessions count synchronized timestamps, not physical displays. App and domain shares can overlap when several displays are captured and indicate exposure, not exclusive intent.
- Empty or missing fields mean unknown (e.g. no domain when the focused app was not a browser, or no AX tree when Accessibility was off).

## Search strategy

1. Resolve the requested local-time window. Treat "last month" as the previous calendar month and "past month" as rolling 30 days; otherwise state the exact half-open `[since, before)` range.
2. Run `screenlog doctor`, then compare unbounded and bounded `screenlog usage coverage --json`. State the observed intersection, active days, session breaks, and missing history before narrating.
3. Pull one bounded baseline with `screenlog digest --since ... --before ... --json`. Treat apps and domains as overlapping screen exposure, not intent or exact time.
4. Sample across the interval with bounded `query sample`, allocating additional pages to different days or sessions. Do not rely on one global sample for a long range.
5. Form candidate workstreams from repeated repository, domain, title, OCR, and transcript clues. Confirm each major claim with at least two non-adjacent observations, preferably across sessions or days, using `query frame --ids ...` and `query context`.
6. Use search to test candidate labels or find anchors. Never estimate project time or importance from search-hit counts; adjacent captures bias frequency.
7. Report observed coverage, inferred workstreams with confidence, passive or ambiguous content, and missing history separately.

## Tips

- Prefer `screenlog search` over saying "FTS" to the user - the user sees results, not engine names. (`query fts` is the same search.)
- Output can get large: use date bounds, `--max-ocr-chars`, batches, and sample cursors. Lower session gap thresholds reveal shorter breaks; higher thresholds merge more activity.
- Start with a small `--limit` and widen only if needed.
- Refine in one query when possible: `screenlog search 'invoice app:Safari site:example.com since:2026-07-01' --json`.
- For meeting or presentation speech, start with `screenlog search 'roadmap' --content transcripts --json`. For words visibly shown on screen, use `--content screen`. Omit `--content` when either kind of evidence is useful.
- Use `list applications` / `list domains` when you need exact filter values or names.

## Guardrails for the output

- Do NOT guess. A frame grounds visible state, not authorship or intent. Confirm OCR, transcript, and user-action claims with surrounding or repeated evidence and be transparent when history is missing.
- Hide technical internals from the user (no SQLite/FTS5/XPC jargon unless they ask).
- Avoid dumping huge OCR blobs unless needed; prefer targeted search + a few frame confirmations.
- Never start or stop capture, capture once, compact, or apply retention unless the user specifically requested that action. Read-only history access remains the normal assistant mode.
- Screenlogger stores and queries the Library locally. Never imply Screenlogger cloud sync or remote database access, and do not promise that a third-party assistant is offline; its provider may process the query and CLI output.
