#!/usr/bin/env python3
"""Reconcile all 150 requirements with implementation evidence and XCTest output."""
import json
import re
from collections import Counter
from pathlib import Path

project = Path(__file__).resolve().parent.parent
development = project / "Development"
requirements = json.loads((development / "FeatureRequirements.json").read_text())["requirements"]
assert len(requirements) == 150
coverage = {}
for path in sorted(development.glob("*Coverage.json")):
    document = json.loads(path.read_text())
    if "requirements" not in document:
        assert path.name == "PDFA-ValidatorCoverage.json", f"Unknown coverage format: {path.name}"
        continue
    for item in document["requirements"]:
        assert item["id"] not in coverage, f"Duplicate {item['id']} in {path.name}"
        coverage[item["id"]] = dict(item, coverage_file=path.name)
assert set(coverage) == {item["id"] for item in requirements}, "Missing or unexpected requirement IDs"
test_sources = "\n".join(path.read_text() for path in (project / "Tests").rglob("*.swift"))
test_names = set(re.findall(r"func\s+(test\w+)\s*\(", test_sources))
entries = []
for requirement in requirements:
    item = coverage[requirement["id"]]
    item["title"] = requirement["title"]
    for test in item.get("tests", []) + item.get("additionalTests", []) + ([item["test"]] if item.get("test") else []):
        assert test.split(".")[-1] in test_names, f"Unknown test for {item['id']}: {test}"
    if item["id"] == "F043":
        item["status"] = "partial"
        item["remaining"] = "Validazione completa ISO 19005 non implementata: undici profili e 1489 voci tracciate, controlli nativi e rapporti disponibili; programmi font avanzati, alcuni codec/semantiche ISO32000, struttura A, payload 3D e riferimenti normativi ancora incompleti. Nessun esito conforme quando esistono lacune. Vedi Development/PDFA-ValidatorScope.md."
    if item["id"] in {"F016", "F017", "F041"}:
        item["manual_validation_required"] = True
    if item["id"] == "F038":
        item["manual_validation_required"] = "Dispatch AppleEvent da Script Editor; AppIntent/CLI testati e dizionario incluso."
    if item["id"] in {"F034", "F035"}:
        item.setdefault("tests", []).append("CartaWorkspaceServicesTests.testUntitledDocumentsRetainIndependentVersionHistories")
    if item["id"] == "F040":
        item.setdefault("tests", []).extend([
            "CartaWorkspaceServicesTests.testCancellingVisualWorkersAlwaysClearsBusyState",
            "CartaWorkspaceServicesTests.testVisualComparisonWorkerRetainsPDFDocumentsDuringRasterization",
        ])
    entries.append(item)

log = (development / "TestResults.log").read_text()
assert "Test Suite 'All tests' passed" in log, "Final full XCTest suite must pass"
counts = re.findall(r"Executed\s+(\d+) tests, with\s+(\d+) failures.*?in\s+([\d.]+)", log)
assert counts and int(counts[-1][1]) == 0, "Test failures remain"
imports = sorted({name for path in (project / "Sources").rglob("*.swift")
                  for name in re.findall(r"^import (\w+)", path.read_text(), re.MULTILINE)})
apple_modules = {"AVFoundation", "AppIntents", "AppKit", "Combine", "Compression", "CoreGraphics", "CoreImage", "CoreText", "CryptoKit", "Darwin", "Foundation", "ImageCaptureCore", "ImageIO", "PDFKit", "Quartz", "ScreenCaptureKit", "Security", "SwiftUI", "UniformTypeIdentifiers", "Vision", "WebKit"}
assert set(imports) <= apple_modules, "Unexpected non-Apple import"
report = {
    "app": "CartaPDF", "version": "3.6.0", "date": "2026-10-18",
    "constraints": {"free": True, "license": "MIT", "completely_local": True,
                    "Apple_frameworks_only": True, "third_party_packages": 0, "imports": imports,
                    "validation_catalogue_data_license": "CC BY 4.0; veraPDF Consortium; original XML; no Java engine",
                    "font_mapping_data_license": "Adobe BSD-3-Clause; CMaps, AGL and PDF-to-Unicode data; no Adobe toolkit code"},
    "summary": dict(Counter(item["status"] for item in entries)),
    "pdfa_validation": {"profiles": 11, "catalogued_rule_entries": 1489,
                        "complete_ISO_validation": False, "conforming_verdict_enabled": False,
                        "scope": "Development/PDFA-ValidatorScope.md", "evidence": "Development/PDFA-ValidatorCoverage.json"},
    "verification": {
        "automated_suite": {"tests": int(counts[-1][0]), "failures": 0, "seconds": float(counts[-1][2]),
                            "state": "passed", "log": "Development/TestResults.log"},
        "manual_passed": [
            "Apertura PDF unito di sei pagine in CartaPDF",
            "Sei risultati di ricerca con estratti e navigazione a pagina 3 con zoom stabile",
            "Divisione avanzata: anteprima, nomi e criteri per conflitti",
            "PDF estratto aperto in Anteprima: tre pagine con testo nell’ordine 2, 3, 1",
            "CLI info, merge, extract, split e text su fixture temporanee",
            "Metadati AppIntents generati con estrattore Apple; bundle firmato ad hoc",
            "Comando merge PDFs compilato in Script Editor usando il dizionario reale dell’app",
            "Versione 3.1: selettore degli 11 profili PDF/A, verifica 4f con 111 voci e rapporto JSON salvato dall’interfaccia",
        ],
        "voiceover": {"status": "manual_verification_pending",
                      "manual_audit": "Audit manuale completo non completato; non attestato come superato.",
                      "observed": "VoiceOver attivato temporaneamente; nessun audit completo attestato; stato iniziale off ripristinato off.",
                      "evidence": "Development/AccessibilityPanelAudit.json; CartaAccessibilityTests; CartaKeyboardEditingTests"},
        "not_verified": ["Acquisizione fisica scanner", "Consenso e cattura reale ScreenCaptureKit",
                         "Riproduzione voce reale", "Audit completo VoiceOver non completato", "Dispatch AppleScript da Script Editor"],
    },
    "material_limits": [
        "F043: validazione ISO PDF/A ancora parziale, con rapporti per 11 profili e scopeGaps espliciti; PDF/X e PDF/UA non certificati.",
        "Modifica originale del testo limitata a Type1 standard WinAnsi e operatori stringa semplici, senza reflow/CID/subset/TJ.",
        "Firma CMS offline senza revoca aggiornata, TSA, qualifica legale o certificazione completa PAdES.",
        "Tag a livello di pagina; preparazione ICC senza conversione di ogni colore o separazione.",
        "Preparazione strutturale, firma, preflight e ridisegno CoreGraphics ancora sincroni sul main actor.",
        "Hardware, gesti UI e lettori PDF generici richiedono verifiche oltre ai test automatici.",
    ],
    "requirements": entries,
}
(development / "FeatureVerification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(f"150 requisiti mappati; {counts[-1][0]} test passati; stati: {report['summary']}")
