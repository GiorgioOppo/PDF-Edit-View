# Changelog

Le voci descrivono implementazioni ed evidenze disponibili. Un test superato non attesta conformità normativa oltre al perimetro documentato. CartaPDF rimane gratuita, locale e basata soltanto su framework Apple.

## Non rilasciato

- Preparazione del repository GitHub privato per una futura pubblicazione dei sorgenti.
- Guide d'uso, compilazione, CLI, architettura, privacy, PDF/A e accessibilità.
- Policy per contributi, supporto, sicurezza, condotta e attribuzione dei dati.
- Risorse SwiftPM trovate nei layout flat/Contents e accanto ai prodotti XCTest, con percorso di test esplicito e verifica CLI del bundle su undici profili.
- Identità dei link salvata anche nella voce locale /CartaPDFLinkID per compensare la perdita di /NM in PDFKit su macOS 15; compatibilità con i link precedenti e protezione dei marker incoerenti. Prove su salvataggio, riapertura, rimozione, undo e cifratura.
- Valori export dei moduli verificati nei byte PDF invece di getter variabili tra macOS.
- CI Xcode26.3 con SDK che espone SecIdentityCreate; composizione delle fixture binarie con append lineari per evitare timeout del type checker.
- Compatibilità del percorso firme: il percorso di errore della firma conserva il CFError nativo o restituisce separatamente un errore Security interno, senza conversioni forzate tra i due tipi.
- Nessuna nuova versione dell'app o nuova certificazione implicita nelle modifiche di documentazione.

## 3.6.0 — 2026-10-18

- Schema degli spazi colore calibrati, Indexed, Separation e DeviceN, con confronti numerici esatti e limiti espliciti.
- Risoluzione degli alias canonici per stream Contents, Metadata, decode e identità dei profili ICC.
- Elementi multiprocesso ICC: canali, matrici, CLUT, curve e tipi supportati.
- Coordinate e bounds TrueType, agganci point-to-point dei compositi e massimi aggregati maxp.
- Attributi strutturali standard Layout/List/Table/PrintField e UserProperties, revisioni e precedenza.
- 512 test nativi superati, zero errori; 2164 PDF del corpus eseguiti sul binario Release senza errori di esecuzione. I risultati globali restano 1509 nonconforming e 655 indeterminate.
- Matrice CLI degli undici profili e fixture dei nuovi controlli colore. La validazione ISO PDF/A integrale resta incompleta e l'esito conforme è disabilitato.

Evidenze: [ambito](Development/PDFA-ValidatorScope.md), [release](Development/ReleaseVerification.json), [corpus](Development/PDFA-CorpusEvidence.json), [funzionalità](Development/FeatureVerification.json).

## 3.5.0 — 2026-10-18

- Controlli nativi delle funzioni PDF 0/2/3/4 raggiunte tramite riferimenti semantici, con dimensionalità, Domain/Range e audit calculator nei percorsi deterministici.
- Alias indiretti delimitati, identità terminali ed eredità delle voci pagina con null/indefiniti.
- Modello meccanico della struttura logica, IDTree/ParentTree, MCID/OBJR, classi e namespace supportati.
- Payload ICC pseq/ncl2/psid, cmap8 supplementare e audit Type2 delimitato.
- 447 test nativi superati; 2164 PDF del corpus eseguiti senza errori di esecuzione. Nuovi risultati del modello riesaminati separatamente.

## 3.4.0 — 2026-10-18

- Controlli ICC v2/v4 ulteriori e correzioni delle condizioni dipendenti dall'edizione.
- Contesti xref storici e inventario ObjStm più rigorosi.
- Inventario CFF CID/FD e cmap aggiuntive; URI XMP con risoluzione RFC3986 locale.
- Framing U3D supportato senza attestare geometria o payload PRC.
- 367 test nativi superati; 2164 PDF del corpus eseguiti senza errori di esecuzione.

## Versioni precedenti

Gli strumenti di editing, organizzazione, OCR, conversione, moduli, firme e automazione sono inventariati nei [150 requisiti](Development/FeatureRequirements.json). I dettagli storici dei controlli del validatore e delle regressioni si trovano nelle evidenze di Development. Non viene ricostruita una cronologia di release precedente senza prove corrispondenti.
