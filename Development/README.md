# Development evidence and tools

[PublicRepositoryAudit.json](PublicRepositoryAudit.json) records repository preparation checks, separately from historical bundle evidence.

This directory contains the catalog of 150 requirements, dated test/audit reports, coverage catalogs, and the original Python development tools. It does not constitute ISO certification or a complete security or accessibility audit.

## Read the results

- `FeatureRequirements.json` lists 100 improvements and 50 new features; `FeatureVerification.json` distinguishes implementations, limitations, and outstanding manual checks.
- `PDFA-ValidatorScope.md` defines the current technical scope: complete ISO PDF/A validation is unfinished, and the app does not emit `conforming`.
- `PDFA-ValidatorCoverage.json`, `PDFARequirementsAudit.json`, and module evidence describe checks and sources. `conditions_preventing_full_validation_claim` contains general acceptance criteria, not an up-to-date inventory of defects.
- `PDFA-CorpusEvidence.json` and `PDFA-CorpusReview*.json` reports describe runs against public data pinned to specific commits. Historical test names are not an accuracy oracle; the corpus covers nine profiles and has no 3a/3u directories.
- `BuildManifest.json`, `ReleaseVerification.json`, and `PackagingVerification.json` are historical evidence for the local 3.6.0 package. They do not automatically attest this commit, later documentation, or a published installer. Their hashes describe the artifacts from the stated date and are not rewritten to imply a new build.
- Temporary paths in reports record the provenance of the original runs. Temporary files, the corpus, raw logs, and bundles are not included in Git; these paths do not link to resources available in a clone.
- Historical log hashes are preserved. The original logs may contain machine diagnostics and remain local. Copies used in a report must be reviewed and anonymized.
- `VoiceOverAudit.json` and `AccessibilityPanelAudit.json` describe work that was actually observed. They do not attest completion of a manual VoiceOver audit.
- `LocalizationVerification.json` records the initial localization checks. `UILocalizationVerification.json` records the subsequent translation/layout corrections and reviewed native component images; its interactive coverage is listed separately. See the [interface review workflow](../docs/UI_LOCALIZATION_AUDIT.md) to reproduce the synthetic fixture and snapshots.
- [InteractiveUILocalizationAudit.json](InteractiveUILocalizationAudit.json) records the separate, incomplete interactive attempt and its automation-service blocker. [PublicationReadiness.json](PublicationReadiness.json) records source-publication preparation, advertised-ref/history and hosted-content checks, and GitHub settings still to apply or verify.

Historical machine-readable reports and detailed development records retain their original language and content. Translating public documentation does not alter or rerun the recorded checks.

## Reproduce local checks

Run from the repository root with full Xcode and a system compatible with the selected toolchain ([requirements](../docs/BUILDING.md)); macOS 14 remains the app's minimum deployment target:

```sh
python3 scripts/check-repository.py
./scripts/test.sh > Development/TestResults.log 2>&1
python3 Development/verify-features.py
./scripts/build-app.sh > Development/BuildResults.log 2>&1
```

The last two scripts generate local reports and bundles; they do not push or publish anything. Corpus preparation and execution tools are documented in [docs/PDFA.md](../docs/PDFA.md). Acquiring public data requires network access only during development and does not happen in the app.

Python is used only for development tools with the standard library. It is not an app dependency. Tests and builds use Apple frameworks, with no external Swift packages.
