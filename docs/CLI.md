# Command Line Interface

The `screenlog` command is a client of the running Screenlogger app. It does not
open the SQLite database directly.

Install the command from Settings under Integrations. Use these commands to check the connection:

```sh
screenlog --version
screenlog doctor
screenlog status
```

## Search and inspect

```sh
screenlog search "invoice overdue" --limit 20
screenlog search "release 0.1.13" --literal --dedupe-seconds 30 --json
screenlog recent --limit 20
screenlog query frame --ids 42,57,81 --show-ocr --max-ocr-chars 1000 --json
screenlog query context --id 57 --before 3 --after 3 --show-ocr --json
screenlog query sample --since 7d --order newest --limit 40 --show-ocr --json
screenlog image --id 42 --out /tmp/frame.heic
screenlog list applications
screenlog list domains
```

Library search accepts the app's `app:`, `site:`, `date:`, `since:`, and
`before:` filters. Literal search keeps tokenizer terms adjacent and in order.
It does not match punctuation byte for byte. Nearby deduplication reduces
repeated captures but does not count unique events.

Search, recent, and sample limits are 1 through 500. The command resolves
`--out` paths relative to its working directory, not the app's directory.

## Optional related search

Exact `search` and `query fts` remain unchanged. Use them for identifiers, codes,
names, and exact token sequences. Semantic search finds related screen appearance
or meaning. It is off by default. It requires a compatible app and IPC protocol 3.
Older apps reject these commands; update the app and CLI together.
Help works without a running app.

```sh
screenlog semantic status --json
screenlog query semantic "a blue chart app:Safari since:2026-10-01" --mode images --limit 20 --json
screenlog query semantic --query "deployment discussion site:example.com date:2026-10-01" --mode text --json
```

`--mode` accepts `images`, `text`, or `both`. Images searches captured screen
appearance. Text searches screen text and transcripts. Both uses both sources.
A query can narrow the enabled sources, but it cannot enable another source.
Omit `--mode` to use the configured sources. The limit is 1 through 500.
Queries support the same `app:`, `site:`, `date:`, `since:`, and `before:`
operators as exact search. Quote the query or supply it once with `--query`.
Invalid dates, duplicate operators, and conflicting date ranges are rejected
instead of silently removing a constraint.

In Library, the Screens content filter includes image and screen-text matches
from the enabled sources. Transcripts limits results to transcript matches.

Status and queries are read-only. They never download, install, or enable models.
Obtain explicit user approval before each change below. Changes also require
Allow capture control and maintenance in Settings > Integrations.

```sh
screenlog semantic download --mode images --yes
screenlog semantic status --json
screenlog semantic enable --mode images --yes
screenlog semantic pause --yes
screenlog semantic resume --yes
screenlog semantic index-now --yes
screenlog semantic disable --yes
screenlog semantic remove-index --yes
screenlog semantic remove-models --yes
```

Download starts background installation and returns the current status promptly.
It does not enable search. Check status before enabling. Download requires network
access and is blocked in offline mode. Enable uses installed models only.
Automatic indexing waits for a minute of inactivity and external power.
`index-now` skips those waits until pending work is complete; it never enables
search or downloads models. Memory pressure, high temperature, and Low Power Mode
still pause indexing. `resume` restores automatic scheduling.
`remove-index` removes derived semantic data, not captured history.
`remove-models` removes downloaded model files.
Unknown, duplicate, and conflicting flags fail before IPC. These commands have
no `--dry-run` option. Only status and query accept `--json`.

Semantic query JSON contains `schemaVersion`, `scoreType`, `hits`, and `status`.
Each hit has `kind` (`image`, `screenText`, or `transcript`), cosine `score`,
`occurrenceCount`, and a privacy-safe `result` with frame ID, timestamp, title,
application, domain, snippet, and transcript interval when available.
It excludes internal media paths. Scores are similarity, not confidence or
probability. Inspect candidate frames and images before citing them as evidence.

Status includes source counts, pending and failed sources, vector bytes, mode,
phase, `indexingPolicy` (`automatic` or `manual`), and download progress. Results can cover only part of the Library while
indexing. A result limit and a partial index do not establish complete coverage.
Runtime failures in JSON mode include a stable `error.code` and safe message.
Query errors include current status when it is available. The command exits
nonzero on error. Private runtime paths and raw diagnostic messages are not
included in semantic JSON.

## Activity summaries

```sh
screenlog usage coverage --since 30d --json
screenlog digest --since 30d --json
screenlog usage time --since 2026-08-01 --before 2026-09-01
screenlog usage top-applications --since 7d
screenlog usage top-domains --since 7d
screenlog usage sessions --since 7d --gap 10
```

Activity ranges include `--since` and exclude `--before`. Both options accept
local ISO-8601 timestamps, epoch seconds or milliseconds, and durations before
now such as `30d`, `12h`, or `2w`.

Capture intervals vary, so moment counts are not seconds. Capture span measures
session clock time, not active attention or project time. Application and domain
shares can overlap when Screenlogger captures multiple displays.

## Capture and maintenance

```sh
screenlog record start
screenlog record stop
screenlog record once
screenlog compact
screenlog retention
```

These commands require Allow capture control and maintenance in Screenlogger
Settings. Search and status only read data. Commands that change data reject
extra arguments before they connect. There is no `--dry-run` flag.
Do not use an unsupported flag as a safety measure.

Screenlogger automatically migrates older accessibility data to compressed
storage. This migration is separate from video compression. Screenlogger can
resume an interrupted migration. It defers database file reclamation when it
cannot safely complete that step.

## Automation contracts

Use `--json` where available. Samples include `nextCursorMs`.
Use this value as `--cursor` to sample the remaining range again.
Sampling selects representative results. It does not return every result.

Frame evidence includes local timestamps, application and domain context, and
optional OCR text with length limits. It excludes media paths.
Status, diagnostics, and assistant-readiness JSON use versioned schemas and
stable issue codes. They exclude private Library and socket paths.

Run `screenlog --help` for the command list.
Run `screenlog <command> --help` for command details.
