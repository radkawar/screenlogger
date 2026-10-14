# Releasing

`Sources/ScreenlogCore/Resources/ProductVersion.xcconfig` defines the product version.
`MARKETING_VERSION` uses three-component semantic versioning.
Increase `CURRENT_PROJECT_VERSION` for every released build.

## v0.2.0 release notes

- Optional local Meaning search finds captured images and text by description.
  Choose Images, Text, or Images and text in Settings > Search; approve the
  model download before enabling indexing. Exact search needs no model.
- The native Swift encoders run in an isolated Apple-silicon worker using MLX
  and Hugging Face Tokenizers, not llama.cpp or an external model wrapper.
  Model data is downloaded separately, pinned by size and SHA-256, and is not
  included in the app or release archives.
- Search settings provide indexing progress, pause/resume, and removal of
  models or the derived index. Removing either does not remove captured history.
- Existing Libraries receive transactional schema updates and resumable local
  payload migration. Back up the Library before upgrading; do not assume a
  migrated Library can be reopened by an older release.
- Existing receipt-owned CLI and assistant-skill installations are refreshed
  on app launch. Unowned files and integrations you never enabled are preserved.
- Privacy settings no longer report an unmeasured Library size as "Zero KB";
  the size is shown only when a storage measurement is available.
- Timeline omits a repeated app name when the captured title adds no context.
- Source-mode changes invalidate stale Meaning requests; delayed Show in Sessions
  navigation no longer replaces a newer selection.
- Unavailable Meaning search is a disabled native menu action, not a selectable
  picker row whose value is rejected afterward.

Compatibility: the app, Core framework, and CLI target macOS 14+ on arm64 and
x86_64. Meaning search requires native Apple silicon; the semantic worker is
arm64-only. Universal packaging is not evidence of Intel or macOS 14 runtime
validation. Record actual hardware/OS results before claiming those platforms
were tested. Search relevance and performance measurements are not universal
quality or latency guarantees; see [Performance](PERFORMANCE.md).

Release acceptance is separate from these notes: do not describe v0.2.0 as
signed, notarized, or published until its final artifacts pass those gates.

## Trust anchors

Production releases use two separate signature systems:

- Developer ID Application signs the app, nested code, standalone CLI, and DMG.
  Every executable uses Hardened Runtime and a secure timestamp.
- Screenlogger's Ed25519 key signs the final DMG and update feed for Sparkle.

Apple notarizes the app, complete technical ZIP, and final DMG.
The app and DMG both include stapled tickets.
The protected `release-signing` GitHub Environment stores secrets.
It permits only `main` and `v*.*.*` tags.
Never print or commit a private key.
Never put a private key in a release asset.

CI and Release use the `macos-26` runner with Xcode 26.4.1 (Swift 6.3).
MLX 0.32.3 requires Swift 6.3; Xcode 26.3 cannot resolve that dependency.
This build-tool requirement does not change the app's macOS 14 deployment target.
Require the pinned CI app build before tagging: a newer local compiler can accept
SwiftUI expressions that exceed Swift 6.3's type-checking limit. Keep complex
Timeline layers in separate view-building functions.
Upstream semantic-runtime license notices are preserved verbatim; their Unicode
copyright symbols are exempt from the repository's ASCII-only source policy.

## Prepare

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
Scripts/verify-version.sh
Scripts/xcodegen.sh generate
git diff --exit-code -- Screenlog.xcodeproj
Scripts/check-repository.sh
Scripts/check-source-safety.sh
swift test
```

Use the exact tag `v<MARKETING_VERSION>` at the release commit.

## Build locally

The local Keychain must contain the Developer ID identity and the
`screenlogger-notary` notarytool profile.

```sh
export SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"
Scripts/package-release.sh \
  --expected-tag v0.2.0 \
  --signing developer-id \
  --identity 08304A35FC08F4049CFCE649DE8EFF7195F5F0E7 \
  --team-id 3UX5N7Y8TY \
  --notary-profile screenlogger-notary \
  --output build/releases
Scripts/generate-update-feed.sh \
  --archive build/releases/Screenlogger-v0.2.0-macos-universal.dmg \
  --output build/releases/appcast.xml \
  --tag v0.2.0
```

Packaging builds universal arm64 and x86_64 app, Core, and CLI products, plus
the arm64-only semantic worker. The manifests distinguish `architectures`
from `semanticArchitectures`. The worker's dSYM is included when available.
It embeds the compiled MLX Metal resource bundle, semantic license notices,
and the assistant skill; model weights remain optional downloads.
It signs the semantic worker and every Sparkle helper, framework, and executable.
It verifies signatures, Team IDs, timestamps, Hardened Runtime, and resources.
It checks installation, removal, ZIP contents, and the mounted DMG.
It also checks Gatekeeper acceptance and stapled tickets.
It produces checksums and manifests only after final stapling.
Feed generation rejects unsigned, ad-hoc, unstapled, or Gatekeeper-rejected
containers/apps before accessing the update signing key. It requires the
Screenlogger Developer ID team as well as the expected update trust anchors.

The feed also requires the Sparkle Ed25519 private key in the local Keychain
account `screenlogger`, or `SPARKLE_ED_PRIVATE_KEY` in the environment.
The notary profile can instead be replaced by the complete API-key arguments
`--notary-key`, `--notary-key-id`, and `--notary-issuer`; never supply both forms.
Credential existence alone does not establish notary-service authorization.
Do not print keys or pass their contents as command-line arguments.

`package-release.sh` performs all three notarization submissions and staples
the app and DMG in order; do not submit intermediate unsigned builds separately.
For a deliberately separate submission, the existing helper is
`Scripts/notarize-release-artifact.sh --keychain-profile screenlogger-notary PATH`.
That helper submits and waits; it does not staple or regenerate checksums.

For local engineering checks, omit the production signing options to use ad-hoc packaging.
Never publish ad-hoc output as a normal release.

For a local signed build, `Scripts/sign-release-developer-id.sh` also accepts a
certificate SHA-1 fingerprint as `--identity`. Use the fingerprint when Keychain
contains multiple valid certificates with the same display name.

## Publish

Push `main`.
Wait for CI before you create the annotated version tag:

```sh
git tag -a v0.2.0 -m "Screenlogger v0.2.0"
git push origin refs/tags/v0.2.0
```

The Release workflow checks the immutable tag and repeats all quality checks.
It creates a temporary Keychain and imports the protected certificate.
It signs and notarizes the exact release bytes.
It generates the signed appcast and removes temporary credentials.
It publishes the verified release.
It refuses to overwrite an existing release.

Each release keeps immutable versioned assets.
It also publishes stable latest-download DMG and checksum aliases for the README.
These aliases keep public installation links current without version-only source changes.

Publication starts the Update Feed workflow.
This workflow rejects drafts and prereleases.
It checks that the feed references the expected DMG.
It downloads and verifies the published DMG and checksum.
It deploys the exact signed appcast to GitHub Pages.

After completion, check the release and feed:

```sh
gh release view v0.2.0
curl --fail https://radkawar.github.io/screenlogger/appcast.xml
```

Keep offline backups of the Developer ID certificate and its export password.
Keep offline backups of the App Store Connect API key and Sparkle Ed25519 key.
Without the Sparkle key, installed builds cannot trust future update archives.
