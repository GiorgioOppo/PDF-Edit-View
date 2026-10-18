# Preparing for public release

The [GiorgioOppo/PDF-Edit-View](https://github.com/GiorgioOppo/PDF-Edit-View) repository was created as private. This documentation prepares a future source release; **it neither authorizes nor changes visibility, and it does not automatically publish binaries**. The project is named PDF-Edit&View, with the GitHub slug PDF-Edit-View; the app remains CartaPDF 3.6.0.

## Repository contents

The source repository should include code, tests, resources and their licenses, scripts, guides, and selected technical evidence. Build directories, bundles, distribution archives, acquired corpora, personal documents, passwords, private keys, and credentials must stay out of Git. Check both tracked files and commit history before making the repository public: adding a `.gitignore` rule does not remove previously committed data.

Historical reports in Development describe the stated release and may contain paths or fixture names. Preserve the validity of the evidence, but publish only data you can share. Do not edit a hash or result by hand to make verification appear recent.

## Before changing visibility

1. Review the diff and history for credentials, personal documents, identifying paths, confidential content, and material that cannot be redistributed.
2. Check that MIT, CC BY 4.0, and BSD licenses are present, with attributions and manifests in both resource copies.
3. Check relative links, build instructions, version, PDF/A limitations, and VoiceOver audit status.
4. Run repository checks and the appropriate native suite; document the latest actual execution and environment limits separately.
5. Check GitHub settings: default branch, collaborator permissions, Actions, available protections, reporting channels, and private vulnerability reporting if desired and available.
6. The owner explicitly decides to change visibility from private to public after checking the content actually pushed.

An App Store release is not required to distribute the MIT sources. Verified binary distribution has different operational requirements from opening the source code.

## Before distributing a binary

- Build from an identified commit and verify the app actually extracted from the final archive.
- Record the version, architecture, toolchain, SHA-256 hashes, and relevant test results.
- Check resources outside the workspace and the signature on the extracted bundle.
- For signed public distribution, prepare Developer ID signing and notarization with an authorized account and credentials; the current ad hoc signature does not replace them.
- Include licenses, instructions, limitations, and a changelog. Publish artifacts only after verifying their provenance and contents.

No release should describe CartaPDF as a “complete ISO PDF/A validator,” “PDF/UA certified,” “complete PAdES,” or equivalent until the corresponding coverage is demonstrated. The corpus, catalogues, and tests provide evidence within their stated scope.

## Open technical priorities

Specific gaps are documented in [PDFA-ValidatorScope](../Development/PDFA-ValidatorScope.md) and [FeatureVerification](../Development/FeatureVerification.json). Outstanding checks include complete normative semantics, a full VoiceOver audit, real scanner/capture/audio workflows, and AppleScript dispatch. No unverified completion dates or promises are assigned.
