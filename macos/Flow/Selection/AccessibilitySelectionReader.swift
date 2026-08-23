import AppKit
import ApplicationServices

enum AccessibilitySelectionError: Error {
    case permissionRequired
    case noSelectedText(String)
    /// Carries the last AXError macOS reported so transient focus failures can
    /// be distinguished from applications that do not expose a selection.
    case unavailable(AXError?, String)
}

enum AccessibilitySelectionReader {
    private static let focusAttempts = 3
    private static let focusRetryDelay: TimeInterval = 0.05

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static func readFocusedSelection() -> Result<String, AccessibilitySelectionError> {
        guard isTrusted else { return .failure(.permissionRequired) }

        let system = AXUIElementCreateSystemWide()
        let sourceApplication = NSWorkspace.shared.frontmostApplication
        let applicationRoot = sourceApplication.map {
            AXUIElementCreateApplication(pid_t($0.processIdentifier))
        }
        var foundSelectedTextAttribute = false
        var latestError: AXError?
        var diagnostics = CaptureDiagnostics(
            sourceBundle: sourceApplication?.bundleIdentifier ?? "nil"
        )

        // Chromium deliberately keeps parts of its accessibility support
        // disabled until an assistive client asks for the application role.
        // Other apps safely return their ordinary AXApplication role here.
        if let applicationRoot {
            var roleValue: CFTypeRef?
            let roleResult = AXUIElementCopyAttributeValue(
                applicationRoot,
                kAXRoleAttribute as CFString,
                &roleValue
            )
            diagnostics.activation = "\(roleResult.rawValue):\(roleValue != nil)"
        }

        for attempt in 0..<focusAttempts {
            var focusedElements: [AXUIElement] = []
            if let element = focusedElement(
                from: system,
                label: "system\(attempt + 1)",
                latestError: &latestError,
                diagnostics: &diagnostics
            ) {
                focusedElements.append(element)
            }
            // The system-wide focused element can temporarily be absent even
            // though the frontmost application exposes its focus.
            if let applicationRoot,
               let element = focusedElement(
                   from: applicationRoot,
                   label: "app\(attempt + 1)",
                   latestError: &latestError,
                   diagnostics: &diagnostics
               ) {
                focusedElements.append(element)
            }

            for element in focusedElements {
                if let text = selectionInParentChain(
                    from: element,
                    foundSelectedTextAttribute: &foundSelectedTextAttribute,
                    latestError: &latestError,
                    diagnostics: &diagnostics
                ) {
                    return .success(text)
                }
            }

            guard attempt + 1 < focusAttempts,
                  latestError == .noValue || latestError == .cannotComplete else { break }
            Thread.sleep(forTimeInterval: focusRetryDelay)
        }

        if let applicationRoot {
            var focusedWindowValue: CFTypeRef?
            let focusedWindowResult = AXUIElementCopyAttributeValue(
                applicationRoot,
                kAXFocusedWindowAttribute as CFString,
                &focusedWindowValue
            )
            diagnostics.focusedWindow = "\(focusedWindowResult.rawValue):\(focusedWindowValue != nil)"
            if focusedWindowResult == .success,
               let focusedWindowValue,
               CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID(),
               let text = selectedText(
                   in: unsafeBitCast(focusedWindowValue, to: AXUIElement.self),
                   latestError: &latestError,
                   diagnostics: &diagnostics
               ) {
                return .success(text)
            }
        }

        // Do not make the tree fallback conditional on the global focus lookup.
        // A transient missing focus is the reason this fallback is needed.
        if let applicationRoot,
           let text = selectedText(
               in: applicationRoot,
               latestError: &latestError,
               diagnostics: &diagnostics
           ) {
            return .success(text)
        }
        let trace = diagnostics.summary
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-axtrace.log")
        try? trace.write(to: traceURL, atomically: true, encoding: .utf8)
        return .failure(foundSelectedTextAttribute
            ? .noSelectedText(trace)
            : .unavailable(latestError, trace))
    }

    private static func focusedElement(
        from root: AXUIElement,
        label: String,
        latestError: inout AXError?,
        diagnostics: inout CaptureDiagnostics
    ) -> AXUIElement? {
        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            root,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        diagnostics.focus.append("\(label)=\(result.rawValue):\(focusedValue != nil)")
        guard result == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            latestError = result
            return nil
        }
        return unsafeBitCast(focusedValue, to: AXUIElement.self)
    }

    /// Safari, Firefox, and Zen can focus a web-content child while keeping
    /// the actual selection on its enclosing HTML/web area.
    private static func selectionInParentChain(
        from focusedElement: AXUIElement,
        foundSelectedTextAttribute: inout Bool,
        latestError: inout AXError?,
        diagnostics: inout CaptureDiagnostics
    ) -> String? {
        var element = focusedElement
        for _ in 0..<8 {
            switch selectedText(from: element, diagnostics: &diagnostics) {
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

    /// Browsers may expose a selected range on a web-area sibling instead of
    /// the focused element's parent chain. This visits accessibility elements
    /// only and asks only for their selected text, never page text or clipboard
    /// data. The bound keeps a malformed accessibility tree from slowing Flow.
    private static func selectedText(
        in root: AXUIElement,
        latestError: inout AXError?,
        diagnostics: inout CaptureDiagnostics
    ) -> String? {
        var remainingElements = 600
        let text = selectedText(
            in: root,
            remainingElements: &remainingElements,
            latestError: &latestError,
            diagnostics: &diagnostics
        )
        diagnostics.remainingElements = remainingElements
        return text
    }

    private static func selectedText(
        in element: AXUIElement,
        remainingElements: inout Int,
        latestError: inout AXError?,
        diagnostics: inout CaptureDiagnostics,
    ) -> String? {
        guard remainingElements > 0 else { return nil }
        remainingElements -= 1
        diagnostics.visitedElements += 1

        switch selectedText(from: element, diagnostics: &diagnostics) {
        case .text(let text):
            return text
        case .unavailable(let error):
            latestError = error
        case .empty:
            break
        }

        var childrenValue: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue,
        )
        diagnostics.childrenResults[childrenResult.rawValue, default: 0] += 1
        guard childrenResult == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let text = selectedText(
                in: child,
                remainingElements: &remainingElements,
                latestError: &latestError,
                diagnostics: &diagnostics
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

    private static func selectedText(
        from element: AXUIElement,
        diagnostics: inout CaptureDiagnostics
    ) -> SelectedTextResult {
        var selectedValue: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedValue,
        )
        diagnostics.selectedResults[selectedResult.rawValue, default: 0] += 1
        if selectedResult == .success {
            let result = textResult(selectedValue as? String)
            if case .empty = result {
                diagnoseMarkerAfterEmptySelection(from: element, diagnostics: &diagnostics)
            }
            return result
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
        diagnostics.markerResults[markerResult.rawValue, default: 0] += 1
        guard markerResult == .success,
              let markerRange else {
            return .unavailable(markerResult)
        }
        var textValue: CFTypeRef?
        let markerTextResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
            markerRange,
            &textValue,
        )
        diagnostics.markerTextResults[markerTextResult.rawValue, default: 0] += 1
        guard markerTextResult == .success else {
            return .empty
        }
        return textResult(textValue as? String)
    }

    private static func diagnoseMarkerAfterEmptySelection(
        from element: AXUIElement,
        diagnostics: inout CaptureDiagnostics
    ) {
        var markerRange: CFTypeRef?
        let markerResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextMarkerRangeAttribute as CFString,
            &markerRange
        )
        diagnostics.emptySelectionMarkerResults[markerResult.rawValue, default: 0] += 1
        guard markerResult == .success, let markerRange else { return }

        var textValue: CFTypeRef?
        let textResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
            markerRange,
            &textValue
        )
        diagnostics.emptySelectionMarkerTextResults[textResult.rawValue, default: 0] += 1
        if textResult == .success,
           let text = textValue as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.markerTextFoundAfterEmptySelection += 1
        }
    }

    private struct CaptureDiagnostics {
        let sourceBundle: String
        var activation = "not-attempted"
        var focusedWindow = "not-attempted"
        var focus: [String] = []
        var visitedElements = 0
        var remainingElements = 600
        var selectedResults: [Int32: Int] = [:]
        var markerResults: [Int32: Int] = [:]
        var markerTextResults: [Int32: Int] = [:]
        var emptySelectionMarkerResults: [Int32: Int] = [:]
        var emptySelectionMarkerTextResults: [Int32: Int] = [:]
        var markerTextFoundAfterEmptySelection = 0
        var childrenResults: [Int32: Int] = [:]

        var summary: String {
            "[DEBUG-AXTRACE] source=\(sourceBundle) "
                + "activation=\(activation) "
                + "window=\(focusedWindow) "
                + "focus=\(focus.joined(separator: ",")) "
                + "visited=\(visitedElements) remaining=\(remainingElements) "
                + "selected=\(counts(selectedResults)) marker=\(counts(markerResults)) "
                + "markerText=\(counts(markerTextResults)) "
                + "emptyMarker=\(counts(emptySelectionMarkerResults)) "
                + "emptyMarkerText=\(counts(emptySelectionMarkerTextResults)) "
                + "emptyMarkerFound=\(markerTextFoundAfterEmptySelection) "
                + "children=\(counts(childrenResults))"
        }

        private func counts(_ values: [Int32: Int]) -> String {
            values.keys.sorted().map { "\($0):\(values[$0] ?? 0)" }.joined(separator: ",")
        }
    }

    private static func textResult(_ text: String?) -> SelectedTextResult {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        return .text(text)
    }
}
