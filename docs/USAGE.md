# Guida d'uso

La versione corrente richiede macOS 14 o successivo. Per compilare l'app dai sorgenti, segui [BUILDING](BUILDING.md). Il bundle locale è firmato ad hoc e non è notarizzato Developer ID; non costituisce una distribuzione firmata per il pubblico.

## Aprire e modificare

Apri un PDF dal Finder oppure dall'app. Ogni documento ha una finestra indipendente. Usa le miniature per raggiungere e riordinare le pagine, la ricerca per trovare testo e le viste di lettura per regolare zoom e disposizione.

Apri **Strumenti** con **⇧⌘T** per cercare un'operazione. Le annotazioni e le modifiche ordinarie alle pagine si salvano con **⌘S** e si annullano con **⌘Z**. Il pannello da tastiera delle marcature si apre con **⇧⌘K** e permette di modificare anche posizione e dimensioni.

Gli strumenti strutturali, le scansioni, le conversioni e le firme preparano copie separate. Controlla il nome e la destinazione prima di salvare. Mantieni l'originale quando devi conservare firme, interattività o una versione precedente del contenuto.

## Unire documenti

1. Cerca **Unisci** in Strumenti e aggiungi i documenti alla coda.
2. Riordina i file e imposta gli eventuali intervalli di pagine.
3. Controlla l'anteprima dell'ordine finale e le segnalazioni su duplicati o formati diversi.
4. Salva il documento risultante in una nuova destinazione.

Sono disponibili anche unione alternata fronte/retro e gruppi per nome. I documenti protetti devono essere accessibili e consentire l'operazione richiesta.

## Dividere documenti

Gli strumenti di divisione supportano intervalli, ogni N pagine, segnalibri, testo separatore, pagine bianche, QR/codici a barre e dimensione massima dell'output. Scegli il criterio, verifica l'anteprima dei gruppi e dei nomi, poi scegli la cartella di destinazione. I criteri basati sul contenuto o sul riconoscimento possono richiedere correzioni manuali.

La CLI `split` produce una pagina per file; i criteri avanzati sono disponibili nell'interfaccia. Vedi [CLI](CLI.md).

## Scansioni e conversioni

L'OCR usa Vision sul Mac. Seleziona le lingue e controlla il testo riconosciuto, soprattutto per colonne, tabelle e documenti inclinati. Acquisizione da scanner, cattura schermo e lettura ad alta voce dipendono da dispositivi, autorizzazioni e risorse del sistema.

TXT, RTF, DOCX ed EPUB esportano il testo supportato: non ricostruiscono fedelmente una pagina Office con formule, tabelle e immagini. L'HTML importato è statico; JavaScript e risorse remote sono bloccati. Le conversioni raster, l'appiattimento e la compressione possono perdere testo selezionabile, annotazioni, moduli, firme o protezioni nella copia. La compressione non garantisce un file più piccolo.

## Contenuto nascosto, cifratura e firme

Il ritaglio modifica l'area visibile e lascia i contenuti sottostanti nel PDF. La modifica di testo o la rimozione di un allegato può conservare i byte nelle revisioni precedenti. Per oscurare informazioni usa lo strumento di oscuramento in copia raster e controlla l'output, incluse tutte le pagine interessate.

Il salvataggio ordinario mantiene la cifratura del documento supportato. Alcune elaborazioni producono una copia con caratteristiche diverse; controlla le indicazioni dello strumento. Le operazioni strutturali non decifrano PDF protetti.

La firma CMS con certificato locale e la firma grafica sono strumenti diversi. La verifica è offline e riguarda integrità, revisione firmata e fiducia disponibile localmente: non prova revoca aggiornata, timestamp TSA, validazione a lungo termine, PAdES completo o qualifica legale. Modificare un documento firmato può invalidare la firma o aggiungere una revisione non coperta da essa.

## Rapporti archivistici

La generazione PDF/A tramite CoreGraphics e il rapporto del validatore sono operazioni distinte. Scegli il profilo richiesto e leggi sia le violazioni sia le verifiche incomplete. **CartaPDF 3.6.0 non attesta conformità ISO PDF/A integrale**. Le regole superate non cancellano le lacune del modello. Vedi [PDFA](PDFA.md).

La preparazione di un intento ICC CMYK non certifica PDF/X. I tag e le descrizioni a livello di pagina non certificano PDF/UA.

## Biblioteca e recupero

La biblioteca conserva un indice locale e riferimenti ai file; se li sposti fuori dall'app, può essere necessario aggiornare il collegamento. Le cartelle monitorate funzionano mentre l'app e il relativo pannello sono aperti.

Le preferenze permettono di gestire le copie automatiche di recupero. Il pannello delle versioni conserva fino a 20 versioni per documento. Questi dati occupano spazio sul Mac e possono includere contenuti sensibili: consulta [PRIVACY](PRIVACY.md) prima di condividere cartelle, backup o rapporti diagnostici.
