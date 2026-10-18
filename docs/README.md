# CartaPDF documentation

CartaPDF is a free, native macOS PDF editor built with Swift and Apple frameworks. The **PDF-Edit&View** project contains its code, tests, and documentation in the [PDF-Edit-View](https://github.com/GiorgioOppo/PDF-Edit-View) repository; GitHub normalized the repository name. The app is named CartaPDF and supports seven languages, selected automatically from macOS preferences with English fallback.

All document processing happens locally. PDF/A inspection covers eleven profiles, but version 3.6.0 does not provide complete ISO validation or emit a conforming verdict. Code is MIT licensed; bundled reference data retain their own licenses.

| Document | Contents |
| --- | --- |
| [User guide](USAGE.md) | Opening, annotating, merging, splitting, exporting, and saving documents. |
| [Building and verification](BUILDING.md) | Requirements, local builds, tests, and evidence provenance. |
| [CLI and automation](CLI.md) | Commands, exit codes, passwords, and Shortcuts. |
| [Architecture](ARCHITECTURE.md) | Swift components, resources, and the validation pipeline. |
| [Privacy and permissions](PRIVACY.md) | Local processing, data stored on the Mac, and system integrations. |
| [PDF/A validation](PDFA.md) | Eleven profiles, result interpretation, and required limitations. |
| [Accessibility](ACCESSIBILITY.md) | Available controls, automated checks, and outstanding manual audits. |
| [Localization interface review](UI_LOCALIZATION_AUDIT.md) | Isolated app copies, native component snapshots, interactive review and evidence limits. |
| [Preparing a public release](PUBLIC_RELEASE.md) | Repository checks and steps for a future public distribution. |
| [Publication preparation evidence](../Development/PublicationReadiness.json) | Scoped history and hosted-content checks, current private status and prepared GitHub settings. |

For contributors, see [CONTRIBUTING](../CONTRIBUTING.md), the [code of conduct](../CODE_OF_CONDUCT.md), [support](../SUPPORT.md), and [security](../SECURITY.md). [Release notes](../CHANGELOG.md) and [data licenses](../THIRD_PARTY_NOTICES.md) are documented separately.

Detailed technical evidence is in [Development](../Development/). These records describe checks performed on the versions they identify; adding documentation or changing the repository does not mean those tests have been rerun.

- [Languages and translation maintenance](LOCALIZATION.md): automatic macOS matching, English fallback, native resources and checks.
