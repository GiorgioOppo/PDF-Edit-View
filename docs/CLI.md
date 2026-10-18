# CLI and local automation

The bundle executable accepts `--cli` and performs operations on the Mac without opening the main interface. These examples assume a build created using [BUILDING](BUILDING.md).

```sh
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli help
```

## Commands

| Command after `--cli` | Result |
| --- | --- |
| `language` | JSON with selected/preferred languages, packaged catalogue counts and translated control labels; no preferences are changed. |
| `info input.pdf` | JSON with page count, encryption, permissions, and extracted character count. |
| `merge output.pdf input1.pdf input2.pdf ...` | Ordered merge of at least two documents. |
| `extract input.pdf output.pdf '1-3,5'` | Copy of selected pages, numbered from 1. |
| `split input.pdf folder` | One-page files written to the specified folder. |
| `text input.pdf output.txt` | UTF-8 text extraction. |
| `ocr input.pdf output.pdf` | OCR through Vision and a new PDF copy. |
| `flatten input.pdf output.pdf` | Rasterized copy at 200 DPI. |
| `compress input.pdf output.pdf` | Rasterized copy at 150 DPI with JPEG; a smaller file is not guaranteed. |
| `validate-pdfa input.pdf profile [report.json]` | PDF/A JSON report; writes to standard output if no destination is supplied. |

The CLI does not expose every advanced splitting criterion, OCR language setting, or parameter available in the graphical tools.

```sh
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli merge Merged.pdf A.pdf B.pdf
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli extract A.pdf Extracted.pdf '1-3,5'
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli split A.pdf Pages
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli validate-pdfa A.pdf 4f Report.json
```

## PDF/A and exit codes

Accepted profiles: `1a`, `1b`, `2a`, `2b`, `2u`, `3a`, `3b`, `3u`, `4`, `4e`, `4f`.

| Code | Meaning |
| --- | --- |
| `0` | Ordinary operation completed. For `validate-pdfa`, this would mean complete conformity: **it is not emitted in 3.6.0**. |
| `1` | Usage, read, write, or execution error. |
| `2` | `validate-pdfa`: at least one demonstrated violation. |
| `3` | `validate-pdfa`: indeterminate result, with incomplete checks or obligations. |

Exit code 2 or 3 from `validate-pdfa` is a validator result, not necessarily a process failure. Handle it explicitly in scripts that stop on a nonzero exit code:

```sh
status=0
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli validate-pdfa A.pdf 4 Report.json || status=$?
case "$status" in
  0) printf '%s\n' 'Complete conformity attested' ;;
  2) printf '%s\n' 'Violations: read the report' ;;
  3) printf '%s\n' 'Incomplete validation: read the report' ;;
  *) exit "$status" ;;
esac
```

Exit code 0 is reserved for a future complete implementation. Do not treat the absence of violations, a single `passed` result, or the number of rules as an attestation of conformity. Read `scopeGaps` and the additional model checks as well. See [PDFA](PDFA.md).

## Passwords and destinations

For operations that open the document through PDFKit, use `--password-file path`. The file is read locally; protect it with appropriate permissions and keep it out of the repository. Do not pass the password as a direct argument or save it in examples, presets, or logs.

`validate-pdfa` analyzes the original bytes and does not decrypt the document using `--password-file`; encrypted PDFs are handled according to the archival rules and parser limitations.

File-writing operations refuse to overwrite source files. `--overwrite` allows an existing output to be replaced for commands that write through a file destination. `split` uses a folder and its own conflict handling; do not assume that `--overwrite` permits replacing the files it produces. Use separate destinations and check the results before deleting originals.

OCR, flattening, and compression can change selectable text, interactivity, encryption, and signatures in the copy. Operations respect supported PDF permissions and may reject protected documents.

## Shortcuts and AppleScript

After opening the app, search for **“Merge PDFs”** in Shortcuts. The App Intent receives documents and returns a merged file, preserving the sources. This is the English action title; search for its translated name when using another selected language. See [languages](LOCALIZATION.md).

The AppleScript dictionary exposes:

```applescript
tell application id "it.cartapdf.editor"
    merge PDFs files {"/path/A.pdf", "/path/B.pdf"} destination "/path/Merged.pdf"
end tell
```

The CLI and the Intent have automated tests. The AppleScript dictionary has been compiled in Script Editor; actual dispatch from the calling program remains an outstanding manual check, as recorded in the [feature report](../Development/FeatureVerification.json).
