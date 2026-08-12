# Architecture

Screenlogger has three product targets:

- `Screenlogger.app` owns capture, permissions, preferences, the Library, and
  all database writes.
- `screenlog` is a bounded local client used by Terminal and assistants.
- `ScreenlogCore` contains capture, recognition, storage, search, retention,
  exclusions, permissions, and local IPC.

## Capture path

The capture engine reads one ScreenCaptureKit snapshot and captures either the
active display or every connected display, according to the Capture setting.
Every successful image from an all-display interval receives the same timestamp
and its global display geometry. Excluded applications are removed from each
ScreenCaptureKit content filter before pixels are captured. Website protections
continue to follow the active browser.

Recognition and storage run independently for each captured display. A partial
display failure does not discard the other successful images. Capture pauses on
missing permission, excluded frontmost activity, strict privacy uncertainty,
inactivity when enabled, or low disk space.

## Audio transcription path

Audio Transcription is an independent opt-in available on macOS 26 or later.
ScreenCaptureKit emits separate computer-audio and microphone PCM streams.
Screenlogger gates both streams on capture readiness and the current privacy
context, then sends them to independent SpeechAnalyzer pipelines using Apple's
on-device SpeechTranscriber and SpeechDetector modules. The stream starts fail
closed, application activation closes its sample gate immediately, and an
exclusion-filter update failure pauses transcription.

Finalized transcript segments are associated with the nearest saved Timeline
moment and indexed in a dedicated FTS table. The streams remain in memory; no
audio file is created. Microphone segments are labeled You and system-audio
segments are labeled Computer. Deleting a moment cascades to its transcript and
search-index rows.

## Timeline model

A timestamp is one Timeline moment. A single-display moment has one frame; an
all-display moment can have several frames distinguished by display geometry.
The Timeline shows one display at its natural aspect ratio with a display
switcher when the selected moment contains more than one. Time navigation and
replay advance between timestamps and preserve the chosen display when possible.

Queries limit and count moments rather than physical frames. Search may open the
specific display that matched. Deleting a moment removes every display frame at
that timestamp. Compaction groups each display geometry into its own video
sequence so simultaneous frames are never interleaved into one movie.

## Storage

SQLite runs in WAL mode and is owned by the app process. Schema migrations are
transactional. Search uses FTS indexes. Managed stills and compacted videos are
referenced from database rows and verified by maintenance, backup, restore, and
deletion operations.

## Process boundary

The CLI connects to the running app through a local socket protocol with explicit
version negotiation, bounded payloads, stable error documents, and separate
read-only versus mutation capabilities. It never receives a database handle.

## Project generation

`project.yml` is the XcodeGen source of truth. `Screenlog.xcodeproj` remains
checked in so contributors can open the project immediately. CI regenerates it
and fails when the checked-in project differs.

## Platform frameworks

The implementation uses public Apple frameworks including SwiftUI, AppKit,
ScreenCaptureKit, Vision, Speech, AVFoundation, ApplicationServices,
ServiceManagement, OSLog, and Core Graphics, plus system SQLite and compression
libraries.

## Updates

Sparkle provides the native update interface, atomic app replacement, and
relaunch behavior. It reads a signed appcast from the project's GitHub Pages
site and downloads DMGs from the project's GitHub Releases. The app requires
both a signed feed and pre-extraction Ed25519 archive verification. The private
key is held outside the repository in the maintainer Keychain and the protected
`release-signing` GitHub Environment. Keep Screenlogger Offline gates every
update check through the updater delegate. GitHub releases are separately
protected with Developer ID, Hardened Runtime, Apple notarization, and stapled
tickets on both the app and DMG.
