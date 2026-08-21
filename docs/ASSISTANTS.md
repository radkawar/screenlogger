# Assistant Integrations

Screenlogger supports Claude Code, Codex, Cursor, Grok Build, and OpenClaw.
Integrations install a small skill that teaches the assistant to call the local
`screenlog` command.

## Setup

1. Open Settings and choose Integrations.
2. Complete Terminal Access and command verification.
3. Connect an installed assistant.
4. Restart that assistant if Screenlogger requests it.
5. Run Test Search to verify Screenlogger's local command path.
6. Try a small Library search from each connected assistant before relying on it.

The same lifecycle is available from Terminal:

```sh
screenlog skill install
screenlog skill status all
screenlog skill upgrade grok
screenlog skill remove codex
```

Install is idempotent. Upgrade replaces only authenticated stale content. Remove
does not delete unrelated files and stops on conflicts unless the user explicitly
chooses a recovery action.

After an integration has been installed, launching a newer Screenlogger build
updates its Screenlogger-owned skill copy automatically. Missing integrations
are not installed implicitly, and unrelated or blocked destinations are left
for explicit review in Settings.

## Search handoff

Command-Return from Library search opens the configured assistant. If one ready
assistant exists, Screenlogger can route directly. If several are ready, the
routing preference can ask every time or select a preferred target.

Terminal-based assistants launch in Apple Terminal through macOS Automation.
Each target receives an isolated working directory so
project pickers and unrelated repository context do not intercept the request.

## Privacy boundary

Screenlogger sends the assistant a request to search the local Library. The
assistant decides how to execute tools and may send retrieved material to its AI
provider. Review the assistant's privacy settings. External command access is
read-only unless Allow capture control and maintenance is enabled separately.
