# Contributing

Screenlogger is a native macOS application in Swift.
Changes must preserve privacy, predictable native behavior, and tested release requirements.

## Before making a change

- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- Follow [docs/styling.md](docs/styling.md) for interface work and user-facing language.
- Add or update tests for behavior changes.
- Do not read, modify, or commit a real Screenlogger Library.
- Do not add generated output, local paths, credentials, or text from other products.

## Local checks

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.4.1.app/Contents/Developer
Scripts/check-repository.sh
xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests UITests
swift test
Scripts/xcodegen.sh generate
git diff --exit-code -- Screenlog.xcodeproj/project.pbxproj
Scripts/build.sh
```

Use the CI-pinned Xcode 26.4.1 / Swift 6.3 formatter. Newer formatters can
produce a different import order and fail the release formatting gate.
Concurrent tests of blocking socket clients must use dispatch workers, not
occupy Swift's cooperative pool while waiting for the async server.

Run `Scripts/test-ui.sh` after changes to navigation, accessibility labels,
permission presentation, Library, Timeline, or Settings.
Run `Scripts/measure-performance.sh` after changes to search, media decoding,
Timeline loading, capture intervals, or storage queries.

## Pull requests

Describe the user-visible result, privacy effects, failure behavior, and tests.
Keep changes related to one purpose.
Do not combine unrelated changes without a clear reason.

## Releases

Only maintainers create version tags and publish artifacts.
Follow [docs/RELEASING.md](docs/RELEASING.md) for releases.
