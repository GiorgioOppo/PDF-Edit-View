# Public releases and distribution

The [GiorgioOppo/PDF-Edit-View](https://github.com/GiorgioOppo/PDF-Edit-View) repository is public. The first downloadable release, [CartaPDF 3.6.0](https://github.com/GiorgioOppo/PDF-Edit-View/releases/tag/v3.6.0), was published on October 18, 2026. The project is named PDF-Edit&View, with the GitHub slug PDF-Edit-View; the app is named CartaPDF. This guide records the published distribution and the checks to repeat for future releases. Historical preparation reports retain the settings and limitations observed at their original dates.

## Published 3.6.0 download

- [CartaPDF-3.6.0-macOS-arm64.zip](https://github.com/GiorgioOppo/PDF-Edit-View/releases/download/v3.6.0/CartaPDF-3.6.0-macOS-arm64.zip): Apple Silicon only, macOS 14 or later, version 3.6.0/build 9. No Intel or universal binary is included.
- [Installation guide](INSTALLATION.md): checksum verification, copying the app to Applications and app-specific first-launch approval. The ZIP includes standalone instructions, notes and licenses; [release-time instructions](https://github.com/GiorgioOppo/PDF-Edit-View/releases/download/v3.6.0/INSTALLATION.md) are also available as an asset.
- [Release notes](https://github.com/GiorgioOppo/PDF-Edit-View/releases/tag/v3.6.0), [SHA-256 checksums](https://github.com/GiorgioOppo/PDF-Edit-View/releases/download/v3.6.0/SHA256SUMS.txt) and [verification manifest](https://github.com/GiorgioOppo/PDF-Edit-View/releases/download/v3.6.0/ReleaseVerification.json).

The app has an **ad hoc signature and is not Apple-notarized**. It has no Developer ID identity. The public verification manifest describes the exact ZIP and app inventory, build toolchain, checks outside the workspace and signing status. It is separate from older local-build reports under `Development/`.

The source tag `v3.6.0` identifies commit `84c4ec255069757f7773e2e8e28ed90e9e839812`. Both required CI jobs passed for that commit in [run 39154449179](https://github.com/GiorgioOppo/PDF-Edit-View/actions/runs/39154449179). The distributed app was built separately with the toolchain recorded in its verification manifest. Subsequent documentation updates do not rebuild or modify the published archive.

`main` is protected with both required checks, an up-to-date branch, resolved conversations and a pull request, including for administrators. Force pushes and deletion are blocked. Check the live GitHub settings and workflow results when preparing each subsequent change.

## Repository contents

The source repository should include code, tests, resources and their licenses, scripts, guides, and selected technical evidence. Build directories, bundles, distribution archives, acquired corpora, personal documents, passwords, private keys, and credentials must stay out of Git. Check both tracked files and commit history before making the repository public: adding a `.gitignore` rule does not remove previously committed data.

Historical reports in Development describe the stated release and may contain paths or fixture names. Preserve the validity of the evidence, but publish only data you can share. Do not edit a hash or result by hand to make verification appear recent.

## Before changing visibility

1. Review the diff and the history reachable from every advertised remote branch and tag that will be exposed for credentials, personal documents, identifying paths, confidential content, and material that cannot be redistributed. Also inspect repository issues, pull requests, release assets, historical Actions logs/artifacts and any wiki; a source-file check does not inspect these surfaces.
2. Check that MIT, CC BY 4.0, and BSD licenses are present, with attributions and manifests in both resource copies.
3. Check relative links, build instructions, version, PDF/A limitations, VoiceOver audit status and the distinction between native snapshots and completed interactive UI observations.
4. Run repository checks and the appropriate native suite; document the latest actual execution and environment limits separately. Confirm that the GitHub workflow passed for the exact pushed commit being considered for publication.
5. Check GitHub settings: default branch, collaborator permissions, Actions, available protections, reporting channels, and private vulnerability reporting if desired and available.
6. The owner explicitly decides to change visibility from private to public after checking the content actually pushed.

An App Store release is not required to distribute the MIT sources. Verified binary distribution has different operational requirements from opening the source code.

## Reproducible source checks

Run these checks on the proposed publication tree:

```sh
python3 scripts/check-repository.py
python3 scripts/check-localization.py
./scripts/test.sh
./scripts/build-app.sh
python3 scripts/check-built-app.py dist/CartaPDF.app
```

The repository checker inspects tracked working-tree files, relative Markdown links, resource licenses and hashes, permitted imports, selected credential patterns and CI permissions. Add intended new source files to the index before relying on it. It does not inspect past commits, untracked files, hosted GitHub content or every possible secret. Review those separately and record the branches, tags and commit range actually checked. Do not publish local task snapshots or mirror all local refs as part of an ordinary source push.

Keep raw logs, screenshots, generated app copies and fixtures outside the published tree unless they have been explicitly reviewed for redistribution. Dated evidence should identify the source commit, command, result, hashes and any skips or unavailable checks. A previous successful run remains historical evidence rather than a result for later changes.

For a complete local history, the read-only history checker takes explicit refs. Include every advertised branch and tag and acquire any PR merge refs being reviewed separately:

```sh
python3 scripts/check-publication-history.py \
  --ref refs/heads/main \
  --ref refs/remotes/origin/main
python3 Development/verify-publication-history.py
```

The first command checks only the refs supplied and refuses a shallow history. Add the actual additional refs from the repository inventory; the example is not an assertion that `main` is the only exposed branch. The fixture verifier exercises historical removal, renamed sensitive filenames, commit/tag identities and scope boundaries in disposable local Git repositories. CI runs these regression fixtures without changing repository visibility.

GitHub also makes historical Actions logs visible when a repository becomes public. Review their contents before changing visibility, including earlier failed runs; successful current tests do not sanitize older hosted data. See [GitHub's visibility consequences](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility).

## GitHub security settings

Dependabot alerts were enabled and verified with HTTP 204 from the repository's vulnerability-alerts endpoint; that operation also enables the dependency graph. The [maintenance record](../Development/RepositoryMaintenanceVerification.json) dates this configuration and the observed alert inventory while the repository was still private. GitHub's alerts for Actions support semantic-version references, not SHA references; the pinned checkout action is maintained through the separate Dependabot version-update configuration. Enabled alerts and an empty alert inventory do not establish complete security coverage. See [GitHub's documented alert limitations](https://docs.github.com/en/code-security/concepts/supply-chain-security/dependabot-alerts#limitations).

The [main protection payload](../.github/main-protection.json) requires both configured checks, `Apple Silicon · Xcode 26.3` and `Apple Silicon · Xcode 26.6`, on an up-to-date branch, resolved conversations and a pull request, and blocks force pushes and branch deletion. It applies the requirements to administrators too. Verify successful executions and the exact rendered names before applying it. Zero mandatory approving reviews supports a solo maintainer while retaining the pull-request and CI requirements.

The earlier private-repository attempt documented in the maintenance record returned HTTP 403 requiring GitHub Pro or public visibility. That attempt applied no protection, activated no paid plan and preserved visibility. On a plan that supports private branch protection, or after an explicitly authorized visibility change, the owner can apply the current payload with:

```sh
gh api --method PUT repos/GiorgioOppo/PDF-Edit-View/branches/main/protection \
  --input .github/main-protection.json
```

Then verify the returned protection settings and the exact required check name. Check approval policy for workflows from outside contributors, secret scanning/push protection and private vulnerability reporting in the public repository. Their availability is not evidence that they are enabled. [GitHub documents private vulnerability reporting separately](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository).

## What is ready and what remains separate

The repository contains English setup, usage, contribution, support and security guides, issue forms, a pull-request template, the MIT license and bundled-data notices. The [verification records](../Development/README.md) describe the checks actually performed; [PublicationReadiness](../Development/PublicationReadiness.json) separates publication-preparation findings from settings or checks still pending. These files establish documentation and evidence coverage; GitHub settings and publication decisions must still be verified separately.

The following statements must remain visible in the public README and guides:

- All seven interface languages are bundled, with eight resource variants and English fallback. Native component snapshots and partial interactive observations have different scopes; neither establishes a complete VoiceOver or independent linguistic audit.
- All eleven PDF/A profiles are distinguished, but complete ISO validation remains unfinished and this version never emits `conforming`.
- Hardware workflows, complete accessibility testing and AppleScript dispatch retain their documented manual-check status.
- Source builds and the public 3.6.0 download use an ad hoc signature. The published download is not notarized; app signing does not qualify document signatures or certify PDF output.

These technical limitations do not need to be hidden or relabeled to publish the source. Keep them accurate and link the relevant evidence instead of claiming unperformed validation.

## Before distributing a binary

- Build from an identified commit and verify the app actually extracted from the final archive.
- Record the version, architecture, toolchain, SHA-256 hashes, and relevant test results.
- Check resources outside the workspace and the signature on the extracted bundle.
- For an identified developer signature and notarization, use Developer ID signing with an authorized account and credentials. An ad hoc release must disclose the absence of Developer ID and notarization and provide app-specific first-launch instructions without disabling system protections.
- Include licenses, instructions, limitations, and a changelog. Publish artifacts only after verifying their provenance and contents.

No release should describe CartaPDF as a “complete ISO PDF/A validator,” “PDF/UA certified,” “complete PAdES,” or equivalent until the corresponding coverage is demonstrated. The corpus, catalogues, and tests provide evidence within their stated scope.

## Open technical priorities

Specific gaps are documented in [PDFA-ValidatorScope](../Development/PDFA-ValidatorScope.md) and [FeatureVerification](../Development/FeatureVerification.json). Outstanding checks include complete normative semantics, a full VoiceOver audit, real scanner/capture/audio workflows, and AppleScript dispatch. No unverified completion dates or promises are assigned.
