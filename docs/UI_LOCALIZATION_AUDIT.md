# Localization interface review

This guide describes a reproducible visual review of CartaPDF's seven interface languages: English, Italian, Spanish, German, French, Chinese and Japanese. Chinese has separate Simplified and Traditional variants, so the review uses eight app copies.

Preparing the copies and passing command-line checks does not complete a GUI review. Record the windows actually opened, interactions performed, window sizes and screenshots before reporting a surface as reviewed.

## Prepare isolated copies

Start with a freshly assembled macOS app and a new output directory:

```sh
python3 Development/prepare-ui-audit.py dist/CartaPDF.app \
  --output /private/tmp/CartaPDF-UIAudit-review
```

The output directory must not already exist. Omitting `--output` creates a new temporary directory automatically. The script requires the macOS developer tools and uses Python's standard library together with Apple's native tools.

The script creates `CartaPDF UI <language>.app` for `en`, `it`, `es`, `de`, `fr`, `zh-Hans`, `zh-Hant` and `ja`, plus `Support/`, `Sandboxes/` and `manifest.json`. Each copy has a unique bundle identifier. The original app remains unchanged; the copies receive an ad hoc signature for local testing.

A small native launcher runs the copied CartaPDF executable with a process-only `-AppleLanguages '("<language>")'` argument. It sets `CFFIXED_USER_HOME` to that copy's isolated Foundation home directory, records the location in the task-specific `CARTAPDF_UI_AUDIT_HOME` variable, and sets `TMPDIR` to its temporary directory. The inherited `HOME` and `CODEX_HOME` variables remain unchanged. The launcher clears SwiftPM resource overrides so the copy loads its packaged translations. These settings do not change the user's macOS language preferences.

The manifest records hashes of the base executable and localization tables, the generated launchers, bundle identifiers, signature verification and each copy's `--cli language` result. Its preparation flags deliberately remain `gui_launched: false` and `manual_ui_audit_completed: false`: the script does not open or inspect windows. A successful CLI preflight establishes resource loading and language selection, not text visibility or layout quality.

The isolated directories keep app preferences and local app data separate. Host services, hardware and macOS permissions remain subject to the real system's configuration. Use synthetic documents and avoid granting unrelated permissions during this review.

## Native component snapshots

The opt-in `CartaUISnapshotTests` test renders the app's own SwiftUI/AppKit components through Apple's `NSHostingController`/`NSHostingView`, `NSWindow`, PDFKit and native bitmap APIs. Generate the deterministic three-page fixture, then run the companion driver with a new output directory:

```sh
python3 Development/make-ui-audit-fixture.py \
  /private/tmp/CartaPDF-UIAudit-fixture.pdf
python3 Development/run-ui-snapshots.py \
  --fixture /private/tmp/CartaPDF-UIAudit-fixture.pdf \
  --output /private/tmp/CartaPDF-UIAudit-snapshots
```

The fixture generator uses Python's standard library, writes an original PDF with selectable text, a long bookmark, an annotation and two form fields, and refuses to overwrite an existing file. It prints the fixture's SHA-256 for the evidence record.

Use `--skip-build` only when the native test executable and its resources have already been rebuilt from the current sources. The driver runs a separate process for each of the eight language variants, so `L10n` resolves that process's language at startup. Without the explicit audit fixture and output environment variables, the snapshot test skips its work in the normal test suite.

The test uses temporary Foundation preferences and a volatile argument domain to set the synthetic annotation author `UI Audit`, while retaining the process's language arguments. It preserves `HOME` and `CODEX_HOME`. No personal document, account name or production app preference is required.

Each test-owned window is positioned outside all connected display frames and ordered behind other windows with `orderBack`, allowing the native rendering pipeline to prepare its display list. The renderer uses its own views and controls; it does not generate desktop input, inspect another app through accessibility, or automate a user session. Record and inspect the actual window origin, `isVisible` state and intersections with display frames where reported. An off-display window is not necessarily an unordered or invisible window, and those states must not be inferred from the PNG alone.

The planned set contains 23 component images per language, or 184 across all eight variants, including editor and text controls, tools, preferences, forms at normal and deliberately constrained widths, keyboard annotations, five workflow panels, OCR, export, four structure sections and PDF/A reports. The OCR review targets a 1,080 × 620-point minimum and a 1,120 × 760-point larger viewport; export includes a 760 × 580-point viewport. Read each image's scenario and actual dimensions in its manifest: merge/split previews are generated in memory; OCR rows are seeded presentation examples; the PDF/A panel analyzes the synthetic fixture and retains its incomplete-coverage messages. The fixture hash is checked again after the run.

Inspect these PNGs for missing labels, overlap, clipping, wrapping and scrollable content at the recorded sizes. Native component snapshots complement interactive inspection: they do not exercise menu expansion, clicks, file pickers, keyboard focus transitions or a complete user workflow. Producing 23 files is not itself evidence that their layout has been visually reviewed. Record results only after rendering succeeds and the images are inspected.

## Review the running interface

Open one generated app copy at a time through the native UI automation tool (CUA), selecting the copy by its full app path. The launcher supplies the language automatically, including when LaunchServices opens the app. Do not change global `AppleLanguages`, the user's preferred-language order or the production app's preferences to drive the review.

Use the same synthetic PDF in every language. Include several pages with selectable text, bookmarks and annotations, plus supported form fields. Add a second synthetic PDF for merge and comparison previews. OCR review can use a locally generated image page. Keep original fixture text and filenames fixed: document content is intentionally independent of interface language.

Capture screenshots from the actual running app and inspect the rendered pixels as well as the accessibility hierarchy. Check the initial window and a narrower supported window size. Resize panels where available, scroll to the end of longer forms and reports, expand menus and exercise compact controls. A translation can be present in an accessibility label while its visible title is clipped, so both observations matter.

For each issue, record the language, surface, action, observed text and window size. After a correction, rebuild the app, prepare fresh copies and repeat the affected interaction. Keep screenshots associated with the executable and resource hashes in the preparation manifest; screenshots of an older build do not verify a later change.

## Interactive coverage recorded so far

Interactive CUA inspection has covered six German-language surfaces: the editor with a PDF open, the Edit menu's Undo/Redo commands, the tools catalogue, Merge, Split and Preferences. Further CUA inspection stopped after the native automation service crashed. CartaPDF remained running and was subsequently closed normally.

This limited interactive coverage does not establish interactive review of the other language variants or every panel. Native component snapshots are a separate source of layout evidence, with the scope described above. Completed image reviews and their manifests must be recorded separately before reporting results across all eight variants.

The first component review inspected all 184 PNGs through Codex's image-viewing tool. It found count wording, a source-language typo and contextual translation issues, which were corrected before regenerating the images. The [verification record](../Development/UILocalizationVerification.json) distinguishes this initial review from the subsequent checks of affected components.

The offscreen renderer has observed limits: PDF previews/thumbnails and some symbols can be omitted, steppers can show only their minus glyph, and the structure section selector can appear black. These images do not establish the appearance of those controls. Content below the initial scroll position also requires a separate interaction. The deliberately constrained 620-point forms image is below the supported 700-point minimum and is diagnostic only. No screenshot count or nonuniform-pixel check overrides these limits.

## Surface checklist

Run this checklist for all eight variants. Mark an item as pending, reviewed, corrected and rechecked, or unavailable with a concrete reason. Do not infer a result for an unopened panel from another language's result.

| Surface | Review actions |
| --- | --- |
| Main window and menus | Inspect empty and open-document states; expand app, File, Edit, View, Window and Help menus; distinguish Undo/Redo from Cancel/Reset. |
| Sidebar and navigation | Switch pages, contents, annotations and search; inspect page counts, search controls, segmented/menu fallback and long bookmark titles. |
| Tools | Open every tool category; search for tools; check wrapped titles, descriptions, badges and disabled states. |
| Preferences | Inspect author, stroke, cache, recovery and shortcut settings; check full labels and scroll to the last setting. |
| Annotations | Select Note, Text and Draw; inspect the editing bar, style controls, keyboard annotation editor and delete/undo actions. |
| Merge | Add both fixture PDFs; reorder inputs; edit page ranges; generate and inspect the merge preview and save controls. |
| Split | Inspect split methods, ranges, naming templates, separator options and previews; retain literal template syntax. |
| Layout and printing | Inspect crop, N-up, booklet, poster, overlay and page-order controls, including units and preview explanations. |
| Scanning and OCR | Inspect recognition-language options, progress, cancellation, preview and export controls; record unavailable scanner hardware separately. |
| Export | Inspect text, image and other supported export panels, destination controls, quality settings and overwrite messages using temporary outputs. |
| Forms | Search and edit supported fixture fields; inspect required/read-only states, field creation and CSV filling controls. |
| PDF structure | Inspect properties, labels, images, attachments, portfolios, layers and original-content controls; check long paths and explanatory messages. |
| Certificates | Inspect local identity selection, reason fields, signing controls and offline verification messages; distinguish drawn signatures from certificate signatures. |
| PDF/A | Open profile selection and validation reports; inspect all eleven profile labels, rule filters, detail text, unverified rules and export controls. |

Hardware acquisition, real certificate signing and every possible document-specific error need separate fixtures or equipment. Merely opening their settings panel covers that panel's layout only.

## Corrections covered by this review workflow

The editing menu now uses dedicated localized Undo and Redo keys instead of sharing Cancel and Reset translations. Tool names and explanations use consistent redaction and flattening terms; reordering commands describe moving a page or workflow step earlier/later. Traditional Chinese uses regional interface vocabulary, and font-size labels identify their point units.

Layout changes accommodate longer translated text through wrapping, adaptive controls and scrolling. Examples include a compact editing bar, a sidebar menu when segments do not fit, flexible tool descriptions and scrollable settings/detail panels. These implementation changes still require inspection in the running app at the chosen window sizes.

## Intentional original-language content and limits

PDF text, user-supplied filenames, field names, annotation contents, certificate identities and source-document metadata retain their original content. PDF names, protocol identifiers, CLI verbs, page-range tokens and template placeholders retain their syntax. Upstream reference and normative catalogue descriptions keep their supplied language and licensing; they are not missing interface translations.

The current catalogues contain 3,040 keys per variant. Static checks verify coverage, placeholders, formats and fragment whitespace. Native CLI checks verify packaged resources and automatic language selection. GUI observations verify only the rendered surfaces and interactions recorded with evidence. They do not establish an exhaustive linguistic review, a complete VoiceOver audit or complete ISO PDF/A conformance validation. Localization does not expand the validator's documented normative coverage.
