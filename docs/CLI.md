# CLI e automazione locale

L'eseguibile del bundle accetta `--cli` ed esegue le operazioni sul Mac senza aprire l'interfaccia principale. Gli esempi presuppongono una build creata con [BUILDING](BUILDING.md).

```sh
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli help
```

## Comandi

| Comando dopo `--cli` | Risultato |
| --- | --- |
| `info input.pdf` | JSON con pagine, cifratura, autorizzazioni e numero di caratteri estratti. |
| `merge output.pdf input1.pdf input2.pdf ...` | Unione ordinata di almeno due documenti. |
| `extract input.pdf output.pdf '1-3,5'` | Copia delle pagine selezionate, numerate da 1. |
| `split input.pdf cartella` | Divisione in file di una pagina nella cartella indicata. |
| `text input.pdf output.txt` | Estrazione testuale UTF-8. |
| `ocr input.pdf output.pdf` | OCR tramite Vision e nuova copia PDF. |
| `flatten input.pdf output.pdf` | Copia rasterizzata a 200 DPI. |
| `compress input.pdf output.pdf` | Copia rasterizzata a 150 DPI con JPEG; riduzione della dimensione non garantita. |
| `validate-pdfa input.pdf profilo [rapporto.json]` | Rapporto PDF/A JSON; senza destinazione, scrive sullo standard output. |

I criteri avanzati di divisione, le lingue OCR e gli altri parametri degli strumenti grafici non sono tutti esposti da questa CLI.

```sh
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli merge Unione.pdf A.pdf B.pdf
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli extract A.pdf Estratto.pdf '1-3,5'
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli split A.pdf Pagine
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli validate-pdfa A.pdf 4f Rapporto.json
```

## PDF/A e codici di uscita

Profili accettati: `1a`, `1b`, `2a`, `2b`, `2u`, `3a`, `3b`, `3u`, `4`, `4e`, `4f`.

| Codice | Significato |
| --- | --- |
| `0` | Operazione ordinaria completata. Per `validate-pdfa` sarebbe conformità integrale: **non viene emessa in 3.6.0**. |
| `1` | Errore di uso, lettura, scrittura o esecuzione. |
| `2` | `validate-pdfa`: almeno una violazione dimostrata. |
| `3` | `validate-pdfa`: esito indeterminato, con verifiche o obblighi incompleti. |

Un codice 2 o 3 di `validate-pdfa` è un risultato del validatore, non necessariamente un guasto del processo. Negli script che interrompono l'esecuzione sui codici diversi da zero, gestiscilo esplicitamente:

```sh
status=0
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli validate-pdfa A.pdf 4 Rapporto.json || status=$?
case "$status" in
  0) printf '%s\n' 'Conformità integrale attestata' ;;
  2) printf '%s\n' 'Violazioni: leggere il rapporto' ;;
  3) printf '%s\n' 'Verifica incompleta: leggere il rapporto' ;;
  *) exit "$status" ;;
esac
```

Lo stato 0 è previsto per una futura implementazione completa. Non usare l'assenza di violazioni, un singolo `passed` o il numero delle regole come attestazione di conformità. Leggi anche `scopeGaps` e i controlli aggiuntivi del modello. Vedi [PDFA](PDFA.md).

## Password e destinazioni

Per le operazioni che aprono il documento tramite PDFKit, usa `--password-file percorso`. Il file viene letto localmente; proteggilo con i permessi appropriati e non inserirlo nel repository. La password non va passata come argomento diretto né salvata in esempi, preset o log.

`validate-pdfa` analizza i byte originali e non decifra il documento con `--password-file`; un PDF cifrato viene trattato secondo le regole archivistiche e i limiti del parser.

Le scritture a file rifiutano di sovrascrivere i sorgenti. `--overwrite` consente di sostituire un output esistente per i comandi che scrivono tramite la destinazione file. `split` usa una cartella e la propria gestione dei conflitti: non presumere che `--overwrite` autorizzi la sostituzione dei file prodotti. Usa destinazioni distinte e controlla i risultati prima di eliminare gli originali.

OCR, appiattimento e compressione possono cambiare testo selezionabile, interattività, cifratura e firme della copia. Le operazioni rispettano le autorizzazioni PDF supportate e possono rifiutare documenti protetti.

## Comandi Rapidi e AppleScript

Dopo aver aperto l'app, cerca **Unisci PDF** in Comandi Rapidi. L'App Intent riceve i documenti e restituisce un file unito, conservando i sorgenti.

Il dizionario AppleScript espone:

```applescript
tell application id "it.cartapdf.editor"
    merge PDFs files {"/percorso/A.pdf", "/percorso/B.pdf"} destination "/percorso/Unione.pdf"
end tell
```

La CLI e l'Intent hanno test automatici. Il dizionario AppleScript è stato compilato in Script Editor; il dispatch effettivo dal programma resta una verifica manuale aperta, come indicato nel [rapporto funzionale](../Development/FeatureVerification.json).
