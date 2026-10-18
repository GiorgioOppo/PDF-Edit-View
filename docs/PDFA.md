# PDF/A validation: interpreting results

**CartaPDF 3.6.0 is not a complete ISO PDF/A validator and does not emit the overall `conforming` verdict.** Its report distinguishes demonstrated violations, incomplete checks, and conditions verified within the implemented scope.

The engine is written in Swift and uses only Apple frameworks. Original veraPDF catalogues are local XML data under CC BY 4.0; the veraPDF Java engine is not included.

## Profiles and catalogues

| Family | Profiles | Catalogue entries per profile |
| --- | --- | --- |
| PDF/A-1 | 1a, 1b | 135, 129 |
| PDF/A-2 | 2a, 2b, 2u | 153, 144, 146 |
| PDF/A-3 | 3a, 3b, 3u | 155, 146, 148 |
| PDF/A-4 | 4, 4e, 4f | 111 each |

The **1489 entries** include conditions shared across profiles; they are not 1489 independent implementations. The catalogue pinned to commit `b76c28ff0d8809c30c4d0e64dc6c393f3c9019dc` is verified with SHA-256. A complete inventory does not prove complete coverage of the underlying ISO 32000 semantics.

## Document verdict

| Verdict | Interpretation |
| --- | --- |
| `nonconforming` | At least one violation is demonstrated by the implemented checks. |
| `indeterminate` | No demonstrated violation, but obligations, parsing, resources, or checks remain incomplete; cancellation and budgets may also prevent a conclusion. |
| `conforming` | Reserved for future demonstrated complete coverage; disabled in the current version. |

A condition's `passed` result applies to that condition in its stated context. `notApplicable` applies only to objects explicitly indexed by the check. `notVerified` and `scopeGaps` cannot be interpreted as passing results. The report retains the SHA-256 hash of the analyzed bytes and additional model checks separate from catalogue entries.

## Implemented scope

Checks include supported physical syntax and references, fonts and Unicode mapping, RDF/XMP, ICC/color spaces, PDF functions, modeled graphics, annotations, forms, OCGs, attachments, and signatures. Version 3.6 adds calibrated/Indexed/Separation/DeviceN color-space schemas, stream/Metadata aliases, ICC multiprocess elements, TrueType coordinates and point attachments, and standard structure attributes.

Complete ISO 32000/PDF 2.0 semantics, advanced codecs and payloads, font execution/hinting, colorimetry and functions over their entire domains, some XMP forms, logical structure meaning, U3D/PRC/Engineering, and full normative reconciliation remain incomplete. The authoritative technical list is [PDFA-ValidatorScope](../Development/PDFA-ValidatorScope.md), with linked module evidence.

The validator reads a byte snapshot without modifying the PDF. Explicit limits include 512 MiB of input and 256 MiB per decoded stream, with bounded counts and depths. Reaching a limit makes verification incomplete; it does not prove validity. Payloads, font programs, and attachments are not executed.

## Generation and identification

Apple's `kCGPDFContextCreatePDFA` option requests archival generation and does not certify the output. The declared level is read from the bytes: in the verified fixture, requesting 2u produced a document declaring 2b, correctly distinguished from the requested profile. CartaPDF does not artificially raise the XMP level.

XMP identification, generation, and validation are three separate facts. A document that declares a profile or renders correctly can still violate its requirements.

## Version 3.6 evidence

- 512 XCTest tests passed with zero failures in the recorded execution.
- Release binary extracted from the package: 2164 corpus PDFs analyzed without execution errors, producing 1509 `nonconforming` and 655 `indeterminate` verdicts.
- CLI matrix for all eleven profiles and positive and negative fixtures for the new color checks.
- Extracted bundle resources and ad hoc signature verified; test inputs unchanged.

The pinned corpus contains directories for nine profiles, without 3a and 3u. The native matrix exercises those profiles without claiming independent corpus coverage for them. Automatic mapping between historical fixture names and current rules is provisional: the results are neither an accuracy percentage nor ISO certification.

Result sources: [FeatureVerification](../Development/FeatureVerification.json), [CorpusEvidence](../Development/PDFA-CorpusEvidence.json), [ReleaseVerification](../Development/ReleaseVerification.json), and [coverage](../Development/PDFA-ValidatorCoverage.json).

## Contributing to the validator

A new condition requires a primary source with edition and clause, an explicit semantic scope, positive and negative fixtures, and separate handling of ambiguous, private, canceled, or limited cases. Isolate a regression in the relevant bytes or model. Do not remove `scopeGaps` merely because tests or catalogues pass: coverage of the corresponding normative obligation must be demonstrated.
