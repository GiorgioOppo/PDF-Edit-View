import Foundation

/// ISO font predicates backed by actual resource usage/program/CMap evidence.
/// Missing semantic evidence is never converted into a passing predicate.
final class PDFArchiveFontChecks {
    private struct Font {
        let dictionary:[String:PDFSyntaxValue]
        let location:String
        let parent:[String:PDFSyntaxValue]?
    }
    private struct Glyph {
        let font:[String:PDFSyntaxValue]
        let parent:[String:PDFSyntaxValue]
        let code:Data
        let cid:Int?
        let gid:Int?
        let name:String?
        let unicode:String?
        let unicodeDetermined:Bool
        let actualTextPresent:Bool
        let missingGlyph:Bool?
        let vertical:Bool
        let visible:Bool
        let location:String
        let program:PDFArchiveFontProgram?
    }
    private let reader:PDFStructureDocument
    private let profile:PDFArchiveProfile
    private var evidence:PDFArchiveContentEvidence?
    private var fonts:[Font] = []
    private var glyphs:[Glyph]?
    private var glyphGaps:[String] = []
    private var invalidCodeUses:[String] = []
    private var fontDictionaryIssues:[String] = []
    private var programs:[String:Result<PDFArchiveFontProgram?,Error>] = [:]
    private var cmaps:[PDFObjectID:PDFArchiveCMap] = [:]
    private static let families:Set<String> = ["PDFont","PDSimpleFont","PDType0Font","PDCIDFont","PDCMap","CMapFile","PDType1Font","PDTrueTypeFont","TrueTypeFontProgram","Glyph","PDReferencedCMap","CosActualText"]
    init(reader:PDFStructureDocument,profile:PDFArchiveProfile) { self.reader = reader; self.profile = profile }
    func evaluate(_ rule:PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation? {
        guard Self.families.contains(rule.objectType) else { return nil }
        if reader.encrypted { return .unknown("Font/contenuti cifrati non decodificati.") }
        try loadEvidence()
        let object = rule.objectType
        if object == "CosActualText" {
            return aggregate(evidence!.actualTexts.map { text in
                .check(!text.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) || (0xF0000...0xFFFFD).contains($0.value) || (0x100000...0x10FFFD).contains($0.value) },"ActualText privo di scalari Unicode Private Use.")
            },family:"ActualText",complete:evidence!.incompleteContexts.isEmpty)
        }
        if object == "Glyph" { return try glyphRule(rule) }
        if object == "CMapFile" || object == "PDCMap" || object == "PDReferencedCMap" { return try cmapRule(rule) }
        let selected = fonts.filter { font in
            let type = font.dictionary["Subtype"]?.name ?? ""
            switch object {
            case "PDType0Font":return type == "Type0"
            case "PDCIDFont":return type == "CIDFontType0" || type == "CIDFontType2"
            case "PDSimpleFont":return ["Type1","MMType1","TrueType","Type3"].contains(type)
            case "PDType1Font":return type == "Type1" || type == "MMType1"
            case "PDTrueTypeFont":return type == "TrueType"
            case "TrueTypeFontProgram":return type == "TrueType"
            default:return true
            }
        }
        var results:[PDFArchiveRuleEvaluation] = []
        for font in selected {
            do { results.append(try fontRule(rule,font:font)) }
            catch { results.append(.unknown(font.location + ": " + error.localizedDescription)) }
        }
        return aggregate(results,family:object,complete:evidence!.incompleteContexts.isEmpty)
    }
    /// Additional normative-model evidence is deliberately outside the pinned
    /// catalogue. Passing these bounded checks is not a complete font validator.
    var modelChecks:[PDFArchiveRuleResult] {
        var rows:[PDFArchiveRuleResult] = []
        func row(_ id:String,_ object:String,_ status:PDFArchiveRuleStatus,_ detail:String,_ locations:[String])->PDFArchiveRuleResult {
            .init(id:"CartaPDF:FontProgram:" + id,specification:profile.part == 4 ? "ISO 32000-2:2020":"ISO 32000-1:2008",clause:"9.6–9.8; specifiche dei programmi font referenziate",testNumber:id,objectType:object,requirement:"Il programma font incorporato deve avere strutture binarie coerenti con il proprio formato; accettazione CGFont non equivale a verifica normativa completa.",status:status,detail:detail,locations:locations)
        }
        guard !reader.encrypted else { return [row("encrypted","EmbeddedFontProgramModel",.notVerified,"Programmi font cifrati non decodificati.",[])] }
        do { try loadEvidence() }
        catch { return [row("inventory","EmbeddedFontProgramModel",.notVerified,"Inventario font non risolto: " + error.localizedDescription,[])] }
        for (index,font) in fonts.enumerated() where ["CIDFontType0","CIDFontType2"].contains(font.dictionary["Subtype"]?.name ?? "") {
            do {
                if let parent = font.parent,try encodingMap(parent)?.writingMode == 1 { try validateCIDVerticalMetrics(font.dictionary) }
            } catch PDFStructureError.malformed(let detail) { rows.append(row("\(index)-vertical-dictionary","FontDictionaryModel",.failed,"Metriche PDF verticali W2/DW2 non valide: " + detail,[font.location])) }
            catch { rows.append(row("\(index)-vertical-dictionary","FontDictionaryModel",.notVerified,"Applicabilità/grammatica W2/DW2 non risolta: " + error.localizedDescription,[font.location])) }
        }
        for (index,font) in fonts.enumerated() where !["Type0","Type3"].contains(font.dictionary["Subtype"]?.name ?? "") {
            do {
                guard let program = try program(font.dictionary) else { continue }
                let audit = program.structuralAudit()
                let bytecode = audit.gaps.filter{$0.hasPrefix("Bytecode TrueType") || $0.hasPrefix("Esecuzione completa Type2") || $0.hasPrefix("Semantica completa del programma PostScript")}
                let structural = audit.gaps.filter{!bytecode.contains($0)}
                let status:PDFArchiveRuleStatus = !audit.issues.isEmpty ? .failed:structural.isEmpty ? .passed:.notVerified
                let facts = "Formato \(program.format.rawValue), \(audit.checkedGlyphs) glifi verificati nei controlli implementati: directory/bounds, tabelle metriche, cmap0/2/4/6/8/10/12/13/14 e glyf/loca/maxp, delta delle coordinate semplici e indici degli agganci compositi con phantom points; CFF FD/Private/Subrs e token/stack/arity/path/mask Type2. Posizioni finali dei compositi, geometria e hinting completi non attestati. "
                rows.append(row("\(index)-structure","EmbeddedFontProgramModel",status,facts+(audit.issues+structural).joined(separator:"; "),[font.location]))
                rows.append(row("\(index)-bytecode","FontBytecodeModel",bytecode.isEmpty && audit.instructionScanComplete ? .passed:.notVerified,"\(audit.instructionPrograms) programmi istruzione, \(audit.instructionBytes) byte analizzati. " + (bytecode.isEmpty ? (audit.instructionScanComplete ? "Nessun bytecode TrueType da eseguire nei contesti verificati.":"Inventario istruzioni incompleto; nessuna assenza di bytecode viene presunta."):bytecode.joined(separator:"; ")),[font.location]))
            } catch PDFStructureError.malformed(let detail) {
                rows.append(row("\(index)-structure","EmbeddedFontProgramModel",.failed,"Struttura del programma incorporato non valida: " + detail,[font.location]))
            } catch {
                rows.append(row("\(index)-structure","EmbeddedFontProgramModel",.notVerified,"Programma incorporato non risolto: " + error.localizedDescription,[font.location]))
            }
        }
        if !fontDictionaryIssues.isEmpty { rows.append(row("required-font-dictionary","FontDictionaryModel",.failed,"Type0 richiede un unico dizionario CIDFont in DescendantFonts; null non è un font vuoto valido.",fontDictionaryIssues)) }
        if let evidence,!evidence.incompleteContexts.isEmpty { rows.append(row("inventory-incomplete","EmbeddedFontProgramModel",.notVerified,evidence.incompleteContexts.joined(separator:"; "),[])) }
        return rows
    }
    private func key(_ font:[String:PDFSyntaxValue])->String { PDFSyntaxValue.dictionary(font).encoded.base64EncodedString() }
    private func loadEvidence() throws {
        guard evidence == nil else { return }
        evidence = try PDFArchiveContentScanner(reader:reader).scan(allowPartial:true)
        var seen = Set<String>()
        // A010: an unreferenced named font is exempt from these font clauses.
        // Tf/gs selection counts even without text; FontUse remains glyph-only.
        for resource in evidence!.referencedFonts {
            let dictionary = resource.dictionary
            if seen.insert(key(dictionary)).inserted { fonts.append(.init(dictionary:dictionary,location:resource.location,parent:nil)) }
            if dictionary["Subtype"]?.name == "Type0" {
                do {
                    guard let descendants = try reader.resolve(dictionary["DescendantFonts"])?.array,descendants.count == 1 else { fontDictionaryIssues.append(resource.location + "/DescendantFonts: richiesto array con un unico CIDFont.");continue }
                    for descendant in descendants {
                        guard let resolved = try reader.resolve(descendant),resolved.dictionary != nil else {
                            fontDictionaryIssues.append(resource.location + "/DescendantFonts: elemento risolto null/non dizionario, richiesto un CIDFont.")
                            continue
                        }
                        let child = try PDFArchiveFontEncoding.resolvedFontHeader(reader.dictionary(resolved),reader:reader)
                        if seen.insert(key(child)).inserted { fonts.append(.init(dictionary:child,location:resource.location + "/DescendantFonts",parent:dictionary)) }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { evidence!.incompleteContexts.append(resource.location + "/DescendantFonts: " + error.localizedDescription) }
            }
        }
    }
    private func descriptor(_ font:[String:PDFSyntaxValue]) throws -> [String:PDFSyntaxValue] { try reader.dictionary(font["FontDescriptor"]) }
    private func symbolic(_ font:[String:PDFSyntaxValue]) throws -> Bool? {
        guard let flags = try reader.resolve(descriptor(font)["Flags"])?.int else { return nil }; return flags&4 != 0
    }
    private func program(_ font:[String:PDFSyntaxValue]) throws -> PDFArchiveFontProgram? {
        let id = key(font)
        if let cached = programs[id] { return try cached.get() }
        let value = Result<PDFArchiveFontProgram?,Error> {
            let descriptor = try self.descriptor(font)
            for field in ["FontFile","FontFile2","FontFile3"] {
                if let reference = descriptor[field]?.reference { let file = try reader.dictionary(.reference(reference)); return try PDFArchiveFontProgram(data:reader.decodedStream(reference),type1Length1:file["Length1"]?.int,type1Length2:file["Length2"]?.int) }
            }
            return nil
        }
        programs[id] = value; return try value.get()
    }
    private func containsFile(_ font:[String:PDFSyntaxValue]) throws -> Bool {
        let descriptor = try self.descriptor(font)
        for field in ["FontFile","FontFile2","FontFile3"] {
            if let reference = descriptor[field]?.reference { return try !(reader.object(reference).stream?.isEmpty ?? true) }
        }
        return false
    }
    private func aggregate(_ results:[PDFArchiveRuleEvaluation],family:String,complete:Bool) -> PDFArchiveRuleEvaluation {
        let failures = results.filter { $0.status == .failed }
        if !failures.isEmpty { return .check(false,failures.map(\.detail).joined(separator:"; "),locations:Array(failures.flatMap(\.locations).prefix(64))) }
        let gaps = results.filter { $0.status == .notVerified }
        if !complete || !gaps.isEmpty { return .unknown((!complete ? "Scansione di contesti incompleta: " + (evidence?.incompleteContexts.joined(separator:"; ") ?? "") + ". " : "") + gaps.map(\.detail).joined(separator:"; ")) }
        if results.isEmpty || results.allSatisfy({$0.status == .notApplicable}) { return .absent("Nessun oggetto applicabile: " + family) }
        return .check(true,"\(results.count) condizioni \(family) verificate con dati font/contenuti effettivi.")
    }
    private func fontRule(_ rule:PDFArchiveCatalogueRule,font:Font) throws -> PDFArchiveRuleEvaluation {
        let dictionary = font.dictionary, subtype = dictionary["Subtype"]?.name ?? "", expression = rule.expression
        func checked(_ success:Bool,_ detail:String)->PDFArchiveRuleEvaluation { .check(success,detail,locations:[font.location]) }
        if expression == "Type == \"Font\"" { return checked(dictionary["Type"]?.name == "Font","Type del font.") }
        if expression.hasPrefix("Subtype == \"Type1\"") { return checked(["Type1","MMType1","TrueType","Type3","Type0","CIDFontType0","CIDFontType2"].contains(subtype),"Subtype del font.") }
        if expression == "Subtype == \"Type3\" || fontName != null" { return checked(subtype == "Type3" || dictionary["BaseFont"]?.name != nil,"BaseFont salvo Type3.") }
        if rule.objectType == "PDSimpleFont" {
            let name = dictionary["BaseFont"]?.name ?? ""
            let standard = Set(["Times-Roman","Times-Bold","Times-Italic","Times-BoldItalic","Helvetica","Helvetica-Bold","Helvetica-Oblique","Helvetica-BoldOblique","Courier","Courier-Bold","Courier-Oblique","Courier-BoldOblique","Symbol","ZapfDingbats"]).contains(name)
            if standard { return checked(true,"Eccezione font standard del predicato.") }
            if expression.contains("FirstChar != null") { return checked(dictionary["FirstChar"] != nil,"FirstChar per font non standard.") }
            if expression.contains("LastChar != null") { return checked(dictionary["LastChar"] != nil,"LastChar per font non standard.") }
            if expression.contains("Widths_size") {
                let first = try reader.resolve(dictionary["FirstChar"])?.int,last = try reader.resolve(dictionary["LastChar"])?.int,widths = try reader.resolve(dictionary["Widths"])?.array
                return checked(first != nil && last != nil && widths != nil && last!>=first! && widths!.count == last!-first!+1,"Numero Widths coerente con FirstChar/LastChar.")
            }
        }
        if expression.hasPrefix("fontFileSubtype") {
            let file = try descriptor(dictionary)["FontFile3"]
            guard let file else { return .absent("FontFile3 assente.") }
            let name = try reader.dictionary(file)["Subtype"]?.name
            let allowed = profile.part == 1 ? ["Type1C","CIDFontType0C"]:["Type1C","CIDFontType0C","OpenType"]
            return checked(name == nil || allowed.contains(name!),"Subtype del FontFile3.")
        }
        if expression.contains("renderingMode == 3") && expression.contains("containsFontFile") {
            if subtype == "Type0" || subtype == "Type3" { return checked(true,"Type0 delega al discendente; Type3 dispone di CharProcs.") }
            if try containsFile(dictionary) { return checked(true,"Stream FontFile incorporato non vuoto; la validità del programma è verificata separatamente.") }
            let uses = evidence!.fonts.filter { use in key(use.dictionary) == key(dictionary) || (font.parent != nil && key(use.dictionary) == key(font.parent!)) }
            if uses.isEmpty { return .unknown("Font referenziato da Tf/ExtGState ma senza glifi mostrati: esenzione embedding Tr=3 non presunta.") }
            return checked(uses.allSatisfy { !$0.visible },"Embedding richiesto per ogni uso visibile; esenzione solo per usi esclusivamente Tr=3.")
        }
        if rule.objectType == "PDTrueTypeFont" {
            guard let symbolic = try symbolic(dictionary) else { return .unknown("Flags simbolico/non simbolico assenti o non risolti.") }
            let encoding = try PDFArchiveFontEncoding.baseEncoding(font:dictionary,reader:reader),differences = try PDFArchiveFontEncoding.differences(font:dictionary,reader:reader)
            if expression.hasPrefix("isSymbolic == false") { return checked(!symbolic || dictionary["Encoding"] == nil,"Font TrueType simbolico senza Encoding PDF.") }
            if expression.hasPrefix("isSymbolic == true") {
                if symbolic { return checked(true,"Eccezione font simbolico.") }
                guard ["WinAnsiEncoding","MacRomanEncoding"].contains(encoding ?? "") else { return checked(false,"TrueType non simbolico richiede WinAnsi o MacRoman.") }
                if profile.part == 1 { return checked(differences.isEmpty,"PDF/A-1 vieta Differences nel TrueType non simbolico.") }
                if differences.isEmpty { return checked(true,"WinAnsi/MacRoman senza Differences.") }
                return aggregate(differences.values.map { name in PDFArchiveFontReferenceData.shared == nil ? .unknown("Dati AGL offline non disponibili."):checked(PDFArchiveFontEncoding.unicode(name:name) != nil,"Differences mappabile Unicode AGL/uni/u: " + name) },family:"Differences",complete:true)
            }
        }
        if rule.objectType == "TrueTypeFontProgram" {
            guard let program = try program(dictionary) else { return .absent("Programma TrueType non incorporato.") }
            guard program.format == .sfntTrueType || program.format == .sfntCFF,let symbolic = try symbolic(dictionary) else { return .unknown("Programma SFNT/Flags non risolti.") }
            let records = program.cmapRecords,count = records.count,present30 = records.contains{$0.platform == 3 && $0.encoding == 0}
            if expression == "isSymbolic == false || nrCmaps == 1" { return checked(!symbolic || count == 1,"TrueType simbolico: una sola sottotabella cmap.") }
            if expression.contains("cmap31Present") { return checked(symbolic || records.contains{$0.platform == 3 && $0.encoding == 1} || records.contains{$0.platform == 1 && $0.encoding == 0},"Sottotabella Unicode3/1 o Mac1/0 nel programma.") }
            if expression.contains("cmap30Present == true ?") { return checked(symbolic || (present30 ? count>1:count>0),"TrueType non simbolico: numero reale di sottotabelle cmap.") }
            if expression.contains("cmap10Present") { return checked(!symbolic || present30 || records.contains{$0.platform == 1 && $0.encoding == 0},"TrueType simbolico: cmap3/0 o1/0.") }
            if expression == "isSymbolic == false || nrCmaps == 1 || cmap30Present == true" { return checked(!symbolic || count == 1 || present30,"TrueType simbolico: cmap unico o3/0.") }
        }
        if rule.objectType == "PDCIDFont",expression.contains("CIDToGIDMap") {
            if subtype != "CIDFontType2" { return checked(true,"Non CIDFontType2.") }
            if let mapping = dictionary["CIDToGIDMap"] {
                if try reader.resolve(mapping)?.name == "Identity" { return checked(true,"CIDToGIDMap Identity.") }
                if let id = mapping.reference,try reader.object(id).stream != nil { return checked(true,"CIDToGIDMap stream.") }
                if case .null? = try reader.resolve(mapping) {} else { return checked(false,"CIDToGIDMap deve essere Identity o stream.") }
            }
            if profile.part == 1 {
                if let parent = font.parent {
                    let relevant = evidence!.fonts.filter { key($0.dictionary) == key(parent) }
                    guard !relevant.isEmpty else { return .unknown("CIDFont referenziato senza glifi: esenzione Tr=3 non dimostrata.") }
                    return checked(relevant.allSatisfy{!$0.visible},"CIDToGIDMap assente: esenzione Tr=3 solo nel profilo1.")
                }
                return .unknown("Uso del discendente CID non risolto.")
            }
            return checked(try !containsFile(dictionary),"CIDToGIDMap obbligatorio quando CIDFontType2 incorporato.")
        }
        if rule.objectType == "PDType0Font" {
            let encoding = try reader.resolve(dictionary["Encoding"])
            if encoding?.name == "Identity-H" || encoding?.name == "Identity-V" { return checked(true,"CMap Identity standard.") }
            guard let map = try encodingMap(dictionary),let child = try reader.resolve(dictionary["DescendantFonts"])?.array?.first else { return .unknown("CMap non Identity/ROS non risolto.") }
            let info = try reader.dictionary(reader.dictionary(child)["CIDSystemInfo"])
            let registry = try reader.resolve(info["Registry"])?.text,ordering = try reader.resolve(info["Ordering"])?.text
            let same = registry == map.registry && ordering == map.ordering && map.registry != nil && map.ordering != nil
            if profile.part == 1 { return checked(same,"Registry/Ordering CMap e CIDFont coincidenti.") }
            guard let supplement = info["Supplement"]?.int,let mapSupplement = map.supplement else { return .unknown("Supplement CMap/CIDSystemInfo non risolto.") }
            return checked(same && supplement<=mapSupplement,"ROS CMap/CIDFont compatibili, Supplement del font non superiore a quello CMap.")
        }
        if rule.objectType == "PDType1Font",expression.contains("CharSet") {
            let name = dictionary["BaseFont"]?.name ?? "",subset = name.range(of:"^[A-Z]{6}\\+",options:.regularExpression) != nil
            if !subset { return checked(true,"Font Type1 non subset.") }
            let descriptor = try self.descriptor(dictionary),characterSet = descriptor["CharSet"]?.text
            if profile.part != 1,(!((try? containsFile(dictionary)) ?? false) || characterSet == nil) { return checked(true,"CharSet opzionale nei casi previsti da PDF/A-2/3/4.") }
            guard let characterSet else { return checked(false,"CharSet obbligatorio nel subset Type1 PDF/A-1.") }
            guard let program = try program(dictionary) else { return .unknown("Programma Type1/CFF non disponibile per verificare CharSet.") }
            let listed = Set(characterSet.split(separator:"/").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter{!$0.isEmpty})
            var actual = Set<String>()
            if profile.part == 1 {
                // Validation TWG clarification, issue983: A1 covers used
                // glyphs; A2/3 covers all program glyphs when CharSet exists.
                try loadGlyphs()
                for glyph in glyphs! where key(glyph.parent) == key(dictionary) {
                    guard let name = glyph.name else { return .unknown("Nome di un glifo usato non risolto per CharSet PDF/A-1.") }
                    if name != ".notdef" { actual.insert(name) }
                }
                guard glyphGaps.isEmpty else { return .unknown("Uso glifi incompleto per CharSet PDF/A-1: " + glyphGaps.joined(separator:"; ")) }
            } else {
                for glyph in 1..<program.glyphCount { guard let name = program.glyphName(glyph) else { return .unknown("Nomi di tutti i glifi del programma non risolti.") };actual.insert(name) }
            }
            return checked(actual.isSubset(of:listed),profile.part == 1 ? "CharSet copre tutti i glifi usati (chiarificazione Validation TWG PDF/A-1).":"CharSet copre tutti i glifi incorporati escluso .notdef.")
        }
        if rule.objectType == "PDCIDFont",expression.contains("CIDSet") { return try cidSetRule(font) }
        return .unknown("Semantica font non risolta per \(rule.objectType): \(expression)")
    }
    private func encodingMap(_ font:[String:PDFSyntaxValue]) throws -> PDFArchiveCMap? {
        if let name = try reader.resolve(font["Encoding"])?.name { if name == "Identity-H" || name == "Identity-V" { return .identity(vertical:name == "Identity-V") };return try PDFArchiveFontReferenceData.shared?.cmap(name) }
        if let id = font["Encoding"]?.reference { return try readMap(id,active:[]) };return nil
    }
    private func readMap(_ id:PDFObjectID,active:Set<PDFObjectID>) throws -> PDFArchiveCMap {
        if let map = cmaps[id] { return map }
        guard active.count<30,!active.contains(id) else { throw PDFStructureError.unsupported("UseCMap ricorsivo") }
        var map = try PDFArchiveCMap(data:reader.decodedStream(id)),dictionary = try reader.dictionary(.reference(id))
        if let parent = dictionary["UseCMap"]?.reference {
            let base = try readMap(parent,active:active.union([id]))
            map = map.inheriting(base);map.baseName = nil
        } else if let name = dictionary["UseCMap"]?.name { map.baseName = name }
        if let name = map.baseName {
            let base:PDFArchiveCMap
            if name == "Identity-H" || name == "Identity-V" { base = .identity(vertical:name == "Identity-V") }
            else { guard let data = PDFArchiveFontReferenceData.shared else { throw PDFStructureError.unsupported("dati Adobe offline non disponibili") };base = try data.cmap(name) }
            map = map.inheriting(base);map.baseName = nil
        }
        cmaps[id] = map;return map
    }
    private func loadGlyphs() throws {
        guard glyphs == nil else { return };glyphs = []
        for use in evidence!.fonts {
            do {
                let parent = use.dictionary,type = parent["Subtype"]?.name ?? "",composite = type == "Type0"
                let descendant = composite ? try reader.resolve(parent["DescendantFonts"])?.array: nil
                if composite,descendant?.count != 1 { throw PDFStructureError.unsupported("Type0 senza unico discendente") }
                let actual = composite ? try PDFArchiveFontEncoding.resolvedFontHeader(reader.dictionary(descendant!.first!),reader:reader):parent
                let program:PDFArchiveFontProgram?
                do { program = try self.program(actual) } catch { program = nil;glyphGaps.append(use.location + ": " + error.localizedDescription) }
                let encoding = composite ? try encodingMap(parent):nil
                if composite,encoding == nil { throw PDFStructureError.unsupported("predefined CMap non Identity richiede dati CID/ROS esterni non incorporati") }
                let codes:[Data]
                do { codes = composite ? try encoding!.codes(in:use.bytes):use.bytes.map{Data([$0])} }
                catch PDFStructureError.malformed(let reason) where reason == "codice fuori codespace CMap" {
                    invalidCodeUses.append(use.location);continue
                }
                let toUnicode = try parent["ToUnicode"]?.reference.map { try readMap($0,active:[]) }
                for code in codes {
                    let cid = composite ? encoding?.cid(code):nil
                    var gid:Int?,name:String?,unicode:String?,determined = false,missingGlyph:Bool?
                    if let text = use.actualText,!text.isEmpty { unicode = text;determined = true }
                    else if let toUnicode {
                        if let bytes = toUnicode.unicode[code] { unicode = PDFArchiveCMap.unicodeString(bytes);determined = true }
                        else if toUnicode.baseName == nil { determined = true }
                    } else if composite,let cid {
                        let info = try reader.dictionary(actual["CIDSystemInfo"])
                        let childRegistry = try reader.resolve(info["Registry"])?.text,childOrdering = try reader.resolve(info["Ordering"])?.text
                        // ISO32000 §9.10.2 takes the second CMap's ROS from
                        // the font Encoding CMap, not from an unrelated guess.
                        let registry = encoding?.registry ?? childRegistry,ordering = encoding?.ordering ?? childOrdering
                        let collections = profile.part == 4 ? ["Japan1","GB1","CNS1","Korea1","KR"]:["Japan1","GB1","CNS1","Korea1"]
                        if childRegistry == "Adobe",collections.contains(childOrdering ?? ""),registry == "Adobe",let ordering,collections.contains(ordering) {
                            guard let data = PDFArchiveFontReferenceData.shared else { throw PDFStructureError.unsupported("dati Unicode Adobe offline non disponibili") }
                            guard let supplement = try encoding?.supplement ?? reader.resolve(info["Supplement"])?.int else { throw PDFStructureError.unsupported("Supplement CID non risolto") }
                            unicode = try data.unicode(cid:cid,registry:"Adobe",ordering:ordering,supplement:supplement);determined = true
                        } else if childRegistry != nil,childOrdering != nil { determined = true }
                    } else if !composite {
                        name = try PDFArchiveFontEncoding.glyphName(code:code[0],font:parent,reader:reader)
                        if name == nil { name = program?.builtInGlyphName(code:code[0]) }
                        let base = try PDFArchiveFontEncoding.baseEncoding(font:parent,reader:reader)
                        if ["WinAnsiEncoding","MacRomanEncoding","MacExpertEncoding"].contains(base ?? "") {
                            unicode = try PDFArchiveFontEncoding.unicode(code:code[0],font:parent,reader:reader)
                            if unicode == nil,let name { unicode = PDFArchiveFontEncoding.unicode(name:name) }
                            determined = base != "MacExpertEncoding" || name != nil
                        } else if let name {
                            let approved = PDFArchiveFontEncoding.latinNames.contains(name) || PDFArchiveFontEncoding.symbolNames.contains(name)
                            unicode = approved ? PDFArchiveFontEncoding.unicode(name:name):nil;determined = true
                        } else if type == "TrueType",base == nil,program != nil { determined = true }
                    }
                    if composite,let cid,let program {
                        if actual["Subtype"]?.name == "CIDFontType0",let cff = program.cff { gid = cff.cidByGlyph.first(where:{$0.value == cid})?.key ?? 0;missingGlyph = gid == 0 }
                        else if let mapID = actual["CIDToGIDMap"]?.reference {
                            let bytes = Array(try reader.decodedStream(mapID));guard bytes.count%2 == 0 else { throw PDFStructureError.malformed("CIDToGIDMap dispari") };if cid<bytes.count/2 { gid = Int(bytes[cid*2])<<8|Int(bytes[cid*2+1]) } else { gid = 0 }
                        } else if actual["CIDToGIDMap"]?.name == "Identity" { gid = cid }
                        if let gid,missingGlyph == nil { missingGlyph = gid == 0 }
                        name = gid.flatMap(program.glyphName)
                    } else if !composite {
                        if name == nil { name = try PDFArchiveFontEncoding.glyphName(code:code[0],font:parent,reader:reader) ?? program?.builtInGlyphName(code:code[0]) }
                        if let program {
                            if actual["Subtype"]?.name == "TrueType" {
                                if try symbolic(actual) == true { gid = try program.symbolicGlyph(code:code[0]) }
                                else if name == ".notdef" { gid = 0 }
                                else if let text = try PDFArchiveFontEncoding.unicode(code:code[0],font:parent,reader:reader),text.unicodeScalars.count == 1 { gid = try program.glyph(unicode:text.unicodeScalars.first!.value) }
                            } else if let name { gid = program.glyph(named:name) ?? 0 }
                            if let gid { missingGlyph = gid == 0;name = program.glyphName(gid) ?? name }
                        }
                    }
                    glyphs!.append(.init(font:actual,parent:parent,code:code,cid:cid,gid:gid,name:name,unicode:unicode,unicodeDetermined:determined,actualTextPresent:use.actualText != nil,missingGlyph:missingGlyph,vertical:encoding?.writingMode == 1,visible:use.visible,location:use.location,program:program))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { glyphGaps.append(use.location + ": " + error.localizedDescription) }
        }
    }
    private func glyphRule(_ rule:PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation {
        try loadGlyphs();let expression = rule.expression
        var results:[PDFArchiveRuleEvaluation] = []
        for glyph in glyphs! {
            func checked(_ success:Bool,_ detail:String)->PDFArchiveRuleEvaluation { .check(success,detail,locations:[glyph.location + " code " + glyph.code.map{String(format:"%02X",$0)}.joined()]) }
            if expression.contains("renderingMode == 3"),!glyph.visible { results.append(checked(true,"Esenzione Tr=3 per presenza/metriche, non per Unicode."));continue }
            if !evidence!.actualTextComplete,!glyph.actualTextPresent,(expression.contains("toUnicode") || expression.contains("unicodePUA")) {
                results.append(.unknown("ActualText strutturale non interamente risolto: nessun errore Unicode viene presunto prima di risolvere la sostituzione."));continue
            }
            if expression == "toUnicode != null" {
                results.append(glyph.unicodeDetermined ? checked(glyph.unicode != nil,"Mapping Unicode effettivo del codice usato."):.unknown("Mapping Unicode non risolto; assenza ToUnicode non viene equiparata automaticamente a violazione."))
            } else if expression.contains("toUnicode.indexOf") {
                if let unicode = glyph.unicode { results.append(checked(!unicode.unicodeScalars.contains{[0,0xFFFE,0xFEFF].contains($0.value)},"Unicode non contiene NUL/FFFE/FEFF.")) }
                else if glyph.unicodeDetermined { results.append(checked(true,"Mapping nullo: condizione del predicato; disponibilità verificata separatamente.")) }
                else { results.append(.unknown("Mapping Unicode non risolto.")) }
            } else if expression == "unicodePUA == false || actualTextPresent == true" {
                if glyph.actualTextPresent { results.append(checked(true,"ActualText presente per il glifo con Unicode Private Use.")) }
                else if let unicode = glyph.unicode {
                    let privateUse = unicode.unicodeScalars.contains{ (0xE000...0xF8FF).contains($0.value) || (0xF0000...0xFFFFD).contains($0.value) || (0x100000...0x10FFFD).contains($0.value) }
                    results.append(checked(!privateUse,"Unicode Private Use richiede ActualText per livello A."))
                } else if glyph.unicodeDetermined { results.append(checked(true,"Unicode assente; disponibilità verificata da regola separata.")) }
                else { results.append(.unknown("Unicode/ActualText non risolti per controllo Private Use.")) }
            } else if expression == "name != \".notdef\"" {
                results.append(glyph.name.map{checked($0 != ".notdef","Il glifo usato non è .notdef.")} ?? .unknown("Nome del glifo non risolto."))
            } else if expression.contains("isGlyphPresent") {
                if glyph.missingGlyph == true { results.append(checked(false,"Codice usato non definito dal programma: risoluzione a .notdef.")) }
                else if let program = glyph.program,let gid = glyph.gid { results.append(checked(try program.glyphDataIsPresent(gid),"GID presente nell’effettivo programma incorporato.")) }
                else if glyph.font["Subtype"]?.name == "Type3",let name = glyph.name { results.append(checked(try reader.dictionary(glyph.font["CharProcs"])[name] != nil,"CharProc del glifo Type3 presente.")) }
                else { results.append(.unknown("Presenza del glifo non risolta senza programma/codice-GID verificabile.")) }
            } else if expression.contains("widthFromFontProgram") {
                let width = try pdfWidth(glyph)
                if glyph.font["Subtype"]?.name == "Type3",let name = glyph.name,let width {
                    let matrix = try reader.resolve(glyph.font["FontMatrix"])?.array?.compactMap(\.real)
                    if let actual = try type3Width(font:glyph.font,name:name),let matrix,matrix.count == 6,matrix[1] == 0,matrix[2] == 0,matrix[0] != 0 {
                        results.append(checked(abs(actual-width)*abs(matrix[0])*1000<=1,"Avanzamento CharProc d0/d1 contro Widths e FontMatrix del Type3, tolleranza1/1000."))
                    } else { results.append(.unknown("Metrica CharProc Type3 d0/d1 o FontMatrix non diagonale non risolta.")) };continue
                }
                if let program = glyph.program,let gid = glyph.gid,let actual = try program.advance(glyph:gid),let width {
                    // ISO32000-1 §9.2.4: glyph width is horizontal displacement.
                    // §9.9 explicitly forbids using vhea/vmtx for PDF placement;
                    // W2/DW2 are authoritative, not a duplicate of font vmtx.
                    results.append(checked(abs(actual-width)<=1,"Larghezza orizzontale programma \(actual) contro W/DW/Widths PDF \(width), tolleranza1/1000; valida anche con WMode1."))
                }
                else { results.append(.unknown("Larghezza programma/dizionario non risolta integralmente.")) }
            } else { results.append(.unknown("Predicato Glyph non implementato: " + expression)) }
        }
        if !invalidCodeUses.isEmpty {
            if expression.contains("isGlyphPresent") || expression == "name != \".notdef\"" { results.append(.check(false,"Codice non appartenente a nessun codespace: risoluzione a .notdef secondo ISO32000 §9.7.6.3.",locations:invalidCodeUses)) }
            else { results.append(.unknown("Codici incompleti/fuori codespace: Unicode e metriche non risolti.")) }
        }
        let complete = evidence!.incompleteContexts.isEmpty && glyphGaps.isEmpty
        if !glyphGaps.isEmpty { results.append(.unknown(glyphGaps.joined(separator:"; "))) }
        return aggregate(results,family:"Glyph",complete:complete)
    }
    private func type3Width(font:[String:PDFSyntaxValue],name:String) throws -> Double? {
        guard let id = try reader.dictionary(font["CharProcs"])[name]?.reference else { return nil }
        var lexer = PDFSyntaxLexer(try reader.decodedStream(id)),operands:[PDFSyntaxValue] = []
        while true {
            lexer.skip();if lexer.offset == lexer.bytes.count { return nil };let token = try lexer.value()
            if case .keyword(let op) = token {
                guard ["d0","d1"].contains(op),operands.count == (op == "d0" ? 2:6),let width = operands[0].real,operands[1].real == 0 else { return nil };return width
            };operands.append(token);guard operands.count<=6 else { return nil }
        }
    }
    private func pdfWidth(_ glyph:Glyph) throws -> Double? {
        if let cid = glyph.cid {
            let widths = try reader.resolve(glyph.font["W"])?.array ?? [];var cursor = 0
            while cursor<widths.count {
                guard let first = widths[cursor].int,first>=0,cursor+1<widths.count else { throw PDFStructureError.malformed("W CID") };cursor += 1
                if let list = widths[cursor].array { if cid>=first,cid-first<list.count { return list[cid-first].real };cursor += 1 }
                else { guard let last = widths[cursor].int,cursor+1<widths.count,let width = widths[cursor+1].real else { throw PDFStructureError.malformed("range W CID") };if cid>=first,cid<=last { return width };cursor += 2 }
            }
            return try reader.resolve(glyph.font["DW"])?.real ?? 1000
        }
        guard let first = try reader.resolve(glyph.font["FirstChar"])?.int,let widths = try reader.resolve(glyph.font["Widths"])?.array else { return nil }
        let index = Int(glyph.code[0])-first
        if index>=0,index<widths.count { return widths[index].real }
        return try descriptor(glyph.font)["MissingWidth"]?.real
    }
    private func validateCIDVerticalMetrics(_ font:[String:PDFSyntaxValue]) throws {
        if let value = try reader.resolve(font["DW2"]),case .null = value {} else if let value = try reader.resolve(font["DW2"]) {
            guard let array = value.array,array.count == 2,array.allSatisfy({$0.real?.isFinite == true}) else { throw PDFStructureError.malformed("DW2 deve contenere due numeri finiti") }
        }
        guard let value = try reader.resolve(font["W2"]) else { return };if case .null = value { return }
        guard let array = value.array else { throw PDFStructureError.malformed("W2 deve essere array") }
        guard array.count<=100_000 else { throw PDFStructureError.limit }
        var cursor = 0
        while cursor<array.count {
            guard let first = array[cursor].int,(0...65535).contains(first),cursor+1<array.count else { throw PDFStructureError.malformed("W2: CID iniziale non valido") };cursor += 1
            if let values = array[cursor].array {
                guard values.count%3 == 0,values.count/3<=65536-first,values.allSatisfy({$0.real?.isFinite == true}) else { throw PDFStructureError.malformed("W2: triplette/valori/range CID non validi") };cursor += 1
            } else {
                guard let last = array[cursor].int,last>=first,last<=65535,cursor+3<array.count,array[(cursor+1)...(cursor+3)].allSatisfy({$0.real?.isFinite == true}) else { throw PDFStructureError.malformed("W2: range o metrica non validi") };cursor += 4
            }
        }
    }
    private func cmapRule(_ rule:PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation {
        var results:[PDFArchiveRuleEvaluation] = [],ids = Set<PDFObjectID>()
        for font in fonts {
            if let id = font.dictionary["ToUnicode"]?.reference { ids.insert(id) }
            if font.dictionary["Subtype"]?.name == "Type0",let id = font.dictionary["Encoding"]?.reference { ids.insert(id) }
            if rule.objectType == "PDCMap",font.dictionary["Subtype"]?.name == "Type0" {
                let encoding = try reader.resolve(font.dictionary["Encoding"])
                if let name = encoding?.name {
                    let names = rule.expression.components(separatedBy:"\"").enumerated().filter{$0.offset%2 == 1}.map(\.element)
                    results.append(.check(names.contains(name),"Nome CMap predefinito ammesso dal profilo: " + name,locations:[font.location]))
                } else if font.dictionary["Encoding"]?.reference != nil { results.append(.check(true,"CMap incorporato in stream.",locations:[font.location])) }
                else { results.append(.unknown("Encoding CMap non risolto.")) }
            }
        }
        if rule.objectType == "PDCMap" { return aggregate(results,family:rule.objectType,complete:evidence!.incompleteContexts.isEmpty) }
        var inspected = Set<PDFObjectID>(),queue = Array(ids)
        while let id = queue.popLast() {
            guard inspected.insert(id).inserted else { continue };guard inspected.count<=10_000 else { throw PDFStructureError.limit }
            do {
                let raw = try PDFArchiveCMap(data:reader.decodedStream(id)),stream = try reader.dictionary(.reference(id))
                if let parent = stream["UseCMap"]?.reference { queue.append(parent) }
                if rule.objectType == "PDReferencedCMap" {
                    var names = raw.referencedNames;if let name = stream["UseCMap"]?.name { names.append(name) }
                    let allowed = rule.expression.components(separatedBy:"\"").enumerated().filter{$0.offset%2 == 1}.map(\.element)
                    results += names.map { .check(allowed.contains($0),"UseCMap predefinita ammessa: " + $0,locations:["CMap " + id.syntax]) }
                } else {
                    let map = try readMap(id,active:[])
                    if rule.expression == "maximalCID <= 65535" { results.append(.check(map.maximalCID<=65535,"CID massimo delle mappe ereditate: \(map.maximalCID).",locations:["CMap " + id.syntax])) }
                    else if rule.expression == "WMode == dictWMode" { results.append(.check(map.writingMode == (try reader.resolve(stream["WMode"])?.int ?? 0),"WMode del programma/UseCMap contro dizionario.",locations:["CMap " + id.syntax])) }
                    else { results.append(.unknown("Predicato CMapFile non implementato.")) }
                }
            } catch { results.append(.unknown(error.localizedDescription)) }
        }
        return aggregate(results,family:rule.objectType,complete:evidence!.incompleteContexts.isEmpty)
    }
    private func cidSetRule(_ font:Font) throws -> PDFArchiveRuleEvaluation {
        let dictionary = font.dictionary,name = dictionary["BaseFont"]?.name ?? "",subset = name.range(of:"^[A-Z]{6}\\+",options:.regularExpression) != nil
        if !subset { return .check(true,"Font CID non subset.") }
        let descriptor = try self.descriptor(dictionary)
        guard let id = descriptor["CIDSet"]?.reference else { return profile.part == 1 ? .check(false,"CIDSet obbligatorio nel subset CID PDF/A-1.",locations:[font.location]):.check(true,"CIDSet opzionale nei profili2/3/4.") }
        guard let program = try program(dictionary) else { return .unknown("Programma CID non disponibile per confrontare CIDSet.") }
        var cids:Set<Int>
        if profile.part == 1 {
            try loadGlyphs();cids = []
            for glyph in glyphs! where key(glyph.font) == key(dictionary) { guard let cid = glyph.cid else { return .unknown("CID usato non risolto per CIDSet PDF/A-1.") };cids.insert(cid) }
            guard glyphGaps.isEmpty else { return .unknown("Uso CID incompleto per CIDSet PDF/A-1.") }
        } else if let cff = program.cff,!cff.cidByGlyph.isEmpty { cids = Set(cff.cidByGlyph.values) }
        else if dictionary["CIDToGIDMap"]?.name == "Identity" { cids = Set(0..<program.glyphCount) }
        else if let map = dictionary["CIDToGIDMap"]?.reference {
            let data = Array(try reader.decodedStream(map));guard data.count%2 == 0 else { throw PDFStructureError.malformed("CIDToGIDMap dispari") };cids = Set(stride(from:0,to:data.count-1,by:2).compactMap { p in (Int(data[p])<<8|Int(data[p+1])) == 0 ? nil:p/2 })
        } else { return .unknown("Tutti i CID incorporati non enumerabili dal programma/mappa.") }
        cids.remove(0);let bits = Array(try reader.decodedStream(id))
        let missing = cids.filter { cid in cid/8>=bits.count || bits[cid/8]&(0x80>>UInt8(cid%8)) == 0 }
        return .check(missing.isEmpty,"CIDSet copre i CID del programma/mappa verificati.",locations:[font.location])
    }
}
