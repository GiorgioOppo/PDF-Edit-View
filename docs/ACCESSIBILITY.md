# Accessibilità

L'interfaccia include nomi accessibili, valori e unità, stati dei controlli, annunci e operazioni da tastiera. Il pannello delle marcature **⇧⌘K** permette creazione, modifica, eliminazione e regolazione di coordinate/dimensioni con undo. Il catalogo Strumenti è ricercabile con **⇧⌘T**.

## Verifiche disponibili

La revisione statica e i test nativi sono documentati in [AccessibilityPanelAudit](../Development/AccessibilityPanelAudit.json), `CartaAccessibilityTests` e `CartaKeyboardEditingTests`. Queste verifiche controllano aspetti dell'interfaccia supportati dal codice e non sostituiscono una sessione completa con tecnologie assistive.

**L'audit manuale completo VoiceOver non è stato completato.** Una breve attivazione di VoiceOver non viene presentata come audit superato. Lo stato tecnico resta `manual_verification_pending` nel [rapporto funzionale](../Development/FeatureVerification.json).

Scanner fisico, cattura schermo autorizzata e riproduzione della voce richiedono prove reali aggiuntive. Non è dichiarata una conformità generale dell'interfaccia a uno standard di accessibilità.

## Accessibilità dei documenti PDF

La generazione di tag a livello di pagina, lingua e descrizioni non ricostruisce automaticamente la struttura semantica completa del contenuto. I controlli ParentTree/MCID e degli attributi strutturali verificano relazioni modellate, senza attestare significato umano, ordine di lettura o PDF/UA.

## Segnalare un problema

Indica versione di macOS e CartaPDF, tecnologia assistiva e impostazioni pertinenti, controllo interessato, sequenza di tasti e comportamento atteso/osservato. Usa un PDF sintetico senza informazioni personali. Per le modalità di segnalazione consulta [SUPPORT](../SUPPORT.md).
