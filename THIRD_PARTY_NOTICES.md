# Data licenses and attribution

CartaPDF's original Swift code and project documentation are under the [MIT license](LICENSE). Bundled reference data retain the original licenses listed below and are not relicensed under MIT.

The app uses Apple's system frameworks. It does not bundle third-party PDF engines, the veraPDF Java engine or Adobe toolkit code. The resources described here are local data. No affiliation with or endorsement by Apple, Adobe, veraPDF, ISO, the PDF Association or Creative Commons is claimed.

## veraPDF validation profiles

- Copyright © 2015 veraPDF Consortium.
- Source: [veraPDF-validation-profiles](https://github.com/veraPDF/veraPDF-validation-profiles/tree/b76c28ff0d8809c30c4d0e64dc6c393f3c9019dc).
- Pinned commit: `b76c28ff0d8809c30c4d0e64dc6c393f3c9019dc`.
- License: **Creative Commons Attribution 4.0 International (CC BY 4.0)**.
- Eleven original XML files, preserved byte-for-byte without modifications.

Attribution, the legal text, the upstream statement and hashes are in [Resources/PDFAProfiles](Resources/PDFAProfiles/): [NOTICE](Resources/PDFAProfiles/NOTICE.txt), [LICENSE](Resources/PDFAProfiles/LICENSE.txt), [UPSTREAM-README](Resources/PDFAProfiles/UPSTREAM-README.md) and [MANIFEST](Resources/PDFAProfiles/MANIFEST.json). The same data are mirrored under `Sources/CartaPDF/Resources/PDFAProfiles` for SwiftPM.

Normative catalogue descriptions reproduced in reports retain their attribution and CC BY 4.0 license. Availability of the profiles does not certify the validator or the documents it analyzes.

## Adobe CMap, AGL and PDF-to-Unicode data

Copyright Adobe and the respective contributors. The data are distributed under their respective **BSD 3-Clause licenses** and preserved in their original bytes.

| Resource | Pinned commit |
| --- | --- |
| [cmap-resources](https://github.com/adobe-type-tools/cmap-resources/tree/f5cf3bca7fdfeaceb77aa82847e974f2306c20b4) | `f5cf3bca7fdfeaceb77aa82847e974f2306c20b4` |
| [agl-aglfn](https://github.com/adobe-type-tools/agl-aglfn/tree/4036a9ca80a62f64f9de4f7321a9a045ad0ecfd6) | `4036a9ca80a62f64f9de4f7321a9a045ad0ecfd6` |
| [mapping-resources-pdf](https://github.com/adobe-type-tools/mapping-resources-pdf/tree/2dd5e53fb74a01718b9dfd448a0d1cce6fff2aa5) | `2dd5e53fb74a01718b9dfd448a0d1cce6fff2aa5` |

See [NOTICE](Resources/PDFFontData/NOTICE.txt), [MANIFEST](Resources/PDFFontData/MANIFEST.json), [CMaps/LICENSE](Resources/PDFFontData/CMaps/LICENSE.md), [AGL/LICENSE](Resources/PDFFontData/AGL/LICENSE.md) and the headers of individual mappings. These data are also mirrored under `Sources/CartaPDF/Resources/PDFFontData`.

## Development corpus

The veraPDF corpus pinned to commit `377728596647e40edf16003d68d620773ce96ec5` is acquired separately for development under CC BY 4.0 and is not distributed in the app bundle. The evidence records provenance and checks; Isartor is excluded. Any acquisition or redistribution must preserve the original license and attribution. See [PDFA-CorpusEvidence](Development/PDFA-CorpusEvidence.json).

## Standards and trademarks

References to ISO, PDF/XMP/ICC/font specifications and Apple documentation identify technical sources. They do not grant redistribution rights to those texts. Complete copies of the ISO 19005 standards are not included. Acrobat is mentioned only to describe the functional inspiration, without claiming equivalence, affiliation or certification.

When redistributing, retain the complete legal texts, attribution and manifests supplied with the resources. This summary does not replace the original licenses.
