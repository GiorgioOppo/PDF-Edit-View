# Validazione PDF/A: leggere correttamente i risultati

**CartaPDF 3.6.0 non è un validatore ISO PDF/A completo e non emette l'esito globale `conforming`.** Il rapporto distingue violazioni dimostrate, verifiche incomplete e condizioni verificate nel perimetro implementato.

Il motore è scritto in Swift e usa soltanto framework Apple. I cataloghi originali veraPDF sono dati XML locali sotto CC BY 4.0; non viene incluso il motore Java veraPDF.

## Profili e cataloghi

| Famiglia | Profili | Voci del catalogo per profilo |
| --- | --- | --- |
| PDF/A-1 | 1a, 1b | 135, 129 |
| PDF/A-2 | 2a, 2b, 2u | 153, 144, 146 |
| PDF/A-3 | 3a, 3b, 3u | 155, 146, 148 |
| PDF/A-4 | 4, 4e, 4f | 111 ciascuno |

Le **1489 voci** includono condizioni condivise tra profili; non sono 1489 implementazioni indipendenti. Il catalogo fissato al commit `b76c28ff0d8809c30c4d0e64dc6c393f3c9019dc` è verificato tramite SHA-256. La completezza dell'inventario non prova la completezza delle semantiche ISO 32000 sottostanti.

## Esito del documento

| Esito | Interpretazione |
| --- | --- |
| `nonconforming` | Almeno una violazione è dimostrata dai controlli implementati. |
| `indeterminate` | Nessuna violazione dimostrata, ma rimangono obblighi, parsing, risorse o verifiche incompleti; anche cancellazione e budget possono impedire la conclusione. |
| `conforming` | Riservato a una futura copertura integrale dimostrata; disabilitato nella versione corrente. |

Il risultato `passed` di una condizione riguarda quella condizione, nel contesto descritto. `notApplicable` riguarda solo gli oggetti indicizzati esplicitamente dal controllo. `notVerified` e `scopeGaps` non possono essere interpretati come superati. Il rapporto conserva SHA-256 dei byte analizzati e controlli aggiuntivi del modello separati dalle voci del catalogo.

## Perimetro implementato

I controlli includono sintassi fisica e riferimenti supportati, font e mapping Unicode, RDF/XMP, ICC/spazi colore, funzioni PDF, grafica modellata, annotazioni, moduli, OCG, allegati e firme. La versione 3.6 aggiunge schema dei colori calibrati/Indexed/Separation/DeviceN, alias stream/Metadata, elementi multiprocesso ICC, coordinate e agganci TrueType e attributi strutturali standard.

Restano incomplete semantiche integrali ISO 32000/PDF 2.0, codec e payload avanzati, esecuzione font/hinting, colorimetria e funzioni sull'intero dominio, alcune forme XMP, significato della struttura logica, U3D/PRC/Engineering e riconciliazione normativa integrale. L'elenco tecnico autorevole è [PDFA-ValidatorScope](../Development/PDFA-ValidatorScope.md), con le evidenze dei moduli collegate.

Il validatore legge una fotografia dei byte e non modifica il PDF. Sono applicati limiti espliciti, tra cui 512 MiB di input e 256 MiB per stream decodificato, oltre a conteggi e profondità delimitati. Il limite raggiunto produce incompletezza; non prova validità. Payload, programmi font e allegati non vengono eseguiti.

## Generazione e identificazione

L'opzione Apple `kCGPDFContextCreatePDFA` richiede la generazione archivistica e non certifica l'output. Il livello dichiarato viene letto dai byte: nella fixture verificata, richiedere 2u ha prodotto un documento dichiarato 2b, correttamente distinto dal profilo richiesto. CartaPDF non alza artificialmente il livello XMP.

Identificazione XMP, generazione e validazione sono tre fatti separati. Un documento che dichiara un profilo o viene visualizzato correttamente può comunque violarne i requisiti.

## Evidenze della versione 3.6

- 512 test XCTest superati, zero errori, nell'esecuzione registrata.
- Binario Release estratto dal pacchetto: 2164 PDF del corpus analizzati senza errori di esecuzione, con 1509 esiti `nonconforming` e 655 `indeterminate`.
- Matrice CLI per tutti gli undici profili e fixture positive/negative dei nuovi controlli colore.
- Risorse e firma ad hoc del bundle estratto verificate; input delle prove invariati.

Il corpus fissato contiene directory per nove profili, senza 3a e 3u. Questi ultimi sono esercitati dalla matrice nativa, senza attribuire loro una copertura indipendente del corpus. La relazione automatica tra nomi storici delle fixture e regole attuali è provvisoria: i risultati non sono una percentuale di accuratezza o una certificazione ISO.

Fonti dei risultati: [FeatureVerification](../Development/FeatureVerification.json), [CorpusEvidence](../Development/PDFA-CorpusEvidence.json), [ReleaseVerification](../Development/ReleaseVerification.json) e [copertura](../Development/PDFA-ValidatorCoverage.json).

## Contribuire al validatore

Una nuova condizione richiede una fonte primaria con edizione/clausola, un ambito semantico esplicito, fixture positive e negative e trattamento separato di casi ambigui, privati, cancellati o limitati. Una regressione va isolata nei byte o nel modello pertinente. Non rimuovere `scopeGaps` solo perché passano test o cataloghi: deve essere dimostrata la copertura dell'obbligo normativo corrispondente.
