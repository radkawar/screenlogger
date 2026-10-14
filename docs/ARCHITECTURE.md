# Architecture

Screenlogger has four product targets:

- `Screenlogger.app` owns capture, permissions, preferences, the Library, and
  all database writes.
- `screenlog` is a bounded local client used by Terminal and assistants.
- `ScreenlogCore` contains capture, recognition, storage, search, retention,
  exclusions, permissions, and local IPC.
- `screenlog-semantic-worker` runs the optional local model on Apple silicon.
  It has no database handle or model downloader.

## Capture path

The capture engine reads one ScreenCaptureKit snapshot.
The Capture setting selects the active display or all connected displays.
Successful images from one all-display capture share a timestamp.
Each image also has its global display geometry.
Screenlogger removes excluded applications from each ScreenCaptureKit content
filter before capture. Website protection follows the active browser.

Recognition and storage run separately for each display.
A failure on one display does not discard successful images from other displays.
Capture pauses for missing permissions, excluded foreground activity,
uncertain website identity under strict protection, or low disk space.
Capture also pauses for inactivity when that option is on.

## Audio transcription path

Audio Transcription is a separate optional feature for macOS 26 or later.
ScreenCaptureKit supplies separate PCM streams for computer audio and microphone audio.
Screenlogger checks capture readiness and privacy conditions before it accepts samples.
It sends allowed samples to separate SpeechAnalyzer pipelines.
These pipelines use Apple's on-device SpeechTranscriber and SpeechDetector modules.

The stream initially rejects samples.
Application activation immediately stops sample acceptance.
An exclusion-filter update failure pauses transcription.

Screenlogger associates final transcript segments with the nearest saved Timeline
moment. It indexes these segments in a separate FTS table.
Audio streams stay in memory. Screenlogger creates no audio file.
It labels microphone segments You and computer audio segments Computer.
Moment deletion also removes the associated transcript and search-index rows.

## Timeline model

A timestamp identifies one Timeline moment.
A single-display moment has one frame.
An all-display moment can have several frames with different display geometry.
Timeline shows one display at its natural aspect ratio.
A display selector appears when the selected moment has multiple displays.

Time navigation and replay move between timestamps.
They keep the selected display when possible.
Queries limit and count moments, not physical frames.
Search can open the specific display that matched.
Moment deletion removes all display frames at that timestamp.

Compaction puts each display geometry in a separate video sequence.
It does not mix simultaneous frames into one movie.

## Storage

The app process controls SQLite access.
SQLite uses WAL mode.
Schema migrations use transactions.
Search uses FTS indexes.

Database rows reference managed still images and compressed videos.
Maintenance, backup, restore, and deletion operations verify these references.
An automatic migration starts after app startup, independently of capture and Settings.
Each batch targets 32 rows or 4 MiB of source data.
A single payload can use more than the batch target, up to 32 MiB.
The migration commits each batch with its versioned cursor.
It preserves decoded content and raw hashes.
Its completion marker prevents later payload scans.

Database file reclamation uses a separate pending marker.
It waits at least 30 seconds after migration and requires stopped capture.
It waits for transfers, deletion, and manual maintenance to finish.
It requires approximately twice the database size plus 256 MiB of free space.
A checkpoint first checks for active readers that prevent completion.
Failures remain pending for another attempt after five minutes.

Payload migration can run while capture runs.
Reclamation closes local socket and XPC access and waits for active requests to finish.
It checks again that capture has stopped before it waits for old capture tasks.
An accepted capture-start request prevents reclamation.
During reclamation, the interface disables Start and Once.

Reclamation does not restart capture.
It reopens only previously running command services, if current settings still permit them.

## Session overview

Session names are user-authored metadata keyed by `session.name.<startMs>` in
the existing SQLite metadata table. The stable start timestamp keeps a name
attached as a live session grows. Reset removes the override; existing whole-
database backups include names without a new sidecar or schema migration.

The session overview distinguishes elapsed duration from recorded coverage.
Coverage follows Timeline's cadence threshold and midpoint attribution, excludes
capture gaps, and counts simultaneous displays once. Aggregates return the top
eight applications and websites plus six temporal sample moments, not complete
OCR payloads or decoded images. Representative moments support inspection;
they are not an AI-generated narrative of intent.

## Related search

Exact search keeps the existing FTS path. Related search is a separate, optional path.
Images compares screen appearance. Text compares screen text and transcripts.
Images and text enables both sources. All modes are off by default.

The app downloads pinned model data only after approval.
The worker uses owned Swift encoders, Apple MLX, and Hugging Face Tokenizers.
It does not use a model wrapper or llama.cpp.
The text and image encoders share a 768-value output space.
Image preparation uses sRGB, a 2,048-pixel side limit, and 280 image tokens.
The encoder uses the canonical bicubic antialias resize.
Text uses 512-token chunks with a 64-token body overlap.
Each document chunk keeps its title and required model prefix.

Schema 9 stores vectors, source references, and content hashes in ordinary SQLite tables.
Equal prepared images and text chunks share vectors.
Each background batch admits at most 256 source candidates.
Persisted cursors resume this work after a restart.
Capture triggers cannot advance a cursor past older pending sources.
Deletion removes derived references in the source transaction.
Compaction preserves completed image vectors and replaces stale pending work.

Queries use exact application, website, and time filters before similarity ranking.
Library filter choices replace conflicting constraints of the same kind, whether
chosen in the sidebar or entered as query operators. Compatible app and website
filters stay combined. Date and session scopes stay combined only when their time
ranges overlap. Selected facets remain visible even when no results match.
Images-only meaning search disables the transcript filter and resets an existing
transcript selection to All content.

Scores are cosine similarity, not confidence.
The worker gives queries priority over background work.
Automatic indexing waits for external power and 60 idle seconds.
Index Now bypasses those waits until the backlog is complete.
Low Power Mode, high temperature, and memory pressure pause both policies.
Pause, disable, configuration changes, and draining reset manual indexing.
Disable, restore, reclamation, and Quit stop and drain model work.
The worker also exits when its app parent exits.

## Process boundary

The CLI connects to the running app through a local socket protocol.
This protocol negotiates versions and limits data sizes.
It uses stable error documents.
It separates read access from access that changes data.
The CLI never receives a database handle.
The socket admits at most 16 clients and four concurrent semantic searches.
Independent requests do not wait behind model inference.
Stopping a listener closes admission. An asynchronous drain keeps each accepted
request's Store alive until that request finishes.

## Project generation

`project.yml` defines the XcodeGen project.
The repository includes `Screenlog.xcodeproj` so contributors can open it immediately.
CI regenerates the project.
CI fails when the included project differs from the generated project.

## Platform frameworks

The implementation uses public Apple frameworks including SwiftUI, AppKit,
ScreenCaptureKit, Vision, Speech, AVFoundation, ApplicationServices,
ServiceManagement, OSLog, and Core Graphics, plus system SQLite and compression
libraries.

## Updates

Sparkle provides the native update interface, atomic app replacement, and restart.
It reads a signed appcast from the project's GitHub Pages site.
It downloads DMGs from the project's GitHub Releases.
The app requires a signed feed.
It also requires Ed25519 archive verification before extraction.

The maintainer keeps the private key outside the repository.
The key resides in the maintainer Keychain and protected `release-signing`
GitHub Environment. The updater delegate blocks every update check when Keep
Screenlogger Offline is on.

GitHub releases also use Developer ID signatures, Hardened Runtime, and Apple notarization.
The app and DMG both include stapled tickets.
