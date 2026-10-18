# Contributing to CartaPDF

We welcome fixes, tests and documentation that keep the app free, entirely local and based only on Apple frameworks. See the [documentation](docs/README.md) for the architecture and build requirements.

## Before you start

Read the [limitations](README.md), [data licenses](THIRD_PARTY_NOTICES.md) and [code of conduct](CODE_OF_CONDUCT.md). For an ordinary defect, open an issue with a minimal synthetic example. For larger changes, describe the problem and proposed approach before investing in a substantial implementation. Follow [SECURITY](SECURITY.md) for vulnerabilities.

Do not upload personal PDFs, certificates containing private keys, password files, logs containing credentials or copies of standards you do not have permission to redistribute. Examples must be created for testing or come from a source with a documented license.

## Implementation constraints

- Use Swift and public Apple APIs. Do not introduce third-party packages, engines, network services, telemetry or runtime dependencies.
- Make scope, errors and operations that save a separate copy explicit. Do not present rasterization as lossless structural editing.
- Respect undo, cancellation, memory limits and document permissions in the relevant workflows.
- Distinguish editing, redaction, encryption and signing. Incremental revisions and cropping do not guarantee data removal.
- Avoid unrelated changes and preserve the attribution of bundled data.

## PDF/A validator

A new or corrected check must cite a primary source, edition and clause in the appropriate evidence. Define which objects, revisions and contexts it inspects, and how it handles null values, aliases, private objects, unsupported input, limits and cancellation. Add positive and negative fixtures that isolate the requirement, including a regression test when fixing an actual defect.

Do not use a corpus fixture's filename as the only normative evidence. Do not mark an unimplemented check as `passed` or `notApplicable`. Do not remove `scopeGaps` without demonstrating complete coverage of the corresponding obligation. The current version does not report overall ISO conformity.

Catalogues and font tables are pinned data verified by hashes. When proposing an update, preserve the provenance, commit, license and original bytes. Update both resource copies and their code contracts together. Do not modify upstream data to make a check pass.

## Verify a change

```sh
python3 scripts/check-repository.py
./scripts/test.sh --filter SuiteName
./scripts/test.sh
./scripts/build-app.sh
```

Choose checks appropriate to the change. A text-only edit does not justify claiming a new runtime verification. Changes to parsing, writing, signing or validator results need targeted tests of actual behavior. For UI and hardware checks, record what you observed and what remains unverified.

Do not rewrite historical reports as though their tests were rerun. When generating new evidence, record the version, environment, inputs and relevant hashes. See [BUILDING](docs/BUILDING.md) for instructions.

## Pull requests

Describe the concrete problem, resulting behavior, checks actually run and remaining limitations. Link relevant issues and include screenshots only if they contain no personal information. Feature changes must update the affected guides or limitations; normative corrections must update the module's evidence.

Repository documentation and GitHub templates use English. The app supports seven languages and follows macOS language preferences with English fallback. See [translation maintenance](docs/LOCALIZATION.md) before changing interface strings. You may discuss contributions in English or Italian.

By submitting a contribution, you confirm that you have the right to share it under the code's MIT license or, for separate data, its stated license and provenance. No copyright assignment is required. Resources with their own licenses retain their respective obligations.
