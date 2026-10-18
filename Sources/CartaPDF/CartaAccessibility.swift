import AppKit
import Foundation

@MainActor
enum CartaAccessibility {
    static func announce(_ message: String, in window: NSWindow? = nil) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, NSWorkspace.shared.isVoiceOverEnabled,
              let target = window ?? NSApp?.keyWindow,
              target.isVisible, target.isKeyWindow || target.attachedSheet != nil else { return }
        NSAccessibility.post(element: target, notification: .announcementRequested,
                             userInfo: [.announcement: String(message.prefix(800)),
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

enum CartaAnnotationFocusRoute: Equatable {
    case select(Int), leaveDocument

    static func tab(selected: Int?, count: Int, backwards: Bool) -> Self {
        guard count > 0 else { return .leaveDocument }
        guard let selected else { return .select(backwards ? count - 1 : 0) }
        let next = selected + (backwards ? -1 : 1)
        return (0..<count).contains(next) ? .select(next) : .leaveDocument
    }
}
