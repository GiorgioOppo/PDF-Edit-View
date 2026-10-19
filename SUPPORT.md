# Support

Start with the [README](README.md), [installation guide](docs/INSTALLATION.md), [user guide](docs/USAGE.md), [build instructions](docs/BUILDING.md) and [CLI reference](docs/CLI.md). The [3.6.0 release](https://github.com/GiorgioOppo/PDF-Edit-View/releases/tag/v3.6.0) provides the Apple Silicon app, release notes and checksums. For first-launch warnings, follow the installation guide's app-specific approval steps; the download is ad hoc signed and not notarized. The project does not promise commercial support or response times. Documentation and GitHub forms are in English. The app automatically selects a supported macOS language, with English fallback; see [languages](docs/LOCALIZATION.md).

## Questions, problems and requests

Use the repository's [issue forms](https://github.com/GiorgioOppo/PDF-Edit-View/issues/new/choose):

- **Usage or documentation question** for help using the app, building from source or understanding a guide.
- **Bug report** for reproducible incorrect behavior or a regression.
- **Feature request** for a new tool or a concrete improvement.

For a reproducible problem, include:

- CartaPDF version or commit, macOS version, architecture and Xcode version when relevant;
- the selected interface language for translation, text clipping or keyboard-navigation problems, plus the approximate window size;
- the operation and minimal steps needed to reproduce it;
- expected and observed results, including the error message;
- a synthetic fixture or public source with a redistributable license;
- checks you have already performed.

Do not attach personal PDFs, passwords, keys, signatures containing confidential information or unreviewed logs. Reports can contain names, paths and metadata. Prefer a newly created synthetic example; inspect redacted examples for hidden text, previous revisions and metadata before sharing. Follow [SECURITY](SECURITY.md) for vulnerabilities or data exposure.

## PDF/A results

An `indeterminate` result is expected when required checks are missing or the model does not support the document. Version 3.6.0 does not report complete ISO conformity. Before reporting a result, read [PDFA](docs/PDFA.md) and the [validator scope](Development/PDFA-ValidatorScope.md). For a discrepancy, include the profile, condition identifier, relevant bytes or object and a primary source. A historical corpus test name is not sufficient on its own.

## Manual verification

The complete VoiceOver audit remains open. Scanning, screen capture and audio depend on the actual environment; state the device and permissions without sharing personal data. Successful compilation of the AppleScript dictionary does not prove dispatch from Script Editor.

The repository and its issues are not a document storage service, ISO certification service or legal signature assessment.
