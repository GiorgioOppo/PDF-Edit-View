# Architecture

CartaPDF is a Swift Package Manager executable with an XCTest target. Its interface uses SwiftUI and AppKit; ordinary document handling and rendering use PDFKit. There are no third-party Swift packages, application servers, or external PDF engines.

## Components

| Area | Main sources | Responsibility |
| --- | --- | --- |
| Startup and windows | `CartaPDFApp`, `PDFWorkspaceDocument`, `ContentView` | NSDocument lifecycle, opening, saving, and panel composition. |
| Editor state | `PDFEditorModel`, `PDFCanvas`, `DocumentNavigationView` | Active document, selection, rendering, navigation, editing, and undo. |
| Tools | `ToolBrowserView`, `PDFPageTools`, `PDFTextTools`, `PDFRedactionTools` | Searchable tool catalogue and page or content operations. |
| Batch workflows | `PDFWorkflowTools`, `PDFWorkflowViews` | Merging, splitting, presets, and local workflows. |
| Capture and export | `PDFScanExport*`, `PDFConversionTools` | Vision OCR, Image Capture, ScreenCaptureKit, static WebKit content, and conversions. |
| PDF structure | `PDFStructureEngine`, `PDFStructureTools`, `PDFStructureViews`, `PDFStreamFilters` | COS/xref reader, streams, supported structural changes, and signatures. |
| Local services | `CartaWorkspaceServices`, `CartaFileIO`, `CartaRenderingServices`, `PDFLocalLibrary` | Preferences, versions, recovery, writes, caches, and local index. |
| Automation | `CartaAutomation` | CLI, App Intent, and AppleScript command. |
| Validation | `PDFArchiveValidator*`, `PDFArchive*Checks`, `ICCModel` | PDF/A reports, model checks, and explicit coverage gaps. |

The abbreviated names in the table refer to files under [Sources/CartaPDF](../Sources/CartaPDF/).

## Documents and writes

`PDFWorkspaceDocument` connects NSDocument to the editor model. Reversible changes register explicit undo groups; saving serializes the supported document. Tools that change structure or rasterize content prepare a copy. `CartaFileIO` centralizes atomic writes and some destination and available-space checks.

Links created by the app receive a UUID identifier in the `/NM` and `/CartaPDFLinkID` entries. The second preserves identity on macOS 15, where PDFKit omits `/NM` when saving. A malformed or inconsistent private marker prevents editing; earlier links with only `/NM` remain recognized. These markers prevent accidental changes to imported links; they are not signatures or proof of authenticity. PDFKit continues to handle saving, including encrypted documents.

The structural reader operates on PDF bytes separately from PDFKit rendering. It follows modeled xref revisions, resolves indirect aliases within limits, and distinguishes physical objects from terminal identities. Implemented filters are original Swift code, using Apple's Compression framework for supported operations. Unmodeled cases remain explicit.

## PDF/A validation path

1. The validator receives an immutable byte snapshot and the selected profile.
2. It loads the pinned local XML catalogue for that profile and verifies its integrity.
3. The parser and semantic inventories collect supported facts: objects, streams, fonts, metadata, colors, structure, attachments, and signatures.
4. Checks produce results for catalogue entries and separate results for the PDF model.
5. The report includes the bytes' SHA-256 hash, diagnostic details, limits, and `scopeGaps`.

A demonstrated violation produces `nonconforming`. Without a violation, a coverage gap, unavailable resource, or limit produces `indeterminate`. Overall conformity remains disabled in 3.6.0. Successful rendering is not evidence of conformity and does not clear incomplete checks.

Checks have limits on input size, decoded streams, depth, and counts. The validator does not execute PDF JavaScript, font programs, attachments, or 3D payloads. Reaching a budget does not become proof of validity. See the [technical scope](../Development/PDFA-ValidatorScope.md).

## Concurrency and limits

Conversion and validation jobs use workers, limits, and cancellation. Some structural preparation, preflight, signing, and CoreGraphics redraw operations still run on the main actor; large files may temporarily block the relevant panel. This limit is tracked in the feature report.

## Embedded data

PDF/A XML catalogues and CMap/AGL/PDF-to-Unicode data are original upstream data stored locally, versioned with manifests and SHA-256 hashes. Copies under `Resources` and `Sources/CartaPDF/Resources` must match. Their presence supplies reference data; it does not automatically implement every normative obligation. Their [licenses](../THIRD_PARTY_NOTICES.md) remain separate from MIT.

## Verification

Tests construct synthetic documents and check reopened content, bytes, pixels, errors, cancellation, and profile differences. The development corpus is acquired separately. When adding checks, use a primary source and positive and negative cases that isolate the condition; do not turn a historical corpus name into a normative assertion. See [CONTRIBUTING](../CONTRIBUTING.md).
