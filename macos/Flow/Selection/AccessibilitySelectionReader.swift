import AppKit
import ApplicationServices

enum AccessibilitySelectionError: Error {
    case permissionRequired
    case noSelectedText
    case selectionNeedsRefresh
    /// Carries the last AXError macOS reported so failures can be diagnosed.
    case unavailable(AXError?)
}

enum AccessibilitySelectionReader {
    private static let focusAttempts = 3
    private static let focusRetryDelay: TimeInterval = 0.05

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Chromium and Firefox-family browsers build parts of their accessibility
    /// tree only after an assistive client asks for it.
    @discardableResult
    static func prepare(pid: pid_t) -> Bool {
        guard isTrusted, pid != ProcessInfo.processInfo.processIdentifier else {
            return false
        }

        let root = AXUIElementCreateApplication(pid)
        var roleValue: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            root,
            kAXRoleAttribute as CFString,
            &roleValue
        )

        // Firefox-family apps can expose their application role before their
        // web-content accessibility tree is enabled.
        AXUIElementSetAttributeValue(
            root,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )

        // These queries warm the active tree without reading any text values.
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            root,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        var childrenValue: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(
            root,
            kAXChildrenAttribute as CFString,
            &childrenValue
        )

        return roleResult == .success
            && (focusedResult == .success || childrenResult == .success)
    }

    static func readFocusedSelection() -> Result<String, AccessibilitySelectionError> {
        guard isTrusted else { return .failure(.permissionRequired) }

        let system = AXUIElementCreateSystemWide()
        let sourceApplication = NSWorkspace.shared.frontmostApplication
        let applicationRoot = sourceApplication.map {
            AXUIElementCreateApplication(pid_t($0.processIdentifier))
        }
        var foundFocusedElement = false
        var foundSelectedTextAttribute = false
        var latestError: AXError?

        if let sourceApplication {
            prepare(pid: pid_t(sourceApplication.processIdentifier))
        }

        for attempt in 0..<focusAttempts {
            var focusedElements: [AXUIElement] = []
            if let element = focusedElement(from: system, latestError: &latestError) {
                focusedElements.append(element)
            }
            if let applicationRoot,
               let element = focusedElement(from: applicationRoot, latestError: &latestError) {
                focusedElements.append(element)
            }
            foundFocusedElement = foundFocusedElement || !focusedElements.isEmpty

            for element in focusedElements {
                if let text = selectionInParentChain(
                    from: element,
                    foundSelectedTextAttribute: &foundSelectedTextAttribute,
                    latestError: &latestError
                ) {
                    return .success(text)
                }
            }

            guard attempt + 1 < focusAttempts,
                  latestError == .noValue || latestError == .cannotComplete else { break }
            Thread.sleep(forTimeInterval: focusRetryDelay)
        }

        // Search the focused window before the whole application. Browser menu
        // and toolbar trees can otherwise consume the bounded traversal before
        // Flow reaches the selected web content.
        if let applicationRoot,
           let focusedWindow = elementAttribute(
               from: applicationRoot,
               attribute: kAXFocusedWindowAttribute as CFString,
               latestError: &latestError
           ),
           let text = selectedText(in: focusedWindow, latestError: &latestError) {
            return .success(text)
        }

        // Focus can be temporarily absent while the app tree remains readable.
        if let applicationRoot,
           let text = selectedText(in: applicationRoot, latestError: &latestError) {
            return .success(text)
        }

        if isZen(sourceApplication), foundFocusedElement, latestError == .noValue {
            return .failure(.selectionNeedsRefresh)
        }
        return .failure(foundSelectedTextAttribute ? .noSelectedText : .unavailable(latestError))
    }

    private static func isZen(_ application: NSRunningApplication?) -> Bool {
        application?.bundleIdentifier?.hasPrefix("app.zen-browser.zen") == true
    }

    private static func focusedElement(
        from root: AXUIElement,
        latestError: inout AXError?
    ) -> AXUIElement? {
        elementAttribute(
            from: root,
            attribute: kAXFocusedUIElementAttribute as CFString,
            latestError: &latestError
        )
    }

    private static func elementAttribute(
        from element: AXUIElement,
        attribute: CFString,
        latestError: inout AXError?
    ) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            latestError = result
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Safari, Firefox, and Zen can focus a web-content child while keeping
    /// the actual selection on its enclosing HTML/web area.
    private static func selectionInParentChain(
        from focusedElement: AXUIElement,
        foundSelectedTextAttribute: inout Bool,
        latestError: inout AXError?
    ) -> String? {
        var element = focusedElement
        for _ in 0..<8 {
            switch selectedText(from: element) {
            case .text(let text):
                return text
            case .empty:
                foundSelectedTextAttribute = true
            case .unavailable(let error):
                latestError = error
            }

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXParentAttribute as CFString,
                &parentValue
            ) == .success,
                  let parentValue,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                break
            }
            element = unsafeBitCast(parentValue, to: AXUIElement.self)
        }
        return nil
    }

    /// Browsers can expose a selected range on a web-area sibling instead of
    /// the focused element's parent chain. The bound prevents malformed or
    /// unusually large accessibility trees from stalling Flow.
    private static func selectedText(
        in root: AXUIElement,
        latestError: inout AXError?
    ) -> String? {
        var remainingElements = 600
        return selectedText(
            in: root,
            remainingElements: &remainingElements,
            latestError: &latestError
        )
    }

    private static func selectedText(
        in element: AXUIElement,
        remainingElements: inout Int,
        latestError: inout AXError?
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
            &childrenValue
        ) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let text = selectedText(
                in: child,
                remainingElements: &remainingElements,
                latestError: &latestError
            ) {
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
            &selectedValue
        )
        if selectedResult == .success {
            return textResult(selectedValue as? String)
        }

        // Chromium- and WebKit-based content can provide a text-marker range
        // instead of AXSelectedText.
        var markerRange: CFTypeRef?
        let markerResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextMarkerRangeAttribute as CFString,
            &markerRange
        )
        guard markerResult == .success, let markerRange else {
            return .unavailable(markerResult)
        }
        var textValue: CFTypeRef?
        let markerTextResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
            markerRange,
            &textValue
        )
        guard markerTextResult == .success else {
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
