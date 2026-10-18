# Compilazione e verifica

## Requisiti

- macOS 14 o successivo.
- Xcode completo con SDK macOS compatibile; il manifest Swift Package Manager richiede Swift tools 5.9 o successivo.
- Strumenti Apple disponibili tramite `xcrun`.
- Python 3 solo per gli script di sviluppo e i rapporti; non è una dipendenza dell'app.

Il pacchetto non dichiara dipendenze Swift esterne. I framework runtime sono quelli Apple elencati nel [rapporto delle funzionalità](../Development/FeatureVerification.json). I cataloghi PDF/A e le tabelle font sono dati locali con licenze proprie.

Le evidenze della versione 3.6.0 riguardano il bundle Apple Silicon. Una compilazione su altre architetture non equivale a una verifica di quella piattaforma. Non è documentato un bundle universale verificato.

## Compilare

Dalla radice del repository:

```sh
./scripts/build-app.sh
open dist/CartaPDF.app
```

Lo script compila in Release, assembla l'app, genera l'icona, include dizionario AppleScript e metadati App Intents e applica una firma ad hoc locale. `--no-sign` omette la firma. La build ricrea `dist/CartaPDF.app`; conserva altrove eventuali copie che vuoi mantenere.

Se è selezionato solo Command Line Tools e Xcode si trova nella posizione standard, gli script scelgono Xcode per il singolo processo. Non modificano `xcode-select` globale. Per usare un'altra installazione:

```sh
DEVELOPER_DIR="/percorso/Xcode.app/Contents/Developer" ./scripts/build-app.sh
```

La firma ad hoc non identifica un editore e non sostituisce firma Developer ID e notarizzazione. Questa procedura prepara una build locale, non pubblica automaticamente binari o release su GitHub.

## Test nativi

```sh
./scripts/test.sh
./scripts/test.sh --filter PDFArchiveColorSpaceChecksTests
```

Il runner usa `swift test` e una cartella temporanea separata dalla build Release. Non accetta le opzioni di selezione test di `xcodebuild`. I test esercitano PDFKit, Vision, WebKit e altre API native; un ambiente senza sessione grafica o con restrizioni del sistema può produrre risultati diversi. Distingui tali problemi dai difetti del codice e documenta ambiente e messaggio effettivo.

Per conservare un nuovo risultato e rigenerare il rapporto funzionale:

```sh
./scripts/test.sh > Development/TestResults.log 2>&1
python3 Development/verify-features.py
```

La versione 3.6.0 ha un'evidenza integrata di **512 test superati e zero errori**. Il conteggio descrive quella esecuzione: una modifica successiva richiede una nuova verifica appropriata.

I log grezzi `*.log` sono esclusi da Git per evitare la pubblicazione involontaria di percorsi e diagnostica locale. I comandi sopra li rigenerano sul Mac; i rapporti JSON versionati conservano i risultati selezionati e la provenienza documentata.

## Integrazione continua

Il workflow [macOS checks](../.github/workflows/ci.yml) usa il runner GitHub `macos-15` Apple Silicon e seleziona esplicitamente Xcode16.4. Esegue `python3 scripts/check-repository.py`, controlli di sintassi, la suite nativa, la build Release e una verifica di firma/architettura/CLI. L’azione checkout ufficiale è fissata a un commit SHA; i permessi sono di sola lettura e le credenziali non vengono persistite nel checkout. Dependabot propone aggiornamenti delle Actions.

La CI non acquisisce il corpus, non attiva VoiceOver, non pubblica release e non modifica la visibilità del repository. Il risultato locale non sostituisce l’esito del workflow relativo al commit. Se l’immagine GitHub rimuove la toolchain scelta, aggiorna la selezione in una modifica verificata anziché cambiare SDK silenziosamente.


## Risorse e manifest

Le directory `Resources/PDFAProfiles` e `Resources/PDFFontData` sono replicate sotto `Sources/CartaPDF/Resources` per SwiftPM. Lo script di build ne controlla l'identità. Aggiorna le due copie insieme e conserva licenze, attribuzioni e manifest. Gli hash dei cataloghi fissati sono verificati anche nel codice Swift: aggiornare solo il manifest non aggiorna il contratto del validatore.

## Corpus di sviluppo

Il corpus ufficiale viene acquisito separatamente e non è incluso nell'app. La preparazione richiede rete ed è un comando volontario di sviluppo:

```sh
python3 Development/prepare-corpus.py --output /percorso/corpus
python3 Development/validate-corpus.py \
  --corpus /percorso/corpus \
  --executable dist/CartaPDF.app/Contents/MacOS/CartaPDF \
  --report /percorso/rapporto.json
```

Gli script usano il validatore Swift di CartaPDF, senza incorporare il motore veraPDF. I numeri storici presenti nei nomi delle fixture non sono un oracolo normativo completo; la mappatura automatica nome/regola resta provvisoria. Il corpus fissato contiene casi per nove profili, senza directory 3a e 3u. Vedi [PDFA](PDFA.md).

## Evidenze di una release

`Development/ReleaseVerification.json`, `PackagingVerification.json`, `BuildManifest.json` e i rapporti dei moduli registrano le prove della release indicata. Non modificarli a mano per dichiarare una nuova verifica. Dopo cambiamenti ai sorgenti o al pacchetto, rigenera solo le evidenze effettivamente rieseguite, conserva la provenienza dei risultati storici e verifica gli hash degli artefatti finali.

Il manifest della release 3.6 fotografa la build verificata prima della preparazione pubblica del repository: include l'hash del README di quella build. Non attesta l'identità dell'intero albero Git dopo gli aggiornamenti della documentazione e non viene rietichettato come una nuova build.

Per una futura distribuzione pubblica segui [PUBLIC_RELEASE](PUBLIC_RELEASE.md). La preparazione del repository non cambia la versione dell'app né certifica i formati prodotti.
