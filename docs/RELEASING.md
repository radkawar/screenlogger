# Releasing

`Sources/ScreenlogCore/Resources/ProductVersion.xcconfig` is the product version
source of truth. `MARKETING_VERSION` uses three-component semantic versioning.
Increment `CURRENT_PROJECT_VERSION` for every shipped build.

## Trust anchors

Production releases use two independent trust systems:

- Developer ID Application signs the app, its nested code, the standalone CLI,
  and the DMG. Every executable uses Hardened Runtime and a secure timestamp.
- Screenlogger's Ed25519 key signs the final DMG and update feed for Sparkle.

Apple notarizes the app, complete technical ZIP, and final DMG. The app and DMG
both carry stapled tickets. Secrets live in the protected `release-signing`
GitHub Environment, limited to `main` and `v*.*.*` tags. Never print, commit, or
place a private key in a release asset.

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

The tag must be exactly `v<MARKETING_VERSION>` and point at the release commit.

## Build locally

The local Keychain must contain the Developer ID identity and the
`screenlogger-notary` notarytool profile.

```sh
export SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"
Scripts/package-release.sh \
  --expected-tag v0.1.2 \
  --signing developer-id \
  --identity "Developer ID Application: Radheshyam Kawar (3UX5N7Y8TY)" \
  --team-id 3UX5N7Y8TY \
  --notary-profile screenlogger-notary \
  --output build/releases
Scripts/generate-update-feed.sh \
  --archive build/releases/Screenlogger-v0.1.2-macos-universal.dmg \
  --output build/releases/appcast.xml \
  --tag v0.1.2
```

Packaging builds universal arm64 and x86_64 products and explicitly signs every
Sparkle helper, framework, and executable. It verifies signatures, Team IDs,
timestamps, Hardened Runtime, resources, install and removal, extracted ZIP
contents, the mounted DMG, Gatekeeper acceptance, and stapled tickets. Checksums
and manifests are produced only after final stapling.

Ad-hoc packaging remains available for local engineering checks by omitting the
production signing options. Ad-hoc output must never be published as a normal
release.

## Publish

Push `main` and wait for CI before creating the annotated version tag:

```sh
git tag -a v0.1.2 -m "Screenlogger v0.1.2"
git push origin refs/tags/v0.1.2
```

The Release workflow checks the immutable tag, repeats all quality gates,
creates a temporary Keychain, imports the protected certificate, signs and
notarizes the exact release bytes, generates the signed appcast, removes the
temporary credentials, and publishes the verified release. It refuses to
overwrite any existing release. Each release keeps immutable versioned assets
and also publishes stable latest-download DMG and checksum aliases used by the
README, so public install links never need a version-only source commit.

Publishing triggers the Update Feed workflow. That workflow rejects drafts and
prereleases, confirms the feed references the expected DMG, downloads the
published DMG and checksum, verifies them, and deploys the exact signed appcast
to GitHub Pages.

After completion, confirm:

```sh
gh release view v0.1.2
curl --fail https://radkawar.github.io/screenlogger/appcast.xml
```

Keep offline backups of the Developer ID certificate, its export password, the
App Store Connect API key, and the Sparkle Ed25519 key. Losing the Sparkle key
prevents installed builds from trusting future update archives.
