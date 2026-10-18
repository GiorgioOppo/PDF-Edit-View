# Architettura

CartaPDF è un eseguibile Swift Package Manager con un target di test XCTest. L'interfaccia usa SwiftUI e AppKit; il documento e il rendering ordinario usano PDFKit. Non ci sono pacchetti Swift di terze parti, server applicativi o motori PDF esterni.

## Componenti

| Area | Sorgenti principali | Responsabilità |
| --- | --- | --- |
| Avvio e finestre | `CartaPDFApp`, `PDFWorkspaceDocument`, `ContentView` | Ciclo di vita NSDocument, apertura, salvataggio e composizione dei pannelli. |
| Stato editor | `PDFEditorModel`, `PDFCanvas`, `DocumentNavigationView` | Documento attivo, selezione, rendering, navigazione, modifiche e undo. |
| Strumenti | `ToolBrowserView`, `PDFPageTools`, `PDFTextTools`, `PDFRedactionTools` | Catalogo ricercabile e operazioni sulle pagine o sul contenuto. |
| Flussi batch | `PDFWorkflowTools`, `PDFWorkflowViews` | Unione, divisione, preset e procedure locali. |
| Acquisizione ed export | `PDFScanExport*`, `PDFConversionTools` | Vision OCR, Image Capture, ScreenCaptureKit, WebKit statico e conversioni. |
| Struttura PDF | `PDFStructureEngine`, `PDFStructureTools`, `PDFStructureViews`, `PDFStreamFilters` | Lettore COS/xref, stream, modifiche strutturali supportate e firme. |
| Servizi locali | `CartaWorkspaceServices`, `CartaFileIO`, `CartaRenderingServices`, `PDFLocalLibrary` | Preferenze, versioni, recupero, scritture, cache e indice locale. |
| Automazione | `CartaAutomation` | CLI, App Intent e comando AppleScript. |
| Validazione | `PDFArchiveValidator*`, `PDFArchive*Checks`, `ICCModel` | Rapporti PDF/A, controlli del modello e lacune esplicite. |

I nomi abbreviati nella tabella corrispondono ai file sotto [Sources/CartaPDF](../Sources/CartaPDF/).

## Documenti e scritture

`PDFWorkspaceDocument` collega NSDocument al modello dell'editor. Le modifiche reversibili registrano gruppi undo espliciti; il salvataggio serializza il documento supportato. Gli strumenti che cambiano la struttura o rasterizzano preparano una copia. `CartaFileIO` centralizza le scritture atomiche e alcuni controlli su destinazioni e spazio disponibile.

Il lettore strutturale opera sui byte del PDF, separatamente dal rendering di PDFKit. Segue le revisioni xref modellate, risolve gli alias indiretti con limiti e distingue oggetti fisici da identità terminali. I filtri implementati sono codice Swift originale, con Compression Apple per le operazioni supportate. I casi non modellati restano espliciti.

## Percorso della validazione PDF/A

1. Il validatore riceve una fotografia immutabile dei byte e il profilo scelto.
2. Carica il catalogo XML locale fissato per quel profilo e ne verifica l'integrità.
3. Il parser e gli inventari semantici raccolgono i fatti supportati: oggetti, stream, font, metadati, colori, struttura, allegati e firme.
4. I controlli producono risultati per le voci del catalogo e risultati separati per il modello PDF.
5. Il rapporto include SHA-256 dei byte, dettagli diagnostici, limiti e `scopeGaps`.

Una violazione dimostrata produce `nonconforming`. Senza violazioni, una lacuna, una risorsa non disponibile o un limite produce `indeterminate`. La conformità globale resta disabilitata in 3.6.0. Il rendering riuscito non è una prova di conformità e non viene usato per cancellare controlli incompleti.

I controlli hanno limiti di input, stream decodificati, profondità e conteggi. Il validatore non esegue JavaScript PDF, programmi font, allegati o payload 3D. Il raggiungimento di un budget non viene trasformato in prova di validità. Vedi [ambito tecnico](../Development/PDFA-ValidatorScope.md).

## Concorrenza e limiti

I job di conversione e validazione usano worker, limiti e cancellazione. Alcune preparazioni strutturali, preflight, firme e ridisegni CoreGraphics sono ancora eseguiti sul main actor; su file grandi possono bloccare temporaneamente il relativo pannello. Questo limite è tracciato nel rapporto funzionale.

## Dati incorporati

I cataloghi PDF/A XML e i dati CMap/AGL/PDF-to-Unicode sono dati originali locali, versionati con manifest e SHA-256. Le copie sotto `Resources` e `Sources/CartaPDF/Resources` devono coincidere. La loro presenza rende disponibile il riferimento, non implementa automaticamente tutti gli obblighi normativi. Le [licenze](../THIRD_PARTY_NOTICES.md) restano distinte da MIT.

## Verifica

I test costruiscono documenti sintetici e verificano contenuti riaperti, byte, pixel, errori, cancellazione e differenze di profilo. Il corpus di sviluppo è acquisito separatamente. Per aggiungere controlli, usa una fonte primaria e casi positivi/negativi che isolino la condizione: non trasformare un nome storico del corpus in un'affermazione normativa. Vedi [CONTRIBUTING](../CONTRIBUTING.md).
