import AppKit
import ApplicationServices

enum AccessibilitySelectionError: Error {
    case permissionRequired
    case noSelectedText
    /// Carries the last AXError macOS reported so failures can be diagnosed;
    /// apps like Chromium intermittently time out (.cannotComplete).
    case unavailable(AXError?)
}

enum AccessibilitySelectionReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static func readFocusedSelection() -> Result<String, AccessibilitySelectionError> {
        guard isTrusted else { return .failure(.permissionRequired) }

        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard focusResult == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .failure(.unavailable(focusResult))
        }

        var element = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var foundSelectedTextAttribute = false
        var latestError: AXError?

        // Safari, Firefox, and Zen can focus a web-content child while keeping
        // the actual selection on its enclosing HTML/web area. Check that short
        // chain before declaring the app unsupported.
        for _ in 0..<8 {
            switch selectedText(from: element) {
            case .text(let text):
                return .success(text)
            case .empty:
                foundSelectedTextAttribute = true
            case .unavailable(let error):
                latestError = error
            }

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXParentAttribute as CFString,
                &parentValue,
            ) == .success,
                  let parentValue,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                break
            }
            element = unsafeBitCast(parentValue, to: AXUIElement.self)
        }
        if let text = selectionInFrontmostApplication(latestError: &latestError) {
            return .success(text)
        }
        return .failure(foundSelectedTextAttribute ? .noSelectedText : .unavailable(latestError))
    }

    /// Browsers may expose a selected range on a web-area sibling instead of
    /// the focused element's parent chain. This visits accessibility elements
    /// only and asks only for their selected text, never page text or clipboard
    /// data. The bound keeps a malformed accessibility tree from slowing Flow.
    private static func selectionInFrontmostApplication(latestError: inout AXError?) -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(pid_t(app.processIdentifier))
        var remainingElements = 600
        return selectedText(in: root, remainingElements: &remainingElements, latestError: &latestError)
    }

    private static func selectedText(
        in element: AXUIElement,
        remainingElements: inout Int,
        latestError: inout AXError?,
    ) -> String? {
        guard remainingElements > 0 else { return nil }
        remainingElements -= 1

        switch selectedText(from: element) {
        case .text(let text):
            return text
        case .unavailable(let error):
            latestError = error
        case .empty:
            break
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue,
        ) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let text = selectedText(in: child, remainingElements: &remainingElements, latestError: &latestError) {
                return text
            }
        }
        return nil
    }

    private enum SelectedTextResult {
        case text(String)
        case empty
        case unavailable(AXError?)
    }

    private static func selectedText(from element: AXUIElement) -> SelectedTextResult {
        var selectedValue: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedValue,
        )
        if selectedResult == .success {
            return textResult(selectedValue as? String)
        }

        // Chromium- and WebKit-based browser content can provide a text-marker
        // range instead of AXSelectedText. Ask Accessibility to resolve only
        // that range, rather than reading the web area's complete value.
        var markerRange: CFTypeRef?
        let markerResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextMarkerRangeAttribute as CFString,
            &markerRange,
        )
        guard markerResult == .success,
              let markerRange else {
            return .unavailable(markerResult)
        }
        var textValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
            markerRange,
            &textValue,
        ) == .success else {
            return .empty
        }
        return textResult(textValue as? String)
    }

    private static func textResult(_ text: String?) -> SelectedTextResult {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        return .text(text)
    }
}
