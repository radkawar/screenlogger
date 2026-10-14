# Development

## Requirements

- macOS 14 or later
- full Xcode with Swift 6.3 or later and the Metal toolchain
- Git

The repository includes a launcher for a fixed XcodeGen version.
The launcher downloads that version into the ignored `.tools` directory when necessary.
Install the Metal toolchain if Xcode does not include it:

```sh
xcodebuild -downloadComponent MetalToolchain
```

The app, Core, and CLI support both Mac architectures.
The optional model worker and its numerical tests require Apple silicon.

## Build and test

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
Scripts/check-repository.sh
xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests UITests
swift test
Scripts/xcodegen.sh generate
Scripts/build.sh
```

Run app presentation tests with the `ScreenlogAppTests` scheme.
Run encoder and pipe-framing tests with the `ScreenlogSemanticTests` scheme.
Run UI tests with `Scripts/test-ui.sh`.
UI fixtures use separate temporary data and preferences.
They do not access the user's Library or macOS permission database.

## Source layout

```text
Sources/ScreenlogApp       Application state, services, and SwiftUI views
Sources/ScreenlogCLI       Terminal client and skill lifecycle
Sources/ScreenlogCore      Capture, recognition, storage, search, and IPC
Sources/ScreenlogSemanticWorker Owned local text/image encoders and private pipe transport
Tests                      Unit and integration tests
UITests                    Routed application and visual regression tests
Tools/ScreenlogPerformance Deterministic performance harness
Scripts                    Build, install, validation, and release automation
Packaging                  DMG presentation assets and archive instructions
```

## Repository rules

- Keep tracked text ASCII-only.
- Use Screenlogger for the product name.
- Use `screenlog` for the command name.
- Follow the language policy in [styling.md](styling.md) for user-facing text and documentation.
- Keep app-controlled database access behind `Store` and the IPC interface.
- Use permission checks without prompts outside explicit user actions.
- Preserve user content when installations, restores, deletions, or upgrades fail.
- Do not commit build products, test evidence, personal data, or scratch files.
