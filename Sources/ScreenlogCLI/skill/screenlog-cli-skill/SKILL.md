---
name: screenlog-cli-skill
description: Search and reconstruct the user's past activity from local screenshots, screen text, optional transcripts, and app or domain metadata with the screenlog CLI. Use for questions about what the user did, saw, heard, read, researched, or spent time around.
---

# Screenlogger CLI Skill

Screenlogger keeps a local Library of captured screens and searchable metadata on this Mac. Optional on-device audio transcription stores finalized text, not audio. Screenlogger does not upload the Library or require a cloud account, but an external assistant's provider may process CLI commands and output.

The CLI is `screenlog` (often `~/.local/bin/screenlog`). Screenlogger.app must be running because the CLI is a thin client; skill lifecycle commands are the exception. Use `screenlog -h` and per-command `--help` as the authoritative flag reference. If the app is unavailable, ask the user to open it and retry rather than guessing from history.

## Commands

### Coverage and usage

- `screenlog digest [--since DATE|30d] [--before DATE] [--gap MIN] [--limit N] [--sample-limit N] [--json]` - bounded coverage, capture span, active days, apps, domains, sessions, and time-spread segment evidence for synthesis; `overview` is an alias
- `screenlog usage coverage [--since DATE|30d] [--before DATE] [--gap MIN] [--json]` - observed endpoints, active days, and threshold-defined sessions and breaks
- `screenlog usage time [--since DATE|30d] [--before DATE] [--json]` - capture span and moment/frame counts, not attention time
- `screenlog usage top-applications|top-domains [--since DATE|30d] [--before DATE] [--limit N] [--json]` - captured-moment shares
- `screenlog usage sessions [--since DATE|30d] [--before DATE] [--gap MIN] [--json]` - contiguous blocks split at the selected gap
- `screenlog list applications|domains` - exact recorded filter values

### Search and inspect

- `screenlog search <QUERY> [--content all|screen|transcripts] [--literal] [--dedupe-seconds N] [--limit N] [--json]` - Library search with `app:`, `site:`, `date:`, `since:`, and `before:` operators; `query fts` is the lower-level alias
- `screenlog query sample [--since DATE|30d] [--before DATE] [--order oldest|newest] [--cursor DATE] [--limit N] [--min-seg-len N] [--show-ocr] [--max-ocr-chars N] [--json]` - time-spread frames from qualifying segments; `--cursor` re-samples the remaining range after/before the cursor timestamp
- `screenlog query frame --id N | --ids N,N,N | --at DATE [--show-ocr] [--max-ocr-chars N] [--json]` - inspect one frame or batch several IDs
- `screenlog query context --id N [--before N] [--after N] [--show-ocr] [--max-ocr-chars N] [--json]` - adjacent captured moments around a lead
- `screenlog recent [--limit N] [--show-ocr] [--max-ocr-chars N] [--json]` - newest captured moments
- `screenlog query image --id N | --at DATE [--out PATH] [--base64] [--json]` - export a screenshot; top-level `image` is an alias
- `screenlog query ocrboxes --id N` / `screenlog query axtree --id N` - OCR geometry or the captured accessibility tree when available

Timestamps accept local-time ISO-8601 or epoch seconds/milliseconds. Activity-command bounds also accept durations before now such as `30d`, `12h`, and `2w`; they are half-open: `since` is included and `before` is excluded. Prefer `--json` for synthesis and set OCR caps deliberately.

## Interpret the data truthfully

- A moment is one synchronized capture timestamp; physical frames may include multiple displays. Capture cadence varies with settings, power state, skipped unchanged screens, and heartbeats. Do not convert moment or frame counts to time by assuming two seconds.
- Capture span is the sum of threshold-defined session wall-clock spans. It is not active attention, exclusive application time, or project time.
- Active days are local calendar days touched by observed sessions. Session breaks are gaps at or above `--gap`; they are not proof that history outside those blocks is missing. First and last timestamps alone do not prove that a requested interval is fully covered.
- A session's `startingBundleID` and `startingDisplayName` describe its earliest frame, not its dominant application or purpose.
- Application and domain shares can overlap across displays. Treat them as screen exposure, not exclusive intent or time allocation.
- Digest and `query sample` spread selected qualifying segments across the requested time range, but they are not random, exhaustive, or duration-proportional. The chosen frame is early in its segment. Long-range claims still need evidence across days and sessions.
- `--literal` makes tokenizer terms adjacent and ordered; punctuation itself is not matched byte for byte. `--dedupe-seconds` suppresses only nearby results with matching app/domain and a normalized snippet fingerprint. It reduces repetition but does not count unique events.
- OCR and transcripts can be wrong. Visible or audible content proves exposure only, not authorship, agreement, intent, or that the content was created at capture time.
- Missing fields are unknown, not negative evidence. OCR is included only with `--show-ocr`, and `--max-ocr-chars` truncates it.

## Coverage-first reconstruction

1. Resolve the requested local-time window. For ambiguous phrases such as "last month," state the concrete calendar or rolling range; ask only when the distinction materially changes the answer.
2. Run `screenlog doctor`. Query unbounded `screenlog usage coverage --json` for the Library's observed extent, then bounded coverage for the requested range. Report the observed intersection, active days, threshold gaps, and material missing history before narrating.
3. Run one date-bounded `screenlog digest ... --json` for the baseline. Do not treat its apps, domains, capture span, or sampled frames as a finished account of intent.
4. For a long interval, inspect evidence across different days and sessions with bounded `query sample`. Add narrower day/session samples where the baseline is sparse rather than only increasing one global limit.
5. Form candidate workstreams from repeated repository, domain, application, title, OCR, and transcript clues. Batch likely frame IDs with `query frame --ids ...`; use `query context` around ambiguous leads. Confirm major claims with multiple non-adjacent observations, preferably across sessions or days.
6. Use `search` to test candidate labels or find anchors. Use `--literal` for punctuation-heavy token sequences and `--dedupe-seconds` to reduce adjacent copies. Never estimate project time or importance from search-hit counts.
7. Report observed coverage, inferred workstreams with confidence, passive or ambiguous content, and missing history separately. Distinguish capture span from inferred work and avoid exact project-time claims without stronger structured evidence.

Keep output bounded: start with small limits, use date ranges and cursors, batch IDs, and cap OCR. Search visible words with `--content screen`, speech with `--content transcripts`, or omit `--content` when either source is useful.

## Safety and lifecycle

Read-only history access is the default. Never run `record start|stop|once`, `compact`, or `retention` unless the user specifically requested that action. These commands also require the user-enabled Screenlogger integration permission; do not ask the user to enable it for a read-only task.

`screenlog skill install|status|upgrade|remove [TARGET]` manages assistant copies and does not require Screenlogger.app. Use `--force` only when the user explicitly wants to replace or remove a conflicting path. For automation, `skill status --json` emits schema-v1 status before exiting 0 when ready, 1 for non-ready states, or 2 for invalid usage; follow its remediation records without inferring private paths.

Do not expose storage paths or dump large OCR blocks without need. Never imply cloud sync or remote Library access. Review the assistant's own settings and privacy policy before sharing output, and do not promise that a third-party assistant is offline.
