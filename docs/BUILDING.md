# Building and verification

To use the published app, [download CartaPDF 3.6.0](https://github.com/GiorgioOppo/PDF-Edit-View/releases/download/v3.6.0/CartaPDF-3.6.0-macOS-arm64.zip) and follow the [installation guide](INSTALLATION.md). The download requires Apple Silicon and macOS 14 or later; running it does not require Xcode or Python. This guide covers building and verifying the source.

## Requirements

- **Running the app:** macOS 14 or later.
- **Building and testing:** a macOS version supported by the selected Xcode release. Apple lists Sequoia 15.6–Tahoe 26.x for Xcode 26.3; consult the [official requirements](https://developer.apple.com/xcode/system-requirements) for your toolchain.
- A full Xcode installation with a recent macOS SDK. CI uses Xcode 26.3 on macOS 15 and Xcode 26.6 on macOS 26; both passed for the published source baseline identified below. The Swift Package Manager manifest uses Swift tools 5.9 format, which does not imply that every API is available in older SDKs. Cryptographic fixtures use `SecIdentityCreate`, exposed by recent SDKs, without writing to Keychain.
- Apple tools available through `xcrun`.
- Python 3 for development scripts and reports only; it is not an app dependency.

The package declares no external Swift dependencies. Its runtime frameworks are the Apple frameworks listed in the [feature report](../Development/FeatureVerification.json). PDF/A catalogues and font tables are local data with separate licenses.

The evidence for version 3.6.0 covers the Apple Silicon bundle. Building for another architecture does not verify that platform. No verified universal bundle is documented.

## Build

From the repository root:

```sh
./scripts/build-app.sh
open dist/CartaPDF.app
```

The script builds in Release configuration, assembles the app, generates its icon, includes the AppleScript dictionary and App Intents metadata, and applies a local ad hoc signature. `--no-sign` skips signing. The build recreates `dist/CartaPDF.app`; keep any copies you want to preserve elsewhere.

If only Command Line Tools is selected and Xcode is installed at the standard location, the scripts select Xcode for that process. They do not change the global `xcode-select` setting. To use another installation:

```sh
DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer" ./scripts/build-app.sh
```

An ad hoc signature does not identify a publisher or replace Developer ID signing and notarization. This procedure prepares a local build; it does not automatically publish binaries or GitHub releases.

## Native tests

```sh
./scripts/test.sh
./scripts/test.sh --filter PDFArchiveColorSpaceChecksTests
```

The runner uses `swift test` and a temporary directory separate from the Release build. It exposes the resource bundle produced by SwiftPM to the test process only, independently of the checkout, to support flat and `Contents/Resources` layouts and XCTest products across OS versions. It does not accept `xcodebuild` test selection options. Tests exercise PDFKit, Vision, WebKit, and other native APIs; a system without a graphical session or with system restrictions may produce different results. Distinguish environment issues from code defects and record the actual environment and error message.

To save a new result and regenerate the feature report:

```sh
./scripts/test.sh > Development/TestResults.log 2>&1
python3 Development/verify-features.py
```

Version 3.6.0 has recorded evidence of **512 tests passing with zero failures**. This count describes that execution; subsequent changes require appropriate new verification.

Repository preparation at commit `9538462` subsequently recorded **517 tests with zero failures**, including one skip on the hosted runner because the optional corpus was absent. The [verified workflow](https://github.com/GiorgioOppo/PDF-Edit-View/actions/runs/39108436451) is historical evidence for that commit, not verification of later localization changes.

Raw `*.log` files are excluded from Git to avoid unintentionally publishing local paths and diagnostics. The commands above regenerate them on your Mac; versioned JSON reports retain selected results and their documented provenance.

## Continuous integration

The [macOS checks](../.github/workflows/ci.yml) workflow is configured with two Apple Silicon jobs: `macos-15` with Xcode 26.3 and `macos-26` with Xcode 26.6. Each job selects its Xcode installation explicitly and runs the same repository, localization, publication-history regression and syntax checks, native suite, Release build, and checks of the signature, architecture, and actual bundled CLI across all eleven profiles. Matrix failures do not cancel the other job. The smoke test uses a synthetic PDF without XMP: it requires complete catalogues and a nonconforming result, preventing a false conformity claim. The packaged localization checks also exercise twenty language-selection scenarios described below. The official checkout action is pinned to a commit SHA; permissions are read-only and credentials are not persisted in the checkout. Dependabot proposes Actions updates.

The [maintenance verification record](../Development/RepositoryMaintenanceVerification.json) identifies the earlier passing baseline at commit `92408f4bd0a7cce213772656444321ec52537d1e` and [workflow run 39151458030](https://github.com/GiorgioOppo/PDF-Edit-View/actions/runs/39151458030), which used macOS 15 and Xcode 26.3. The published `v3.6.0` source baseline, `84c4ec255069757f7773e2e8e28ed90e9e839812`, subsequently passed both jobs in [workflow run 39154449179](https://github.com/GiorgioOppo/PDF-Edit-View/actions/runs/39154449179). The earlier record retains its original Dependabot and private-plan protection findings; it is not a report of the later run or current visibility.

The first Xcode 26.6 executions exposed compiler type-checking timeouts in CIDToGIDMap enumeration and long-decimal string construction. The [compatibility follow-up](../Development/CICompatibilityVerification.json) records the failures, the equivalent explicit parsing steps and focused regression results separately from the earlier configuration record. The corrections do not expand ISO PDF/A coverage or relabel the baseline as a run on another SDK.

CI does not acquire the corpus, enable VoiceOver, publish releases, or change repository visibility. A local result does not replace the workflow result for a particular commit. If the GitHub image removes the selected toolchain, update the selection in a verified change instead of silently changing SDKs.

## Resources and manifests

The `Resources/PDFAProfiles` and `Resources/PDFFontData` directories are mirrored under `Sources/CartaPDF/Resources` for SwiftPM. The build script checks that they match. Update both copies together and preserve licenses, attributions, and manifests. Pinned catalogue hashes are also verified in Swift code: updating the manifest alone does not update the validator's integrity checks.

## Localization checks

Translations are versioned under `Sources/CartaPDF/Resources/Localization` in eight `.lproj` directories: `en`, `it`, `es`, `de`, `fr`, `zh-Hans`, `zh-Hant`, and `ja`. The build includes them in both the app's main resources and the SwiftPM resource bundle. Each directory contains `Localizable.strings`, `AppShortcuts.strings`, and `InfoPlist.strings`; these provide application messages, native shortcut phrases, and document-type names.

Run the static checker before a build:

```sh
python3 scripts/check-localization.py
```

It compares the tables with the explicit [source inventory](../Development/LocalizationInventory.json), checks source coverage and matching keys, and validates numbered placeholders, native shortcut placeholders, printf formats, fragment whitespace, and English fallback declarations. This check runs in CI; it does not launch the app or establish visual or VoiceOver correctness.

After the normal signed build, verify the assembled application:

```sh
python3 scripts/check-built-app.py dist/CartaPDF.app
dist/CartaPDF.app/Contents/MacOS/CartaPDF -AppleLanguages '("de-AT")' --cli language
```

The packaged check reads the actual eight resource directories and all three table types with Apple's parser, checks matching keys and counts, and compares CLI labels with those packaged translations. It launches twenty isolated cases: eight supported language codes, eight regional preferences, two Chinese script overrides, an unsupported preference followed by French, and an entirely unsupported list that must fall back to English. Each launch uses a temporary working directory and a process-local `-AppleLanguages` argument, without changing system preferences or downloading translations. The JSON diagnostic exposes the selected and preferred languages, supported codes, catalogue counts, and sample labels. Signature, arm64, dataset integrity, and all eleven PDF/A CLI checks remain part of the same packaged verification.

See [localization maintenance](LOCALIZATION.md) for language resolution and translation changes. New passing results must be recorded after these checks actually run; the historical counts above are not updated by adding checks.

For visual review, the [localization interface workflow](UI_LOCALIZATION_AUDIT.md) describes isolated app copies and the opt-in `CartaUISnapshotTests` driver. Native component rendering and interactive GUI review have separate scopes; normal catalogue and CLI checks do not establish either result.

## Development corpus

The official corpus is acquired separately and is not included in the app. Preparation requires network access and is an optional development command:

```sh
python3 Development/prepare-corpus.py --output /path/to/corpus
python3 Development/validate-corpus.py \
  --corpus /path/to/corpus \
  --executable dist/CartaPDF.app/Contents/MacOS/CartaPDF \
  --report /path/to/report.json
```

The scripts use CartaPDF's Swift validator without incorporating the veraPDF engine. Historical numbers in fixture names are not a complete normative oracle; automatic name-to-rule mapping remains provisional. The pinned corpus contains cases for nine profiles, without 3a or 3u directories. See [PDF/A validation](PDFA.md).

## Release evidence

`Development/ReleaseVerification.json`, `PackagingVerification.json`, `BuildManifest.json`, and module reports record evidence for the stated release. Do not edit them by hand to claim new verification. After source or package changes, regenerate only evidence for checks that were actually rerun, preserve the provenance of historical results, and verify final artifact hashes.

The version 3.6 manifest under `Development/` records the local build from before the repository was prepared for public release, including the README hash from that build. It does not attest to the identity of the entire Git tree after documentation updates and is not relabeled as a new build.

The separate [public 3.6.0 verification manifest](https://github.com/GiorgioOppo/PDF-Edit-View/releases/download/v3.6.0/ReleaseVerification.json) identifies the distributed ZIP, its source commit, build toolchain, app file inventory and checks performed after archive extraction. The release is Apple Silicon only, ad hoc signed and not notarized. Its [SHA-256 checksums](https://github.com/GiorgioOppo/PDF-Edit-View/releases/download/v3.6.0/SHA256SUMS.txt) cover the published assets. Later documentation commits do not replace that archive or its source tag.

For subsequent distributions, follow [release maintenance](PUBLIC_RELEASE.md). Documentation updates do not change the app version or certify its output formats.
