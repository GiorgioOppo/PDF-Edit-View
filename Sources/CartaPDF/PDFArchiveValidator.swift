import Foundation
import CryptoKit

private final class PDFArchiveBundleLocator {}

/// Profiles are distinct ISO editions/conformance levels, never aliases for 2u.
enum PDFArchiveProfile: String, CaseIterable, Codable, Sendable, Identifiable {
    case pdfa1a = "1a", pdfa1b = "1b", pdfa2a = "2a", pdfa2b = "2b", pdfa2u = "2u"
    case pdfa3a = "3a", pdfa3b = "3b", pdfa3u = "3u", pdfa4 = "4", pdfa4e = "4e", pdfa4f = "4f"
    var id: String { rawValue }
    var title: String { "PDF/A-" + rawValue }
    var part: Int { Int(rawValue.prefix(1))! }
    var fileName: String { "PDFA-" + rawValue.uppercased() + ".xml" }
    var expectedCatalogueSHA256: String {
        switch self {
        case .pdfa1a: return "c01d2b36faeb4e7703d96e88b4fa87605e67c39fa431a8adc93a1d50cbe54442"
        case .pdfa1b: return "93a8254a209a298cdf38d2f259906d585dfcdd1cc700650271b86920be9c00e6"
        case .pdfa2a: return "22ef9e98557d1ff714e252d5cf020840b0ec05fddd437c47058eeaa225dc6af5"
        case .pdfa2b: return "bae015161f0c9b4296481f11936c97728dfd12dffb2df48ea744f885794da382"
        case .pdfa2u: return "52bddd46bc6c8bfcfb00cf4589935a7328668f709d92928d2e8841446c05a21d"
        case .pdfa3a: return "4eac441409c0523ded5d29d77e567f63ae3ac285d82505f673d2992286da674a"
        case .pdfa3b: return "fc6f5c9cccc8c52af8584f98505fe62979522e66acd525a67ce391c36d8dbc17"
        case .pdfa3u: return "2ac7b14a789681c4dc9d53ec66e9a28f6efa2cd61a4633487b4c15c111281bf2"
        case .pdfa4: return "4d5eac9e102b76469119d3492fdd7ea45386701f3f8ef5b3740f676e0cd9e730"
        case .pdfa4e: return "4ef67b1d8c7e34d55457850d9906ec13f5d2c4aa5bafebd5b601b6b1b8dc180a"
        case .pdfa4f: return "dbbe4b0327bc76db801951e1ea76d0277847851faad7fe00f060a5c8d841e77e"
        }
    }
    var expectedRuleCount: Int {
        switch self {
        case .pdfa1a: return 135; case .pdfa1b: return 129
        case .pdfa2a: return 153; case .pdfa2b: return 144; case .pdfa2u: return 146
        case .pdfa3a: return 155; case .pdfa3b: return 146; case .pdfa3u: return 148
        case .pdfa4, .pdfa4e, .pdfa4f: return 111
        }
    }
}
enum PDFArchiveVerdict: String, Codable, Sendable {
    case conforming, nonconforming, indeterminate
    var title: String {
        switch self { case .conforming: return "Conforme"; case .nonconforming: return "Non conforme"; case .indeterminate: return "Indeterminato" }
    }
}
enum PDFArchiveRuleStatus: String, Codable, Sendable {
    case passed, failed, notVerified, notApplicable
    var title: String {
        switch self { case .passed: return "Verificata"; case .failed: return "Violata"; case .notVerified: return "Non verificata"; case .notApplicable: return "Non applicabile" }
    }
}
struct PDFArchiveRuleResult: Identifiable, Codable, Sendable {
    let id: String
    let specification: String
    let clause: String
    let testNumber: String
    let objectType: String
    let requirement: String
    let status: PDFArchiveRuleStatus
    let detail: String
    let locations: [String]
}
struct PDFArchiveValidationReport: Codable, Sendable {
    let profile: PDFArchiveProfile
    let verdict: PDFArchiveVerdict
    let rules: [PDFArchiveRuleResult]
    let modelChecks: [PDFArchiveRuleResult]
    let diagnostics: [String]
    let sha256: String
    let coverageComplete: Bool
    let scopeGaps: [String]
    let catalogueCommit: String
    var passedCount: Int { (rules + modelChecks).filter { $0.status == .passed }.count }
    var failedCount: Int { (rules + modelChecks).filter { $0.status == .failed }.count }
    var unverifiedCount: Int { (rules + modelChecks).filter { $0.status == .notVerified }.count }
    var notApplicableCount: Int { (rules + modelChecks).filter { $0.status == .notApplicable }.count }
    var textReport: String {
        var lines = ["\(profile.title): \(verdict.title)", "SHA-256: \(sha256)",
                     "Regole: \(rules.count); verificate \(passedCount), violate \(failedCount), non verificate \(unverifiedCount), non applicabili \(notApplicableCount).",
                     "Copertura ISO completa dimostrata: \(coverageComplete ? "sì" : "no")", "Catalogo veraPDF CC BY 4.0, commit \(catalogueCommit)."]
        lines += diagnostics + scopeGaps.map { "Lacuna: " + $0 }
        for rule in modelChecks + rules {
            lines.append("[\(rule.status.rawValue)] \(rule.specification) §\(rule.clause), test \(rule.testNumber), \(rule.objectType)\n\(rule.requirement)\n\(rule.detail)\n\(rule.locations.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n\n")
    }
}
struct PDFArchiveCatalogueRule: Sendable {
    let specification: String, clause: String, testNumber: String, objectType: String, requirement: String, expression: String
    var id: String { specification + ":" + clause + ":" + testNumber }
}

enum PDFArchiveValidator {
    static let catalogueCommit = "b76c28ff0d8809c30c4d0e64dc6c393f3c9019dc"
    /// A catalogued rule is not the whole ISO 32000/ICC/font model it depends on.
    /// These explicit residual obligations prevent a false positive even if all
    /// currently applicable catalogue predicates happen to pass.
    static let scopeGaps = [
        "Semantiche integrali ISO 32000-1/2 e PDF 2.0, codec immagini e tutte le revisioni non verificati integralmente; filtri generali, sintassi e riferimenti null supportati non costituiscono un parser ISO completo.",
        "Programmi font: esecuzione hinting/bytecode, PostScript dinamico, semantiche complete Type1/Type2 e Private, composizione FD FontMatrix, CFF2 e variazioni non verificati integralmente. Inventario CID FD/Subrs, cmap2/8/10/14 incluso Unicode supplementare cmap8, audit Type2 bounded, glifi e metriche supportati sono verificati separatamente.",
        "Grafica: colorimetria e tutti i payload/funzioni ICC, payload JPEG2000/JBIG2/CCITT, alcuni rendering mode Type3, stato iniziale di pattern ereditati e confini inline con codec non supportati restano incompleti. Le funzioni PDF hanno controlli separati su parametri/campioni e sintassi/stack calculator; l’esecuzione calculator sull’intero dominio resta non dimostrata.",
        "XMP: DTD complesse/esterne, rdf:datatype nelle edizioni precedenti, alcuni vocabolari/tipi opachi, URI relative senza base assoluta e date di granularità/fuso ambigui restano non verificati; xml:base è risolto localmente secondo RFC3986. Struttura significativa A, geometria e payload U3D/PRC e schemi DER CMS opachi/estensibili non completi; il framing U3D è verificato separatamente.",
        "Copertura integrale del testo ISO 19005 e dei riferimenti normativi non dimostrata; crosswalk del corpus storico non interamente verificato. Nessuna attestazione di conformità ISO completa."
    ]
    /// Reads an unambiguous RDF/XMP declaration. It does not validate the PDF,
    /// upgrade the declared level or infer conformance from a generation option.
    static func declaredProfile(data: Data) -> PDFArchiveProfile? {
        do {
            let reader = try PDFStructureDocument(data: data)
            guard !reader.encrypted, let metadata = try reader.dictionary(.reference(reader.rootID))["Metadata"]?.reference else { return nil }
            let xmp = try PDFArchiveXMP(data: reader.decodedStream(metadata))
            let parts = xmp.values("part"), levels = xmp.values("conformance")
            guard parts.count == 1, let part = Int(parts[0]), (1...4).contains(part) else { return nil }
            if part == 4 {
                if levels.isEmpty { return .pdfa4 }
                guard levels.count == 1 else { return nil }
                return levels[0] == "E" ? .pdfa4e : (levels[0] == "F" ? .pdfa4f : nil)
            }
            guard levels.count == 1, ["A", "B", "U"].contains(levels[0]) else { return nil }
            return PDFArchiveProfile(rawValue: String(part) + levels[0].lowercased())
        } catch { return nil }
    }
    static func validate(data: Data, profile: PDFArchiveProfile, catalogueDirectory: URL? = nil) -> PDFArchiveValidationReport {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var diagnostics: [String] = [], results: [PDFArchiveRuleResult] = [], modelChecks: [PDFArchiveRuleResult] = []
        do {
            let catalogue = try catalogue(profile: profile, directory: catalogueDirectory)
            let context: PDFArchiveRuleContext?
            do { context = try PDFArchiveRuleContext(data: data, profile: profile) }
            catch { context = nil; diagnostics.append("Analisi oggetti non completa: " + error.localizedDescription) }
            for rule in catalogue {
                if Task.isCancelled { diagnostics.append("Validazione annullata; le regole residue non sono state verificate.") }
                let evaluation: PDFArchiveRuleEvaluation
                if Task.isCancelled { evaluation = .unknown("Operazione annullata.") }
                else if let context {
                    do { evaluation = try context.evaluate(rule) }
                    catch { evaluation = .unknown("Controllo interrotto: " + error.localizedDescription) }
                } else {
                    // Header/EOF can be checked even when encryption, unsupported
                    // filters or malformed object structures stop the PDF model.
                    evaluation = PDFArchiveRuleContext.fileEvaluation(rule, data: data, profile: profile) ?? .unknown("Modello oggetti indisponibile: impossibile stabilire l’applicabilità.")
                }
                results.append(.init(id: rule.id, specification: rule.specification, clause: rule.clause,
                                     testNumber: rule.testNumber, objectType: rule.objectType, requirement: rule.requirement,
                                     status: evaluation.status, detail: evaluation.detail, locations: evaluation.locations))
            }
            if let context { diagnostics += context.diagnostics; modelChecks = context.modelChecks }
        } catch { diagnostics.append("Catalogo ufficiale non disponibile o non integro: " + error.localizedDescription) }
        let complete = results.count == profile.expectedRuleCount && !(results + modelChecks).contains { $0.status == .notVerified } && diagnostics.isEmpty && scopeGaps.isEmpty
        let verdict: PDFArchiveVerdict = (results + modelChecks).contains { $0.status == .failed } ? .nonconforming : (complete ? .conforming : .indeterminate)
        return .init(profile: profile, verdict: verdict, rules: results, modelChecks: modelChecks, diagnostics: Array(Set(diagnostics)).sorted(), sha256: hash,
                     coverageComplete: complete, scopeGaps: scopeGaps, catalogueCommit: catalogueCommit)
    }
    static func catalogue(profile: PDFArchiveProfile, directory: URL? = nil) throws -> [PDFArchiveCatalogueRule] {
        let location = directory ?? resourceDirectory()
        guard let location else { throw PDFStructureError.malformed("risorse PDF/A mancanti") }
        let manifestData = try Data(contentsOf: location.appendingPathComponent("MANIFEST.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.upstream_commit == catalogueCommit, let entry = manifest.profiles.first(where: { $0.file == profile.fileName }), entry.rule_count == profile.expectedRuleCount else {
            throw PDFStructureError.malformed("versione/inventario del catalogo PDF/A")
        }
        let xml = try Data(contentsOf: location.appendingPathComponent(profile.fileName))
        guard xml.count < 4 * 1024 * 1024, SHA256.hash(data: xml).map({ String(format: "%02x", $0) }).joined() == profile.expectedCatalogueSHA256, entry.sha256 == profile.expectedCatalogueSHA256 else {
            throw PDFStructureError.malformed("hash del catalogo PDF/A")
        }
        let delegate = CatalogueParser(), parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.rules.count == entry.rule_count,
              Set(delegate.rules.map(\.id)).count == delegate.rules.count else { throw PDFStructureError.malformed("XML/inventario regole PDF/A") }
        return delegate.rules
    }
    /// Unlike SwiftPM's generated Bundle.module accessor this lookup never
    /// terminates the app when an installation lacks its resource bundle.
    static func resourceDirectory(searchRoots: [URL]? = nil) -> URL? {
        var roots = searchRoots ?? [Bundle.main.resourceURL, Bundle(for: PDFArchiveBundleLocator.self).resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        #if DEBUG
        if searchRoots == nil, let path = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"] ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            roots.insert(URL(fileURLWithPath:path),at:0)
        }
        #endif
        for root in roots {
            let direct = root.appendingPathComponent("PDFAProfiles",isDirectory:true)
            if FileManager.default.fileExists(atPath:direct.appendingPathComponent("MANIFEST.json").path) { return direct }
            if let bundle = Bundle(url:root.appendingPathComponent("CartaPDF_CartaPDF.bundle",isDirectory:true)),
               let directory = bundle.url(forResource:"PDFAProfiles",withExtension:nil) { return directory }
        }
        return nil
    }
    private struct Manifest: Decodable {
        struct Entry: Decodable { let file: String, sha256: String, rule_count: Int }
        let upstream_commit: String, profiles: [Entry]
    }
    private final class CatalogueParser: NSObject, XMLParserDelegate {
        var rules: [PDFArchiveCatalogueRule] = []
        private var object = "", specification = "", clause = "", number = "", requirement = "", expression = "", capture = ""
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            guard namespaceURI == "http://www.verapdf.org/ValidationProfile" else { return }
            if elementName == "rule" { object = attributes["object"] ?? ""; requirement = ""; expression = "" }
            if elementName == "id" { specification = attributes["specification"] ?? ""; clause = attributes["clause"] ?? ""; number = attributes["testNumber"] ?? "" }
            if elementName == "description" || elementName == "test" { capture = elementName }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capture == "description" { requirement += string }; if capture == "test" { expression += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == capture { capture = "" }
            if elementName == "rule", !specification.isEmpty, !clause.isEmpty, !object.isEmpty {
                rules.append(.init(specification: specification, clause: clause, testNumber: number, objectType: object,
                                   requirement: requirement.trimmingCharacters(in: .whitespacesAndNewlines), expression: expression.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }
}
