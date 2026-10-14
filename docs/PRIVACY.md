# Privacy

Screenlogger keeps the Library on this Mac. The app controls database access.

## Stored content

Enabled features determine which data a captured moment contains:

- a screenshot;
- recognized foreground and background text;
- application identity and window title;
- website domain and address, when Accessibility supplies them;
- final microphone or computer audio transcript text, when Audio Transcription is on;
- an accessibility snapshot with size limits;
- capture time, display metadata, and search indexes.
- derived image or text vectors, when Related search is on.

Screenlogger uses this default Library location:

```text
~/Library/Application Support/dev.screenlog/
```

The CLI and assistant integrations use a local connection while Screenlogger
runs. This connection limits request and response sizes.

## Permissions

Screenlogger requires Screen Recording and Accessibility for capture.
Without Accessibility, it cannot reliably identify browser websites or apply
all exclusions that depend on context. Permission checks use macOS preflight
APIs. These checks do not capture content.

Screenlogger requests Automation access only when you choose to start an
assistant in Terminal.

Audio Transcription is off by default. It requires macOS 26 or later.
The Microphone source requests microphone access only after you enable the
feature. Computer Audio uses Screen Recording access. macOS may also request
permission to capture computer audio.

## Exclusions

You can exclude applications and websites in Settings. Screenlogger includes
project-maintained lists of common password managers and financial services.
These lists do not cover every service or guarantee protection.
Add services that you use before you work with sensitive information.

Private Browsing protection depends on Accessibility context.
Capture pauses if strict protection is on and Screenlogger cannot identify
the current website.

Browser accessibility snapshots include only the focused window, not background
windows or application menus. Page content has its own bounded depth budget so
browser toolbar nesting does not cut off the page text. A window change during
extraction discards the snapshot. Complex pages can still produce partial trees.

Website attribution reads only the browser's focused window. It uses the
top-level page address exposed by Accessibility, or the focused window's
document address when the page does not expose one. It does not borrow an
address from another window, page links, or editable fields. Blank or internal
pages, ambiguous page information, and Accessibility timeouts leave the
website unknown; strict protection pauses capture in that case.

Audio uses the same application and website exclusions as screenshots.
Audio always pauses in Private Browsing and while Screenlogger is the active
application. It also pauses when capture cannot save a corresponding Timeline
moment. Screenlogger excludes its own process from the computer audio stream.
macOS cannot reliably identify the website for audio from a background browser
tab. An allowed foreground tab can therefore coexist with audio from another tab.

## Audio transcription

Screenlogger uses Apple's on-device Speech framework. It processes microphone
and computer audio as separate PCM streams in memory. It labels their
transcripts You and Computer. Screenlogger stores and indexes only final text
with timestamps. It does not create or keep an audio recording.
It does not use a remote speech service if local transcription fails.

macOS may need to download the Apple language model when you first enable
Audio Transcription.

## Related search

Meaning search is off by default. In Settings > Search, choose Images, Text, or Images and text.
Model downloads require approval. Opening Search settings does not download models or enable indexing.
Enable the feature only for sources that you want to index.
Images uses captured screens, not OCR as a substitute.
Text uses screen text and final transcripts. It does not use audio recordings.

The model runs in a separate local process. Queries and captured content stay on this Mac.
The derived index can reveal the meaning of captured content. Treat it as private Library data.
Disabling the feature stops its work but keeps its index and model files.
Remove Index deletes the derived index, not captured history.
Remove Models deletes model files and disables the feature. It keeps the index.
Deleting captured history also removes its derived index references.

Model files use a separate location:

```text
~/Library/Application Support/dev.screenlog.models/
```

## Network access

Capture, text recognition, indexing, search, and Library maintenance do not
require a network connection. Audio transcription runs without a network
connection after macOS installs the selected Apple speech model.
Related search also runs without a network connection after its model download.
Model downloads contact Hugging Face. They do not send captured content or search text.
Keep Screenlogger Offline blocks these downloads and cancels an active model download.

Website icon downloads are off by default. When you enable them, Screenlogger
sends only a domain name to DuckDuckGo's public icon endpoint. This feature
does not send screenshots, recognized text, full page addresses, or Library
identifiers.

Update checks are off by default. Automatic or manual checks request the signed
update feed from `radkawar.github.io`. Update downloads request the selected
DMG from `github.com/radkawar/screenlogger`. These requests exclude Library
content, searches, captured metadata, and system profiles.
Keep Screenlogger Offline stops both automatic and manual update checks.

## Assistant integrations

Screenlogger sends a search request with size limits to the selected assistant.
It asks the assistant to use the local `screenlog` command. The assistant may
send the request and retrieved content to its configured provider.
The assistant controls this transmission, not Screenlogger.
Review the assistant's account settings before you connect it.
Review its privacy settings before you connect it.

External command access only reads data by default. To permit capture control
or Library maintenance, enable the separate option in Integrations.
