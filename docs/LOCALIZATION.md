# Languages and automatic selection

CartaPDF supports Italian (`it`), Spanish (`es`), English (`en`), German (`de`), French (`fr`), Chinese in Simplified (`zh-Hans`) and Traditional (`zh-Hant`) scripts, and Japanese (`ja`). These are seven languages represented by eight native localization folders.

## Selection at launch

The app reads macOS's ordered `Locale.preferredLanguages`, including a per-app language preference where configured. It chooses the first supported language family. Region variants such as `it-CH`, `es-MX`, `en-GB`, `de-AT`, `fr-CA` and `ja-JP` match their base language. If no preference matches, the app uses English. It does not write `AppleLanguages` or change system settings.

For Chinese, an explicit Hans/Hant script takes priority. Without a script, Taiwan, Hong Kong and Macao select Traditional Chinese; other Chinese regions and plain `zh` select Simplified Chinese. Relaunch the app after changing macOS language preferences: selection and resource loading occur at startup.

| Ordered preferences | Selected localization |
| --- | --- |
| `it-IT` | Italian |
| `ko-KR`, `fr-CA`, `en-GB` | French |
| `zh-TW` | Traditional Chinese |
| `zh-Hans-HK` | Simplified Chinese |
| `nl-NL`, `sv-SE` | English fallback |

Menus, tools, panels, messages, accessibility labels and announcements use the selected translation. SwiftUI roots receive the selected locale. Native `.lproj` resources also provide App Intent/Shortcuts and document-type strings.

PDF text, filenames supplied by users, certificate identities, protocol identifiers, PDF objects and command-line verbs/options are not translated. OCR recognition languages are chosen for the source document separately from interface language. Upstream normative catalogue descriptions and historical evidence retain their original language and licensing. Localization does not change PDF/A validation coverage or complete the manual VoiceOver audit.

## Read-only diagnostics

After building:

```sh
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli language
```

The JSON includes selected and preferred languages, supported codes, catalogue counts and translated Open/Save/Cancel labels. It does not read documents or change preferences.

For development, macOS launch arguments can exercise another process language without changing the user's settings:

```sh
dist/CartaPDF.app/Contents/MacOS/CartaPDF -AppleLanguages '("de-AT")' --cli language
dist/CartaPDF.app/Contents/MacOS/CartaPDF -AppleLanguages '("ko-KR","fr-CA")' --cli language
dist/CartaPDF.app/Contents/MacOS/CartaPDF -AppleLanguages '("ko-KR")' --cli language
```

The last example must select English. The packaged-app check exercises supported languages, Chinese scripts, preference ordering and unsupported-language fallback from a temporary working directory.

## Translation maintenance

Resources live under `Sources/CartaPDF/Resources/Localization/<code>.lproj`. The build copies the native folders into the app's `Contents/Resources` and retains SwiftPM resource support. English is the development region and fallback.

Use `L10n.tr("Italian source text with \(value)")` for interface literals. Interpolation captures inert argument values and creates numbered `{0}`, `{1}` placeholders; translations may reorder them without interpreting document text as a format string. Use `L10n.string(key)` only for an explicit internal display key, such as an enum label. Keep stored raw values and identifiers stable.

Update the explicit [inventory](../Development/LocalizationInventory.json) and all eight `Localizable.strings` tables when adding a key. Retain exact numbered and named placeholders, printf conversions, and leading/trailing whitespace in fragments. Literal page-range tokens (`all`, `odd`, `even`, `last`) and filename/template tokens are syntax, not words to translate. Keep UTF-8 files and the existing escaped key/value format.

`AppShortcuts.strings` preserves `${applicationName}` in the native shortcut phrase. `InfoPlist.strings` localizes the PDF document-type name. Reference-data XML, manifests and license files remain unchanged.

Run:

```sh
python3 scripts/check-localization.py
python3 scripts/check-repository.py
./scripts/test.sh --filter CartaLocalizationTests
./scripts/test.sh
./scripts/build-app.sh
python3 scripts/check-built-app.py dist/CartaPDF.app
```

The static check verifies source-key coverage, equal key inventories, placeholders, formats, fragment whitespace and bundle declarations. Native tests check actual Foundation resource loading and safe interpolation. The assembled-app check verifies actual launch-language selection and packaged resources. Translation and layout review remain part of ordinary UI review; these checks do not claim a complete accessibility or linguistic audit.

Follow the [interface review workflow](UI_LOCALIZATION_AUDIT.md) to prepare isolated language-specific app copies, render opt-in native component snapshots and record interactive CUA inspection. It distinguishes resource checks, rendered layout evidence and completed user interactions.
