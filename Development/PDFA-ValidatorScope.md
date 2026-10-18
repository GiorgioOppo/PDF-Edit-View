# Validazione PDF/A nativa: perimetro verificato e lacune

Data della ricerca: 18 ottobre 2026. Implementazione Swift/Foundation/Compression/CoreGraphics/CryptoKit/Security; nessun motore, eseguibile, servizio di rete o dipendenza runtime esterno.

## Esito di conformità

Il software non è attualmente un validatore ISO PDF/A completo. Gestisce gli undici profili separatamente e produce un rapporto per ogni regola del catalogo, senza scambiare la presenza di XMP, font o ICC per conformità.

- `nonconforming`: esiste almeno una violazione dimostrata delle regole implementate.
- `indeterminate`: nessuna violazione dimostrata, ma rimangono regole o obblighi normativi non verificati, parsing non supportato, risorse mancanti, cifratura o cancellazione.
- `conforming`: riservato a copertura integrale dimostrata e a tutte le condizioni applicabili verificate. **Questo esito non viene emesso dalla versione corrente**: `scopeGaps` conserva gli obblighi del modello normativo non implementati.

`passed` riguarda la singola condizione indicata, non l’intero documento. `notApplicable` riguarda solo il modello di oggetti esplicitamente indicizzato. Ogni proprietà non modellata restituisce `notVerified`. I contatori dei cataloghi non dimostrano la copertura del modello ISO 32000 sottostante.

## Cataloghi tracciati

Dati originali del progetto ufficiale veraPDF, commit `b76c28ff0d8809c30c4d0e64dc6c393f3c9019dc`, distribuiti separatamente sotto CC BY 4.0 con attribuzione, licenza e manifest. Nessun codice del motore Java viene incorporato. SHA-256 attesi fissati anche nel sorgente Swift: alterare XML e manifest insieme non consente di inventare un catalogo ufficiale.

| Profilo | Regole nel rapporto | Base della famiglia |
|---|---:|---|
| 1a | 135 | PDF 1.4, struttura logica A |
| 1b | 129 | PDF 1.4 |
| 2a | 153 | ISO 32000-1, struttura logica A |
| 2b | 144 | ISO 32000-1 |
| 2u | 146 | ISO 32000-1, mapping Unicode |
| 3a | 155 | ISO 32000-1, allegati e struttura logica A |
| 3b | 146 | ISO 32000-1 e allegati |
| 3u | 148 | ISO 32000-1, allegati e mapping Unicode |
| 4 | 111 | ISO 32000-2/PDF 2.0 |
| 4e | 111 | PDF 2.0, Engineering |
| 4f | 111 | PDF 2.0, file incorporati obbligatori |

Totale delle voci nei cataloghi: 1489, comprendenti condizioni condivise tra profili. Non sono 1489 implementazioni indipendenti. PDF/A-4:2020 è trattato come edizione fissata, non come futura revisione in preparazione.

## Controlli implementati con evidenza diretta nella versione 3.6

- Header, versione, marker binario, EOF, ID e trailer dell’ultima revisione; divieti Encrypt e condizioni Info/PieceInfo specifiche di PDF/A-4.
- Parsing aggiuntivo rigoroso degli oggetti fisici indicizzati e compressi: numeri, escape dei nomi, chiavi duplicate, stringhe hex prima del padding, spazi degli oggetti, stream/Length/EOL e righe xref. Xref ibride supportate. I controlli ISO 32000 aggiuntivi compaiono in `modelChecks`, separatamente dalle 1489 voci del catalogo.
- Limiti lessicali e risorse nei contenitori non dipinti, con esenzione di §6.1.12 per risorse nominate inutilizzate in A1 (TechNote0010 A010): pagina, Form, Pattern, appearance, Type3 e soft mask. Il mancato uso non viene trasformato in uso di un font o di un colore.
- Font Type1/eexec, CFF e SFNT TrueType/OpenType: inventario delle risorse distinto dalle selezioni Tf/ExtGState e dall’uso dei glifi; embedding sul testo realmente usato e Tr; glyph/CID/GID, cmap, metriche hmtx o CharString supportate, CIDToGIDMap, Widths/W/DW, subset CharSet/CIDSet, encoding, CMap e Unicode/ActualText. Dati Adobe CMap, AGL e PDF-to-Unicode locali, versionati e verificati con SHA-256. Le restrizioni CharSet/CIDSet distinguono glifi usati in A1 e glifi incorporati in A2/3.
- XMP/RDF secondo l’edizione Adobe richiesta: attributi e forme abbreviate, array, strutture, qualificatori, wrapper xpacket, pacchetti secondari, identificazione e prefissi, registri predefiniti (168 proprietà 2004 e 273 proprietà 2005), tipi e vocabolari supportati, extension schema e coerenza Info/XMP. Dettagli e casi ancora non verificati in `MetadataValidationEvidence.json`.
- Colori: per le parti 1–3 anche la sola specificazione del colore costituisce uso (TechNote0010 A011/A015); per la parte 4 è modellato il contesto del colore dipinto. Default color spaces, output e blending di pagina/Form, tiling/shading Pattern, soft mask, overprint; DeviceN e Separation; header ICC e struttura della tabella tag, componenti e identità dei profili; box JPEG2000/JP2/SIZ; confini inline provati tramite dimensioni/campioni indipendenti. L può guidare il parsing, ma non prova la propria correttezza. Un confine filtrato ambiguo rimane non verificato.
- Annotazioni/appearance e flag, campi con FT ereditato, XFA/AA, azioni contestuali; OCG Name/Order/AS; struttura, ParentTree/RoleMap e riferimenti MCID; lingua; AF, file associati, Assets RichMedia e allegati PDF/A ricorsivi con limiti espliciti.
- ByteRange delle firme e contenuto CMS tramite Security, senza eseguire azioni, aprire allegati, consultare la rete o importare certificati nel Portachiavi.

Aggiunte della versione 3.3:

- Filtri ASCIIHex, ASCII85, RunLength, LZW (EarlyChange 0/1) e Flate con EOD, checksum Adler32 e verifica originale della struttura deflate RFC 1951. Espansione tramite Compression Apple; il consumo anticipato del decoder Apple non prova il confine. Predittori TIFF/PNG a 1/2/4/8/16 bit; Filter/DecodeParms indiretti e array controllati; riferimenti indefiniti/liberi risolti a null. Numeri nei content stream verificati prima di normalizzarli.
- CFF Expert/ExpertSubset/ExpertEncoding e nomi standard Adobe 5176; controlli strutturali SFNT e token delle istruzioni distinti dall’esecuzione hinting.
- DTD locali limitate, distinte da parole letterali in commenti/CDATA; rdf:datatype, nodeID e xml:base secondo l’edizione XMP; sintassi MIME e URI senza riparazioni implicite.
- DER ricorsivo originale secondo ITU X.690, SET OF CMS/RDN e DEFAULT X.509 nei percorsi modellati; estensioni opache non verificate. AF/Filespec nel grafo Catalog PDF 2.0 e condizioni AF/MCAF dei marked content; nessuna esecuzione dei payload.
- ExtGState dei pattern shading applicato temporaneamente dallo stato iniziale del contenitore che definisce la risorsa; origine non provata delle risorse ereditate segnalata come incompleta.

Aggiunte della versione 3.4:

- Header ICC v2/v4, calendario, D50, tag obbligatori per classe v4, compatibilità firma/tipo, conteggi e intervalli di curve, mluc, LUT8/16 e LUT A/B. La contiguità integrale dei tag si applica a v4.4; un tag privato non diventa invalido per il suo nome. Restano incomplete le funzioni, la colorimetria e i payload ICC non modellati.
- Vista xref propria di ciascuna revisione per Length e riferimenti storici; inventario ObjStm con header integer, offset crescenti, slice di un singolo valore e confini dei commenti. Ogni contesto registrato di uno stream ripubblicato è verificato: una modifica successiva non cancella la prova di una versione precedente.
- Inventario CFF CID FDArray/FDSelect/Private/Subrs, larghezze per FD e cmap2/8/10/14. Nella versione 3.4 la conversione supplementare Unicode di cmap8 era ancora non verificata; nella versione 3.6 è implementata. Composizione FD FontMatrix e VM/hinting completi rimangono non verificati.
- Risoluzione RFC3986 dei riferimenti XMP e xml:base, senza filesystem/rete o base implicita. Vocabolari EXIF/Flashpix e sintassi dei valori ulteriormente controllati.
- Framing U3D originale Swift per header, blocchi, padding, metadati e Priority Update. Geometria U3D e payload PRC restano non verificati. I riferimenti RichMedia Instance/Asset sono seguiti anche fuori dalla name tree.
- L’identità indiretta dei profili OutputIntent viene confrontata solo quando l’array contiene più di una voce; la validità dei singoli ICC ha un controllo del modello separato.

Aggiunte della versione 3.5:

- Payload ICC pseq/ncl2/psid e descrizioni embedded v2/v4, con layout/placeholder condivisi e ambiguità esplicite. Modelli required-tag v2 limitati alle edizioni documentate; v2.0 non riceve retroattivamente i requisiti v2.4.
- cmap8 Unicode supplementare e scelta full-repertoire; audit Type2 bounded su stack, arità, path, hint/mask, terminatori e subroutine. Non attesta geometria, hinting, tutte le semantiche Private o una VM font completa.
- Modello meccanico della struttura logica: gerarchia/P/Pg/S, IDTree e ParentTree bidirezionali, MCID/OBJR, classi/attributi e namespace modellati. Null opzionali e alias sono risolti senza falsi fallimenti. Significato umano e ordine di lettura restano non provati.
- Funzioni PDF 0/2/3/4 raggiunte tramite collegamenti semantici: parametri e dimensionalità, campioni packed, Domain/Range/Bounds confrontati come decimali esatti; grammatica calculator e stack su percorsi deterministici. L’aritmetica calculator sull’intero dominio rimane non verificata. Nessun campionamento viene usato per affermare validità universale.
- Lettore COS con alias indiretti bounded, identità terminali, Root/Pages/Kids/Type/Parent canonici e Length/Filter/N/First indiretti. Null e riferimenti indefiniti non interrompono l’eredità delle voci pagina. Cicli alias, cancellazione e budget restano incompleti.

- Schema nativo degli spazi colore: WhitePoint esatto senza arrotondamento Double, BlackPoint/Gamma CalGray/Matrix/Range, estensione delle lookup Indexed stringa/stream e alias, restrizioni degli spazi alternati, dimensioni tint/Range, nomi DeviceN/None/All/NChannel e Colorants. Voci null sono omesse, limiti e abbreviazioni fuori contesto restano incompleti. Le relazioni complete Process/MixingHints e la colorimetria non sono dimostrate. Dettagli in `ColorSpaceValidationEvidence.json`.
- ICC multiProcessElements: posizioni, canali della catena, matrici, CLUT float32, curveSet/segmented/formula/sampled e ACS. Valori binari non finiti/subnormali vietati sono separati dalle formule non verificate sull’intero dominio e dai tipi privati ignoti.
- TrueType: coordinate dei glifi semplici, bounds, agganci point-to-point con indici unsigned e punti phantom, massimi aggregati maxp e nesting delimitato. numberOfContours negativo identifica compositi anche se diverso da−1; hinting/VM e geometria finale dei compositi restano incompleti.
- Attributi strutturali standard: Layout, List, Table, PrintField e UserProperties; revisioni e precedenza A/C; Headers verso ID/TH; differenze PDF1.7/PDF2 di WritingMode, tipi e valori. Namespace custom, schemi export, significato delle intestazioni e reading order restano non verificati.
- Stream Contents singoli/array, decode, Metadata e identità ICC seguono ora alias canonici; i cache condividono la stessa identità terminale. Null Contents è omissione, elementi non stream in un array sono distinti da cicli/budget non verificabili.

I controlli leggono una fotografia immutabile dei byte e non modificano il PDF. I limiti restano espliciti: 512 MiB input, 256 MiB stream decodificato, conteggi e profondità delimitati; il raggiungimento di un limite produce esito incompleto. L’esecuzione avviene in un job in background con cancellazione.

## Verifica indipendente

Il corpus ufficiale veraPDF è fissato al commit `377728596647e40edf16003d68d620773ce96ec5`: 2164 PDF delle directory `PDF_A-*`, licenza CC BY 4.0, hash Git blob verificati durante l’acquisizione. Isartor è escluso. Il corpus non è distribuito nell’app e non viene scaricato durante l’uso. Il corpus fissato contiene casi per nove profili e non contiene directory 3a/3u; questi ultimi sono esercitati dalla matrice nativa degli undici profili, senza attribuire loro una copertura indipendente del corpus.

`Development/prepare-corpus.py --output /percorso/corpus` acquisisce e verifica i dati ufficiali solo su esplicita esecuzione durante lo sviluppo; richiede rete. `Development/validate-corpus.py --corpus /percorso/corpus --executable /percorso/CartaPDF.app/Contents/MacOS/CartaPDF --report /percorso/rapporto.json` esegue il binario Swift originale sui dati locali, senza un motore Java. Questi script non vengono eseguiti né richiesti dall’app. I nomi di molti test usano numeri storici differenti dai predicati dei cataloghi fissati: il confronto automatico nome→regola è **provvisorio**, non misura l’accuratezza normativa. Un fallimento su una regola estranea non dimostra che il requisito del test sia stato verificato. Le regressioni semanticamente riesaminate sono documentate separatamente nei test e nelle evidenze.

## Lacune residue obbligatorie

1. Semantiche integrali ISO 32000 e PDF 2.0, tutti i filtri/codec e verifiche dei payload; gestione rigorosa di ogni revisione, riferimento indefinito e struttura non supportata. Alcune violazioni fisiche sono ora rilevate, ma ciò non costituisce un parser ISO completo.
2. Esecuzione/verifica integrale dei programmi font: hinting e bytecode, casi PostScript dinamici e contesti non modellati. I programmi non vengono eseguiti dal validatore. Le metriche verticali PDF W2/DW2 sono distinte dai fatti dei programmi font, secondo ISO 32000-1 §9.9.
3. Modello grafico completo, funzioni/colorimetria ICC e tutti i tag/payload, filtri JPX/JBIG2/CCITT, stato iniziale dei pattern in risorse ereditate e casi inline con codec non supportato.
4. XMP con DTD complesse/esterne, rdf:datatype nelle edizioni 2004/2005, vocabolari versionati non risolti, tipi custom opachi, URI relative senza base assoluta e coerenza di date con granularità/fuso ambigui. xml:base e i riferimenti relativi con base sono risolti localmente secondo RFC3986, senza I/O. Le DTD locali limitate a entità testuali sono supportate; nessuna risorsa esterna viene letta.
5. Assegnazione e significato di tutto il contenuto nella struttura logica A; interpretazione completa U3D/PRC/Engineering e schemi CMS/ASN.1 opachi o estensibili. Le associazioni AF del grafo attivo PDF 2.0 e la struttura DER supportata non provano questi obblighi più ampi.
6. Riconciliazione completa di ISO 19005-1/2/3/4 e riferimenti normativi, tutte le eccezioni e i contesti, crosswalk verificato del corpus e revisione specialistica. I testi integrali ISO 19005-1/2/3/4 non sono stati acquisiti; l’utente non dispone di copie locali. La versione pubblica Adobe di ISO 32000-1 è stata consultata per le specifiche tecniche citate, senza riconciliazione integrale.

Queste lacune sono riportate anche in `scopeGaps` e impediscono l’esito `conforming`. Non vengono nascoste da un catalogo completo, da test superati o da un’opzione di generazione Apple. I framework Apple consentono l’implementazione locale dei controlli, ma non offrono un’API di validazione ISO PDF/A integrale.

## Prova sul generatore Apple

`kCGPDFContextCreatePDFA` richiede la generazione archivistica, non certifica l’output. Nella fixture realmente eseguita su questo SDK, una pagina senza testo ha prodotto XMP `part=2`, `conformance=B`: scegliendo 2u, la regola ISO 19005-2 §6.6.4 test 3 è correttamente violata. Non si cambia XMP per fingere un livello superiore. Il livello va rilevato dai byte e poi verificato; l’identificazione resta una dichiarazione, non una certificazione.

## Test

La suite integrata include `PDFArchiveValidatorTests`, `PDFArchiveFontChecksTests`, `PDFArchiveMetadataChecksTests`, `PDFArchiveGraphicsSyntaxTests`, `PDFArchiveStructureChecksTests`, `PDFArchiveObjectChecksTests` e `CartaArchiveValidationTests`. Verifica casi positivi, negativi, differenze di profilo, regressioni del corpus, risorse mancanti/manomesse e rapporti JSON/CLI. Il risultato finale è in `Development/TestResults.log`; inventario e limiti in `PDFA-ValidatorCoverage.json` e nelle evidenze dei singoli moduli.

## Fonti primarie

- ISO 19005-1:2005 e corrigenda: https://www.iso.org/standard/38920.html
- ISO 19005-2:2011: https://www.iso.org/standard/50655.html
- ISO 19005-3:2012: https://www.iso.org/standard/57229.html
- ISO 19005-4:2020: https://www.iso.org/standard/71832.html
- ISO 32000-1 reso disponibile da Adobe: https://opensource.adobe.com/dc-acrobat-sdk-docs/standards/pdfstandards/pdf/PDF32000_2008.pdf
- Regole ufficiali e licenza dei dati veraPDF: https://github.com/veraPDF/veraPDF-validation-profiles/tree/b76c28ff0d8809c30c4d0e64dc6c393f3c9019dc
- Modello e struttura delle regole: https://docs.verapdf.org/validation/rules/
- Correzioni tecniche PDF/A-4 pubblicate dalla PDF Association: https://pdf-issues.pdfa.org/19005-4-2020/
- Contratto nativo Apple: `CGPDFContext.h`, chiave pubblica `kCGPDFContextCreatePDFA`, SDK Xcode installato. Nessun simbolo privato viene usato.

Le descrizioni normative distribuite nei cataloghi e riprodotte nei rapporti mantengono attribuzione e licenza CC BY 4.0 dei dati; il codice Swift del validatore è implementazione originale del progetto.

Fonti aggiuntive consultate per la versione 3.2:

- Adobe XMP: https://developer.adobe.com/xmp/docs/xmp-specifications/
- ICC.1:2022: https://www.color.org/specifications/ICC.1-2022-05.pdf
- CharSet/CIDSet: https://pdfa.org/wp-content/uploads/2018/06/1530_Seggern.pdf e https://github.com/veraPDF/veraPDF-library/issues/983
- Errata PDF 2.0: https://pdf-issues.pdfa.org/32000-2-2020/
- Corpus ufficiale: https://github.com/veraPDF/veraPDF-corpus/tree/377728596647e40edf16003d68d620773ce96ec5

I dati Adobe CMap/AGL/PDF-to-Unicode mantengono licenze BSD a 3 clausole e attribuzioni in `Resources/PDFFontData`; non viene importato codice del toolkit Adobe.

Fonti aggiuntive della versione 3.3: ISO 32000-1 §§7.3.10/7.4/7.8.2 e Tabella 77; [RFC 1950](https://www.rfc-editor.org/rfc/rfc1950), [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951); Adobe 5176 e specifiche font Apple/Microsoft citate nelle evidenze font; ITU X.690:2021 e PDF Association AN002 citati nelle evidenze struttura. Le nuove regressioni, gli hash e le verifiche indipendenti sono documentati in StreamValidationEvidence.json e nelle evidenze dei moduli.

ASCIIHex senza terminatore >: i due casi del corpus con lunghezza e ICC coerenti sono trattati come non verificati. Le fonti pubbliche non risolvono esplicitamente la sostituzione del terminatore con EOF delimitato da Length. I confini inline richiedono sempre una prova indipendente. La presenza di un ICC non decodificabile non equivale ad assenza del profilo.

Il precedente giro Release 3.3 ha analizzato 2164 file senza errori di esecuzione. Sette nomi storici pass hanno inoltre una violazione del modello sui campioni inline: Flate produce 1062 byte con dizionario di un pixel RGB da 3 byte e nessun filtro DCT. Tredici payload sono stati decodificati indipendentemente con zlib della libreria standard durante lo sviluppo; byte e riferimenti normativi sono in PDFA-CorpusModelReview.json. I nomi storici restano confronti provvisori delle singole clausole, non attestazioni globali sui file.

Fonti aggiuntive della versione 3.4: ICC.1:2001-04, ICC.1:2010-12 e ICC.1:2022-05 pubblicate da color.org; RFC3986, W3C XML Base e specifiche XMP citate nelle evidenze metadati; ECMA-363 e l’errata PDF 2.0 Table343 citati nell’evidenza Engineering. Le verifiche sono implementazioni Swift originali; nessun motore esterno è incluso. Prove e limiti in ICCValidationEvidence.json e nelle altre evidenze dei moduli.

Precedente Release 3.4 verificata: **367 test nativi passati, zero errori**. Il binario estratto dal pacchetto ha analizzato **2164 file in 19,209 secondi, zero errori di esecuzione**, e le risorse di tutti gli 11 profili sono state verificate fuori dal progetto. La revisione dei nuovi fallimenti del modello è in PDFA-CorpusReview34.json; i risultati del corpus non provano la completezza ISO. Il binario non emette conformità integrale.

Fonti aggiuntive della versione 3.5: ISO 32000-1 §7.10/Tabelle 38–42 e §§7.3.9/7.3.10; errata PDF 2.0, clausole 7 e 14; specifiche font Microsoft/Apple/Adobe e ICC PSD_TechNote citate nelle evidenze. Prove in FunctionValidationEvidence.json, ReferenceResolutionEvidence.json e nei supplementi3.5 dei moduli.

Release 3.5 verificata: **447 test nativi passati, zero errori**. Il binario estratto dal pacchetto ha analizzato **2164 PDF in 18.913 secondi, zero errori di esecuzione**. Tutti gli 11 profili e le risorse sono stati verificati fuori dal progetto. Le 29 nuove anomalie sui nomi storici pass sono riesaminate in PDFA-CorpusReview35.json; tre correzioni controfattuali sono state verificate sul binario Release. Nessun risultato del corpus prova la completezza ISO; conformità globale ancora disabilitata.

## Evidenza Release 3.6

512 test XCTest superati, zero errori; 65 nuovi rispetto alla 3.5. Il binario estratto dallo ZIP esegue 2164 PDF del corpus in 18.559s, senza errori di esecuzione: 1509 nonconforming e 655 indeterminate. Nessun nuovo/rimosso fallimento rispetto alla 3.5; i risultati per file coincidono con il preflight congelato, salvo l’ordine delle location diagnostiche in 24 file (multiset identico). La matrice CLI include anche 22 fixture colore positive/negative sugli undici profili. Firma ad hoc strict verificata sul pacchetto estratto, risorse locali e hash registrati in `ReleaseVerification.json`, `PackagingVerification.json` e `BuildManifest.json`. Questi risultati non dimostrano la validazione ISO integrale.
