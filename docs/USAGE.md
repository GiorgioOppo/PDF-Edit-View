# User guide

The current version requires macOS 14 or later. To build the app from source, follow [BUILDING](BUILDING.md). The local bundle uses an ad hoc signature and is not notarized with Developer ID; it is not a signed public distribution.

The app follows macOS language preferences and supports seven languages, including both Chinese scripts, with English fallback. See [language selection](LOCALIZATION.md). This guide uses the English control names; the app displays their translations in the selected language. Search for tools using their displayed names.

## Open and edit documents

Open a PDF from Finder or from the app. Each document has its own window. Use thumbnails to navigate and reorder pages, search to find text, and reading views to adjust zoom and layout.

Open **Tools** with **⇧⌘T** to search for an operation. Save annotations and ordinary page edits with **⌘S**, and undo them with **⌘Z**. Open **Keyboard Annotations** with **⇧⌘K** to edit annotations, including their position and size.

Structural tools, scanning, conversions, and signing prepare separate copies. Check the filename and destination before saving. Keep the original when you need to preserve signatures, interactivity, or an earlier version of the content.

## Merge documents

1. Search for **“merge”** in **Tools**, open **Advanced Merging**, and add documents to the queue. In another interface language, search for the translated tool name.
2. Reorder the files and set any page ranges.
3. Check the preview of the final order and any warnings about duplicates or different formats.
4. Save the resulting document to a new destination.

Alternating front/back merging and grouping by name are also available. Protected documents must be accessible and permit the requested operation.

## Split documents

Splitting tools support page ranges, every N pages, bookmarks, separator text, blank pages, QR/barcodes, and a maximum output size. Choose the criterion, check the preview of groups and names, then choose the destination folder. Criteria based on content or recognition may need manual corrections.

The `split` CLI command produces one page per file; advanced criteria are available in the app interface. See [CLI](CLI.md).

## Scanning and conversions

OCR uses Vision on the Mac. Select the languages and check the recognized text, especially for columns, tables, and skewed documents. Scanner acquisition, screen capture, and reading aloud depend on system devices, permissions, and resources.

TXT, RTF, DOCX, and EPUB exports contain supported text; they do not faithfully reconstruct an Office page with formulas, tables, and images. Imported HTML is static; JavaScript and remote resources are blocked. Raster conversion, flattening, and compression can remove selectable text, annotations, forms, signatures, or protections from the copy. Compression does not guarantee a smaller file.

## Hidden content, encryption, and signatures

Cropping changes the visible area and leaves the underlying content in the PDF. Editing text or removing an attachment may leave its bytes in earlier revisions. To redact information, use the redaction tool that creates a raster copy and inspect the output, including every affected page.

Ordinary saving preserves encryption for supported documents. Some processing tools create a copy with different properties; check the tool's instructions. Structural operations do not decrypt protected PDFs.

CMS signing with a local certificate and a graphical signature are separate tools. Verification runs offline and checks integrity, the signed revision, and locally available trust. It does not establish current revocation status, TSA timestamps, long-term validation, complete PAdES support, or legally qualified status. Editing a signed document can invalidate its signature or add a revision that the signature does not cover.

## Archival reports

PDF/A generation through CoreGraphics and the validator report are separate operations. Choose the required profile and read both violations and incomplete checks. **CartaPDF 3.6.0 does not attest complete ISO PDF/A conformity**. Passed rules do not eliminate gaps in the model. See [PDFA](PDFA.md).

Preparing a CMYK ICC output intent does not certify PDF/X. Page-level tags and descriptions do not certify PDF/UA.

## Library and recovery

The library stores a local index and file references. If you move files outside the app, you may need to update their references. Watched folders operate while the app and the relevant panel are open.

Preferences let you manage automatic recovery copies. The versions panel keeps up to 20 versions per document. These records use disk space on the Mac and may contain sensitive content; read [PRIVACY](PRIVACY.md) before sharing folders, backups, or diagnostic reports.
