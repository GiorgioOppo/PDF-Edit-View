# Privacy and permissions

CartaPDF processes documents on the Mac. It requires no account, subscription, or cloud service and contains no application telemetry or remote AI services. OCR, comparison, conversions, search, and CMS/PDF/A checks run locally. The project does not automatically upload PDFs or reports to GitHub.

This description covers the app's code. System settings, backups, synchronization of user-selected folders, and external services opened voluntarily remain under the control of the user and macOS.

## Connections and external content

Web links in PDFs open through system integrations when the user activates them. The browser or destination service applies its own privacy policy. HTML conversion uses static content with JavaScript and remote resources blocked.

Signature verification does not contact online revocation or timestamp services. The PDF/A validator does not resolve external DTDs, open attachments, or execute payloads. Metadata URIs are analyzed as data.

Development scripts for acquiring the corpus require network access only when explicitly run. GitHub and repository collaboration tools are services separate from the app.

## Data stored locally

| Data | Location or mechanism | Contents |
| --- | --- | --- |
| Documents and output | User-selected destinations | Exported PDFs, images, text, signatures, and reports. |
| Preferences | UserDefaults for `it.cartapdf.editor` | Annotation author, tools, shortcuts, cache, jobs, and panel settings. |
| Library | `~/Library/Application Support/CartaPDF/Library.json` | Paths, bookmarks, categories/tags, and a text index of imported documents. |
| Local versions | `~/Library/Application Support/CartaPDF/Versions` | Up to 20 copies per document and version metadata. |
| Recovery | `~/Library/Application Support/CartaPDF/Recovery` | Automatic copies of modified documents and associated metadata. |
| Reading state | `~/Library/Application Support/CartaPDF/Reading` | Page, zoom, and layout; the record name is derived from a hash of the path. |
| Temporary files | macOS temporary directory | Working data and staging for operations that require them. |

Local copies and indexes may contain confidential information. Hashing a path does not encrypt the record's content or metadata. The library does not add encryption to its text index. Recovery and version copies use the document's serialized bytes; their protection depends on the document and the supported saving path.

The annotation author defaults to the macOS user's full name and can be changed in preferences. It can appear in saved annotation metadata. Paths, names, text, and metadata may appear in reports or files you choose to share; review them before publishing.

## Passwords, keys, and certificates

PDF passwords are requested for an operation or read by the CLI with `--password-file`. The app does not save them in presets or history. The password file is created and managed by the user and may remain on disk until removed.

Signing uses the selected local certificate; verification uses the original bytes and locally available trust. Keychain credentials and system permissions remain managed by macOS. Do not attach private keys, password files, or confidential documents to issues or pull requests.

## Permissions and integrations

- **Files:** the app accesses selected documents and folders and its own local support directories. The bundle produced by the build script must not be described as a sandboxed app.
- **Screen recording:** ScreenCaptureKit capture requires the relevant macOS consent.
- **Scanners:** Image Capture requires a compatible device and driver already available on the system.
- **Speech:** reading aloud uses voices available on the Mac; the app does not download voices.
- **Automation:** Shortcuts and AppleScript may involve system permissions for the calling program.

Physical scanner, actual screen capture, and audio playback checks are separate from automated tests. A complete VoiceOver audit has not been attested; see [ACCESSIBILITY](ACCESSIBILITY.md).

## Manage or remove data

Use the library panel to remove indexed entries and the versions/recovery panels to manage available copies. Preferences let you disable automatic recovery copies. Removing a library reference does not necessarily delete the original PDF.

To delete all support data, first close the app, check which copies you want to keep, and use Finder to delete the `CartaPDF` folder in Application Support. This also removes the index, versions, and recovery copies. PDFs saved elsewhere, user-created password files, and backup copies remain in their respective destinations. System preferences are separate from the support folder.

For a vulnerability that exposes data, follow [SECURITY](../SECURITY.md). For a usage problem without confidential data, follow [SUPPORT](../SUPPORT.md).
