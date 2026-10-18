# Contribuire a CartaPDF

Il progetto accoglie correzioni, test e documentazione che mantengano l'app gratuita, completamente locale e basata soltanto su framework Apple. Per l'architettura e i requisiti di build vedi [docs](docs/README.md).

## Prima di iniziare

Leggi i [limiti](README.md), le [licenze dei dati](THIRD_PARTY_NOTICES.md) e il [codice di condotta](CODE_OF_CONDUCT.md). Per un difetto ordinario puoi aprire un'issue, se le issue sono abilitate, con un esempio sintetico riproducibile. Per cambiamenti ampi descrivi problema e approccio prima di investire in un'implementazione estesa. Le vulnerabilità seguono [SECURITY](SECURITY.md).

Non caricare PDF personali, certificati con chiavi private, file password, log contenenti credenziali o copie degli standard senza diritto di redistribuzione. Gli esempi devono essere creati per il test oppure provenire da una fonte con licenza documentata.

## Vincoli di implementazione

- Usa Swift e API pubbliche Apple; non introdurre pacchetti, motori, servizi di rete, telemetria o dipendenze runtime di terze parti.
- Mantieni espliciti ambito, errori e operazioni che salvano una copia. Non presentare una rasterizzazione come modifica strutturale senza perdita.
- Rispetta undo, cancellazione, limiti di memoria e autorizzazioni dei documenti nei percorsi pertinenti.
- Distingui modifica, oscuramento, cifratura e firma; revisioni incrementali e ritaglio non garantiscono rimozione dei dati.
- Evita modifiche non correlate e preserva le attribuzioni dei dati incorporati.

## Validatore PDF/A

Un controllo nuovo o corretto deve citare una fonte primaria, edizione e clausola nelle evidenze appropriate. Definisci quali oggetti, revisioni e contesti analizza e come tratta null, alias, oggetti privati, input non supportato, limiti e cancellazione. Aggiungi fixture positive e negative che isolino il requisito; includi una regressione quando correggi un difetto reale.

Non usare il nome di una fixture del corpus come sola prova normativa. Non trasformare un controllo non implementato in `passed` o `notApplicable`. Non rimuovere `scopeGaps` senza dimostrare che l'obbligo corrispondente sia coperto integralmente. La versione corrente non emette conformità ISO globale.

Cataloghi e tabelle font sono dati fissati e verificati con hash. Se proponi un aggiornamento, conserva provenienza, commit, licenza e byte originali; aggiorna le due copie delle risorse e i contratti nel codice insieme. Non modificare i dati upstream per far passare un controllo.

## Verificare una modifica

```sh
./scripts/test.sh --filter NomeSuite
./scripts/test.sh
./scripts/build-app.sh
```

Scegli verifiche adeguate al cambiamento. Una sola modifica di testo non richiede di dichiarare una nuova prova runtime. Le modifiche a parsing, scritture, firme o risultati del validatore richiedono test mirati sui comportamenti reali. Per UI e hardware documenta ciò che hai osservato e ciò che resta non verificato.

Non riscrivere rapporti storici come se la suite fosse stata rieseguita. Quando generi nuove evidenze, indica versione, ambiente, input e hash pertinenti. Le istruzioni sono in [BUILDING](docs/BUILDING.md).

## Pull request

Descrivi il problema concreto, il comportamento risultante, le verifiche realmente eseguite e i limiti residui. Collega le issue pertinenti e includi schermate solo prive di dati personali. Una modifica alle funzionalità deve aggiornare le guide o i limiti interessati; una correzione normativa deve aggiornare l'evidenza del modulo.

Inviando un contributo dichiari di avere il diritto di condividerlo secondo la licenza MIT del codice o, per dati separati, secondo la licenza e la provenienza dichiarate. Non è richiesto un trasferimento di copyright. Le risorse con licenze proprie conservano i rispettivi obblighi.
