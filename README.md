# PDF-Edit&View — CartaPDF

A free, offline PDF editor for macOS, written in Swift using Apple frameworks only. The app is called **CartaPDF**, version **3.6.0**. PDF/A validation is partial and never reports full conformance while coverage gaps remain.

Editor PDF per macOS scritto in Swift. Gratuito, con sorgenti sotto licenza MIT, completamente locale e basato soltanto su framework Apple. Nessuna dipendenza software di terze parti, account, abbonamento, server, telemetria o servizio AI. OCR, confronto, conversioni, firme e ricerche vengono eseguiti sul Mac. Un collegamento web in un PDF viene aperto solo su azione dell’utente.

Il nome del repository è [PDF-Edit-View](https://github.com/GiorgioOppo/PDF-Edit-View); il nome dell’app e del bundle resta CartaPDF. Il progetto è indipendente e non è affiliato ad Adobe. Il progetto implementa strumenti ispirati alle attività di Acrobat Pro, con i limiti descritti sotto. Il catalogo delle 100 migliorie e 50 nuove funzioni è in `Development/FeatureRequirements.json`; [il rapporto di verifica](Development/FeatureVerification.json) distingue funzioni implementate, ambiti limitati e verifiche che richiedono hardware o intervento manuale.

## Documentazione

- [Indice delle guide](docs/README.md), [uso dell’app](docs/USAGE.md) e [CLI](docs/CLI.md).
- [Compilazione e test](docs/BUILDING.md), [architettura](docs/ARCHITECTURE.md) e [contributi](CONTRIBUTING.md).
- [Privacy e permessi](docs/PRIVACY.md), [accessibilità](docs/ACCESSIBILITY.md) e [sicurezza](SECURITY.md).
- [Stato PDF/A](docs/PDFA.md), [changelog](CHANGELOG.md), [licenze dei dati](THIRD_PARTY_NOTICES.md) e [supporto](SUPPORT.md).
- [Preparazione della pubblicazione](docs/PUBLIC_RELEASE.md) e [interpretazione delle evidenze](Development/README.md).


## Uso

Apri **Strumenti** o premi **⇧⌘T** per cercare un’operazione. Gli strumenti avanzati hanno anteprime, parametri e messaggi sul proprio ambito. Le operazioni su struttura, scansioni, firme e conversioni salvano copie separate. Le normali annotazioni e modifiche alle pagine si salvano con **⌘S** e si annullano con **⌘Z**.

| Area | Strumenti |
| --- | --- |
| Lettura e accesso | Finestre indipendenti, Finder, miniature trascinabili, ricerca durante la digitazione con estratti, viste singola/continua/affiancata, zoom ancorato al puntatore, stampa, stato di lettura persistente, scorciatoie configurabili, controlli con nomi, valori/unità, stati e annunci accessibili. |
| Unione | Coda riordinabile, intervalli per file, anteprima ordine finale, statistiche, rilevamento duplicati e formati diversi, segnalibri rimappati, fronte/retro alternato, gruppi per nome. |
| Divisione | Intervalli, ogni N pagine, segnalibri, testo separatore, QR/codici a barre tramite Vision, pagine bianche e dimensione massima effettiva; nomi, anteprima conflitti, progresso, annullamento e output nel Finder. |
| Impaginazione | Organizer, duplicazione/spostamento, pagine affiancate da scansioni di libri, N pagine per foglio, libretti fronte/retro, poster, sovrapposizione PDF, ritaglio interattivo con unità e margini validati. |
| Marcature | Evidenziazioni, note, testo aggiunto, disegno regolarizzato, forme, collegamenti, timbri riutilizzabili, filigrane configurabili, intestazioni/piè di pagina dinamici, numeri, Bates, sommario cliccabile. Selezione sincronizzata, spostamento, ridimensionamento, autore e spessore configurabili. Pannello da tastiera con coordinate, creazione/modifica/eliminazione e undo (⇧⌘K). |
| Scansioni | Vision OCR con scelta lingue, orientamento, raddrizzamento, pulizia, retry, ordine multicolonna, priorità pagina visibile e rapporto per pagina. Acquisizione da scanner compatibili Image Capture e cattura schermo/finestre con ScreenCaptureKit. |
| Conversioni | PDF da immagini con margini e da testo/RTF/DOCX; HTML locale statico in PDF; TXT, RTF, DOCX, EPUB testuale, PNG e TIFF multipagina; CSV da regioni tabellari con colonne manuali o rilevamento automatico. Anteprima JPEG, DPI, profili colore e confronto dimensioni. |
| Moduli | Creazione e compilazione di testo, checkbox ed elenchi; ricerca campi, gruppi per pagina, obbligatorietà, limiti caratteri, valori condivisi e stato modifiche; una copia compilata per ogni riga CSV. |
| Struttura originale | Numerazione logica delle sezioni, estrazione immagini incorporate, sostituzione XObject immagine, modifica di stringhe testuali supportate nei content stream, allegati, raccolte PDF e visibilità dei livelli OCG. |
| Analisi | Confronto testuale e visivo, pagine visivamente duplicate, font incorporati, risoluzione immagini, box pagina, intenti ICC, metadati e struttura di accessibilità. |
| Archiviazione e stampa | Conversione nativa CoreGraphics PDF/A con rilevamento del livello dichiarato; rapporto per 11 profili, clausole, verifiche incomplete e JSON/testo; preparazione di un intento di stampa con profilo ICC CMYK locale, tag e descrizioni a livello di pagina. |
| Protezione e firme | Apertura protetta, mantenimento cifratura nel salvataggio ordinario, copie cifrate verificate, oscuramento in copia raster, firma CMS con certificato locale e verifica offline dell’integrità e della catena disponibile. |
| Organizzazione locale | Biblioteca con categorie/tag, ricerca su più PDF, ridenominazione da contenuti, cartelle monitorate, procedure batch ordinate e preset JSON, cronologia delle ultime 20 versioni per documento e copie di recupero. |
| Automazione | Intent nativo “Unisci PDF” per Comandi Rapidi, comando AppleScript `merge PDFs`, interfaccia a riga di comando per info/unione/estrazione/divisione/testo/OCR/appiattimento/compressione e rapporti PDF/A con codici di uscita distinti. |

## Ambito e limiti

- La modifica originale del testo supporta font standard Type1 WinAnsi e stringhe semplici Tj, senza reimpaginazione automatica. Font subset/CID, ToUnicode, operatori TJ complessi e contenuti non supportati sono rifiutati esplicitamente. Le modifiche strutturali non decifrano i PDF protetti. Le revisioni incrementali conservano i dati precedenti: modifica del testo e rimozione di allegati non equivalgono a oscuramento. Le immagini supportate sono XObject, con i filtri documentati dallo strumento; sostituire un oggetto condiviso interessa tutte le pagine che lo usano.
- **PDF/A:** il validatore nativo distingue 1a/1b, 2a/2b/2u, 3a/3b/3u, 4/4e/4f e traccia le 1489 voci dei cataloghi ufficiali. Per ogni clausola riporta verificata, violata, non verificata o non applicabile, con impronta SHA-256 dei byte analizzati. **La validazione ISO 19005 completa resta da implementare**: Sono disponibili controlli nativi dei programmi font, glifi, metriche e mapping Unicode; metadati RDF/XMP ed extension schema; colori effettivamente dipinti, ICC e JPEG2000; annotazioni, moduli, OCG, firme e allegati ricorsivi. Restano incomplete alcune semantiche del modello ISO 32000, codec/font avanzati, struttura logica A, payload 3D e riconciliazione normativa integrale. Nessuna violazione dimostrata significa “indeterminato”, finché esistono lacune; questa versione non emette “conforme”. [Ambito verificato e lacune](Development/PDFA-ValidatorScope.md). CoreGraphics può dichiarare 2b anche quando l’API richiede 2u: il livello viene letto dai byte e non viene alzato artificialmente.
- **PDF/X e accessibilità dei PDF:** l’intento ICC CMYK prepara la stampa. I tag sono a livello di pagina con lingua e descrizione; non certificano ISO 15930 o PDF/UA.
- **Firme:** la firma con certificato locale produce CMS e ByteRange; la verifica usa i byte originali e non effettua richieste di rete. Può verificare integrità e fiducia disponibile localmente, ma non revoca aggiornata, timestamp TSA, validazione a lungo termine, PAdES completo o qualifica legale. Modificare un PDF già firmato può invalidare o superare la revisione firmata. La firma grafica rimane un’annotazione distinta.
- DOCX/RTF/EPUB riguardano il testo: non ricostruiscono fedelmente impaginazione Office, formule, tabelle o immagini. Il riconoscimento automatico delle tabelle e delle colonne OCR è euristico e richiede controllo dei risultati. L’OCR può produrre errori.
- Raddrizzamento, pulizia, oscuramento, appiattimento, JPEG e pagine riconosciute dall’OCR possono rasterizzare i contenuti e perdere interattività, password o firme nella copia. Le dimensioni JPEG possono aumentare. Il ritaglio modifica l’area visibile e non elimina i contenuti nascosti.
- Le scritture e i worker di conversione sono annullabili e limitati; preparazione strutturale, preflight, firma e ridisegno CoreGraphics restano sul main actor. Documenti molto grandi possono bloccare temporaneamente quel pannello.
- Moduli XFA, radio button, campi password e JavaScript/calcoli non sono supportati. I widget sul documento restano in sola lettura durante l’uso; il pannello Moduli ripristina i flag originali in salvataggio.
- Lo scanner richiede un dispositivo e un driver compatibile con Image Capture. La cattura richiede il consenso di macOS alla registrazione schermo. La lettura ad alta voce usa le voci già presenti nel sistema. Queste integrazioni non installano driver o scaricano voci.
- L’HTML è statico, senza JavaScript e con risorse remote bloccate. La biblioteca memorizza riferimenti ai file locali; spostarli esternamente richiede di aggiornarli. Le cartelle monitorate operano mentre l’app e il relativo pannello sono aperti.

Novità della versione 3.6: schema degli spazi colore calibrati, Indexed, Separation e DeviceN; stream e Metadata con alias indiretti; elementi multiprocesso ICC; coordinate e agganci compositi TrueType; attributi standard Layout/List/Table/PrintField e proprietà utente. I controlli delle funzioni PDF 0/2/3/4 e i precedenti audit restano disponibili. I rapporti separano le 1489 voci dei cataloghi dai controlli aggiuntivi del modello PDF. Le lacune residue continuano a impedire attestazioni di conformità integrale.

## Compilazione e verifica

L’app richiede **macOS14+**. Per compilare e verificare i sorgenti serve Xcode completo con SDK recente su un sistema compatibile: vedi [requisiti di build](docs/BUILDING.md). Il build locale su Apple Silicon genera un bundle arm64 in `dist/`, escluso da Git. Il repository contiene i sorgenti; non viene pubblicato automaticamente un installer. Firma ad hoc locale, senza notarizzazione Developer ID.

```sh
./scripts/test.sh
./scripts/build-app.sh
open dist/CartaPDF.app
```

Gli script usano Xcode installato solo per il processo, senza cambiare `xcode-select`. Il test runner compila in una cartella temporanea. Il bundle include icona, dizionario AppleScript e metadati App Intents estratti con gli strumenti Apple.

I test verificano dati riaperti, contenuti e pixel, non solo la presenza dei pulsanti: undo, form, cifratura, bookmark, flussi testo, immagini, allegati, CMS/alterazioni, OCR Vision, QR, impaginazione, CSV, EPUB/CRC, TIFF, HTML offline, procedure batch, cancellazione e file con mille pagine.

Evidenza della versione 3.6 del 18 ottobre 2026: **512 test superati, zero errori**; corpus indipendente documentato in Development/PDFA-CorpusEvidence.json. Il risultato della suite integrata e lo stato dei 150 requisiti sono registrati in `Development/FeatureVerification.json`. La validazione ISO PDF/A completa resta parziale. L’audit manuale completo VoiceOver non è completato; revisione statica e test nativi sono documentati separatamente. Scanner, cattura schermo e audio richiedono anche la verifica con dispositivi e autorizzazioni dell’utente.

La CI esegue controlli del repository, test nativi, compilazione Release, firma e CLI su macOS. Le prove con hardware e l’audit manuale completo VoiceOver restano separati. I log grezzi sono locali ed esclusi da Git.

Per verificare i contenuti del repository e rigenerare il rapporto dopo i test:

```sh
python3 scripts/check-repository.py
./scripts/test.sh > Development/TestResults.log 2>&1
python3 Development/verify-features.py
```

```sh
# L’eseguibile all’interno del bundle funziona anche senza interfaccia.
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli help
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli merge Unione.pdf A.pdf B.pdf
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli extract A.pdf Estratto.pdf '1-3,5'
dist/CartaPDF.app/Contents/MacOS/CartaPDF --cli validate-pdfa A.pdf 4f Rapporto.json
```

`validate-pdfa` restituisce 0 per conforme, 2 per violazioni dimostrate, 3 per indeterminato e 1 per errori di uso/I/O. L’esito 0 è riservato alla futura copertura completa e non viene emesso da questa versione.

La CLI rifiuta di sovrascrivere sorgenti e output esistenti salvo `--overwrite` per gli output. Le password si passano tramite `--password-file`, mai direttamente nella riga di comando. Nessuna chiave o password viene conservata nei preset o nella cronologia.

Il dizionario AppleScript espone:

```applescript
tell application id "it.cartapdf.editor"
    merge PDFs files {"/percorso/A.pdf", "/percorso/B.pdf"} destination "/percorso/Unione.pdf"
end tell
```

Per Comandi Rapidi cerca l’azione **Unisci PDF** di CartaPDF dopo aver aperto l’app. La CLI e l’Intent sono verificati automaticamente; il dispatch dal programma Script Editor è da verificare manualmente.

## Sorgenti

`PDFEditorModel`, `PDFWorkspaceDocument` e `PDFCanvas` gestiscono documento, undo e interazione. `PDFWorkflow*` contiene organizzazione e batch; `PDFScanExport*` e `PDFLocalLibrary` gestiscono scansioni, conversioni e biblioteca; `PDFStructure*` contiene lettura/scrittura strutturale e certificati; `CartaWorkspaceServices`, `CartaRenderingServices`, `CartaVisualTools`, `CartaFileIO` e `CartaAutomation` gestiscono preferenze, recupero, memoria, confronto, scritture e automazioni. Il catalogo è in `ToolBrowserView`.

I cataloghi XML PDF/A originali veraPDF sono dati sotto licenza **CC BY 4.0**; i dati Adobe CMap/AGL e PDF-to-Unicode sono sotto **BSD a 3 clausole**. Le licenze dei dati sono distinte dalla licenza MIT del codice. Il bundle e i sorgenti includono attribuzione, licenze e manifest con hash in `Resources/PDFAProfiles` e `Resources/PDFFontData`. Non includono il motore Java, toolkit Adobe o altri framework esterni. Il corpus ufficiale di sviluppo è acquisito separatamente e non è incluso nell’app.

## Licenza

Codice originale sotto [MIT](LICENSE). I dati inclusi mantengono le licenze e attribuzioni descritte in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Le specifiche ISO e il corpus esterno non vengono redistribuiti.
