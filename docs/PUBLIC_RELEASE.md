# Preparazione alla pubblicazione pubblica

Il repository [GiorgioOppo/PDF-Edit-View](https://github.com/GiorgioOppo/PDF-Edit-View) nasce privato. Questa documentazione prepara una futura apertura dei sorgenti; **non autorizza né esegue il cambio di visibilità e non pubblica automaticamente binari**. Il nome del progetto è PDF-Edit&View, con slug GitHub PDF-Edit-View, mentre l'app resta CartaPDF 3.6.0.

## Contenuti del repository

Il repository sorgente deve comprendere codice, test, risorse e relative licenze, script, guide e prove tecniche selezionate. Cartelle di build, bundle, archivi di distribuzione, corpus acquisiti, documenti personali, password, chiavi private e credenziali devono restare fuori da Git. Verifica sia i file tracciati sia la storia dei commit prima di rendere il repository pubblico: aggiungere una regola a `.gitignore` non rimuove dati già registrati.

I rapporti storici in Development descrivono la release indicata e possono contenere percorsi o nomi di fixture. Conserva la validità dell'evidenza, ma pubblica solo dati che puoi condividere. Non aggiornare un hash o un esito a mano per far apparire recente una verifica.

## Prima di cambiare visibilità

1. Riesamina diff e storia per credenziali, documenti personali, percorsi identificativi, contenuti riservati e materiale non redistribuibile.
2. Verifica che licenze MIT, CC BY 4.0 e BSD siano presenti, con attribuzioni e manifest nelle due copie delle risorse.
3. Controlla link relativi, istruzioni di build, versione, limiti PDF/A e stato dell'audit VoiceOver.
4. Esegui i controlli di repository e la suite nativa appropriata; documenta separatamente l'ultima esecuzione reale e i limiti dell'ambiente.
5. Verifica le impostazioni GitHub: branch predefinito, permessi collaboratori, Actions, protezioni disponibili, canali di segnalazione e private vulnerability reporting se desiderato e disponibile.
6. Il proprietario decide esplicitamente il passaggio da privato a pubblico, dopo aver verificato i contenuti effettivamente inviati.

Non è richiesta una pubblicazione App Store per distribuire i sorgenti MIT. Una distribuzione binaria verificata ha requisiti operativi diversi dalla sola apertura del codice.

## Prima di distribuire un binario

- Compila da un commit identificato e verifica l'app realmente estratta dall'archivio finale.
- Registra versione, architettura, toolchain, SHA-256 e risultati delle prove pertinenti.
- Controlla le risorse fuori dal workspace e la firma sul bundle estratto.
- Se desideri una distribuzione firmata per il pubblico, prepara firma Developer ID e notarizzazione con un account e credenziali autorizzati; la firma ad hoc attuale non le sostituisce.
- Allega licenze, istruzioni, limiti e changelog. Pubblica artefatti solo dopo averne verificato provenienza e contenuto.

Nessuna release deve chiamare CartaPDF “validatore ISO PDF/A completo”, “certificato PDF/UA”, “PAdES completo” o equivalente finché la relativa copertura non è dimostrata. Il corpus, i cataloghi e i test sono evidenze limitate al loro ambito.

## Priorità tecniche aperte

Le lacune concrete sono documentate in [PDFA-ValidatorScope](../Development/PDFA-ValidatorScope.md) e [FeatureVerification](../Development/FeatureVerification.json). Tra le verifiche aperte figurano semantiche normative integrali, audit VoiceOver completo, scanner/cattura/audio reali e dispatch AppleScript. Non vengono assegnate date o promesse di completamento non verificate.
