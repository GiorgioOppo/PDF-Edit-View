import CoreGraphics
import Foundation
import XCTest
@testable import CartaPDF

final class PDFArchiveICCModelTests:XCTestCase {
    private func u16(_ n:Int)->Data { Data([UInt8(n>>8 & 255),UInt8(n & 255)]) }
    private func u32(_ n:Int)->Data { Data([UInt8(n>>24 & 255),UInt8(n>>16 & 255),UInt8(n>>8 & 255),UInt8(n & 255)]) }
    private func tag(_ name:String,_ payload:Data = Data())->Data { Data(name.utf8)+Data(repeating:0,count:4)+payload }
    private func xyz()->Data { tag("XYZ ",u32(0xF6D6)+u32(65536)+u32(0xD32D)) }
    private func mluc()->Data { tag("mluc",u32(1)+u32(12)+Data("enUS".utf8)+u32(2)+u32(28)+u16(65)) }
    private func legacyDescription(_ ascii:Data = Data([65,0]),unicode:[Int] = [],script:Data = Data())->Data {
        var payload = u32(ascii.count)+ascii+u32(0)+u32(unicode.count)
        for value in unicode { payload += u16(value) }
        payload += u16(0)+Data([UInt8(script.count)])+script+Data(repeating:0,count:67-script.count)
        return tag("desc",payload)
    }
    private func lut8(_ inputs:Int,_ outputs:Int)->Data {
        let points = (0..<inputs).reduce(outputs){value,_ in value*2}
        return tag("mft1",Data([UInt8(inputs),UInt8(outputs),2,0])+Data(repeating:0,count:36+inputs*256+points+outputs*256))
    }
    private func namedColors(_ count:Int = 1,channels:Int = 0,name:Data = Data([65,0]))->Data {
        var payload = u32(0)+u32(count)+u32(channels)+Data(repeating:0,count:64)
        let root = name+Data(repeating:0,count:32-name.count)
        for _ in 0..<count { payload += root+Data(repeating:0,count:6+2*channels) }
        return tag("ncl2",payload)
    }
    private func sequence(_ first:Data,_ second:Data,records:Int = 1,pad:Bool = false)->Data {
        func aligned(_ value:Data)->Data { value+Data(repeating:0,count:pad ? (4-value.count%4)%4:0) }
        var payload = u32(records)
        for _ in 0..<records { payload += Data(repeating:0,count:20)+aligned(first)+aligned(second) }
        return tag("pseq",payload)
    }
    private func identifiers(_ count:Int = 1,shared:Bool = false,description:Data? = nil)->Data {
        let record = Data(repeating:0,count:16)+(description ?? mluc())
        let padded = record+Data(repeating:0,count:(4-record.count%4)%4)
        var payload = u32(count),offset = 12+8*count
        for _ in 0..<count { payload += u32(offset)+u32(record.count);if !shared { offset += padded.count } }
        for _ in 0..<(shared ? min(1,count):count) { payload += padded }
        return tag("psid",payload)
    }
    private func floats(_ values:[Float])->Data { values.reduce(into:Data()){$0 += u32(Int($1.bitPattern))} }
    private func element(_ name:String,inputs:Int = 1,outputs:Int = 1,_ payload:Data = Data())->Data { tag(name,u16(inputs)+u16(outputs)+payload) }
    private func matrix(_ inputs:Int = 1,_ outputs:Int = 1)->Data { element("matf",inputs:inputs,outputs:outputs,Data(repeating:0,count:4*outputs*(inputs+1))) }
    private func mpe(_ elements:[Data],inputs:Int = 1,outputs:Int = 1,shared:Bool = false)->Data {
        var payload = u16(inputs)+u16(outputs)+u32(elements.count),offset = 16+8*elements.count
        for value in elements { payload += u32(offset)+u32(value.count);if !shared { offset += (value.count+3)/4*4 } }
        for value in (shared ? Array(elements.prefix(1)):elements) { payload += value+Data(repeating:0,count:(4-value.count%4)%4) }
        return tag("mpet",payload)
    }
    private func formula(_ function:Int = 0)->Data {
        tag("parf",u16(function)+u16(0)+floats(function == 0 ? [1,1,0,0]:[1,1,1,1,0]))
    }
    private func segmented(_ segments:[Data],breaks:[Float] = [])->Data { tag("curf",u16(segments.count)+u16(0)+floats(breaks)+segments.reduce(Data(),+)) }
    private func curveSet(_ curves:[Data],shared:Bool = false)->Data {
        var payload = Data(),offset = 12+8*curves.count
        for curve in curves { payload += u32(offset)+u32(curve.count);if !shared { offset += (curve.count+3)/4*4 } }
        for curve in (shared ? Array(curves.prefix(1)):curves) { payload += curve+Data(repeating:0,count:(4-curve.count%4)%4) }
        return element("cvst",inputs:curves.count,outputs:curves.count,payload)
    }
    private func clut(_ grids:[Int],outputs:Int = 1)->Data {
        let count = grids.reduce(outputs,*)
        return element("clut",inputs:grids.count,outputs:outputs,Data(grids.map(UInt8.init))+Data(repeating:0,count:16-grids.count)+Data(repeating:0,count:4*count))
    }
    private func profile(_ extras:[String:Data] = [:],major:Int = 4,minor:Int = 3,gap:Int = 0,device:String = "mntr",space:String = "GRAY",pcs:String = "XYZ ",removing:Set<String> = [])->Data {
        var tags:[String:Data] = ["desc":mluc(),"cprt":mluc(),"wtpt":xyz(),"kTRC":tag("curv",u32(0))]
        if major == 2 {
            var description = u32(2)+Data([65,0]);description += u32(0)+u32(0);description += u16(0)+Data(repeating:0,count:68)
            tags["desc"] = tag("desc",description);tags["cprt"] = tag("text",Data([65,0]))
        }
        tags.merge(extras){_,new in new}
        for key in removing { tags.removeValue(forKey:key) }
        var result = Data(repeating:0,count:132),table = Data(),values = Data()
        result[8] = UInt8(major);result[9] = UInt8(minor<<4)
        result.replaceSubrange(12..<16,with:Data(device.utf8));result.replaceSubrange(16..<20,with:Data(space.utf8));result.replaceSubrange(20..<24,with:Data(pcs.utf8))
        let date = [2024,2,29,12,0,0].reduce(into:Data()){ $0 += u16($1) };result.replaceSubrange(24..<36,with:date)
        result.replaceSubrange(36..<40,with:Data("acsp".utf8));result.replaceSubrange(68..<80,with:xyz().dropFirst(8))
        result.replaceSubrange(128..<132,with:u32(tags.count))
        var offset = 132+12*tags.count
        for (index,key) in tags.keys.sorted().enumerated() {
            let data = tags[key]!;table += Data(key.utf8)+u32(offset)+u32(data.count);values += data
            let padding = (4-data.count%4)%4;values += Data(repeating:0,count:padding);offset += data.count+padding
            if index == 0,gap > 0 { values += Data(repeating:0,count:gap);offset += gap }
        }
        result += table+values;result.replaceSubrange(0..<4,with:u32(result.count));return result
    }
    private func audit(_ bytes:Data) throws -> PDFArchiveICCAudit { PDFArchiveICCAudit(profile:try PDFArchiveICCProfile(data:bytes)) }
    func testRealAppleMatrixProfileHasNoInventedStructuralViolations() throws {
        let data = try XCTUnwrap(CGColorSpace(name:CGColorSpace.displayP3)?.copyICCData()) as Data
        let result = try audit(data);XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
    }
    func testHeaderCalendarVersionPCSReservedAndD50AreChecked() throws {
        XCTAssertTrue(try audit(profile()).issues.isEmpty)
        for (range,value) in [(24..<26,u16(2023)),(20..<24,Data("RGB ".utf8)),(100..<104,u32(1)),(68..<72,u32(1)),(10..<12,u16(1))] {
            var bad = profile();bad.replaceSubrange(range,with:value);XCTAssertFalse(try audit(bad).issues.isEmpty)
        }
    }
    func testV2AndV4HaveDifferentTextTypesAndReservedRanges() throws {
        XCTAssertTrue(try audit(profile(major:2,minor:4)).issues.isEmpty)
        var bad = profile(major:2,minor:4);bad[84] = 1
        let v2 = try audit(bad);XCTAssertTrue(v2.issues.isEmpty);XCTAssertTrue(v2.gaps.contains{$0.contains("riservato")})
        XCTAssertTrue(try audit(profile(["cprt":tag("text",Data([65,0]))])).issues.contains{$0.contains("incompatibile")})
    }
    func testContiguousLayoutRuleIsLimitedToV44() throws {
        XCTAssertTrue(try audit(profile(minor:3,gap:4)).issues.isEmpty)
        XCTAssertTrue(try audit(profile(minor:4,gap:4)).issues.contains{$0.contains("non contiguo")})
        XCTAssertTrue(try audit(profile(minor:4)).issues.isEmpty)
    }
    func testCurveAndParametricPayloadsUseCountsRatherThanCgAcceptance() throws {
        XCTAssertTrue(try audit(profile(["kTRC":tag("curv",u32(100)+u16(1))])).issues.contains{$0.contains("troncata")})
        XCTAssertTrue(try audit(profile(["kTRC":tag("para",u16(4)+u16(0)+u32(1))])).issues.contains{$0.contains("troncata")})
        XCTAssertTrue(try audit(profile(["kTRC":tag("para",u16(0)+u16(0)+u32(65536))])).issues.isEmpty)
    }
    func testMlucBoundsAndMalformedUTF16AreNotRepaired() throws {
        let badOffset = tag("mluc",u32(1)+u32(12)+Data("enUS".utf8)+u32(2)+u32(999)+u16(65))
        XCTAssertFalse(try audit(profile(["desc":badOffset])).issues.isEmpty)
        let badUnicode = tag("mluc",u32(1)+u32(12)+Data("enUS".utf8)+u32(2)+u32(28)+u16(0xD800))
        XCTAssertFalse(try audit(profile(["desc":badUnicode])).issues.isEmpty)
    }
    func testLut8And16DimensionsAndTableExtentsAreChecked() throws {
        var payload = Data([1,1,2,0])+Data(repeating:0,count:36)
        payload += Data(repeating:0,count:256+2+256)
        XCTAssertTrue(try audit(profile(["test":tag("mft1",payload)])).issues.isEmpty)
        var short = payload;short.removeLast(2)
        XCTAssertTrue(try audit(profile(["test":tag("mft1",short)])).issues.contains{$0.contains("troncata")})
        let lut16 = Data([1,1,2,0])+Data(repeating:0,count:36)+u16(2)+u16(2)+Data(repeating:0,count:12)
        XCTAssertTrue(try audit(profile(["test":tag("mft2",lut16)])).issues.isEmpty)
    }
    func testLutABEmbeddedCurvesCLUTOffsetsAndChannelsAreChecked() throws {
        var payload = Data([1,1,0,0])+u32(32)+u32(0)+u32(0)+u32(0)+u32(0);payload += tag("curv",u32(0))
        XCTAssertTrue(try audit(profile(["test":tag("mAB ",payload),"best":tag("mBA ",payload)])).issues.isEmpty)
        var bad = payload;bad.replaceSubrange(4..<8,with:u32(33))
        XCTAssertTrue(try audit(profile(["A2B0":tag("mAB ",bad)])).issues.contains{$0.contains("offset")})
    }
    func testUnknownPrivateTagIsUnverifiedRatherThanInventedInvalidity() throws {
        let result = try audit(profile(["priv":tag("zzzz",Data([1,2,3,4]))]))
        XCTAssertTrue(result.issues.isEmpty);XCTAssertFalse(result.gaps.isEmpty)
        let notAStandardType = try audit(profile(["priv":tag("clot",u32(0))]))
        XCTAssertTrue(notAStandardType.issues.isEmpty);XCTAssertFalse(notAStandardType.gaps.isEmpty)
    }
    func testRequiredV4MatrixModelAndTagTypeAreActuallyInspected() throws {
        var bad = profile();bad.replaceSubrange(16..<20,with:Data("RGB ".utf8))
        XCTAssertTrue(try audit(bad).issues.contains{$0.contains("incompleto")})
        XCTAssertTrue(try audit(profile(["wtpt":tag("curv",u32(0))])).issues.contains{$0.contains("incompatibile")})
    }
    func testLutChannelsAgreeWithProfileDataSpaceAndPCS() throws {
        var payload = Data([1,1,2,0])+Data(repeating:0,count:36)
        payload += Data(repeating:0,count:256+2+256)
        XCTAssertTrue(try audit(profile(["A2B0":tag("mft1",payload),"B2A0":tag("mft1",payload)])).issues.contains{$0.contains("canali LUT")})
    }
    func testThreeChannelMatrixModelIsNotLimitedToRGB() throws {
        let tags = ["rXYZ":xyz(),"gXYZ":xyz(),"bXYZ":xyz(),"rTRC":tag("curv",u32(0)),"gTRC":tag("curv",u32(0)),"bTRC":tag("curv",u32(0))]
        for space in ["CMY ","YCbr","3CLR","Luv "] {
            var data = profile(tags);data.replaceSubrange(16..<20,with:Data(space.utf8))
            let result = try audit(data);XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
        }
        XCTAssertEqual(PDFArchiveICCProfile.channels("ACLR"),10)
        XCTAssertEqual(PDFArchiveICCProfile.channels("FCLR"),15)
        XCTAssertNil(PDFArchiveICCProfile.channels("1CLR"))
    }
    func testPrivateTagWithSimilarPrefixIsNotAStandardTransform() throws {
        XCTAssertTrue(try audit(profile(["A2BX":tag("ui08",Data([1])),"B2AX":tag("ui08",Data([2]))])).issues.isEmpty)
    }
    func testTagSafetyBudgetIsIncompleteRatherThanMalformed() throws {
        var data = profile();data.replaceSubrange(128..<132,with:u32(4097))
        data += Data(repeating:0,count:4097*12);data.replaceSubrange(0..<4,with:u32(data.count))
        XCTAssertThrowsError(try PDFArchiveICCProfile(data:data)) { error in
            guard case PDFStructureError.limit = error else { return XCTFail("Budget deve produrre limit: \(error)") }
        }
    }
    func testLutABOnlyPermitsNormativeElementCombinations() throws {
        let empty = Data([1,1,0,0])+Data(repeating:0,count:20)
        XCTAssertTrue(try audit(profile(["test":tag("mAB ",empty)])).issues.contains{$0.contains("curve B")})
        var matrix = Data([3,3,0,0])+u32(32)+u32(68)+u32(0)+u32(0)+u32(0)
        matrix += tag("curv",u32(0))+tag("curv",u32(0))+tag("curv",u32(0))+Data(repeating:0,count:48)
        XCTAssertTrue(try audit(profile(["test":tag("mAB ",matrix)])).issues.contains{$0.contains("comparire insieme")})
        matrix.replaceSubrange(12..<16,with:u32(116))
        matrix += tag("curv",u32(0))+tag("curv",u32(0))+tag("curv",u32(0))
        let result = try audit(profile(["test":tag("mAB ",matrix)]));XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
    }
    func testV4DeviceClassesRequireTheirOwnModelTags() throws {
        for (device,missing) in [("prtr","A2B0"),("spac","B2A0"),("abst","A2B0"),("nmcl","ncl2"),("link","pseq")] {
            var data = profile();data.replaceSubrange(12..<16,with:Data(device.utf8))
            if device == "prtr" { data.replaceSubrange(16..<20,with:Data("RGB ".utf8)) }
            XCTAssertTrue(try audit(data).issues.contains{$0.contains(missing)})
        }
    }
    func testKnownTagTypeMismatchIsDetectedEvenForOpaqueTypes() throws {
        XCTAssertTrue(try audit(profile(["pseq":tag("zzzz",Data())])).issues.contains{$0.contains("incompatibile")})
        XCTAssertTrue(try audit(profile(["clot":tag("ui08",Data([1]))])).issues.contains{$0.contains("incompatibile")})
    }
    func testV43PaddingMustBeZeroEvenWhenTagGapsArePermitted() throws {
        var data = profile(minor:3)
        // First sorted element is cprt: a 30-byte mluc followed by two padding bytes.
        let first = 132+4*12
        data[first+30] = 1
        XCTAssertTrue(try audit(data).issues.contains{$0.contains("padding")})
    }
    func testD50FourDecimalPrecisionDoesNotInventUniqueFixedPointEncoding() throws {
        var data = profile(minor:4)
        data.replaceSubrange(68..<72,with:u32(0xF6D5));data.replaceSubrange(76..<80,with:u32(0xD32C))
        let v44 = try audit(data);XCTAssertTrue(v44.issues.isEmpty);XCTAssertTrue(v44.gaps.isEmpty)
        data[9] = 0x30
        let older = try audit(data);XCTAssertTrue(older.issues.isEmpty);XCTAssertTrue(older.gaps.contains{$0.contains("Quantizzazione")})
    }
    func testV2RequiredModelsDoNotInheritV4DisplayAlternativesOrColorantTables() throws {
        let lut = lut8(3,3)
        let v2Display = try audit(profile(["A2B0":lut,"B2A0":lut],major:2,minor:4,space:"RGB "))
        XCTAssertTrue(v2Display.issues.contains{$0.contains("rXYZ")})
        XCTAssertTrue(try audit(profile(["A2B0":lut,"B2A0":lut],space:"RGB ")).issues.isEmpty)
        let link = profile(["A2B0":lut8(2,3),"pseq":sequence(legacyDescription(),legacyDescription())],major:2,minor:4,device:"link",space:"2CLR",pcs:"RGB ",removing:["wtpt"])
        let result = try audit(link)
        XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
        XCTAssertTrue(result.gaps.isEmpty,result.gaps.joined(separator:"; "))
        let earliest = try audit(profile(["A2B0":lut],major:2,minor:0,device:"nmcl",space:"RGB "))
        XCTAssertTrue(earliest.issues.isEmpty);XCTAssertTrue(earliest.gaps.contains{$0.contains("v2.0")})
    }
    func testV2RequiredTagsCoverAllDocumentedClasses() throws {
        for (device,space,missing) in [("scnr","GRAY","kTRC"),("mntr","GRAY","kTRC"),("prtr","GRAY","kTRC"),("prtr","CMYK","A2B1"),("link","CMYK","pseq"),("spac","RGB ","B2A0"),("abst","XYZ ","A2B0"),("nmcl","RGB ","ncl2")] {
            let result = try audit(profile(major:2,minor:4,device:device,space:space,removing:["kTRC"]))
            XCTAssertTrue(result.issues.contains{$0.contains(missing)},device+": "+result.issues.joined(separator:"; "))
        }
        for key in ["desc","cprt","wtpt"] {
            XCTAssertTrue(try audit(profile(major:2,minor:4,removing:[key])).issues.contains{$0.contains(key)})
        }
    }
    func testV2MatrixInputSupportsThreeComponentsAndLabRequiresForwardLUT() throws {
        let matrix = ["rXYZ":xyz(),"gXYZ":xyz(),"bXYZ":xyz(),"rTRC":tag("curv",u32(0)),"gTRC":tag("curv",u32(0)),"bTRC":tag("curv",u32(0))]
        let input = try audit(profile(matrix,major:2,minor:4,device:"scnr",space:"CMY "))
        XCTAssertTrue(input.issues.isEmpty,input.issues.joined(separator:"; "))
        XCTAssertTrue(try audit(profile(matrix,major:2,minor:4,device:"scnr",space:"CMY ",pcs:"Lab ")).issues.contains{$0.contains("A2B0")})
        var withLUT = matrix;withLUT["A2B0"] = lut8(3,3)
        XCTAssertTrue(try audit(profile(withLUT,major:2,minor:4,device:"scnr",space:"CMY ",pcs:"Lab ")).issues.isEmpty)
        let unknownDisplay = try audit(profile(matrix,major:2,minor:4,space:"CMY "))
        XCTAssertTrue(unknownDisplay.issues.isEmpty);XCTAssertTrue(unknownDisplay.gaps.contains{$0.contains("display ICC v2")})
    }
    func testNamedColorRecordsAcceptOptionalCoordinatesInBothEditions() throws {
        for major in [2,4] {
            for channels in [0,1] {
                let result = try audit(profile(["ncl2":namedColors(2,channels:channels)],major:major,minor:4))
                XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
                XCTAssertTrue(result.gaps.isEmpty,result.gaps.joined(separator:"; "))
                XCTAssertTrue(result.checkedTypes.contains("ncl2"))
            }
        }
    }
    func testNamedColorBoundsASCIITerminatorsAndCountsAreNotGuessed() throws {
        var short = namedColors(channels:1);short.removeLast()
        XCTAssertTrue(try audit(profile(["ncl2":short])).issues.contains{$0.contains("troncati")})
        XCTAssertTrue(try audit(profile(["ncl2":namedColors(name:Data(repeating:65,count:32))])).issues.contains{$0.contains("non terminato")})
        XCTAssertTrue(try audit(profile(["ncl2":namedColors(name:Data([0xE9,0]))])).issues.contains{$0.contains("non ASCII")})
        var huge = namedColors();huge.replaceSubrange(16..<20,with:u32(0xFFFFFFFF))
        XCTAssertTrue(try audit(profile(["ncl2":huge])).issues.contains{$0.contains("troncati")})
        var prefix = namedColors();prefix.replaceSubrange(20..<52,with:Data(repeating:65,count:32))
        XCTAssertTrue(try audit(profile(["ncl2":prefix])).issues.contains{$0.contains("non terminato")})
    }
    func testNamedColorUnprovenFlagsCoordinateAgreementAndLegacyLabStayUnknown() throws {
        let mismatch = try audit(profile(["ncl2":namedColors(channels:3)]))
        XCTAssertTrue(mismatch.issues.isEmpty);XCTAssertTrue(mismatch.gaps.contains{$0.contains("coordinate")})
        var flags = namedColors();flags.replaceSubrange(8..<12,with:u32(1))
        let reserved = try audit(profile(["ncl2":flags]));XCTAssertTrue(reserved.issues.isEmpty);XCTAssertTrue(reserved.gaps.contains{$0.contains("Flag")})
        var lab = namedColors();lab.replaceSubrange(116..<118,with:u16(0xFF01))
        let outOfDomain = try audit(profile(["ncl2":lab],pcs:"Lab "))
        XCTAssertTrue(outOfDomain.issues.isEmpty);XCTAssertTrue(outOfDomain.gaps.contains{$0.contains("L*")})
        let extra = try audit(profile(["ncl2":namedColors()+Data([1])]))
        XCTAssertTrue(extra.issues.isEmpty);XCTAssertTrue(extra.gaps.contains{$0.contains("aggiuntivi")})
    }
    func testPseqV2UsesCompleteCountedDescriptionsEvenWhenUnaligned() throws {
        let first = legacyDescription(Data([65,66,0]),unicode:[0x41,0],script:Data([65,0]))
        let second = legacyDescription(Data([0]))
        let result = try audit(profile(["pseq":sequence(first,second,records:2)],major:2,minor:4))
        XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
        XCTAssertTrue(result.gaps.isEmpty,result.gaps.joined(separator:"; "))
    }
    func testPseqV4MlucUsesItsOwnOffsetsAndPermitsSharedStrings() throws {
        let shared = tag("mluc",u32(2)+u32(12)+Data("enUS".utf8)+u32(2)+u32(40)+Data("enGB".utf8)+u32(2)+u32(40)+u16(65))
        let result = try audit(profile(["pseq":sequence(shared,mluc(),records:2,pad:true)]))
        XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
        XCTAssertTrue(result.gaps.isEmpty,result.gaps.joined(separator:"; "))
    }
    func testPseqDocumentedEmptyVariantsAndLegacyConversionAvoidFalseFailure() throws {
        let regular = tag("mluc",u32(0)+u32(12)),short = tag("mluc",u32(0)),long = regular+Data(repeating:0,count:12)
        let canonical = try audit(profile(["pseq":sequence(regular,regular)]))
        XCTAssertTrue(canonical.issues.isEmpty);XCTAssertTrue(canonical.gaps.isEmpty)
        for empty in [short,long] {
            let result = try audit(profile(["pseq":sequence(empty,empty)]))
            XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "));XCTAssertFalse(result.gaps.isEmpty)
        }
        let legacy = try audit(profile(["pseq":sequence(legacyDescription(),legacyDescription())]))
        XCTAssertTrue(legacy.issues.isEmpty);XCTAssertTrue(legacy.gaps.contains{$0.contains("legacy")})
        let wrongV2 = sequence(regular,regular)+Data(repeating:0,count:160)
        XCTAssertTrue(try audit(profile(["pseq":wrongV2],major:2,minor:4)).issues.contains{$0.contains("incompatibile")})
    }
    func testPseqAmbiguousStorageAndUnprovenSourceRelationsStayUnknown() throws {
        let unknownStorage = mluc()+Data(repeating:0,count:6)
        let result = try audit(profile(["pseq":sequence(unknownStorage,mluc())]))
        XCTAssertTrue(result.issues.isEmpty);XCTAssertTrue(result.gaps.contains{$0.contains("ambigua")})
        let empty = try audit(profile(["pseq":tag("pseq",u32(0))]))
        XCTAssertTrue(empty.issues.isEmpty);XCTAssertTrue(empty.gaps.contains{$0.contains("vuota")})
    }
    func testPseqKnownTruncationAndMalformedEmbeddedStringsFail() throws {
        let hugeCount = tag("pseq",u32(0xFFFFFFFF)+Data(repeating:0,count:64))
        XCTAssertTrue(try audit(profile(["pseq":hugeCount])).issues.contains{$0.contains("troncati")})
        let wrong = tag("ui08",Data(repeating:0,count:24))
        XCTAssertTrue(try audit(profile(["pseq":sequence(wrong,mluc())])).issues.contains{$0.contains("incompatibile")})
        let badUTF = tag("mluc",u32(1)+u32(12)+Data("enUS".utf8)+u32(2)+u32(28)+u16(0xD800))
        XCTAssertTrue(try audit(profile(["pseq":sequence(badUTF,mluc(),pad:true)])).issues.contains{$0.contains("UTF16")})
        var badUnicode = legacyDescription(Data([65,0]),unicode:[65])
        XCTAssertTrue(try audit(profile(["pseq":sequence(badUnicode,legacyDescription())],major:2,minor:4)).issues.contains{$0.contains("non terminato")})
        badUnicode = legacyDescription(Data([65,0]),script:Data([65]))
        XCTAssertTrue(try audit(profile(["pseq":sequence(badUnicode,legacyDescription())],major:2,minor:4)).issues.contains{$0.contains("non terminato")})
    }
    func testPsidSizedRecordsUseNestedOffsetsAndAllowEntireRecordSharing() throws {
        for shared in [false,true] {
            let result = try audit(profile(["psid":identifiers(2,shared:shared)]))
            XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
            XCTAssertTrue(result.gaps.isEmpty,result.gaps.joined(separator:"; "))
        }
        let legacy = try audit(profile(["psid":identifiers()],major:2,minor:4))
        XCTAssertTrue(legacy.issues.isEmpty);XCTAssertTrue(legacy.gaps.contains{$0.contains("edizione v2")})
    }
    func testPsidOffsetsSizesPaddingAndEmbeddedMlucCannotEscapeTheirRecord() throws {
        for (range,value) in [(12..<16,u32(0)),(12..<16,u32(21)),(16..<20,u32(31)),(16..<20,u32(0xFFFFFFFF))] {
            var bad = identifiers();bad.replaceSubrange(range,with:value)
            XCTAssertFalse(try audit(profile(["psid":bad])).issues.isEmpty)
        }
        var short = identifiers(2);short.replaceSubrange(16..<20,with:u32(32))
        XCTAssertTrue(try audit(profile(["psid":short])).issues.contains{$0.contains("mluc")})
        var padding = identifiers();padding[padding.count-1] = 1
        XCTAssertTrue(try audit(profile(["psid":padding])).issues.contains{$0.contains("padding")})
        let wrong = try audit(profile(["psid":identifiers(description:legacyDescription())]))
        XCTAssertTrue(wrong.issues.contains{$0.contains("incompatibile")})
    }
    func testStructuredRecordSafetyBudgetStaysUnknownInsteadOfMalformed() throws {
        let result = try audit(profile(["psid":identifiers(4097,shared:true,description:tag("mluc",u32(0)+u32(12)))]))
        XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
        XCTAssertTrue(result.gaps.contains{$0.contains("budget")})
        let count = 65_537
        let colors = tag("ncl2",u32(0)+u32(count)+u32(0)+Data(repeating:0,count:64+38*count))
        let named = try audit(profile(["ncl2":colors]))
        XCTAssertTrue(named.issues.isEmpty);XCTAssertTrue(named.gaps.contains{$0.contains("budget")})
    }
    func testMpeMatrixAndClutChainsAreStructuredInBothV4Editions() throws {
        let transform = mpe([matrix(2,3),matrix(3,2),clut([2,3],outputs:1)],inputs:2,outputs:1)
        for minor in [3,4] {
            let result = try audit(profile(["test":transform],minor:minor))
            XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
            XCTAssertTrue(result.gaps.isEmpty,result.gaps.joined(separator:"; "))
            XCTAssertTrue(result.checkedTypes.contains("mpet"))
        }
        let legacy = try audit(profile(["test":transform],major:2,minor:4))
        XCTAssertTrue(legacy.issues.isEmpty);XCTAssertTrue(legacy.gaps.contains{$0.contains("edizione v2")})
    }
    func testMpeHeaderAndInterelementChannelsMustAgree() throws {
        for transform in [mpe([matrix()],inputs:2),mpe([matrix()],outputs:2),mpe([matrix(1,2),matrix()])] {
            XCTAssertTrue(try audit(profile(["test":transform])).issues.contains{$0.contains("canali") || $0.contains("uscita finale")})
        }
        let empty = tag("mpet",u16(1)+u16(1)+u32(0))
        XCTAssertTrue(try audit(profile(["test":empty])).issues.contains{$0.contains("almeno un elemento")})
    }
    func testMpeOffsetsSizesFirstElementAndPaddingAreIndependentOfSharing() throws {
        XCTAssertTrue(try audit(profile(["test":mpe([matrix(),matrix()],shared:true)])).issues.isEmpty)
        for (range,value) in [(16..<20,u32(0)),(16..<20,u32(25)),(20..<24,u32(11)),(20..<24,u32(0xFFFFFFFF))] {
            var bad = mpe([matrix()]);bad.replaceSubrange(range,with:value)
            XCTAssertFalse(try audit(profile(["test":bad])).issues.isEmpty)
        }
        var gap = mpe([matrix()])+Data(repeating:0,count:4);gap.replaceSubrange(16..<20,with:u32(28))
        XCTAssertTrue(try audit(profile(["test":gap])).issues.contains{$0.contains("immediatamente")})
        var padding = mpe([element("priv",Data([1])),matrix()]);padding[45] = 1
        XCTAssertTrue(try audit(profile(["test":padding])).issues.contains{$0.contains("padding")})
    }
    func testMpePrivateElementsDoNotHideLaterKnownViolationsOrBecomeInvalid() throws {
        let unknown = try audit(profile(["test":mpe([element("priv",Data([1,2,3,4])),matrix()])]))
        XCTAssertTrue(unknown.issues.isEmpty);XCTAssertTrue(unknown.gaps.contains{$0.contains("non definito")})
        var short = matrix();short.removeLast(4)
        XCTAssertTrue(try audit(profile(["test":mpe([element("priv"),short])])).issues.contains{$0.contains("float32")})
        let typo = try audit(profile(["test":mpe([element("mflt")])]))
        XCTAssertTrue(typo.issues.isEmpty);XCTAssertTrue(typo.gaps.contains{$0.contains("mflt")})
    }
    func testMpeStoredFloatsRejectNonfiniteAndSubnormalButPermitSignedZeroAndNormals() throws {
        for bits in [0x00000001,0x807FFFFF,0x7F800000,0xFF800000,0x7FC00000] {
            var value = matrix();value.replaceSubrange(12..<16,with:u32(bits))
            XCTAssertTrue(try audit(profile(["test":mpe([value])])).issues.contains{$0.contains("float32Number")})
        }
        for bits in [0x00000000,0x80000000,0x00800000,0x80800000,0x7F7FFFFF,0xFF7FFFFF] {
            var value = matrix();value.replaceSubrange(12..<16,with:u32(bits))
            XCTAssertTrue(try audit(profile(["test":mpe([value])])).issues.isEmpty)
        }
    }
    func testMpeClutGridExtentsReservedDimensionsAndSixteenInputs() throws {
        for values in [[0],[1],[2]] {
            var value = clut([2]);value[12] = UInt8(values[0])
            if values[0] == 2 { value.removeLast(4) }
            XCTAssertTrue(try audit(profile(["test":mpe([value])])).issues.contains{$0.contains("CLUT")})
        }
        var unused = clut([2]);unused[13] = 1
        XCTAssertTrue(try audit(profile(["test":mpe([unused])])).issues.contains{$0.contains("inutilizzate")})
        let sixteen = mpe([clut(Array(repeating:2,count:16))],inputs:16)
        XCTAssertTrue(try audit(profile(["test":sixteen])).issues.isEmpty)
        let tooMany = mpe([element("clut",inputs:17,Data(repeating:0,count:16))],inputs:17)
        XCTAssertTrue(try audit(profile(["test":tooMany])).issues.contains{$0.contains("sedici")})
    }
    func testMpeCurveSetNestedPositionsAndSharedCurvesKeepMathematicalDomainUnknown() throws {
        let curve = segmented([formula()])
        for shared in [false,true] {
            let transform = mpe([curveSet([curve,curve],shared:shared)],inputs:2,outputs:2)
            let result = try audit(profile(["test":transform]))
            XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
            XCTAssertTrue(result.gaps.contains{$0.contains("matematica")})
        }
        let sampled = segmented([formula(),tag("samf",u32(2)+floats([0,1])),formula()],breaks:[0,1])
        XCTAssertTrue(try audit(profile(["test":mpe([curveSet([sampled])])])).issues.isEmpty)
    }
    func testMpeSegmentBreaksAreNondecreasingNotNecessarilyStrict() throws {
        let segments = [formula(),tag("samf",u32(1)+floats([0])),formula()]
        for points in [[Float(0),0],[0,1]] {
            XCTAssertTrue(try audit(profile(["test":mpe([curveSet([segmented(segments,breaks:points)])])])).issues.isEmpty)
        }
        let backwards = segmented(segments,breaks:[1,0])
        XCTAssertTrue(try audit(profile(["test":mpe([curveSet([backwards])])])).issues.contains{$0.contains("decrescenti")})
    }
    func testMpeCurvesRejectTruncationIllegalEndSamplesAndReservedFields() throws {
        let sample = tag("samf",u32(1)+floats([0]))
        for curve in [segmented([sample]),segmented([sample,formula()],breaks:[0]),segmented([formula(),sample],breaks:[0]),segmented([formula(),tag("samf",u32(0)),formula()],breaks:[0,1])] {
            XCTAssertFalse(try audit(profile(["test":mpe([curveSet([curve])])])).issues.isEmpty)
        }
        var reserved = segmented([formula()]);reserved.replaceSubrange(10..<12,with:u16(1))
        XCTAssertTrue(try audit(profile(["test":mpe([curveSet([reserved])])])).issues.contains{$0.contains("reserved")})
        var short = formula();short.removeLast(4)
        XCTAssertTrue(try audit(profile(["test":mpe([curveSet([segmented([short])])])])).issues.contains{$0.contains("float32")})
        var offset = curveSet([segmented([formula()])]);offset.replaceSubrange(12..<16,with:u32(0))
        XCTAssertTrue(try audit(profile(["test":mpe([offset])])).issues.contains{$0.contains("offset")})
    }
    func testMpeFutureFormulaCurveAndZeroChannelsAreUnknownRatherThanMalformed() throws {
        for curve in [segmented([formula(3)]),tag("zzzz",Data(repeating:0,count:4))] {
            let result = try audit(profile(["test":mpe([curveSet([curve])])]))
            XCTAssertTrue(result.issues.isEmpty);XCTAssertFalse(result.gaps.isEmpty)
        }
        let zero = try audit(profile(["test":mpe([matrix(0,0)],inputs:0,outputs:0)]))
        XCTAssertTrue(zero.issues.isEmpty);XCTAssertTrue(zero.gaps.contains{$0.contains("zero canali")})
        let extra = try audit(profile(["test":mpe([matrix()+Data(repeating:0,count:4)])]))
        XCTAssertTrue(extra.issues.isEmpty);XCTAssertTrue(extra.gaps.contains{$0.contains("aggiuntivi")})
    }
    func testMpeAcsPassThroughElementsRequireMatchingChannelCounts() throws {
        let begin = element("bACS",u32(0x12345678)),end = element("eACS",u32(0))
        let result = try audit(profile(["test":mpe([begin,matrix(),end])]))
        XCTAssertTrue(result.issues.isEmpty);XCTAssertTrue(result.gaps.isEmpty)
        let bad = element("bACS",inputs:1,outputs:2,u32(0))
        XCTAssertTrue(try audit(profile(["test":mpe([bad],outputs:2)])).issues.contains{$0.contains("ACS")})
    }
    func testMpePublicTransformTagsBindSixteenBitChannelsToProfileSpaces() throws {
        let result = try audit(profile(["D2B0":mpe([matrix(1,3)],outputs:3),"B2D0":mpe([matrix(3,1)],inputs:3)]))
        XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
        XCTAssertTrue(try audit(profile(["D2B0":mpe([matrix()])])).issues.contains{$0.contains("canali MPE")})
        XCTAssertTrue(try audit(profile(["B2D0":mpe([matrix()])])).issues.contains{$0.contains("canali MPE")})
    }
    func testMpeRecordAndFloatWorkBudgetsRemainUnknown() throws {
        let many = mpe(Array(repeating:matrix(),count:4097),shared:true)
        let result = try audit(profile(["test":many]))
        XCTAssertTrue(result.issues.isEmpty);XCTAssertTrue(result.gaps.contains{$0.contains("budget")})
        let large = mpe([matrix(1024,4096)],inputs:1024,outputs:4096)
        let work = try audit(profile(["test":large]))
        XCTAssertTrue(work.issues.isEmpty);XCTAssertTrue(work.gaps.contains{$0.contains("budget")})
        let segments = segmented(Array(repeating:formula(),count:4097),breaks:Array(repeating:0,count:4096))
        let curve = try audit(profile(["test":mpe([curveSet([segments])])]))
        XCTAssertTrue(curve.issues.isEmpty);XCTAssertTrue(curve.gaps.contains{$0.contains("budget")})
    }
    func testIccCancellationIsExplicitlyUnverified() async throws {
        let bytes = profile(["test":mpe([clut([16,16,16])])])
        let task = Task.detached { () throws -> PDFArchiveICCAudit in
            withUnsafeCurrentTask { $0?.cancel() }
            return PDFArchiveICCAudit(profile:try PDFArchiveICCProfile(data:bytes))
        }
        let result = try await task.value
        XCTAssertTrue(result.issues.isEmpty);XCTAssertTrue(result.gaps.contains{$0.contains("annullati")})
    }
}
