# Install CartaPDF 3.6.0

## Requirements and download

The downloadable app requires **macOS 14 or later on an Apple Silicon Mac (arm64)**. Version 3.6.0 does not include an Intel or universal binary.

Download these files from the [official v3.6.0 release](https://github.com/GiorgioOppo/PDF-Edit-View/releases/tag/v3.6.0):

- [CartaPDF-3.6.0-macOS-arm64.zip](https://github.com/GiorgioOppo/PDF-Edit-View/releases/download/v3.6.0/CartaPDF-3.6.0-macOS-arm64.zip) — the app and accompanying release files.
- [SHA256SUMS.txt](https://github.com/GiorgioOppo/PDF-Edit-View/releases/download/v3.6.0/SHA256SUMS.txt) — published file checksums.
- [Release notes](https://github.com/GiorgioOppo/PDF-Edit-View/releases/download/v3.6.0/RELEASE_NOTES.md) — included tools and known limits.

GitHub's **Source code** archives contain source files, not the built app. To build from source, follow [BUILDING](BUILDING.md).

**The app has an ad hoc signature and is not notarized by Apple.** The signature seals the bundle but does not identify a Developer ID holder. macOS may block its first launch; the app-specific approval steps below apply only if you trust the official download.

## Verify the ZIP

In Terminal, change to the folder containing the downloaded ZIP and run:

```sh
shasum -a 256 CartaPDF-3.6.0-macOS-arm64.zip
```

Compare the complete 64-character hash with the entry for `CartaPDF-3.6.0-macOS-arm64.zip` in `SHA256SUMS.txt`. Other manifest entries describe separate release files; you do not need to download those files to compare the ZIP's hash. A matching hash confirms agreement with the published checksum, rather than Developer ID identity or Apple notarization.

## Install and open

1. Double-click the ZIP in Finder to extract the `CartaPDF-3.6.0` folder.
2. Open that folder and drag `CartaPDF.app` into **Applications**.
3. Open CartaPDF from Applications.
4. Open a PDF with **File > Open** or **⌘O**. Use **⇧⌘T** to open **Tools**, where you can find merging, splitting, OCR and other operations. See the [user guide](USAGE.md).

The interface follows ordered macOS system or per-app language preferences at launch. Italian, Spanish, English, German, French, Chinese (Simplified and Traditional) and Japanese are bundled. If no preference matches, CartaPDF uses English. Quit and reopen the app after changing its language preference. Interface language selection does not translate PDFs or choose OCR recognition languages. See [language selection](LOCALIZATION.md).

## If macOS blocks the first launch

If macOS cannot verify the developer or check the app for malicious software, and you trust the verified official download:

1. Attempt to open CartaPDF from Applications and dismiss the warning.
2. Open **System Settings > Privacy & Security**, scroll to the security section and select **Open Anyway** for CartaPDF if offered.
3. Review the repeated prompt and choose **Open** to approve that app's exception.

Follow [Apple's official guidance](https://support.apple.com/en-us/102445). Managed Macs may restrict this option. If the warning says the app **will damage your computer** or **is damaged**, stop and report the problem; these steps do not resolve that warning. Keep Gatekeeper enabled and retain quarantine attributes.

## Update

Save open documents and quit CartaPDF. Download the intended release from the repository's [Releases page](https://github.com/GiorgioOppo/PDF-Edit-View/releases), read its requirements and notes, and verify its ZIP checksum. Extract it and replace the existing `CartaPDF.app` in Applications when Finder asks. Replacing the app leaves documents and support data in their existing locations. Keep backups of documents and recovery copies you need.

## Permissions and local data

Document processing runs locally, without an application account, subscription or cloud service. Screen capture requires macOS permission; scanning requires an Image Capture-compatible device and driver. Reading aloud uses voices already installed on the Mac. The app does not download drivers or voices. macOS security checks and websites opened voluntarily are separate from CartaPDF's document processing. See [privacy and permissions](PRIVACY.md).

## Uninstall

Quit CartaPDF and move `CartaPDF.app` from Applications to the Trash. Your documents and support data remain in place.

Preferences use the `it.cartapdf.editor` application domain. Library, reading-state, version and recovery data is stored in `~/Library/Application Support/CartaPDF`. Keep that folder if you may reinstall. Before deleting it in Finder, copy out any versions or recovery PDFs you need: removing it deletes those copies and the library index. PDFs saved elsewhere and your system backups remain in their own locations. See [managing local data](PRIVACY.md#manage-or-remove-data).

## License and help

Original code is [MIT-licensed](../LICENSE); bundled reference data retains its [separate licenses and attribution](../THIRD_PARTY_NOTICES.md). Read the [release notes](https://github.com/GiorgioOppo/PDF-Edit-View/releases/download/v3.6.0/RELEASE_NOTES.md) and the documented [PDF/A](PDFA.md) and [accessibility](ACCESSIBILITY.md) limits. For help, follow [SUPPORT](../SUPPORT.md) and use synthetic reproductions without private PDFs, passwords or keys.
