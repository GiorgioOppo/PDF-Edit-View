# Supporto

Per iniziare consulta [README](README.md), [guida d'uso](docs/USAGE.md), [build](docs/BUILDING.md) e [CLI](docs/CLI.md). Il progetto non promette assistenza commerciale o tempi di risposta.

## Problemi e richieste

Se le issue sono abilitate nel repository, usa un'issue per bug riproducibili e richieste di funzionalità. Indica:

- versione di CartaPDF, macOS, architettura e Xcode quando pertinente;
- operazione e passaggi minimi per riprodurre il problema;
- risultato atteso e osservato, con il testo dell'errore;
- fixture sintetica o fonte pubblica con licenza redistribuibile;
- eventuali verifiche già eseguite.

Non allegare PDF personali, password, chiavi, firme contenenti informazioni riservate o log non esaminati. I rapporti possono contenere nomi, percorsi e metadati. Per vulnerabilità o esposizione di dati usa [SECURITY](SECURITY.md).

## Risultati PDF/A

Un esito `indeterminate` è previsto quando mancano verifiche o il modello non supporta il documento. La versione 3.6.0 non emette conformità ISO completa. Prima di segnalare un risultato, leggi [PDFA](docs/PDFA.md) e [scope](Development/PDFA-ValidatorScope.md). Per una discrepanza indica profilo, identificatore della condizione, byte o oggetto pertinente e fonte primaria; il nome storico di un test del corpus non è sufficiente da solo.

## Verifiche manuali

L'audit completo VoiceOver è ancora aperto. Scanner, cattura schermo e audio dipendono dall'ambiente reale; specifica dispositivo e autorizzazioni senza condividere dati personali. La compilazione del dizionario AppleScript non prova il dispatch effettivo da Script Editor.

Il repository e le issue non sono un servizio di conservazione documentale, certificazione ISO o valutazione legale delle firme.
