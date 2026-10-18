# Security

CartaPDF is under development. No complete security audit is claimed, and no response time is guaranteed. Fixes are evaluated against the current version; there is no defined backport policy for earlier versions.

## Report a vulnerability

If **Report a vulnerability** is available in the repository's **Security** tab, use that private GitHub channel. Its availability depends on the owner enabling private vulnerability reporting; this document does not assume it is enabled.

If that channel is unavailable, do not publish exploits, credentials or confidential documents in an issue. You may open a neutral issue asking for a private channel to be enabled, without sensitive details, and wait for an agreed contact method before sharing evidence. No unverified email address is listed.

A useful report includes the app and macOS versions, affected component, observed impact, minimal reproduction steps and a synthetic fixture. Share only data you may redistribute, and remove passwords, private keys and personal information. Keep details confidential until disclosure has been agreed.

## Scope

The dated [repository maintenance record](Development/RepositoryMaintenanceVerification.json) records verified Dependabot alert enablement and the private-plan branch-protection limitation observed during that run. Current settings must be verified on GitHub. The workflow pins its official action to a full SHA and uses read-only permissions without persisting checkout credentials. Dependabot version updates maintain that pin. GitHub's alerts for Actions cover semantic-version references, not SHA references, so alert enablement must not be presented as vulnerability coverage of the pinned action. See [GitHub's alert limitations](https://docs.github.com/en/code-security/concepts/supply-chain-security/dependabot-alerts#limitations).

Relevant issues include data exposure, unexpected writes, unreported loss of encryption, unsafe handling of malformed files or PDFs, bypassed limits and dangerous interpretation of external content. A documented gap in the PDF/A validator is normally a correctness issue; it may have security implications if it causes a false attestation or exploitable behavior.

The app processes data locally, but local files and untrusted PDFs can still exercise native parsers and frameworks. Resource budgets and cancellation reduce some risks; they are not a sandbox or a formal proof of security.

## Protect your data

Do not send confidential documents to the repository. The app may keep a text index, versions and recovery data on the Mac; see [PRIVACY](docs/PRIVACY.md). Ad hoc signing of local builds does not certify the publisher's identity. Legal signature validation, current revocation information and complete ISO conformity are not attested.

If a credential is accidentally committed to Git or shared, revoke or rotate it through the relevant service. Removing a file from the latest commit does not remove copies from history or clones.
