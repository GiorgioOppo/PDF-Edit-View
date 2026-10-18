# Licenze e attribuzioni dei dati

Il codice Swift originale di CartaPDF e la documentazione del progetto sono sotto [licenza MIT](LICENSE). I dati di riferimento incorporati mantengono le licenze originali indicate sotto e non vengono rilicenziati MIT.

L'app usa framework Apple del sistema e non incorpora motori PDF di terze parti, il motore Java veraPDF o codice del toolkit Adobe. Le risorse descritte qui sono dati locali. Nessuna affiliazione o approvazione da parte di Apple, Adobe, veraPDF, ISO, PDF Association o Creative Commons è dichiarata.

## Profili di validazione veraPDF

- Copyright © 2015 veraPDF Consortium.
- Fonte: [veraPDF-validation-profiles](https://github.com/veraPDF/veraPDF-validation-profiles/tree/b76c28ff0d8809c30c4d0e64dc6c393f3c9019dc).
- Commit fissato: `b76c28ff0d8809c30c4d0e64dc6c393f3c9019dc`.
- Licenza: **Creative Commons Attribution 4.0 International (CC BY 4.0)**.
- Undici file XML originali, byte preservati senza modifiche.

Attribuzione, testo legale, dichiarazione upstream e hash sono in [Resources/PDFAProfiles](Resources/PDFAProfiles/): [NOTICE](Resources/PDFAProfiles/NOTICE.txt), [LICENSE](Resources/PDFAProfiles/LICENSE.txt), [UPSTREAM-README](Resources/PDFAProfiles/UPSTREAM-README.md) e [MANIFEST](Resources/PDFAProfiles/MANIFEST.json). Gli stessi dati sono replicati sotto `Sources/CartaPDF/Resources/PDFAProfiles` per SwiftPM.

Le descrizioni normative dei cataloghi riprodotte nei rapporti conservano attribuzione e licenza CC BY 4.0. La disponibilità dei profili non certifica il validatore o i documenti analizzati.

## Dati Adobe CMap, AGL e PDF-to-Unicode

Copyright Adobe e relativi contributori. I dati sono distribuiti sotto le rispettive licenze **BSD a 3 clausole** e conservati nei byte originali.

| Risorsa | Commit fissato |
| --- | --- |
| [cmap-resources](https://github.com/adobe-type-tools/cmap-resources/tree/f5cf3bca7fdfeaceb77aa82847e974f2306c20b4) | `f5cf3bca7fdfeaceb77aa82847e974f2306c20b4` |
| [agl-aglfn](https://github.com/adobe-type-tools/agl-aglfn/tree/4036a9ca80a62f64f9de4f7321a9a045ad0ecfd6) | `4036a9ca80a62f64f9de4f7321a9a045ad0ecfd6` |
| [mapping-resources-pdf](https://github.com/adobe-type-tools/mapping-resources-pdf/tree/2dd5e53fb74a01718b9dfd448a0d1cce6fff2aa5) | `2dd5e53fb74a01718b9dfd448a0d1cce6fff2aa5` |

Vedi [NOTICE](Resources/PDFFontData/NOTICE.txt), [MANIFEST](Resources/PDFFontData/MANIFEST.json), [CMaps/LICENSE](Resources/PDFFontData/CMaps/LICENSE.md), [AGL/LICENSE](Resources/PDFFontData/AGL/LICENSE.md) e gli header dei singoli mapping. Anche questi dati sono replicati sotto `Sources/CartaPDF/Resources/PDFFontData`.

## Corpus di sviluppo

Il corpus veraPDF fissato al commit `377728596647e40edf16003d68d620773ce96ec5` è acquisito separatamente per lo sviluppo sotto CC BY 4.0 e non è distribuito nel bundle. Le evidenze riportano provenienza e verifiche; Isartor è escluso. La sua eventuale acquisizione o redistribuzione deve mantenere licenza e attribuzione originali. Vedi [PDFA-CorpusEvidence](Development/PDFA-CorpusEvidence.json).

## Standard e marchi

I riferimenti a ISO, specifiche PDF/XMP/ICC/font e documentazione Apple identificano le fonti tecniche; non concedono diritti di redistribuzione dei rispettivi testi. Non vengono incluse copie integrali degli standard ISO 19005. Acrobat è citato solo per descrivere l'ispirazione funzionale, senza equivalenza, affiliazione o certificazione dichiarata.

Nelle redistribuzioni conserva i testi legali completi, le attribuzioni e i manifest presenti nelle risorse. Questo riepilogo non sostituisce le licenze originali.
