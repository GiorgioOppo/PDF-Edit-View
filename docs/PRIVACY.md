# Privacy e permessi

CartaPDF elabora i documenti sul Mac. Non richiede account, abbonamenti o un servizio cloud e non contiene telemetria applicativa o servizi AI remoti. OCR, confronto, conversioni, ricerca e verifiche CMS/PDF/A avvengono localmente. Il progetto non carica automaticamente PDF o rapporti su GitHub.

Questa descrizione riguarda il codice dell'app. Le impostazioni del sistema, i backup, la sincronizzazione della cartella scelta dall'utente e i servizi esterni aperti volontariamente restano sotto il controllo dell'utente e di macOS.

## Connessioni e contenuti esterni

Un collegamento web contenuto in un PDF viene aperto su azione dell'utente tramite le integrazioni di sistema. Il browser o il servizio di destinazione applicano la propria informativa. La conversione HTML usa contenuto statico con JavaScript e risorse remote bloccati.

La verifica delle firme non consulta servizi di revoca o timestamp in rete. Il validatore PDF/A non risolve DTD esterne, non apre allegati e non esegue payload. Le URI nei metadati vengono analizzate come dati.

Gli script di sviluppo per acquisire il corpus richiedono rete solo quando vengono eseguiti esplicitamente. GitHub e gli strumenti di collaborazione del repository sono servizi distinti dall'app.

## Dati conservati localmente

| Dati | Posizione o meccanismo | Contenuto |
| --- | --- | --- |
| Documenti e output | Destinazioni scelte dall'utente | PDF, immagini, testo, firme e rapporti esportati. |
| Preferenze | UserDefaults di `it.cartapdf.editor` | Autore annotazioni, strumenti, scorciatoie, cache, job e impostazioni dei pannelli. |
| Biblioteca | `~/Library/Application Support/CartaPDF/Library.json` | Percorsi, bookmark, categorie/tag e indice testuale dei documenti importati. |
| Versioni locali | `~/Library/Application Support/CartaPDF/Versions` | Fino a 20 copie per documento e metadati delle versioni. |
| Recupero | `~/Library/Application Support/CartaPDF/Recovery` | Copie automatiche dei documenti modificati e metadati associati. |
| Stato di lettura | `~/Library/Application Support/CartaPDF/Reading` | Pagina, zoom e disposizione; il nome del record deriva dall'hash del percorso. |
| File temporanei | Directory temporanea di macOS | Dati di lavoro e staging delle operazioni che lo richiedono. |

Le copie e gli indici locali possono contenere informazioni riservate. Un hash del percorso non cifra il contenuto o i metadati del record. La biblioteca non applica una cifratura aggiuntiva all'indice testuale. Le copie di recupero/versione usano i byte serializzati del documento; la protezione dipende dal documento e dal percorso di salvataggio supportato.

L'autore delle annotazioni ha come valore iniziale il nome completo dell'utente macOS e può essere modificato nelle preferenze. Può finire nei metadati delle annotazioni salvate. Percorsi, nomi, testo e metadati possono comparire nei rapporti o nei file condivisi volontariamente: esaminali prima di pubblicarli.

## Password, chiavi e certificati

Le password PDF vengono richieste per l'operazione o lette dalla CLI con `--password-file`. L'app non le salva nei preset o nella cronologia. Il file password è creato e gestito dall'utente e può restare sul disco finché non viene rimosso.

La firma utilizza il certificato locale selezionato; la verifica usa i byte originali e la fiducia disponibile localmente. Le credenziali del Portachiavi e le autorizzazioni di sistema restano gestite da macOS. Non allegare chiavi private, file password o documenti riservati a issue e pull request.

## Permessi e integrazioni

- **File:** l'app accede ai documenti e alle cartelle selezionate e alle proprie directory di supporto locale. Il bundle prodotto dallo script non va presentato come app sandboxed.
- **Registrazione schermo:** la cattura con ScreenCaptureKit richiede il consenso macOS pertinente.
- **Scanner:** Image Capture richiede un dispositivo e un driver compatibili, già disponibili sul sistema.
- **Voce:** la lettura ad alta voce usa le voci presenti sul Mac; l'app non scarica voci.
- **Automazione:** Comandi Rapidi e AppleScript possono coinvolgere le autorizzazioni di sistema relative al programma chiamante.

Le prove su scanner fisico, cattura reale e riproduzione audio restano distinte dai test automatici. Non è attestato un audit completo VoiceOver: vedi [ACCESSIBILITY](ACCESSIBILITY.md).

## Gestire o rimuovere i dati

Usa il pannello della biblioteca per rimuovere le voci indicizzate e i pannelli di versioni/recupero per gestire le copie disponibili. Le preferenze permettono di disattivare le copie automatiche di recupero. Rimuovere un riferimento dalla biblioteca non elimina necessariamente il PDF originale.

Per eliminare tutti i dati di supporto, chiudi prima l'app, verifica le copie che vuoi conservare ed elimina tramite Finder la cartella `CartaPDF` in Application Support. Questa operazione rimuove anche indice, versioni e recupero. I PDF salvati altrove, i file password creati dall'utente e le eventuali copie nei backup restano nelle rispettive destinazioni. Le preferenze di sistema sono separate dalla cartella di supporto.

Per una vulnerabilità che espone dati, segui [SECURITY](../SECURITY.md). Per un problema d'uso senza dati riservati, segui [SUPPORT](../SUPPORT.md).
