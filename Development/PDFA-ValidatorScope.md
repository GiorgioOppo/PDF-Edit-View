# Native PDF/A validation: verified scope and gaps

Research date: October 18, 2026. Swift/Foundation/Compression/CoreGraphics/CryptoKit/Security implementation; no external engine, executable, network service, or runtime dependency.

## Conformity verdict

The software is not currently a complete ISO PDF/A validator. It handles the eleven profiles separately and produces a report for every catalogue rule without mistaking the presence of XMP, fonts, or ICC profiles for conformity.

- `nonconforming`: at least one violation of the implemented rules is demonstrated.
- `indeterminate`: no demonstrated violation, but unverified rules or normative obligations, unsupported parsing, missing resources, encryption, or cancellation remain.
- `conforming`: reserved for demonstrated complete coverage with all applicable conditions verified. **The current version does not emit this verdict**: `scopeGaps` retains unimplemented obligations of the normative model.

`passed` applies to the specified condition, not the entire document. `notApplicable` applies only to the explicitly indexed object model. Every unmodeled property returns `notVerified`. Catalogue counts do not demonstrate coverage of the underlying ISO 32000 model.

## Tracked catalogues

Original data from the official veraPDF project, commit `b76c28ff0d8809c30c4d0e64dc6c393f3c9019dc`, distributed separately under CC BY 4.0 with attribution, license, and manifest. No Java engine code is incorporated. Expected SHA-256 hashes are also pinned in Swift source: changing both XML and manifests cannot fabricate an official catalogue.

| Profile | Rules in the report | Family basis |
|---|---:|---|
| 1a | 135 | PDF 1.4, level A logical structure |
| 1b | 129 | PDF 1.4 |
| 2a | 153 | ISO 32000-1, level A logical structure |
| 2b | 144 | ISO 32000-1 |
| 2u | 146 | ISO 32000-1, Unicode mapping |
| 3a | 155 | ISO 32000-1, attachments and level A logical structure |
| 3b | 146 | ISO 32000-1 and attachments |
| 3u | 148 | ISO 32000-1, attachments and Unicode mapping |
| 4 | 111 | ISO 32000-2/PDF 2.0 |
| 4e | 111 | PDF 2.0, Engineering |
| 4f | 111 | PDF 2.0, required embedded files |

Total catalogue entries: 1489, including conditions shared across profiles. These are not 1489 independent implementations. PDF/A-4:2020 is treated as the pinned edition, not as a future revision under preparation.

## Implemented checks with direct evidence in version 3.6

- Header, version, binary marker, EOF, ID, and latest-revision trailer; Encrypt prohibitions and PDF/A-4-specific Info/PieceInfo conditions.
- Additional strict parsing of indexed and compressed physical objects: numbers, name escapes, duplicate keys, hex strings before padding, object whitespace, stream/Length/EOL, and xref lines. Hybrid xrefs are supported. Additional ISO 32000 checks appear in `modelChecks`, separately from the 1489 catalogue entries.
- Lexical limits and resources in unpainted containers, with the §6.1.12 exemption for unused named resources in A1 (TechNote0010 A010): page, Form, Pattern, appearance, Type3, and soft mask. Lack of use is not treated as font or color use.
- Type1/eexec, CFF, and SFNT TrueType/OpenType fonts: resource inventory separate from Tf/ExtGState selection and glyph use; embedding based on text actually used and Tr; glyph/CID/GID, cmap, supported hmtx or CharString metrics, CIDToGIDMap, Widths/W/DW, subset CharSet/CIDSet, encoding, CMap, and Unicode/ActualText. Local Adobe CMap, AGL, and PDF-to-Unicode data are versioned and SHA-256-verified. CharSet/CIDSet restrictions distinguish used glyphs in A1 from embedded glyphs in A2/3.
- XMP/RDF according to the required Adobe edition: attributes and abbreviated forms, arrays, structures, qualifiers, xpacket wrappers, secondary packets, identification and prefixes, predefined registries (168 properties for 2004 and 273 for 2005), supported types and vocabularies, extension schemas, and Info/XMP consistency. Details and remaining unverified cases are in `MetadataValidationEvidence.json`.
- Colors: for parts 1–3, merely specifying a color also constitutes use (TechNote0010 A011/A015); for part 4, the painted-color context is modeled. Default color spaces, page/Form output and blending, tiling/shading Patterns, soft masks, overprint; DeviceN and Separation; ICC headers and tag-table structure, profile components and identities; JPEG2000/JP2/SIZ boxes; inline boundaries proven through independent dimensions/sample counts. L can guide parsing but does not prove its own correctness. An ambiguous filtered boundary remains unverified.
- Annotations/appearances and flags, fields with inherited FT, XFA/AA, contextual actions; OCG Name/Order/AS; structure, ParentTree/RoleMap, and MCID references; language; AF, associated files, RichMedia Assets, and recursive PDF/A attachments with explicit limits.
- Signature ByteRange and CMS contents through Security, without executing actions, opening attachments, consulting the network, or importing certificates into Keychain.

Version 3.3 additions:

- ASCIIHex, ASCII85, RunLength, LZW (EarlyChange 0/1), and Flate filters with EOD, Adler32 checksums, and original verification of RFC 1951 deflate structure. Expansion uses Apple's Compression framework; early consumption by Apple's decoder does not prove the boundary. TIFF/PNG predictors at 1/2/4/8/16 bits; checked indirect and array Filter/DecodeParms; undefined/free references resolved to null. Numbers in content streams are checked before normalization.
- CFF Expert/ExpertSubset/ExpertEncoding and Adobe 5176 standard names; SFNT structural and instruction-token checks distinct from hinting execution.
- Limited local DTDs, distinguished from literal words in comments/CDATA; rdf:datatype, nodeID, and xml:base according to the XMP edition; MIME and URI syntax without implicit repairs.
- Original recursive DER according to ITU X.690, CMS/RDN SET OF and X.509 DEFAULT in modeled paths; opaque extensions remain unverified. AF/Filespec in the PDF 2.0 Catalog graph and AF/MCAF marked-content conditions; no payload execution.
- Shading-pattern ExtGState applied temporarily from the initial state of the container defining the resource; an unproven origin for inherited resources is reported as incomplete.

Version 3.4 additions:

- ICC v2/v4 headers, calendar, D50, required tags by v4 class, signature/type compatibility, counts and ranges for curves, mluc, LUT8/16, and LUT A/B. Complete tag contiguity applies to v4.4; a private tag is not invalid merely because of its name. Functions, colorimetry, and unmodeled ICC payloads remain incomplete.
- Each revision's own xref view for Length and historical references; ObjStm inventory with integer headers, increasing offsets, single-value slices, and comment boundaries. Every recorded context of a republished stream is checked: a later modification does not erase evidence of an earlier version.
- CFF CID FDArray/FDSelect/Private/Subrs inventory, widths by FD, and cmap2/8/10/14. Supplementary Unicode conversion for cmap8 was still unverified in version 3.4; it is implemented in version 3.6. FD FontMatrix composition and complete VM/hinting remain unverified.
- RFC3986 resolution of XMP references and xml:base, without filesystem/network access or an implicit base. Further EXIF/Flashpix vocabulary and value-syntax checks.
- Original Swift U3D framing for headers, blocks, padding, metadata, and Priority Update. U3D geometry and PRC payloads remain unverified. RichMedia Instance/Asset references are followed outside the name tree too.
- Indirect OutputIntent profile identity is compared only when the array contains more than one entry; individual ICC validity has a separate model check.

Version 3.5 additions:

- ICC pseq/ncl2/psid payloads and embedded v2/v4 descriptions, with shared layouts/placeholders and explicit ambiguities. Required-tag v2 models are limited to documented editions; v2.0 does not retroactively receive v2.4 requirements.
- Supplementary Unicode cmap8 and full-repertoire selection; bounded Type2 audit of stack, arity, paths, hints/masks, terminators, and subroutines. It does not attest to geometry, hinting, all Private semantics, or a complete font VM.
- Mechanical logical-structure model: hierarchy/P/Pg/S, bidirectional IDTree and ParentTree, MCID/OBJR, modeled classes/attributes and namespaces. Optional null values and aliases are resolved without false failures. Human meaning and reading order remain unproven.
- PDF functions 0/2/3/4 reached through semantic links: parameters and dimensionality, packed samples, Domain/Range/Bounds compared as exact decimals; calculator grammar and stack on deterministic paths. Calculator arithmetic over the entire domain remains unverified. Sampling is never used to claim universal validity.
- COS reader with bounded indirect aliases, terminal identities, canonical Root/Pages/Kids/Type/Parent, and indirect Length/Filter/N/First. Null and undefined references do not interrupt page-entry inheritance. Alias cycles, cancellation, and budgets remain incomplete.

Version 3.6 additions:

- Native color-space schemas: exact WhitePoint without Double rounding, BlackPoint/Gamma CalGray/Matrix/Range, string/stream Indexed lookup extent and aliases, alternate-space restrictions, tint/Range dimensions, DeviceN/None/All/NChannel names, and Colorants. Null entries are omitted; limits and abbreviations outside their context remain incomplete. Complete Process/MixingHints relationships and colorimetry are not demonstrated. Details are in `ColorSpaceValidationEvidence.json`.
- ICC multiProcessElements: positions, chain channels, matrices, float32 CLUTs, curveSet/segmented/formula/sampled, and ACS. Prohibited nonfinite/subnormal binary values are distinguished from formulas unverified over their entire domain and unknown private types.
- TrueType: simple-glyph coordinates, bounds, point-to-point attachments with unsigned indices and phantom points, aggregate maxp maxima, and bounded nesting. A negative numberOfContours identifies composites even when it differs from −1; hinting/VM and final composite geometry remain incomplete.
- Standard structure attributes: Layout, List, Table, PrintField, and UserProperties; revisions and A/C precedence; Headers references to ID/TH; PDF1.7/PDF2 differences in WritingMode, types, and values. Custom namespaces, export schemas, header meaning, and reading order remain unverified.
- Single/array Contents streams, decoding, Metadata, and ICC identities now follow canonical aliases; caches share the same terminal identity. Null Contents means omission; non-stream array elements are distinguished from unverifiable cycles/budgets.

Checks read an immutable byte snapshot without modifying the PDF. Limits remain explicit: 512 MiB input, 256 MiB decoded streams, bounded counts and depths; reaching a limit produces an incomplete result. Execution runs in a background job with cancellation.

## Independent verification

The official veraPDF corpus is pinned to commit `377728596647e40edf16003d68d620773ce96ec5`: 2164 PDFs from `PDF_A-*` directories, under CC BY 4.0, with Git blob hashes verified during acquisition. Isartor is excluded. The corpus is not distributed in the app and is not downloaded during use. The pinned corpus contains cases for nine profiles and no 3a/3u directories; the native eleven-profile matrix exercises those profiles without claiming independent corpus coverage for them.

`Development/prepare-corpus.py --output /path/to/corpus` acquires and verifies official data only when explicitly run during development; it requires network access. `Development/validate-corpus.py --corpus /path/to/corpus --executable /path/to/CartaPDF.app/Contents/MacOS/CartaPDF --report /path/to/report.json` runs the original Swift binary on local data without a Java engine. The app neither runs nor requires these scripts. Many test names use historical numbers that differ from the pinned catalogue predicates: automatic name→rule comparison is **provisional**, not a measure of normative accuracy. Failure on an unrelated rule does not demonstrate that the test's requirement was checked. Semantically reviewed regressions are documented separately in tests and evidence.

## Required remaining coverage

1. Complete ISO 32000 and PDF 2.0 semantics, all filters/codecs, and payload verification; strict handling of every revision, undefined reference, and unsupported structure. Some physical violations are now detected, but this does not constitute a complete ISO parser.
2. Complete execution/verification of font programs: hinting and bytecode, dynamic PostScript cases, and unmodeled contexts. The validator does not execute programs. PDF vertical metrics W2/DW2 are distinct from font-program facts under ISO 32000-1 §9.9.
3. Complete graphics model, ICC functions/colorimetry and all tags/payloads, JPX/JBIG2/CCITT filters, initial pattern state in inherited resources, and inline cases with unsupported codecs.
4. XMP with complex/external DTDs, rdf:datatype in the 2004/2005 editions, unresolved versioned vocabularies, opaque custom types, relative URIs without an absolute base, and date consistency with ambiguous granularity/time zones. xml:base and relative references with a base are resolved locally according to RFC3986, without I/O. Local DTDs limited to text entities are supported; no external resource is read.
5. Assignment and meaning of all content in level A logical structure; complete U3D/PRC/Engineering interpretation and opaque or extensible CMS/ASN.1 schemas. AF associations in the active PDF 2.0 graph and supported DER structure do not prove these broader obligations.
6. Complete reconciliation of ISO 19005-1/2/3/4 and normative references, all exceptions and contexts, a verified corpus crosswalk, and specialist review. The complete ISO 19005-1/2/3/4 texts have not been acquired; no local copies were available. Adobe's public version of ISO 32000-1 was consulted for the cited technical specifications, without complete reconciliation.

These gaps also appear in `scopeGaps` and prevent the `conforming` verdict. They are not hidden by a complete catalogue, passing tests, or an Apple generation option. Apple frameworks enable local implementation of checks but do not offer a complete ISO PDF/A validation API.

## Apple generator evidence

`kCGPDFContextCreatePDFA` requests archival generation; it does not certify the output. In the fixture actually run on this SDK, a page without text produced XMP `part=2`, `conformance=B`: when 2u is selected, ISO 19005-2 §6.6.4 test 3 correctly fails. XMP is not changed to pretend a higher level. The level must be detected from the bytes and then verified; identification remains a declaration, not certification.

## Tests

The integrated suite includes `PDFArchiveValidatorTests`, `PDFArchiveFontChecksTests`, `PDFArchiveMetadataChecksTests`, `PDFArchiveGraphicsSyntaxTests`, `PDFArchiveStructureChecksTests`, `PDFArchiveObjectChecksTests`, and `CartaArchiveValidationTests`. It checks positive and negative cases, profile differences, corpus regressions, missing/tampered resources, and JSON/CLI reports. The final local result is generated in `Development/TestResults.log`; inventory and limitations are in `PDFA-ValidatorCoverage.json` and individual module evidence.

## Primary sources

- ISO 19005-1:2005 and corrigenda: https://www.iso.org/standard/38920.html
- ISO 19005-2:2011: https://www.iso.org/standard/50655.html
- ISO 19005-3:2012: https://www.iso.org/standard/57229.html
- ISO 19005-4:2020: https://www.iso.org/standard/71832.html
- ISO 32000-1 made available by Adobe: https://opensource.adobe.com/dc-acrobat-sdk-docs/standards/pdfstandards/pdf/PDF32000_2008.pdf
- Official veraPDF rules and data license: https://github.com/veraPDF/veraPDF-validation-profiles/tree/b76c28ff0d8809c30c4d0e64dc6c393f3c9019dc
- Rule model and structure: https://docs.verapdf.org/validation/rules/
- PDF/A-4 technical corrections published by the PDF Association: https://pdf-issues.pdfa.org/19005-4-2020/
- Apple native API contract: `CGPDFContext.h`, public key `kCGPDFContextCreatePDFA`, installed Xcode SDK. No private symbol is used.

Normative descriptions distributed in the catalogues and reproduced in reports retain the data's attribution and CC BY 4.0 license; the validator's Swift code is the project's original implementation.

Additional sources consulted for version 3.2:

- Adobe XMP: https://developer.adobe.com/xmp/docs/xmp-specifications/
- ICC.1:2022: https://www.color.org/specifications/ICC.1-2022-05.pdf
- CharSet/CIDSet: https://pdfa.org/wp-content/uploads/2018/06/1530_Seggern.pdf and https://github.com/veraPDF/veraPDF-library/issues/983
- PDF 2.0 errata: https://pdf-issues.pdfa.org/32000-2-2020/
- Official corpus: https://github.com/veraPDF/veraPDF-corpus/tree/377728596647e40edf16003d68d620773ce96ec5

Adobe CMap/AGL/PDF-to-Unicode data retain their BSD 3-Clause licenses and attributions in `Resources/PDFFontData`; no Adobe toolkit code is imported.

Additional version 3.3 sources: ISO 32000-1 §§7.3.10/7.4/7.8.2 and Table 77; [RFC 1950](https://www.rfc-editor.org/rfc/rfc1950), [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951); Adobe 5176 and Apple/Microsoft font specifications cited in font evidence; ITU X.690:2021 and PDF Association AN002 cited in structure evidence. New regressions, hashes, and independent checks are documented in StreamValidationEvidence.json and module evidence.

ASCIIHex without the > terminator: the two corpus cases with consistent length and ICC profiles are treated as unverified. Public sources do not explicitly resolve replacing the terminator with EOF bounded by Length. Inline boundaries always require independent proof. An undecodable ICC profile is not equivalent to an absent profile.

The earlier Release 3.3 run analyzed 2164 files without execution errors. Seven historical pass names also have a model violation involving inline samples: Flate produces 1062 bytes with a dictionary declaring one RGB pixel of 3 bytes and no DCT filter. Thirteen payloads were independently decoded with the standard library's zlib during development; bytes and normative references are in PDFA-CorpusModelReview.json. Historical names remain provisional comparisons of individual clauses, not overall attestations for files.

Additional version 3.4 sources: ICC.1:2001-04, ICC.1:2010-12, and ICC.1:2022-05 published by color.org; RFC3986, W3C XML Base, and XMP specifications cited in metadata evidence; ECMA-363 and PDF 2.0 Table343 errata cited in Engineering evidence. Checks are original Swift implementations; no external engine is included. Evidence and limitations are in ICCValidationEvidence.json and other module evidence.

Earlier verified Release 3.4: **367 native tests passed with zero failures**. The binary extracted from the package analyzed **2164 files in 19.209 seconds with zero execution errors**, and resources for all 11 profiles were verified outside the project. New model-failure review is in PDFA-CorpusReview34.json; corpus results do not prove ISO completeness. The binary does not emit complete conformity.

Additional version 3.5 sources: ISO 32000-1 §7.10/Tables 38–42 and §§7.3.9/7.3.10; PDF 2.0 errata, clauses 7 and 14; Microsoft/Apple/Adobe font specifications and ICC PSD_TechNote cited in evidence. Evidence is in FunctionValidationEvidence.json, ReferenceResolutionEvidence.json, and version 3.5 module supplements.

Verified Release 3.5: **447 native tests passed with zero failures**. The binary extracted from the package analyzed **2164 PDFs in 18.913 seconds with zero execution errors**. All 11 profiles and their resources were verified outside the project. The 29 new anomalies on historical pass names are reviewed in PDFA-CorpusReview35.json; three counterfactual corrections were verified on the Release binary. No corpus result proves ISO completeness; overall conformity remains disabled.

## Release 3.6 evidence

512 XCTest tests passed with zero failures; 65 more than version 3.5. The binary extracted from the ZIP processes 2164 corpus PDFs in 18.559 seconds without execution errors: 1509 nonconforming and 655 indeterminate. No new or removed failures compared with 3.5; per-file results match the frozen preflight except for diagnostic location order in 24 files (identical multisets). The CLI matrix also includes 22 positive/negative color fixtures across the eleven profiles. Strict ad hoc signature verification was performed on the extracted package; local resources and hashes are recorded in `ReleaseVerification.json`, `PackagingVerification.json`, and `BuildManifest.json`. These results do not demonstrate complete ISO validation.
