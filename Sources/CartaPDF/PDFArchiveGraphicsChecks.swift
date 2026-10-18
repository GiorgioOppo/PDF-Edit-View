import Foundation
import CryptoKit

/// Tracks paint operations and resource scopes rather than inferring device
/// colour use from resources which might never be painted.
final class PDFArchiveGraphicsChecks {
    private struct Space { let kind: String; var id: PDFObjectID?; var pattern: PDFSyntaxValue?; var base: PDFSyntaxValue? }
    private struct State {
        var fill = Space(kind:"DeviceGray"), stroke = Space(kind:"DeviceGray")
        var fillOP = false, strokeOP = false, opm = 0, textMode = 0
        var blending: Space?
        var mask: PDFObjectID?
        var font: [String:PDFSyntaxValue]?
    }
    private struct Use { let space: Space, output: Space?, blending: Space?, overprint: Bool, opm: Int, location: String }
    private struct ICC { let id: PDFObjectID, data: PDFArchiveICCProfile, n: Int?, output: Bool, location: String }
    private struct Image { let dictionary: [String:PDFSyntaxValue], data: Data, location: String, inline: Bool, reliable: Bool }
    private let reader: PDFStructureDocument
    private let profile: PDFArchiveProfile
    private var uses: [Use] = [], iccs: [ICC] = [], images: [Image] = []
    private var deviceNs: [(names:[String],missing:[String],location:String)] = []
    private var separations: [String:[Data]] = [:]
    private var missing: [String] = [], inherited: [String] = [], unknown: [String] = [], undefined: [String] = []
    private var transparent = Set<Int>(), pageRequirements: [(index:Int,hasOutput:Bool,hasGroup:Bool)] = []
    private var groups: [(kind:String,location:String)] = []
    private var visitedMasks = Set<String>()
    private var maxQ = 0, operations = 0
    private var scanned: Result<Void,Error>?
    private var lexicalEvidence: PDFArchiveContentEvidence?
    private var iccReadIssues:[(status:PDFArchiveRuleStatus,detail:String,location:String)] = []
    private static let operators = Set("b B b* B* BDC BI BMC BT BX c cm CS cs d d0 d1 Do DP EI EMC ET EX f F f* G g gs h i ID j J K k l m M MP n q Q re RG rg ri s S SC sc SCN scn sh T* Tc Td TD Tf Tj TJ TL Tm Tr Ts Tw Tz v w W W* y ' \"".split(separator:" ").map(String.init))
    init(reader: PDFStructureDocument, profile: PDFArchiveProfile) { self.reader = reader; self.profile = profile }
    var modelChecks:[PDFArchiveRuleResult] {
        if scanned == nil { scanned = Result { try scan() } }
        var rows:[PDFArchiveRuleResult] = []
        func row(_ id:String,_ status:PDFArchiveRuleStatus,_ detail:String,_ location:String)->PDFArchiveRuleResult {
            .init(id:"CartaPDF:ICC:"+id,specification:"ICC.1:2001-04 / ICC.1:2010 / ICC.1:2022",clause:"header; tag table; encoded tag structures",testNumber:id,objectType:"ICCStructuralModel",requirement:L10n.tr("Header, tag richiesti nei modelli v4 supportati, strutture binarie e dimensioni dei tipi ICC implementati devono essere coerenti. Il controllo non attesta la colorimetria completa."),status:status,detail:detail,locations:location.isEmpty ? []:[location])
        }
        let active = Set(uses.flatMap{[$0.space.id,$0.output?.id,$0.blending?.id].compactMap{$0}})
        var seen = Set<PDFObjectID>()
        for icc in iccs where (icc.output || profile.part <= 3 || active.contains(icc.id)) && seen.insert(icc.id).inserted {
            let audit = PDFArchiveICCAudit(profile:icc.data)
            let status:PDFArchiveRuleStatus = !audit.issues.isEmpty ? .failed:audit.gaps.isEmpty ? .passed:.notVerified
            rows.append(row(icc.id.syntax,status,"Tipi letti: "+audit.checkedTypes.sorted().joined(separator:", ")+". "+(audit.issues+audit.gaps).joined(separator:"; "),icc.location))
        }
        for (index,item) in iccReadIssues.enumerated() { rows.append(row("read-\(index)",item.status,item.detail,item.location)) }
        if case .failure(let error)? = scanned { rows.append(row("inventory",.notVerified,L10n.tr("Inventario ICC interrotto: ")+error.localizedDescription,"")) }
        return rows
    }
    private func iccReadError(_ error:Error,location:String) {
        let status:PDFArchiveRuleStatus
        if let error = error as? PDFStructureError,case .malformed = error { status = .failed } else { status = .notVerified }
        iccReadIssues.append((status,error.localizedDescription,location))
    }
    func evaluate(_ rule: PDFArchiveCatalogueRule) throws -> PDFArchiveRuleEvaluation? {
        let families: Set<String> = ["PDDeviceRGB","PDDeviceCMYK","PDDeviceGray","PDDeviceN","PDSeparation","PDICCBasedCMYK","ICCInputProfile","ICCOutputProfile","ICCProfile","JPEG2000","PDInlineImage","Op_q_gsave","PDContentStream","Op_Undefined"]
        let pageRule = rule.objectType == "PDPage" && rule.expression.contains("containsTransparency")
        let groupRule = rule.objectType == "PDGroup" && rule.expression == #"S != "Transparency""#
        guard families.contains(rule.objectType) || pageRule || groupRule else { return nil }
        // TechNote0010 A010: unused named resources are exempt from A1
        // §6.1.12, while A2/3 keep §6.1.13 applicable to those resources.
        if (rule.objectType == "Op_q_gsave" && profile.part != 1) || rule.objectType == "PDContentStream" {
            if lexicalEvidence == nil { lexicalEvidence = try PDFArchiveContentScanner(reader:reader).scan(allowPartial:true) }
            let facts = lexicalEvidence!
            let failures = rule.objectType == "Op_q_gsave" ? (facts.maxQDepth > 28 ? [L10n.tr("profondità \(facts.maxQDepth)")] : []) :
                (rule.expression.contains("inheritedResourceNames") ? facts.inheritedResourceNames : facts.undefinedResourceNames)
            if !failures.isEmpty { return .check(false,L10n.tr("Inventario di tutti i contenitori di contenuto, inclusi quelli non dipinti."),locations:Array(failures.prefix(64))) }
            if !(rule.objectType == "Op_q_gsave" ? facts.lexicalComplete : facts.resourceScanComplete) { return .unknown(L10n.tr("Inventario dei contenuti incompleto.")) }
            return .check(true,rule.objectType == "Op_q_gsave" ? L10n.tr("Profondità massima q/Q: \(facts.maxQDepth).") : L10n.tr("Risorse nominate risolte nei relativi contenitori."))
        }
        if scanned == nil { scanned = Result { try scan() } }
        do { try scanned!.get() } catch is CancellationError { throw CancellationError() }
        catch { let detail = "Interpretazione grafica interrotta: " + error.localizedDescription;if !unknown.contains(detail) { unknown.append(detail) } }
        func result(_ failures:[String], _ count:Int, _ detail:String) -> PDFArchiveRuleEvaluation {
            if !failures.isEmpty { return .check(false,detail,locations:Array(failures.prefix(64))) }
            if !unknown.isEmpty { return .unknown(detail + L10n.tr(" Contesti irrisolti: ") + unknown.prefix(8).joined(separator:"; ")) }
            return count == 0 ? .absent(detail + L10n.tr(" Nessun uso applicabile.")) : .check(true,detail)
        }
        let object = rule.objectType, expression = rule.expression
        if groupRule { return result(groups.filter { $0.kind == "Transparency" }.map(\.location),groups.count,L10n.tr("Gruppi di trasparenza, anche senza Type opzionale.")) }
        if object == "Op_Undefined" { return result(undefined,operations,"Operatori PDF definiti, anche dentro BX/EX.") }
        if object == "Op_q_gsave" { return result(maxQ > 28 ? [L10n.tr("profondità \(maxQ)")] : [],operations,L10n.tr("Massima profondità q/Q: \(maxQ).")) }
        if object == "PDContentStream" { return result(expression.contains("inheritedResourceNames") ? inherited : missing,operations,L10n.tr("Risoluzione contestuale delle risorse nominate.")) }
        if ["PDDeviceRGB","PDDeviceCMYK","PDDeviceGray"].contains(object) {
            let kind = String(object.dropFirst(2)), wanted = kind == "DeviceRGB" ? "RGB " : "CMYK"
            let selected = uses.filter { $0.space.kind == kind }
            let failures = selected.filter {
                if $0.output?.kind == "Unknown" { return false }
                if kind == "DeviceGray" { return $0.output == nil }
                if $0.output?.kind == wanted { return false }
                if profile.part == 4, effectiveColor($0.blending) == wanted || (wanted == "RGB " && $0.blending?.kind == "CalRGB") { return false }
                return true
            }.map(\.location)
            return result(failures,selected.count,L10n.tr("\(kind): Default, output e blending nel contesto del colore effettivamente dipinto."))
        }
        if object == "PDICCBasedCMYK" {
            let selected = uses.filter { $0.space.kind == "ICCBasedCMYK" }
            var failures:[String] = []
            for item in selected {
                if expression.contains("overprintFlag") {
                    if item.overprint && item.opm != 0 { failures.append(item.location) }
                } else if let id = item.space.id {
                    for other in [item.output?.id,item.blending?.id].compactMap({ $0 }) {
                        let same:Bool
                        if id == other { same = true }
                        else {
                            let one = try PDFArchiveICCProfile(data:reader.decodedStream(id)),two = try PDFArchiveICCProfile(data:reader.decodedStream(other))
                            guard let first = one.verifiedFingerprint,let second = two.verifiedFingerprint else { unknown.append(item.location + L10n.tr(": Profile ID ICC incoerente con l’impronta ricalcolata"));continue }
                            same = first == second
                        }
                        if same { failures.append(item.location) }
                    }
                }
            }
            return result(failures,selected.count,L10n.tr("CMYK ICCBased: overprint OPM e identità dei profili applicabili."))
        }
        if object == "PDDeviceN" {
            let limit = expression.contains("<= 8") ? 8 : 32
            let failures = deviceNs.filter { expression.contains("nrComponents") ? $0.names.count > limit : !$0.missing.isEmpty }.map(\.location)
            return result(failures,deviceNs.count,L10n.tr("DeviceN: conteggio componenti e Colorants per le tinte spot."))
        }
        if object == "PDSeparation" { return result(separations.filter { Set($0.value).count > 1 }.keys.sorted(),separations.count,L10n.tr("AlternateSpace e tintTransform delle Separation omonime confrontati come oggetti decodificati.")) }
        if ["ICCInputProfile","ICCOutputProfile","ICCProfile"].contains(object) {
            let selected = object == "ICCProfile" ? iccs.filter { !$0.output } : iccs.filter { $0.output == (object == "ICCOutputProfile") }
            var failures:[String] = []
            for item in selected {
                if !item.data.structuralIssues.isEmpty { failures.append(item.location + ": " + item.data.structuralIssues.joined(separator:", ")); continue }
                if object == "ICCProfile" { if item.n == nil || item.n != item.data.components { failures.append(item.location + L10n.tr(": N incompatibile")) } }
                else {
                    let classes = item.output ? ["prtr","mntr"] : ["prtr","mntr","scnr","spac"]
                    let spaces = item.output ? ["RGB ","CMYK","GRAY"] : ["RGB ","CMYK","GRAY","Lab "]
                    if !classes.contains(item.data.deviceClass) || !spaces.contains(item.data.colorSpace) || item.data.majorVersion >= (profile.part == 1 ? 3 : 5) { failures.append(item.location) }
                }
            }
            return result(failures,selected.count,L10n.tr("Header ICC, tabella tag, classe, spazio, versione e N reali."))
        }
        if object == "PDInlineImage" {
            if lexicalEvidence == nil { lexicalEvidence = try PDFArchiveContentScanner(reader:reader).scan(allowPartial:true) }
            let facts = lexicalEvidence!, selected = facts.inlineImages
            let missingL = selected.filter { $0.dictionary["L"]?.int == nil || ($0.dictionary["L"]?.int ?? -1) < 0 }.map(\.location)
            if !missingL.isEmpty { return .check(false,L10n.tr("L obbligatoria in tutte le immagini inline, incluse quelle in contenitori non dipinti."),locations:missingL) }
            let wrong = selected.filter { $0.reliable && $0.dictionary["L"]?.int != $0.length }.map(\.location)
            if !wrong.isEmpty { return .check(false,L10n.tr("L diversa dal numero di byte inline."),locations:wrong) }
            if !facts.lexicalComplete || selected.contains(where:{ !$0.reliable }) { return .unknown(L10n.tr("Inventario o confine inline filtrato non provato.")) }
            return selected.isEmpty ? .absent(L10n.tr("Nessuna immagine inline nell’inventario completo.")) : .check(true,L10n.tr("L confrontata con i byte effettivi di tutte le immagini inline."))
        }
        if object == "JPEG2000" {
            let selected = images.filter { filters($0.dictionary).contains("JPXDecode") }
            var failures:[String] = []
            for image in selected {
                do {
                    let facts = try PDFArchiveJPEG2000(data:image.data), hasCS = image.dictionary["ColorSpace"] != nil
                    let chosen = facts.colorSpecs.sorted { $0.precedence < $1.precedence }.first
                    let valid:Bool
                    if expression.hasPrefix("nrColorChannels") {
                        if !facts.channelCountKnown { unknown.append(image.location + L10n.tr(": canali JP2 non risolti")); continue }
                        valid = [1,3,4].contains(facts.components)
                    } else if expression.hasPrefix("bpccBoxPresent") { valid = !facts.bpccPresent && (1...38).contains(facts.bitDepth) }
                    else if hasCS { valid = true }
                    else if expression.contains("nrColorSpaceSpecs") { valid = facts.colorSpecs.count == 1 || facts.colorSpecs.filter { $0.approximation == 1 }.count == 1 }
                    else if expression.contains("colrEnumCS") { valid = chosen?.enumerated != 19 }
                    else { valid = chosen.map { [1,2,3].contains($0.method) } ?? false }
                    if !valid { failures.append(image.location) }
                } catch { unknown.append(image.location + L10n.tr(": JP2 non analizzabile: ") + error.localizedDescription) }
            }
            return result(failures,selected.count,L10n.tr("JP2/SIZ: canali, colr, APPROX, metodo e profondità."))
        }
        if pageRule { return result(pageRequirements.filter { transparent.contains($0.index) && !$0.hasOutput && !$0.hasGroup }.map { "pagina \($0.index + 1)" },pageRequirements.count,L10n.tr("Pagine trasparenti: output intent applicabile oppure Group/CS.")) }
        return nil
    }
    private func filters(_ dictionary:[String:PDFSyntaxValue]) -> [String] { dictionary["Filter"]?.name.map { [$0] } ?? dictionary["Filter"]?.array?.compactMap(\.name) ?? [] }
    private func effectiveColor(_ space:Space?) -> String? {
        guard let space else { return nil }
        if let id = space.id, let entry = iccs.first(where:{ $0.id == id }) { return entry.data.colorSpace }
        return space.kind
    }
    private func output(_ dictionary:[String:PDFSyntaxValue], location:String) throws -> Space? {
        let intents = try reader.resolve(dictionary["OutputIntents"])?.array ?? []
        var selected:[Space] = [],unresolved = false
        for item in intents {
            let d = try reader.dictionary(item)
            guard d["S"]?.name == "GTS_PDFA1" else { continue }
            guard let id = try reader.resolvedObjectID(d["DestOutputProfile"]) else { unknown.append(location + L10n.tr(": output ICC non incorporato"));unresolved = true;continue }
            do {
                let p = try PDFArchiveICCProfile(data:reader.decodedStream(id))
                iccs.append(.init(id:id,data:p,n:nil,output:true,location:location + "/OutputIntent"))
                selected.append(.init(kind:p.colorSpace,id:id))
            } catch { iccReadError(error,location:location);unknown.append(location + L10n.tr(": ICC non analizzabile: ") + error.localizedDescription);unresolved = true }
        }
        if Set(selected.compactMap(\.id)).count > 1 { unknown.append(location + L10n.tr(": più profili output distinti"));unresolved = true }
        if unresolved { return .init(kind:"Unknown") }
        return selected.first
    }
    private func color(_ value:PDFSyntaxValue?, resources:[String:PDFSyntaxValue], location:String, depth:Int = 0, allowDefault:Bool = true) throws -> Space {
        guard depth < 32 else { throw PDFStructureError.limit }
        let resolved = try reader.resolve(value)
        if let original = resolved?.name {
            let name = ["G":"DeviceGray","RGB":"DeviceRGB","CMYK":"DeviceCMYK"][original] ?? original
            if ["DeviceGray","DeviceRGB","DeviceCMYK"].contains(name) {
                let dictionary = try reader.dictionary(resources["ColorSpace"])
                let key = "Default" + name.dropFirst(6)
                if allowDefault, let replacement = dictionary[String(key)] {
                    let alternative = try color(replacement,resources:resources,location:location + "/" + key,depth:depth + 1,allowDefault:false)
                    if alternative.kind.hasPrefix("Device") { unknown.append(location + L10n.tr(": Default dipendente dal dispositivo")) }
                    return alternative
                }
                return .init(kind:name)
            }
            if name == "Pattern" { return .init(kind:"Pattern") }
            let dictionary = try reader.dictionary(resources["ColorSpace"])
            guard let target = dictionary[name] else { missing.append(location + "/ColorSpace/" + name); return .init(kind:"Unknown") }
            return try color(target,resources:resources,location:location + "/" + name,depth:depth + 1)
        }
        guard let a = resolved?.array, let family = a.first?.name else { unknown.append(location + L10n.tr(": spazio colore non risolto")); return .init(kind:"Unknown") }
        if ["CalGray","CalRGB","Lab"].contains(family) { return .init(kind:family) }
        if family == "Pattern" { return .init(kind:"Pattern",base:a.count > 1 ? a[1] : nil) }
        if family == "ICCBased", a.count == 2, let id = try reader.resolvedObjectID(a[1]) {
            let d = try reader.dictionary(a[1])
            do {
                let p = try PDFArchiveICCProfile(data:reader.decodedStream(id)), n = try reader.resolve(d["N"])?.int
                iccs.append(.init(id:id,data:p,n:n,output:false,location:location))
                return .init(kind:p.colorSpace == "CMYK" ? "ICCBasedCMYK" : "ICCBased",id:id)
            } catch { iccReadError(error,location:location);unknown.append(location + L10n.tr(": ICCBased non analizzabile")); return .init(kind:"Unknown") }
        }
        if ["Indexed","I"].contains(family), a.count == 4 { return try color(a[1],resources:resources,location:location + "/Indexed",depth:depth + 1) }
        if family == "Separation", a.count == 4, let name = a[1].name {
            separations[name,default:[]].append(try canonical(a[2],active:[]) + Data([0]) + canonical(a[3],active:[]))
            return try color(a[2],resources:resources,location:location + "/Separation",depth:depth + 1)
        }
        if family == "DeviceN", a.count >= 4, let names = a[1].array?.compactMap(\.name), names.count == a[1].array?.count {
            let attributes = a.count > 4 ? try reader.dictionary(a[4]) : [:]
            let colorants = try reader.dictionary(attributes["Colorants"]), process = try reader.dictionary(attributes["Process"])
            let processNames = try reader.resolve(process["Components"])?.array?.compactMap(\.name) ?? []
            deviceNs.append((names,names.filter { !["All","None","Cyan","Magenta","Yellow","Black"].contains($0) && !processNames.contains($0) && colorants[$0] == nil },location))
            for (_,space) in colorants { _ = try color(space,resources:resources,location:location + "/Colorants",depth:depth + 1) }
            return try color(a[2],resources:resources,location:location + "/DeviceN",depth:depth + 1)
        }
        unknown.append(location + L10n.tr(": spazio ") + family + L10n.tr(" non risolto"))
        return .init(kind:"Unknown")
    }
    private func canonical(_ value:PDFSyntaxValue, active:Set<PDFObjectID>, depth:Int = 0) throws -> Data {
        guard depth < 64 else { throw PDFStructureError.limit }
        if let id = value.reference {
            guard !active.contains(id) else { throw PDFStructureError.malformed("oggetto colore circolare") }
            let object = try reader.object(id)
            if object.stream != nil, var dictionary = object.value.dictionary {
                dictionary.removeValue(forKey:"Length"); dictionary.removeValue(forKey:"Filter"); dictionary.removeValue(forKey:"DecodeParms")
                return try canonical(.dictionary(dictionary),active:active.union([id]),depth:depth + 1) + Data([0]) + reader.decodedStream(id)
            }
            return try canonical(object.value,active:active.union([id]),depth:depth + 1)
        }
        if let a = value.array {
            var data = Data([91]); for item in a { data += try canonical(item,active:active,depth:depth + 1) + Data([0]) }; return data + Data([93])
        }
        if let d = value.dictionary {
            var data = Data([60,60]); for key in d.keys.sorted() { data += PDFSyntaxValue.name(key).encoded + Data([0]) + (try canonical(d[key]!,active:active,depth:depth + 1)) + Data([0]) }; return data + Data([62,62])
        }
        if let number = value.real { return Data(String(format:"%.17g",number).utf8) }
        return value.encoded
    }
    private func scan() throws {
        let root = try reader.dictionary(.reference(reader.rootID)), global = try output(root,location:"Catalog")
        for (index,id) in try reader.pageIDs().enumerated() {
            let d = try reader.dictionary(.reference(id)), resources = try reader.dictionary(reader.inherited("Resources",pageID:id))
            let local = profile.part == 4 ? try output(d,location:"pagina \(index + 1)") : nil
            let group = try reader.dictionary(d["Group"]), blend = group["S"]?.name != "Transparency" || group["CS"] == nil ? nil : try color(group["CS"],resources:resources,location:"Group/CS")
            var state = State(); state.blending = blend
            state.fill = try color(.name("DeviceGray"),resources:resources,location:"colore iniziale")
            state.stroke = state.fill
            if !group.isEmpty { groups.append((group["S"]?.name ?? "","pagina \(index + 1)/Group")) }
            if !group.isEmpty && group["S"]?.name != "Transparency" { unknown.append("pagina \(index + 1): Group/S non supportato") }
            if group["S"]?.name == "Transparency" { transparent.insert(index) }
            try streams(reader.contentStreamIDs(on:id),resources:resources,initial:state,output:local ?? global,page:index,active:[],inherited:false)
            for annotation in try reader.resolve(d["Annots"])?.array ?? [] {
                let annotation = try reader.dictionary(annotation), ap = try reader.dictionary(annotation["AP"])
                for (_,value) in ap {
                    if let id = value.reference, try reader.object(id).stream != nil { try form(id,resources:resources,state:state,output:local ?? global,page:index,active:[]) }
                    else { for (_,entry) in try reader.dictionary(value) { if let id = entry.reference { try form(id,resources:resources,state:state,output:local ?? global,page:index,active:[]) } } }
                }
            }
            pageRequirements.append((index,local != nil || global != nil,blend != nil))
        }
    }
    private func form(_ id:PDFObjectID, resources:[String:PDFSyntaxValue], state:State, output:Space?, page:Int, active:Set<PDFObjectID>) throws {
        guard active.count < 50, !active.contains(id) else { throw PDFStructureError.unsupported(L10n.tr("Form/appearance circolare")) }
        let d = try reader.dictionary(.reference(id)), own = d["Resources"] != nil
        let nested = own ? try reader.dictionary(d["Resources"]) : resources, group = try reader.dictionary(d["Group"])
        var state = state
        if !group.isEmpty { groups.append((group["S"]?.name ?? "","Form \(id.syntax)/Group")) }
        if !group.isEmpty && group["S"]?.name != "Transparency" { unknown.append(L10n.tr("Form \(id.syntax): Group/S non supportato")) }
        if group["S"]?.name == "Transparency" {
            transparent.insert(page)
            // ISO 32000-1 §11.7.2: non-isolated groups inherit their parent's
            // blending colour space; only isolated groups may specify one.
            if try reader.resolve(group["I"])?.bool == true,let cs = group["CS"] {
                let current = try color(cs,resources:nested,location:"Form/Group/CS")
                state.blending = current
            }
        }
        try streams([id],resources:nested,initial:state,output:output,page:page,active:active.union([id]),inherited:!own)
    }
    private func streams(_ ids:[PDFObjectID], resources:[String:PDFSyntaxValue], initial:State, output:Space?, page:Int, active:Set<PDFObjectID>, inherited isInherited:Bool) throws {
        var state = initial, stack:[State] = [], operands:[PDFSyntaxValue] = []
        let location = "pagina \(page + 1)"
        func resource(_ category:String, _ name:String) throws -> PDFSyntaxValue? {
            let d = try reader.dictionary(resources[category])
            if isInherited { inherited.append(location + "/" + category + "/" + name) }
            if d[name] == nil { missing.append(location + "/" + category + "/" + name) }
            return d[name]
        }
        func apply(_ d:[String:PDFSyntaxValue],to state:inout State) throws {
            if let op = try reader.resolve(d["OP"])?.bool { state.strokeOP = op;if d["op"] == nil { state.fillOP = op } }
            if let op = try reader.resolve(d["op"])?.bool { state.fillOP = op }
            if let n = try reader.resolve(d["OPM"])?.int { state.opm = n }
            let ca = try reader.resolve(d["ca"])?.real ?? 1,CA = try reader.resolve(d["CA"])?.real ?? 1
            if ca < 1 || CA < 1 || (d["BM"] != nil && d["BM"]?.name != "Normal" && d["BM"]?.name != "Compatible") { transparent.insert(page) }
            if d["SMask"] != nil && d["SMask"]?.name != "None" {
                transparent.insert(page);state.mask = try reader.dictionary(d["SMask"])["G"]?.reference
                if state.mask == nil { unknown.append(location + L10n.tr(": G della soft mask non risolta")) }
            } else if d["SMask"]?.name == "None" { state.mask = nil }
            if let font = try reader.resolve(d["Font"])?.array,font.count == 2 { state.font = try reader.dictionary(font[0]) }
        }
        func paint(_ space:Space, _ overprint:Bool) throws {
            if let mask = state.mask {
                let key = "\(page):\(mask.syntax):\(output?.id?.syntax ?? ""):\(state.blending?.id?.syntax ?? state.blending?.kind ?? "")"
                if visitedMasks.insert(key).inserted {
                    var inside = state; inside.mask = nil
                    inside.fill = .init(kind:"DeviceGray"); inside.stroke = .init(kind:"DeviceGray")
                    try form(mask,resources:resources,state:inside,output:output,page:page,active:active)
                }
            }
            if space.kind == "Pattern" {
                guard let selected = space.pattern else { unknown.append(location + L10n.tr(": pattern non selezionato")); return }
                let dictionary = try reader.dictionary(selected)
                if dictionary["PatternType"]?.int == 1, let id = selected.reference {
                    var inside = state
                    inside.fill = .init(kind:"DeviceGray"); inside.stroke = .init(kind:"DeviceGray")
                    if dictionary["PaintType"]?.int == 2 {
                        guard let base = space.base else { unknown.append(location + L10n.tr(": base pattern non colorato assente")); return }
                        let baseSpace = try color(base,resources:resources,location:location + "/PatternBase")
                        uses.append(.init(space:baseSpace,output:output,blending:state.blending,overprint:overprint,opm:state.opm,location:location + "/PatternBase"))
                        inside.fill = baseSpace; inside.stroke = baseSpace
                    }
                    try form(id,resources:resources,state:inside,output:output,page:page,active:active)
                } else if dictionary["PatternType"]?.int == 2 {
                    let shading = try reader.dictionary(dictionary["Shading"])
                    // Table 77: unspecified parameters come from the beginning
                    // of the stream defining the resource, not the paint-time
                    // gs state. Missing Form Resources leaves that origin open.
                    if isInherited { unknown.append(location + L10n.tr(": stato iniziale del pattern ereditato non provato")) }
                    let saved = state;state = initial;defer { state = saved }
                    try apply(reader.dictionary(dictionary["ExtGState"]),to:&state)
                    try paint(color(shading["ColorSpace"],resources:resources,location:location + "/PatternShading"),state.fillOP)
                } else { unknown.append(location + L10n.tr(": programma Pattern non risolto")) }
                return
            }
            let effective = space.kind == "DeviceGray" ? try color(.name("DeviceGray"),resources:resources,location:location + "/DefaultGray") : space
            uses.append(.init(space:effective,output:output,blending:state.blending,overprint:overprint,opm:state.opm,location:location))
        }
        for id in ids {
            var lexer = PDFSyntaxLexer(try reader.decodedStream(id))
            lexer.strict = true;lexer.allowContentOperators = true
            contentLoop: while true {
                try Task.checkCancellation(); lexer.skip(); if lexer.offset >= lexer.bytes.count { break }
                let value = try lexer.value()
                guard case .keyword(let op) = value else { operands.append(value); guard operands.count <= 100_000 else { throw PDFStructureError.limit }; continue }
                operations += 1; guard operations <= 2_000_000 else { throw PDFStructureError.limit }
                if !Self.operators.contains(op) { undefined.append(location + ": " + op) }
                switch op {
                case "q": stack.append(state); maxQ = max(maxQ,stack.count)
                case "Q": guard let old = stack.popLast() else { throw PDFStructureError.malformed(L10n.tr("Q senza q")) }; state = old
                case "g","rg","k","G","RG","K":
                    let name = ["g":"DeviceGray","G":"DeviceGray","rg":"DeviceRGB","RG":"DeviceRGB","k":"DeviceCMYK","K":"DeviceCMYK"][op]!
                    let space = try color(.name(name),resources:resources,location:location)
                    if op.lowercased() == op { state.fill = space } else { state.stroke = space }
                    // TechNote0010 A011/A015: for parts1–3, specifying a
                    // device colour is already use, even without a paint op.
                    if profile.part <= 3,["DeviceRGB","DeviceCMYK","DeviceGray"].contains(space.kind) {
                        uses.append(.init(space:space,output:output,blending:state.blending,overprint:op.lowercased() == op ? state.fillOP : state.strokeOP,opm:state.opm,location:location + "/specificazione " + op))
                    }
                case "cs","CS":
                    if let name = operands.last?.name {
                        if isInherited && !["DeviceGray","DeviceRGB","DeviceCMYK","Pattern"].contains(name) { inherited.append(location + "/ColorSpace/" + name) }
                        let space = try color(.name(name),resources:resources,location:location)
                        if op == "cs" { state.fill = space } else { state.stroke = space }
                        if profile.part <= 3,["DeviceRGB","DeviceCMYK","DeviceGray"].contains(space.kind) {
                            uses.append(.init(space:space,output:output,blending:state.blending,overprint:op == "cs" ? state.fillOP : state.strokeOP,opm:state.opm,location:location + "/specificazione " + op))
                        }
                    }
                case "scn","SCN":
                    if let name = operands.last?.name, let value = try resource("Pattern",name) {
                        if op == "scn" { state.fill.pattern = value } else { state.stroke.pattern = value }
                    }
                case "f","F","f*": try paint(state.fill,state.fillOP)
                case "S","s": try paint(state.stroke,state.strokeOP)
                case "B","B*","b","b*": try paint(state.fill,state.fillOP); try paint(state.stroke,state.strokeOP)
                case "Tr": guard let mode = operands.last?.int, (0...7).contains(mode) else { throw PDFStructureError.malformed("Tr") }; state.textMode = mode
                case "Tj","TJ","'","\"":
                    let values = operands.last?.array ?? operands
                    if values.contains(where:{ !($0.data?.isEmpty ?? true) }) {
                        if let font = state.font,font["Subtype"]?.name == "Type3" {
                            if state.textMode == 0 {
                                let procedures = try reader.dictionary(font["CharProcs"])
                                let nested = font["Resources"] == nil ? resources : try reader.dictionary(font["Resources"])
                                for code in Set(values.compactMap(\.data).flatMap { Array($0) }) {
                                    guard let name = try PDFArchiveFontEncoding.glyphName(code:code,font:font,reader:reader),
                                          let procedure = procedures[name]?.reference else { unknown.append(location + L10n.tr(": CharProc Type3 non risolta"));continue }
                                    guard active.count < 50,!active.contains(procedure) else { unknown.append(location + L10n.tr(": CharProc Type3 ricorsiva"));continue }
                                    var inside = state;inside.font = nil
                                    try streams([procedure],resources:nested,initial:inside,output:output,page:page,active:active.union([procedure]),inherited:font["Resources"] == nil)
                                }
                            } else if state.textMode != 3 { unknown.append(location + L10n.tr(": rendering mode Type3 non modellato")) }
                        } else {
                            if [0,2,4,6].contains(state.textMode) { try paint(state.fill,state.fillOP) }
                            if [1,2,5,6].contains(state.textMode) { try paint(state.stroke,state.strokeOP) }
                        }
                    }
                case "Tf": if operands.count >= 2, let name = operands[operands.count - 2].name,let value = try resource("Font",name) { state.font = try reader.dictionary(value) }
                case "gs":
                    if let name = operands.last?.name, let value = try resource("ExtGState",name) {
                        try apply(reader.dictionary(value),to:&state)
                    }
                case "Do":
                    if let name = operands.last?.name, let value = try resource("XObject",name) {
                        let d = try reader.dictionary(value)
                        if d["Subtype"]?.name == "Form", let id = value.reference { try form(id,resources:resources,state:state,output:output,page:page,active:active) }
                        else if d["Subtype"]?.name == "Image", let id = value.reference {
                            images.append(.init(dictionary:d,data:try reader.object(id).stream ?? Data(),location:location + "/Image/" + name,inline:false,reliable:true))
                            if filters(d).contains("JPXDecode") && filters(d).count > 1 { unknown.append(location + L10n.tr(": JPX con filtri preliminari")) }
                            if d["ImageMask"]?.bool != true {
                                if d["ColorSpace"] != nil { try paint(color(d["ColorSpace"],resources:resources,location:location + "/Image"),state.fillOP) }
                                else if !filters(d).contains("JPXDecode") { unknown.append(location + L10n.tr(": ColorSpace immagine assente")) }
                            } else { try paint(state.fill,state.fillOP) }
                            if d["SMask"] != nil { transparent.insert(page) }
                        }
                    }
                case "sh": if let name = operands.last?.name, let value = try resource("Shading",name) { let d = try reader.dictionary(value); try paint(color(d["ColorSpace"],resources:resources,location:location + "/Shading"),state.fillOP) }
                case "BDC","DP": if let name = operands.last?.name { _ = try resource("Properties",name) }
                case "BI":
                    let image = try PDFArchiveInlineImage.read(from:&lexer)
                    images.append(.init(dictionary:image.dictionary,data:image.bytes,location:location + "/inline",inline:true,reliable:image.lengthReliable))
                    if !image.lengthReliable { unknown.append(location + L10n.tr(": confine immagine inline non provato")) }
                    if image.dictionary["ImageMask"]?.bool != true { try paint(color(image.dictionary["ColorSpace"],resources:resources,location:location + "/Inline"),state.fillOP) }
                    else { try paint(state.fill,state.fillOP) }
                    // Do not turn guessed binary bytes after EI into operators
                    // or proved violations. Only the dictionary is established.
                    if !image.lengthReliable { break contentLoop }
                default: break
                }
                operands.removeAll(keepingCapacity:true)
            }
        }
        guard stack.isEmpty else { throw PDFStructureError.malformed(L10n.tr("q/Q non bilanciati")) }
    }
}
