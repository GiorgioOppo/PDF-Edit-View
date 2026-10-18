import Foundation
@testable import CartaPDF

/// Keeps a diagnostic-family assertion stable across the app's current locale.
/// The canonical Italian fragment selects the same source messages that the old
/// substring assertion selected. Each translated message must then match in
/// full, with only numbered interpolation slots treated as inert arguments.
/// Classification, PDF contents, identifiers and binary values are asserted
/// separately and must never be passed through this display-text helper.
func diagnosticContains(_ rendered: String, _ canonicalFragment: String) -> Bool {
    guard !canonicalFragment.isEmpty else { return false }
    if rendered.contains(canonicalFragment) { return true }
    return DiagnosticLocalizationTemplates.entries.contains { entry in
        entry.key.contains(canonicalFragment) && entry.expression.firstMatch(
            in: rendered, range: NSRange(rendered.startIndex..<rendered.endIndex, in: rendered)) != nil
    }
}

/// Prefix variant for log event counts: a translated message of the same
/// canonical family must start at the beginning, preserving the original guard.
func diagnosticHasPrefix(_ rendered: String, _ canonicalPrefix: String) -> Bool {
    guard !canonicalPrefix.isEmpty else { return false }
    if rendered.hasPrefix(canonicalPrefix) { return true }
    let range = NSRange(rendered.startIndex..<rendered.endIndex, in: rendered)
    return DiagnosticLocalizationTemplates.entries.contains { entry in
        entry.key.hasPrefix(canonicalPrefix) && entry.expression.firstMatch(in: rendered, range: range)?.range.location == 0
    }
}

private enum DiagnosticLocalizationTemplates {
    static let entries: [(key: String, expression: NSRegularExpression)] = {
        let translations = L10n.localizedStrings(for: "en").merging(L10n.localizedStrings(for: L10n.language)) { _, current in current }
        return translations.compactMap { key, value in
            diagnosticTemplateExpression(value).map { (key, $0) }
        }
    }()
}

/// Escapes every literal character before adding wildcard slots. Rendered user
/// values are never compiled as regex or read as additional placeholders.
func diagnosticTemplateExpression(_ template: String) -> NSRegularExpression? {
    guard let placeholders = try? NSRegularExpression(pattern: "\\{[0-9]+\\}") else { return nil }
    let range = NSRange(template.startIndex..<template.endIndex, in: template)
    let slots = placeholders.matches(in: template, range: range)
    var pattern = "", cursor = template.startIndex, literal = ""
    for slot in slots {
        guard let slotRange = Range(slot.range, in: template) else { return nil }
        let segment = String(template[cursor..<slotRange.lowerBound])
        literal += segment
        pattern += NSRegularExpression.escapedPattern(for: segment) + "(?s:.*?)"
        cursor = slotRange.upperBound
    }
    let tail = String(template[cursor...])
    literal += tail
    guard !literal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    pattern += NSRegularExpression.escapedPattern(for: tail)
    return try? NSRegularExpression(pattern: pattern)
}
