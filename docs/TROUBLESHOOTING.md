# Troubleshooting

## Screenlogger is missing from a permission list

Install the app in Applications first.
In Setup, choose Show in Finder.
If Add cannot find Screenlogger, drag the stationary app tile into the open
System Settings permission list.
Do not set up permissions from the mounted DMG.

## Permission still appears disabled

Return to Screenlogger.
Choose Refresh.
Screen Recording changes can require you to quit and reopen the app.
Screenlogger does not repeat a permission request after your first explicit request.

## The CLI cannot connect

Open Screenlogger. Run these commands:

```sh
screenlog doctor
screenlog skill status all
```

If the shell cannot find the command, add `~/.local/bin` to the shell path.
Alternatively, reinstall Terminal Access from Settings.

## An assistant opens but does not run the request

Verify the assistant under Integrations.
Restart it after you install or update its skill.
Terminal assistants use a separate working directory to prevent project selection dialogs.
`screenlog skill status <target> --json` reports stable recovery codes.
It does not show private paths.

## Capture pauses

Open the menu or Capture Settings for the exact reason.
Common causes include missing permission, an exclusion, Private Browsing,
an unknown website with strict protection, inactivity, and low disk space.

## Audio transcription does not start

Audio Transcription requires macOS 26 or later.
It starts only while capture runs.
Open Capture Settings for its exact state.
The first start can take time while macOS installs an Apple speech model.
Microphone transcription also requires Microphone access.
Computer Audio can continue independently if you deny Microphone access.

## The SQLite database stays large after video compression

Video compression changes media files, not older accessibility data inside SQLite.
Screenlogger starts an automatic storage migration after app startup.
It also runs with capture off and Settings closed.
It compresses older accessibility data in small batches without deleting history.
It preserves decoded content and its hashes.
After an interruption, it resumes from the last committed batch.
After completion, it does not scan those records again.

Compression frees pages inside SQLite before the database file becomes smaller.
File reclamation is a separate operation.
It starts no earlier than 30 seconds after migration.
It requires stopped capture, not a timed capture pause.
It also waits for Library transfers, deletion, and manual maintenance to finish.

Payload migration can run while capture runs.
File reclamation temporarily closes local command access.
It also disables Start and Once until reclamation ends.
Reclamation never restarts capture automatically.
Screenlogger restores previously running command access only if current settings permit it.

Reclamation requires free space of approximately twice the database size plus 256 MiB.
An active database reader can block its checkpoint.
Screenlogger keeps reclamation pending if space, readers, or other conditions prevent completion.
It checks again after five minutes while reclamation remains pending.
Database file size, video savings, and filesystem allocation are separate measurements.

Settings can show Updating database storage or Database storage update pending.
After compression, it can show Database space reclamation pending or Reclaiming database space.
These states do not mean that Screenlogger has removed history.
There is no routine Optimize Database action.

Storage limits remove capture media but preserve searchable history.
They are not a complete-history deletion policy.

## Diagnostics

Use Settings under Support and About to export a diagnostics bundle with size limits.
It contains operational events and configuration summaries.
It does not contain captured screenshots or recognized text.
Review the bundle before you share it.
