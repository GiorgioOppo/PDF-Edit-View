# Sicurezza

CartaPDF è un progetto in sviluppo. Non è dichiarato un audit di sicurezza completo e non è promesso un servizio di risposta entro tempi prestabiliti. Le correzioni vengono valutate sulla versione corrente; non è definita una politica di backport per versioni precedenti.

## Segnalare una vulnerabilità

Se nella scheda **Security** del repository è disponibile **Report a vulnerability**, usa quel canale privato di GitHub. La sua presenza dipende dall'abilitazione del private vulnerability reporting da parte del proprietario: questo documento non ne presume l'attivazione.

Se il canale non è disponibile, non pubblicare exploit, credenziali o documenti riservati in un'issue. Puoi aprire un'issue neutra chiedendo di abilitare un canale privato, senza dettagli sensibili, e attendere un contatto concordato prima di trasmettere la prova. Non è indicato un indirizzo email non verificato.

Una segnalazione utile contiene versione dell'app e di macOS, componente interessato, impatto osservato, sequenza minima di riproduzione e fixture sintetica. Condividi solo dati che puoi redistribuire e rimuovi password, chiavi private e informazioni personali. Mantieni i dettagli riservati finché non è concordata la divulgazione.

## Perimetro

Sono rilevanti, tra gli altri, esposizione di dati, scritture inattese, perdita di cifratura non segnalata, gestione non sicura di file/PDF malformati, aggiramento dei limiti e interpretazioni pericolose di contenuti esterni. Una lacuna normativa documentata del validatore PDF/A è normalmente un problema di correttezza; può avere implicazioni di sicurezza se causa una falsa attestazione o un comportamento sfruttabile.

L'app elabora localmente, ma file locali e PDF non attendibili possono comunque attivare parser e framework nativi. I budget e la cancellazione riducono alcuni rischi e non equivalgono a una sandbox o a una prova formale di sicurezza.

## Protezione dei dati

Non inviare documenti riservati al repository. L'app può conservare indice testuale, versioni e recupero sul Mac; consulta [PRIVACY](docs/PRIVACY.md). La firma ad hoc delle build locali non certifica l'identità dell'editore. Non è attestata validazione legale delle firme, revoca aggiornata o conformità ISO integrale.

Se una credenziale è stata inserita in Git o condivisa accidentalmente, revocala o ruotala tramite il servizio competente. Rimuovere il file dall'ultimo commit non elimina le copie nella storia o nei cloni.
