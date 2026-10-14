---
name: screenlog-cli-skill
description: Search the user's past activity with the screenlog CLI. Use local screenshots, screen text, optional transcripts, and application or domain metadata. Use this skill for questions about past actions, observed content, research, or time spent.
---

# Screenlogger CLI Skill

Screenlogger keeps captured screens and searchable metadata in a local Library.
Optional audio transcription runs on this Mac and stores final text, not audio.
Screenlogger does not upload the Library or require a cloud account.
An external assistant's provider may process CLI commands and output.

The CLI is `screenlog`, often at `~/.local/bin/screenlog`.
Screenlogger.app must run because the CLI uses the app's local connection.
Skill management commands are the exception.
Use `screenlog -h` for the command list.
Use each command's `--help` for its exact flags.
If the app is unavailable, ask the user to open it before you retry.

Do not guess from history when the app is unavailable.

## Commands

### Coverage and usage

- `screenlog digest [--since DATE|30d] [--before DATE] [--gap MIN] [--limit N] [--sample-limit N] [--json]`
  Coverage, capture span, active days, applications, domains, sessions, and sampled segment evidence. `overview` is an alias.
- `screenlog usage coverage [--since DATE|30d] [--before DATE] [--gap MIN] [--json]`
  Observed endpoints, active days, and sessions and breaks at the selected gap threshold.
- `screenlog usage time [--since DATE|30d] [--before DATE] [--json]`
  Capture span and moment/frame counts, not attention time.
- `screenlog usage top-applications|top-domains [--since DATE|30d] [--before DATE] [--limit N] [--json]`
  Captured-moment shares.
- `screenlog usage sessions [--since DATE|30d] [--before DATE] [--gap MIN] [--json]`
  Continuous blocks with breaks at the selected gap.
- `screenlog list applications|domains`
  Exact recorded filter values.

### Search and inspect

- `screenlog search <QUERY> [--content all|screen|transcripts] [--literal] [--dedupe-seconds N] [--limit N] [--json]`
  Library search with `app:`, `site:`, `date:`, `since:`, and `before:` operators. `query fts` is the lower-level alias.
- `screenlog query sample [--since DATE|30d] [--before DATE] [--order oldest|newest] [--cursor DATE] [--limit N] [--min-seg-len N] [--show-ocr] [--max-ocr-chars N] [--json]`
  Frames from qualifying segments across time. `--cursor` samples the remaining range after or before the cursor timestamp again.
- `screenlog query frame --id N | --ids N,N,N | --at DATE [--show-ocr] [--max-ocr-chars N] [--json]`
  One frame or a batch of frame IDs.
- `screenlog query context --id N [--before N] [--after N] [--show-ocr] [--max-ocr-chars N] [--json]`
  Adjacent captured moments around a selected frame.
- `screenlog recent [--limit N] [--show-ocr] [--max-ocr-chars N] [--json]`
  Newest captured moments.
- `screenlog query image --id N | --at DATE [--out PATH] [--base64] [--json]`
  Screenshot export. Top-level `image` is an alias.
- `screenlog query ocrboxes --id N` / `screenlog query axtree --id N`
  OCR geometry or the captured accessibility tree, when available.

Timestamps accept local ISO-8601 time or epoch seconds and milliseconds.
Activity ranges also accept durations before now, such as `30d`, `12h`, and `2w`.
The range includes `since` and excludes `before`.
Use `--json` for analysis.
Set OCR length limits explicitly.

### Optional semantic search

1. Run `screenlog semantic status --json` before related search.
   Check enabled mode, installed models, phase, and indexed, pending, and failed source counts.
   Disabled, unavailable, or empty indexes are not evidence that matching history does not exist.
   Status and queries never install or enable anything.
2. Choose the relevant source: `images` for screen appearance, `text` for screen text and transcripts,
   or `both` for both sources. A query can narrow enabled sources, not enable a different source.
   Omit `--mode` to use the configured sources.
3. Run `screenlog query semantic <QUERY> [--mode images|text|both] [--limit 1...500] [--json]`.
   Use one quoted QUERY or `--query <QUERY>`, not both.
   Include `app:`, `site:`, `date:`, `since:`, or `before:` inside the query to restrict private output.
   Example: `screenlog query semantic 'a blue chart app:Safari since:2026-10-01' --mode images --limit 10 --json`.
4. Treat each semantic hit as a candidate. `score` is cosine similarity, not confidence or probability.
   Use `result.frameID` with `query frame --id N --show-ocr --max-ocr-chars 1000 --json`.
   Inspect `query image --id N --json` for visual claims and `query context --id N --json` for context.
   Do not invent lexical highlights or treat a visual match as an exact text match.
5. Cite the verified frame ID, local timestamp, application or domain, and relevant transcript interval.
   State what was observed separately from what you inferred.
   Report partial indexing and failed sources. Repeated occurrences are not unique events or time spent.

Use exact `search` or `query fts` for identifiers, version numbers, names, and codes.
Semantic similarity can miss exact identifiers or return a different one.
Use the same date and application filters when checking candidates with exact search.
Do not upload captured images or text to another service without authorization.

Get user approval before you use the commands below. Tell the user which action and source mode you will use.

- `screenlog semantic download --mode images|text|both --yes`
- `screenlog semantic enable --mode images|text|both --yes`
- `screenlog semantic disable|pause|resume|index-now|remove-index|remove-models --yes`

Select one command and one mode from the alternatives above.
Do not use these commands only because a search fails.
These commands require **Allow capture control and maintenance** in **Settings > Integrations**.
The `download` command installs model files. It does not turn on search.
Use `status` to check the download before you use `enable`.
The `enable` command does not download model files.
The `index-now` command processes pending work without waiting for inactivity or external power.
It requires enabled search and installed models. It does not download or enable anything.
The `resume` command returns to automatic indexing. Check `indexingPolicy` in status.
Offline mode prevents downloads.
The `remove-index` command removes the search index. It does not remove captured history.
The `remove-models` command removes downloaded model files.
Get user approval before you use `--yes`. There is no `--dry-run` option.
Semantic commands require IPC protocol 3.
If the app does not support these commands, use exact search or ask the user to update the app.


## Interpret the data truthfully

- A moment is one synchronized capture timestamp. Physical frames can include multiple displays.
  Capture intervals vary with settings, power state, skipped unchanged screens, and periodic captures.
  Do not convert moment or frame counts to time with an assumed two-second interval.
- Capture span is the sum of session clock durations at the selected gap threshold.
  It is not active attention, exclusive application time, or project time.
- Active days are local calendar days that observed sessions include.
  Session breaks are gaps at or above `--gap`.
  These breaks do not prove that history outside the sessions is missing.
  First and last timestamps alone do not prove complete coverage of a requested range.
- A session's `startingBundleID` and `startingDisplayName` describe its earliest frame.
  They do not identify its main application or purpose.
- Application and domain shares can overlap across displays.
  Treat them as screen exposure, not exclusive intent or time allocation.
- Digest and `query sample` select qualifying segments across the requested time range.
  Their selection is not random, complete, or proportional to duration.
  The selected frame occurs early in its segment.
  Claims about long periods need evidence across days and sessions.
- `--literal` keeps tokenizer terms adjacent and in order.
  It does not match punctuation byte for byte.
  `--dedupe-seconds` suppresses only nearby results with matching application, domain, and normalized snippet fingerprint.
  It reduces repetition but does not count unique events.
- OCR and transcripts can be incorrect.
  Visible or audible content proves exposure only.
  It does not prove authorship, agreement, intent, or creation at capture time.
- Missing fields mean unknown values, not evidence of absence.
  Results include OCR only with `--show-ocr`.
  `--max-ocr-chars` truncates that text.

## Coverage-first reconstruction

1. Identify the requested local time range.
   For phrases such as "last month," state the exact calendar or rolling range.
   Ask a question only if that distinction changes the answer.
2. Run `screenlog doctor`.
3. Run `screenlog usage coverage --json` without date limits for the Library's observed range.
4. Request coverage for the specified date range.
   Report its overlap with observed history, active days, threshold gaps, and important missing history before your analysis.
5. Run one date-bounded `screenlog digest ... --json` for an initial summary.
   Do not treat its applications, domains, capture span, or sampled frames as a complete description of intent.
6. For a long interval, inspect different days and sessions with date-bounded `query sample` requests.
   Add narrower day or session samples where the initial evidence is insufficient.
   Do not only increase one overall limit.
7. Identify possible activities from repeated repository, domain, application, title, OCR, and transcript evidence.
8. Request likely frame IDs together with `query frame --ids ...`.
9. Use `query context` around uncertain evidence.
10. Check major claims against multiple observations that are not adjacent.
    Prefer observations from different sessions or days.
11. Use `search` to test possible activity names or find supporting moments.
12. Use `--literal` for token sequences that contain punctuation.
13. Use `--dedupe-seconds` to reduce adjacent copies.
    Never estimate project time or importance from search-result counts.
14. Report observed coverage, inferred activities, confidence, passive or uncertain content, and missing history separately.
    Distinguish capture span from inferred activities.
    Do not give exact project-time claims without stronger structured evidence.

Start with small result limits.
Use date ranges and cursors to limit output.
Request frame IDs in batches.
Limit OCR length.
Use `--content screen` for visible words.
Use `--content transcripts` for speech.

Omit `--content` when either source is useful.

## Safety and skill management

History access only reads data by default.
Never run `record start|stop|once`, `compact`, or `retention` unless the user specifically requests that action.
These commands also require the user to enable the Screenlogger integration permission.
Do not ask the user to enable this permission for a task that only reads data.

`screenlog skill install|status|upgrade|remove [TARGET]` manages assistant copies without Screenlogger.app.
Use `--force` only when the user explicitly requests replacement or removal of a conflicting path.
For automation, `skill status --json` emits schema-v1 status before it exits.
Exit code 0 means ready, 1 means not ready, and 2 means invalid usage.
Follow the recovery records without inferring private paths.

Do not disclose storage paths without a task requirement.
Do not return large OCR blocks without a task requirement.
Never imply cloud synchronization or remote Library access.
Review the assistant's settings before you share output.
Review its privacy policy before you share output.
Do not promise that a third-party assistant works without a network connection.
