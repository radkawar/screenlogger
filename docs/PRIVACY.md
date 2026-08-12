# Privacy

Screenlogger is designed around a Library owned by the app on this Mac.

## What is stored

Depending on enabled features, a captured moment can include:

- a screenshot;
- recognized foreground and background text;
- application identity and window title;
- website domain and address when Accessibility provides them;
- finalized microphone or computer-audio transcript text when Audio
  Transcription is enabled;
- a bounded accessibility snapshot for structured context;
- capture time, display metadata, and search indexes.

The default Library is:

```text
~/Library/Application Support/dev.screenlog/
```

The app is the sole database owner. The CLI and assistant integrations use a
bounded local connection while Screenlogger is running.

## Permissions

Screen Recording and Accessibility are both required for capture. Without
Accessibility, Screenlogger cannot reliably identify browser websites or apply
all context-dependent exclusions. Permission state checks use macOS preflight
APIs and do not capture content.

Screenlogger asks for Automation access only when the user chooses to launch an
assistant in Terminal.

Audio Transcription is off by default and available on macOS 26 or later. The
Microphone source asks for microphone access only after the person enables the
feature. Computer Audio uses the existing Screen Recording access and may also
surface the system audio-capture consent managed by macOS.

## Exclusions

Applications and websites can be excluded in Settings. Screenlogger also ships
small project-maintained defaults for common password managers and financial
services. These lists are convenience safeguards, not comprehensive guarantees.
Add services specific to your work before handling sensitive information.

Private browsing protection depends on Accessibility context. If Screenlogger
cannot determine a website while strict protection is enabled, capture pauses.

Audio uses the same application and website exclusions as screenshots. It
always pauses in Private Browsing, while Screenlogger is frontmost, and whenever
capture cannot save a corresponding Timeline moment. The current process is
also removed from the system-audio stream. An active background browser tab
cannot be attributed reliably to its website by macOS, so an allowed foreground
tab can coexist with audio from another tab.

## Audio transcription

Screenlogger uses Apple's on-device Speech framework. Microphone and computer
audio are processed as separate in-memory PCM streams and labeled You and
Computer. Only finalized, timestamped text is stored and indexed. Screenlogger
does not create or retain an audio recording and does not fall back to a remote
speech service. The required Apple language model may need to be downloaded the
first time the feature is enabled.

## Network access

Capture, text recognition, indexing, search, and Library maintenance do not
require a network connection. Audio transcription runs offline after macOS has
installed the selected Apple speech model.

Website-icon fetching is off by default. When enabled, Screenlogger sends only a
domain name to DuckDuckGo's public icon endpoint. It does not send screenshots,
recognized text, full page addresses, or Library identifiers for this feature.

Update checks are also off by default. When enabled or started manually,
Screenlogger requests its signed update feed from `radkawar.github.io` and the
selected DMG from `github.com/radkawar/screenlogger`. The request does not
contain Library content, searches, captured metadata, or a system profile. Keep
Screenlogger Offline suspends both scheduled and manual update checks while it
is enabled.

## Assistant integrations

Screenlogger prepares a bounded search request and asks the selected assistant to
use the local `screenlog` command. The assistant may send the request and any
retrieved content to its configured provider. That transmission is controlled by
the assistant, not Screenlogger. Review the assistant's account and privacy
settings before connecting it.

External command access is read-only by default. Capture control and Library
maintenance require a separate opt-in in Integrations.
