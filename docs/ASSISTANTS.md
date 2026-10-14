# Assistant Integrations

Screenlogger supports Claude Code, Codex, Cursor, Grok Build, and OpenClaw.
Integrations install a skill that tells the assistant how to use the local
`screenlog` command.

## Setup

1. Open Settings.
2. Choose Integrations.
3. Complete Terminal Access.
4. Complete command verification.
5. Connect an installed assistant.
6. Restart that assistant if Screenlogger requests it.
7. Run Test Search to check Screenlogger's local command path.
8. Test a small Library search from each connected assistant before you use it for other work.

Terminal also provides these integration commands:

```sh
screenlog skill install
screenlog skill status all
screenlog skill upgrade grok
screenlog skill remove codex
```

Install does not change a current installation. Upgrade replaces only older
content that Screenlogger can authenticate. Remove preserves unrelated files.
It stops on conflicts unless you explicitly choose a recovery action.

A newer Screenlogger build automatically updates existing skill copies that
Screenlogger owns. It does not install missing integrations.
It leaves unrelated files and blocked locations unchanged for review in Settings.

## Search handoff

Command-Return from Library search opens the configured assistant.
Screenlogger can select the assistant directly when only one assistant is ready.
With several ready assistants, the routing preference can request a choice or
select a preferred assistant.

Terminal assistants start in Apple Terminal through macOS Automation.
Each assistant receives a separate working directory. This prevents project
selection dialogs and unrelated repository content from changing the request.

## Activity reconstruction

For broad questions, the bundled skill first checks coverage.
It then requests one digest for the specified date range.
It samples that range and checks supporting moments in batches.
It does not send one command per frame.
It does not treat adjacent search results as time spent.

Useful direct commands include:

```sh
screenlog usage coverage --since 30d --json
screenlog digest --since 30d --json
screenlog query frame --ids 123,456,789 --show-ocr --max-ocr-chars 1000 --json
screenlog query context --id 456 --before 3 --after 3 --show-ocr --json
```

Usage commands and sampling include `--since` and exclude `--before`.
Application and domain totals describe captured screen exposure.
They do not measure exclusive attention or project time.

## Privacy boundary

Screenlogger sends the assistant a request to search the local Library.
The assistant controls tool use and may send retrieved content to its AI provider.
Review the assistant's privacy settings.
External command access only reads data unless you separately enable
Allow capture control and maintenance.
