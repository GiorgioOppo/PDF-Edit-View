import CoreGraphics
import CoreText
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1])
var box = CGRect(x: 0, y: 0, width: 595, height: 842)
guard let context = CGContext(output as CFURL, mediaBox: &box, nil) else { fatalError("PDF context") }
for index in 1...3 {
    context.beginPDFPage(nil)
    let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil)]
    let text = NSAttributedString(string: "CartaPDF smoke test - pagina \(index)", attributes: attributes)
    context.textPosition = CGPoint(x: 55, y: 720)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    context.setFillColor(CGColor(red: CGFloat(index) / 4, green: 0.5, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 55, y: 520, width: 200, height: 100))
    context.endPDFPage()
}
context.closePDF()
