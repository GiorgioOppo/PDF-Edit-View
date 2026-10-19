# Changelog

Entries describe implementations and available evidence. Passing a test does not attest normative conformity beyond the documented scope. CartaPDF remains free, local and based only on Apple frameworks.

## Unreleased

- Added direct links to the published CartaPDF 3.6.0 Apple Silicon app, English installation instructions, checksums and public release evidence. Updated source-build and distribution guides to distinguish the downloadable ad hoc, non-notarized app from historical local builds. This documentation update does not modify the published archive.
- Split CIDToGIDMap enumeration and long-decimal string construction into explicit typed steps to avoid Xcode 26.6 compiler timeouts. Added isolated CIDSet stream regressions for empty/zero mappings, CID0 exclusion, covered/missing CIDs and malformed lengths; existing long-decimal tests cover numeric behavior. PDF/A scope is unchanged. See the [compatibility record](Development/CICompatibilityVerification.json).
- Configured an additional Apple Silicon macOS 26/Xcode 26.6 CI job alongside macOS 15/Xcode 26.3, with identical checks and independent failure reporting. The [maintenance record](Development/RepositoryMaintenanceVerification.json) preserves the verified `92408f4` baseline and its passing workflow, enabled Dependabot alerts, and the unavailable private-repository branch protection. Repository visibility and historical reports are unchanged.
- Added a read-only publication-history checker with synthetic regressions in CI, reviewed hosted workflow history separately from source files, and prepared an optional `main` protection payload. Recorded the interactive localization audit's concrete automation-service blocker without claiming completion.
- Corrected Undo/Redo translations, tool terminology and Traditional Chinese interface vocabulary. Longer labels now wrap or use adaptive controls across the editor, forms, workflow, export, structure and PDF/A panels. OCR has a scrolling options form and a content minimum that preserves all five report columns.
- Added a deterministic synthetic PDF generator and opt-in native interface snapshots for all eight language variants, with separate manifests for rendered components and interactive observations. See the [interface review workflow](docs/UI_LOCALIZATION_AUDIT.md).
- Automatic interface localization for Italian, Spanish, English, German, French, Simplified/Traditional Chinese and Japanese, following ordered macOS preferences with English fallback. Localized menus, tools, messages, accessibility labels and native resources are bundled without translation downloads or language preference writes.
- Added the `L10n` message/resource layer with numbered placeholders, English fallback and explicit boundaries between interface labels, stored identifiers and document content. Added read-only CLI language diagnostics.
- Added a static CI checker for translation coverage, placeholders, formats and native tables, plus twenty packaged language-selection cases covering supported codes, regional variants, Chinese script precedence and fallback. New verification results remain separate from historical release evidence.
- English README, documentation, contribution and support policies, and GitHub issue and pull request templates. Added a usage and documentation question form.
- Prepared the private GitHub repository for future source publication.
- Added guides for usage, building, the CLI, architecture, privacy, PDF/A and accessibility.
- Added contribution, support, security, conduct and data attribution policies.
- Discover SwiftPM resources in flat and Contents layouts and beside XCTest products, with an explicit test path and packaged CLI verification across eleven profiles.
- Save link identity in the local `/CartaPDFLinkID` entry to handle PDFKit dropping `/NM` on macOS 15. Preserve compatibility with earlier links and protect against inconsistent markers. Tests cover saving, reopening, removal, undo and encryption.
- Verify form export values in PDF bytes instead of convenience getters whose behavior varies across macOS versions.
- Use Xcode 26.3 in CI with an SDK exposing `SecIdentityCreate`; construct binary fixtures with linear appends to avoid type-checker timeouts.
- Improve signing error compatibility: preserve the native `CFError` or throw a separate internal Security error, without forced conversions between the types.
- Documentation changes do not imply a new app release or certification.

## 3.6.0 — 2026-10-18

First public binary: [download and release notes](https://github.com/GiorgioOppo/PDF-Edit-View/releases/tag/v3.6.0). Requires Apple Silicon and macOS 14 or later; ad hoc signed, not notarized. See the [installation guide](docs/INSTALLATION.md) and the separate [public packaging verification](https://github.com/GiorgioOppo/PDF-Edit-View/releases/download/v3.6.0/ReleaseVerification.json) for the distributed artifact. The historical results below describe their original executions.

- Added schema checks for calibrated, Indexed, Separation and DeviceN color spaces, with exact numeric comparisons and explicit limits.
- Resolve canonical aliases for Contents and Metadata streams, decoding and ICC profile identity.
- Added ICC multi-process element checks for channels, matrices, CLUTs, curves and supported types.
- Added TrueType coordinate and bounds checks, composite point-to-point attachment checks and aggregate `maxp` limits.
- Added standard Layout/List/Table/PrintField and UserProperties structure attribute checks, revisions and precedence.
- Passed 512 native tests with zero failures. Executed 2,164 corpus PDFs against the Release binary without execution errors. Overall results remain 1,509 `nonconforming` and 655 `indeterminate`.
- Verified the CLI matrix for eleven profiles and fixtures for the new color checks. Complete ISO PDF/A validation remains unfinished, and a conforming result is disabled.

Evidence: [scope](Development/PDFA-ValidatorScope.md), [release](Development/ReleaseVerification.json), [corpus](Development/PDFA-CorpusEvidence.json), [features](Development/FeatureVerification.json).

## 3.5.0 — 2026-10-18

- Added native checks for PDF functions 0/2/3/4 reached through semantic references, including dimensionality, Domain/Range and calculator audits in deterministic paths.
- Added bounded indirect aliases, terminal identities and page entry inheritance with null or undefined values.
- Added a mechanical model of logical structure, IDTree/ParentTree, MCID/OBJR, classes and supported namespaces.
- Added ICC pseq/ncl2/psid payload checks, supplementary cmap8 checks and a bounded Type2 audit.
- Passed 447 native tests and executed 2,164 corpus PDFs without execution errors. New model results were reviewed separately.

## 3.4.0 — 2026-10-18

- Added further ICC v2/v4 checks and corrected edition-dependent conditions.
- Made historical xref contexts and the ObjStm inventory stricter.
- Added CFF CID/FD and additional cmap inventory checks, and local RFC 3986 resolution for XMP URIs.
- Added supported U3D framing checks without attesting geometry or PRC payloads.
- Passed 367 native tests and executed 2,164 corpus PDFs without execution errors.

## Earlier versions

Editing, organization, OCR, conversion, form, signing and automation tools are inventoried in the [150 requirements](Development/FeatureRequirements.json). Historical validator checks and regressions are detailed in the Development evidence. Earlier release history is not reconstructed without corresponding evidence.
