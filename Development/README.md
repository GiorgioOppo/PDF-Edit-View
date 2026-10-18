# Evidenze e strumenti di sviluppo

[PublicRepositoryAudit.json](PublicRepositoryAudit.json) registra i controlli di preparazione del repository, separati dalle prove storiche del bundle.

Questa directory contiene il catalogo dei 150 requisiti, rapporti datati di test/audit, i cataloghi di copertura e gli strumenti Python originali di sviluppo. Non costituisce una certificazione ISO né un audit completo di sicurezza o accessibilità.

## Leggere i risultati

- `FeatureRequirements.json` elenca 100 migliorie e 50 nuove funzionalità; `FeatureVerification.json` distingue implementazioni, limiti e verifiche manuali mancanti.
- `PDFA-ValidatorScope.md` è il perimetro tecnico corrente: la validazione ISO PDF/A integrale non è completa e l’app non emette `conforming`.
- `PDFA-ValidatorCoverage.json`, `PDFARequirementsAudit.json` e le evidenze dei moduli descrivono controlli e fonti. `conditions_preventing_full_validation_claim` contiene criteri generali di accettazione, non un inventario aggiornato dei difetti.
- `PDFA-CorpusEvidence.json` e i rapporti `PDFA-CorpusReview*.json` riferiscono esecuzioni su dati pubblici fissati a commit. I nomi storici dei test non sono un oracolo di accuratezza; il corpus copre nove profili, senza directory 3a/3u.
- `BuildManifest.json`, `ReleaseVerification.json` e `PackagingVerification.json` sono prove storiche del pacchetto locale 3.6.0. Non attestano automaticamente questo commit, documentazione successiva o un installer pubblicato. I loro hash descrivono gli artefatti della data indicata e non vengono riscritti per fingere una nuova compilazione.
- I percorsi temporanei nei rapporti sono riferimenti di provenienza delle esecuzioni originali. I file temporanei, il corpus, i log grezzi e i bundle non sono inclusi in Git; non sono collegamenti a risorse disponibili in un clone.
- Le impronte dei log storici sono conservate; i log originali possono contenere diagnostici della macchina e rimangono locali. Le copie per una segnalazione devono essere controllate e anonimizzate.
- `VoiceOverAudit.json` e `AccessibilityPanelAudit.json` descrivono il lavoro realmente osservato. Non attestano il completamento di un audit manuale VoiceOver.

## Riprodurre le verifiche locali

Dalla radice del repository, con macOS14+ e Xcode completo:

```sh
python3 scripts/check-repository.py
./scripts/test.sh > Development/TestResults.log 2>&1
python3 Development/verify-features.py
./scripts/build-app.sh > Development/BuildResults.log 2>&1
```

Gli ultimi due script generano rapporti e bundle locali; non eseguono un push o una pubblicazione. Gli strumenti di preparazione/esecuzione del corpus sono documentati in [docs/PDFA.md](../docs/PDFA.md): l’acquisizione di dati pubblici richiede rete solo durante lo sviluppo e non avviene nell’app.

Python è usato soltanto per strumenti di sviluppo con la libreria standard. Non è una dipendenza dell’app. Test e build richiedono i framework Apple, senza pacchetti Swift esterni.
