# PDF-Edit&View — CartaPDF

[![macOS checks](https://github.com/GiorgioOppo/PDF-Edit-View/actions/workflows/ci.yml/badge.svg)](https://github.com/GiorgioOppo/PDF-Edit-View/actions/workflows/ci.yml)

A free, offline PDF editor for macOS, written in Swift using Apple frameworks only. **CartaPDF 3.6.0** supports reading, annotations, page organization, merging, splitting, OCR, forms, conversion and local document workflows. It requires no application account, subscription, cloud service or telemetry.

The repository is named **PDF-Edit-View**; the application and bundle are named **CartaPDF**. This is an independent project, unaffiliated with Adobe. Its tools address workflows familiar from Acrobat Pro, within the [documented limits](#scope-and-limitations). Original code is MIT-licensed; bundled reference data has [separate licenses](THIRD_PARTY_NOTICES.md).

Project guides and GitHub support templates are in English. The app supports **Italian, Spanish, English, German, French, Chinese (Simplified and Traditional), and Japanese**. It follows the ordered macOS system or per-app language preferences at launch and falls back to English when none match. Historical machine-readable reports and fixtures retain their original language. See [language selection and translation maintenance](docs/LOCALIZATION.md).

**PDF/A validation is incomplete.** The native validator distinguishes all 11 profiles, including PDF/A-4, 4e and 4f, but does not report full conformance while coverage gaps remain. See [PDF/A status](docs/PDFA.md).

## Getting started

The application targets **macOS 14 or later**. Building requires full Xcode with a recent macOS SDK on a compatible host; see the [build requirements](docs/BUILDING.md). The verified CI environment is Apple Silicon, macOS 15 and Xcode 26.3.

From a checkout of this repository:

```sh
./scripts/test.sh
./scripts/build-app.sh
open dist/CartaPDF.app
```

The build creates `dist/CartaPDF.app`, which is excluded from Git, and applies a local ad hoc signature. This source repository does not automatically publish an installer or a Developer ID-notarized binary. The scripts select Xcode for their own process without changing the global `xcode-select` setting.

Open **Strumenti** (Tools), or press **⇧⌘T**, to find an operation. Advanced tools provide previews, parameters and scope information. Structural changes, scanning, signing and conversion workflows save separate copies. Save ordinary annotations and page edits with **⌘S**; undo with **⌘Z**. See the [user guide](docs/USAGE.md).

## Features

| Area | Tools |
| --- | --- |
| Reading and navigation | Independent windows, Finder integration, draggable thumbnails, live search with excerpts, single/continuous/facing views, pointer-anchored zoom, printing, persistent reading position and configurable shortcuts. Controls expose accessible names, values, units, states and announcements. |
| Merging | Reorderable queue, per-file page ranges, final-order preview, statistics, duplicate and mixed-format detection, remapped bookmarks, alternating front/back pages and filename-based groups. |
| Splitting | Split by ranges, every N pages, bookmarks, separator text, Vision QR/barcode detection, blank pages or actual maximum output size. Includes naming, conflict preview, progress, cancellation and Finder output. |
| Page layout | Page organizer, duplication and movement, book-scan spread separation, N-up, duplex booklets, posters, PDF overlays and interactive cropping with validated units and margins. |
| Annotations | Highlights, notes, added text, smoothed drawing, shapes, links, reusable stamps, configurable watermarks, dynamic headers/footers, page numbers, Bates numbering and a clickable table of contents. Synchronized selection, movement, resizing, author and stroke settings. Keyboard panel for coordinates, creation, editing, deletion and undo (**⇧⌘K**). |
| Scanning and OCR | Apple Vision OCR with language selection, orientation, deskewing, cleanup, retries, multicolumn order, visible-page priority and per-page reports. Image Capture-compatible scanners and ScreenCaptureKit screen/window capture. |
| Conversion | PDF from images with margins and from text/RTF/DOCX; local static HTML to PDF; TXT, RTF, DOCX, text-based EPUB, PNG and multipage TIFF export. CSV from table regions with manual or automatically detected columns. JPEG preview, DPI, color profiles and size comparisons. |
| Forms | Create and fill text, checkbox and choice fields. Field search, page groups, required flags, character limits, shared values and change tracking. Generate a filled copy for each CSV row. |
| Original PDF structure | Logical section numbering, embedded-image extraction, image XObject replacement, supported text-string edits in content streams, attachments, PDF collections and OCG layer visibility. |
| Analysis | Textual and visual comparison, visually duplicate pages, embedded fonts, image resolution, page boxes, ICC output intents, metadata and accessibility structure. |
| Archiving and print preparation | Native CoreGraphics PDF/A conversion with detection of the declared level; reports for 11 profiles with clauses, incomplete checks and JSON/text output. Print-intent preparation using a local CMYK ICC profile, plus page-level tags and descriptions. |
| Protection and signatures | Password-protected opening, encryption retention during ordinary saves, verified encrypted copies, rasterized redaction copies, CMS signing with a local certificate and offline integrity/available-chain verification. |
| Local organization | Library categories/tags, search across PDFs, content-based renaming, watched folders, ordered batch workflows and JSON presets. History of the latest 20 versions per document and recovery copies. |
| Automation | Native **Unisci PDF** (Merge PDFs) App Intent for Shortcuts, the `merge PDFs` AppleScript command, and a CLI for information, merging, extraction, splitting, text, OCR, flattening, compression and PDF/A reports with distinct exit codes. |

The [requirements inventory](Development/FeatureRequirements.json) lists 100 improvements and 50 additional features. The [verification report](Development/FeatureVerification.json) distinguishes implemented functionality, limited scope and checks requiring hardware or manual work.

## Documentation

- [Guide index](docs/README.md), [using the app](docs/USAGE.md) and [command-line interface](docs/CLI.md).
- [Building and testing](docs/BUILDING.md), [architecture](docs/ARCHITECTURE.md) and [contributing](CONTRIBUTING.md).
- [Privacy and permissions](docs/PRIVACY.md), [accessibility](docs/ACCESSIBILITY.md), [languages](docs/LOCALIZATION.md) and [security](SECURITY.md).
- [PDF/A status](docs/PDFA.md), [changelog](CHANGELOG.md) and [third-party notices](THIRD_PARTY_NOTICES.md).
- [Support](SUPPORT.md), [public-release preparation](docs/PUBLIC_RELEASE.md) and [interpreting development evidence](Development/README.md).

## Scope and limitations

- **Original text and images:** text editing supports standard Type1 WinAnsi fonts and simple `Tj` strings, without automatic reflow. Subset/CID fonts, ToUnicode, complex `TJ` operators and unsupported content are explicitly rejected. Structural editing does not decrypt protected PDFs. Incremental revisions preserve earlier data: text changes and attachment removal are not redaction. Image editing supports XObjects with the filters documented by the tool; replacing a shared object affects every page that uses it.
- **PDF/A:** the validator distinguishes 1a/1b, 2a/2b/2u, 3a/3b/3u and 4/4e/4f, tracking 1,489 entries from the upstream reference catalogues. It reports passed, failed, not verified or not applicable checks, together with the SHA-256 of the analyzed bytes. Native checks cover supported font programs, glyphs, metrics and Unicode mappings; RDF/XMP metadata and extension schemas; painted colors, ICC and JPEG2000; annotations, forms, OCGs, signatures and recursive attachments. **Complete ISO 19005 validation remains unimplemented.** Gaps remain in ISO 32000 semantics, advanced codecs/fonts, meaningful level-A logical structure, 3D payloads and full normative reconciliation. If no violation is demonstrated but gaps remain, the result is `indeterminate`; this version never emits `conforming`. See [verified scope and remaining gaps](Development/PDFA-ValidatorScope.md). CoreGraphics may declare 2b even when the API requests 2u: the app reads the actual declaration and does not artificially raise it.
- **PDF/X and PDF accessibility:** a CMYK ICC intent prepares a document for printing. Tags provide page-level language and descriptions; they do not certify ISO 15930 or PDF/UA conformance.
- **Signatures:** local-certificate signing produces CMS and ByteRange data. Verification uses the original bytes without network requests. It can check integrity and locally available trust, but does not provide current revocation status, TSA timestamps, long-term validation, complete PAdES support or legal qualification. Editing a signed PDF may invalidate its signature or create a revision beyond the signed one. A drawn signature is a separate annotation.
- **Text-based conversion:** DOCX/RTF/EPUB workflows do not faithfully reconstruct Office layout, formulas, tables or images. Automatic table and OCR-column detection is heuristic and needs review. OCR can produce errors.
- **Rasterized copies:** deskewing, cleanup, redaction, flattening, JPEG conversion and OCR-recognized pages may rasterize content and lose interactivity, passwords or signatures in the copy. JPEG output can be larger. Cropping changes the visible area without removing hidden content.
- **Large documents:** writes and conversion workers have limits and cancellation. Structural preparation, preflight, signing and CoreGraphics redraws still run on the main actor; large files may temporarily block the corresponding panel.
- **Forms:** XFA, radio buttons, password fields and JavaScript/calculations are unsupported. Document widgets remain read-only during use; the Forms panel restores their original flags when saving.
- **Devices and permissions:** scanning requires an Image Capture-compatible device and driver. Screen capture requires macOS screen-recording permission. Read-aloud uses voices already installed on the system. These integrations do not install drivers or download voices.
- **HTML and local organization:** HTML is static, with JavaScript disabled and remote resources blocked. The library stores references to local files; moving them externally requires updating those references. Watched folders operate while the app and their panel are open.
- **Accessibility verification:** a complete manual VoiceOver audit has not been completed. Static review and native tests are documented separately; scanner, capture and audio workflows also require real-device/permission checks.

Version 3.6 adds checks for calibrated, Indexed, Separation and DeviceN color-space schemas; indirect aliases for streams and Metadata; ICC multiprocess elements; TrueType coordinates and composite attachments; standard Layout/List/Table/PrintField attributes and user properties. PDF function 0/2/3/4 checks and earlier audits remain available. Reports keep the 1,489 catalogue entries separate from additional PDF-model checks. Remaining gaps continue to block full conformance claims.

## Verification

Tests inspect reopened data, content and pixels, rather than only checking that controls exist. They cover undo, forms, encryption, bookmarks, text streams, images, attachments, CMS/tampering, Vision OCR, QR codes, page layout, CSV, EPUB/CRC, TIFF, offline HTML, batch workflows, cancellation and thousand-page documents.

Historical version 3.6 evidence from October 18, 2026 records **512 tests passed, zero failures**. Independent corpus evidence is in [PDFA-CorpusEvidence](Development/PDFA-CorpusEvidence.json), and the integrated feature status is in [FeatureVerification](Development/FeatureVerification.json). These reports describe their original artifacts.

Repository preparation added resource-layout and link-persistence regressions: **517 local tests passed, zero failures**. The [verified GitHub run](https://github.com/GiorgioOppo/PDF-Edit-View/actions/runs/39108436451) for commit `9538462` executed 517 tests with zero failures and one skip because the optional local corpus was absent. It also passed the Release build, signature/arm64 checks and packaged CLI smoke tests for all 11 profiles. See [PublicRepositoryAudit](Development/PublicRepositoryAudit.json) for separate local preparation evidence.

Initial localization verification passed **526 native tests in Italian and 526 in English**, with zero failures. That packaged Release app passed 20 language-selection cases and 88 language/profile comparisons with unchanged PDF/A classifications; its catalogues contained 3,038 messages. See [LocalizationVerification](Development/LocalizationVerification.json) for that artifact's hashes, provenance and limits.

The subsequent interface review corrected translations and constrained layouts and expanded each catalogue to **3,040 messages**. Both Italian and English suites executed **527 tests with zero failures and one optional snapshot skip**. Separate opt-in runs generated 184 native component images per round: all 184 initial images were inspected, and 36 affected images were rechecked after corrections. The final Release app passed 20 language-selection cases and 88 language/profile comparisons. [UILocalizationVerification](Development/UILocalizationVerification.json) records hashes, observations and the separate limited interactive coverage. The [review workflow](docs/UI_LOCALIZATION_AUDIT.md) reproduces the synthetic PDF and offscreen snapshots; it does not imply an exhaustive interactive or linguistic audit.

The [CI workflow](.github/workflows/ci.yml) checks repository contents, script syntax, native tests, the Release build and packaged resources/CLI. Hardware checks and the complete manual VoiceOver audit remain separate. Raw logs stay local and are excluded from Git. A successful smoke test does not demonstrate complete ISO conformance.

The subsequent [publication-preparation record](Development/PublicationReadiness.json) documents the advertised Git history, hosted content and historical Actions logs reviewed, the new history-checker regression fixtures and the GitHub settings still pending. The repository remains private until an explicit owner decision. The separate [interactive attempt](Development/InteractiveUILocalizationAudit.json) records partial English observations and an automation-service blocker; the full interactive checklist across all languages remains incomplete.

To check the repository and regenerate the feature report after a real test run:

```sh
python3 scripts/check-repository.py
python3 scripts/check-localization.py
./scripts/test.sh > Development/TestResults.log 2>&1
python3 Development/verify-features.py
```

## Command-line and automation examples

```sh
# The bundled executable also works without opening the interface.
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli help
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli merge Merged.pdf A.pdf B.pdf
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli extract A.pdf Extracted.pdf '1-3,5'
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli validate-pdfa A.pdf 4f Report.json
```

`validate-pdfa` returns 0 for conforming, 2 for demonstrated violations, 3 for indeterminate and 1 for usage/I/O errors. Exit code 0 is reserved for future complete coverage and is never emitted by this version.

The CLI refuses to overwrite inputs or existing outputs unless `--overwrite` is explicitly used for outputs. Supply passwords through `--password-file`, never directly on the command line. Keys and passwords are not stored in presets or history. Full syntax is in the [CLI guide](docs/CLI.md).

The AppleScript dictionary exposes:

```applescript
tell application id "it.cartapdf.editor"
    merge PDFs files {"/path/A.pdf", "/path/B.pdf"} destination "/path/Merged.pdf"
end tell
```

For Shortcuts, look for CartaPDF's **Unisci PDF** action after opening the app. The CLI and Intent have automated checks; dispatch from Script Editor still requires manual verification.

## Source layout and bundled data

`PDFEditorModel`, `PDFWorkspaceDocument` and `PDFCanvas` manage document state, undo and interaction. `PDFWorkflow*` implements organization and batch workflows; `PDFScanExport*` and `PDFLocalLibrary` handle scanning, conversion and the library. `PDFStructure*` contains structural reading/writing and certificates. `CartaWorkspaceServices`, `CartaRenderingServices`, `CartaVisualTools`, `CartaFileIO` and `CartaAutomation` cover preferences, recovery, memory, comparison, writes and automation. `ToolBrowserView` contains the tool catalogue. See the [architecture guide](docs/ARCHITECTURE.md).

The original veraPDF XML catalogues are **CC BY 4.0** data. Adobe CMap/AGL and PDF-to-Unicode data use **3-clause BSD** licenses. Their licenses are separate from the code's MIT license. Both the app bundle and sources include attribution, licenses and hashed manifests under `Resources/PDFAProfiles` and `Resources/PDFFontData`. No Java validation engine, Adobe toolkit or external runtime framework is included. The external development corpus is acquired separately and is not bundled with the app.

## Support and contributions

Read [SUPPORT.md](SUPPORT.md) for questions and bug reports, [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes, and [SECURITY.md](SECURITY.md) for vulnerability reporting. Use the English issue and pull-request templates. Prefer synthetic or redacted reproductions; never include private PDFs, passwords, keys or confidential raw logs.

The repository is prepared for a future public source release. Visibility changes, branch protections and binary distribution are separate owner decisions described in [PUBLIC_RELEASE.md](docs/PUBLIC_RELEASE.md).

## License

Original code and project documentation are available under [MIT](LICENSE). Bundled data retains the licenses and attribution in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). ISO specifications and the external corpus are not redistributed.
