# Command Line Interface

The `screenlog` command is a client of the running Screenlogger app. It does not
open the SQLite database directly.

Install it from Settings under Integrations, then verify the connection:

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

Library search accepts the same `app:`, `site:`, `date:`, `since:`, and
`before:` refinements used by the app. Literal search keeps punctuation-heavy
token sequences adjacent; it is not a byte-for-byte substring search. Nearby
deduplication reduces repeated captures but does not count unique events.

## Activity summaries

```sh
screenlog usage coverage --since 30d --json
screenlog digest --since 30d --json
screenlog usage time --since 2026-08-01 --before 2026-09-01
screenlog usage top-applications --since 7d
screenlog usage top-domains --since 7d
screenlog usage sessions --since 7d --gap 10
```

All activity bounds are half-open: `--since` is included and `--before` is
excluded. They accept local ISO-8601 timestamps, epoch seconds or milliseconds,
and durations before now such as `30d`, `12h`, or `2w`.

Capture cadence varies, so moment counts are not seconds. Capture span is
session wall-clock span, not active attention or project time. Application and
domain shares can overlap when multiple displays are captured.

## Capture and maintenance

```sh
screenlog record start
screenlog record stop
screenlog record once
screenlog compact
screenlog retention
```

These commands require Allow capture control and maintenance in Screenlogger
Settings. Search and status remain read-only.

## Automation contracts

Use `--json` where available. Samples include `nextCursorMs` for bounded paging.
Frame evidence includes local timestamps, application and domain context, and
optionally bounded OCR. It omits media paths. Status, diagnostics, and
assistant-readiness JSON use versioned schemas and stable issue codes. Private
Library and socket paths are not included.

Run `screenlog --help` and `screenlog <command> --help` for the current command
reference.
