import AppKit
import ApplicationServices

enum AccessibilitySelectionError: Error {
    case permissionRequired
    case noSelectedText
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

    /// Browsers defer building their full accessibility tree until an
    /// assistive client asks for the application's role. Preparing an app when
    /// it becomes active ensures its selection events are observed before the
    /// user invokes Flow.
    @discardableResult
    static func prepare(_ application: NSRunningApplication?, reason: String = "capture") -> Bool {
        guard isTrusted,
              let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
#if DEBUG
            DebugAXTrace.record("prepare_skipped", fields: [
                "reason": reason,
                "trusted": "\(isTrusted)",
                "has_app": "\(application != nil)",
            ])
#endif
            return false
        }

        let root = AXUIElementCreateApplication(pid_t(application.processIdentifier))
        var enhancedBefore: CFTypeRef?
        let enhancedBeforeResult = AXUIElementCopyAttributeValue(
            root,
            "AXEnhancedUserInterface" as CFString,
            &enhancedBefore
        )
        var roleValue: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            root,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        // Firefox-family apps, including Zen, can return the application role
        // before their web-content accessibility tree is fully enabled.
        let enhancedSetResult = AXUIElementSetAttributeValue(
            root,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        var enhancedAfter: CFTypeRef?
        let enhancedAfterResult = AXUIElementCopyAttributeValue(
            root,
            "AXEnhancedUserInterface" as CFString,
            &enhancedAfter
        )

        // Enabling the flag permits accessibility, but Firefox-family apps do
        // not instantiate their web-content objects until a client also asks
        // for the active tree. These queries contain no text values.
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
#if DEBUG
        DebugAXTrace.record("prepare", fields: [
            "reason": reason,
            "pid": "\(application.processIdentifier)",
            "bundle": application.bundleIdentifier ?? "nil",
            "enhanced_before_result": "\(enhancedBeforeResult.rawValue)",
            "enhanced_before": String(describing: enhancedBefore),
            "role_result": "\(roleResult.rawValue)",
            "role": String(describing: roleValue),
            "enhanced_set_result": "\(enhancedSetResult.rawValue)",
            "enhanced_after_result": "\(enhancedAfterResult.rawValue)",
            "enhanced_after": String(describing: enhancedAfter),
            "focused_result": "\(focusedResult.rawValue)",
            "focused_present": "\(focusedValue != nil)",
            "children_result": "\(childrenResult.rawValue)",
            "children_count": "\((childrenValue as? [AXUIElement])?.count ?? -1)",
        ])
#endif
        return roleResult == .success && focusedResult == .success && childrenResult == .success
    }

    static func prepareFrontmostApplication(reason: String = "frontmost") {
        prepare(NSWorkspace.shared.frontmostApplication, reason: reason)
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
        var diagnostics = CaptureDiagnostics()
#if DEBUG
        let captureID = UUID().uuidString
        DebugAXTrace.record("capture_started", fields: [
            "capture_id": captureID,
            "pid": "\(sourceApplication?.processIdentifier ?? -1)",
            "bundle": sourceApplication?.bundleIdentifier ?? "nil",
        ])
#endif

        // Also prepare here in case Flow missed the activation notification.
        prepare(sourceApplication, reason: "capture")

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
#if DEBUG
                    recordCapture(
                        id: captureID,
                        result: "success_parent",
                        textLength: text.count,
                        latestError: latestError,
                        diagnostics: diagnostics
                    )
#endif
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
               label: "window",
               latestError: &latestError
           ),
           let text = selectedText(
               in: focusedWindow,
               label: "window",
               latestError: &latestError,
               diagnostics: &diagnostics
           ) {
#if DEBUG
            recordCapture(
                id: captureID,
                result: "success_window",
                textLength: text.count,
                latestError: latestError,
                diagnostics: diagnostics
            )
#endif
            return .success(text)
        }

        // Focus can be temporarily absent while the app tree remains readable.
        if let applicationRoot,
           let text = selectedText(
               in: applicationRoot,
               label: "application",
               latestError: &latestError,
               diagnostics: &diagnostics
           ) {
#if DEBUG
            recordCapture(
                id: captureID,
                result: "success_application",
                textLength: text.count,
                latestError: latestError,
                diagnostics: diagnostics
            )
#endif
            return .success(text)
        }

#if DEBUG
        recordCapture(
            id: captureID,
            result: foundSelectedTextAttribute ? "failure_empty" : "failure_unavailable",
            textLength: 0,
            latestError: latestError,
            diagnostics: diagnostics
        )
#endif
        return .failure(foundSelectedTextAttribute ? .noSelectedText : .unavailable(latestError))
    }

    private static func focusedElement(
        from root: AXUIElement,
        label: String,
        latestError: inout AXError?,
        diagnostics: inout CaptureDiagnostics
    ) -> AXUIElement? {
        let element = elementAttribute(
            from: root,
            attribute: kAXFocusedUIElementAttribute as CFString,
            label: label,
            latestError: &latestError
        )
        if let element {
            diagnostics.focus.append("\(label)=0:true")
            return element
        }
        diagnostics.focus.append("\(label)=\(latestError?.rawValue ?? 0):false")
        return nil
    }

    private static func elementAttribute(
        from element: AXUIElement,
        attribute: CFString,
        label: String? = nil,
        latestError: inout AXError?
    ) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
#if DEBUG
        if let label {
            DebugAXTrace.record("element_attribute", fields: [
                "label": label,
                "attribute": attribute as String,
                "result": "\(result.rawValue)",
                "present": "\(value != nil)",
            ])
        }
#endif
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
        latestError: inout AXError?,
        diagnostics: inout CaptureDiagnostics
    ) -> String? {
        var element = focusedElement
        for _ in 0..<8 {
            diagnostics.parentNodes += 1
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

    /// Browsers can expose a selected range on a web-area sibling instead of
    /// the focused element's parent chain. The bound prevents malformed or
    /// unusually large accessibility trees from stalling Flow.
    private static func selectedText(
        in root: AXUIElement,
        label: String,
        latestError: inout AXError?,
        diagnostics: inout CaptureDiagnostics
    ) -> String? {
        var remainingElements = 600
        let visitedBefore = diagnostics.visitedNodes
        let text = selectedText(
            in: root,
            remainingElements: &remainingElements,
            latestError: &latestError,
            diagnostics: &diagnostics
        )
        diagnostics.scans.append(
            "\(label):visited=\(diagnostics.visitedNodes - visitedBefore):remaining=\(remainingElements):found=\(text != nil)"
        )
        return text
    }

    private static func selectedText(
        in element: AXUIElement,
        remainingElements: inout Int,
        latestError: inout AXError?,
        diagnostics: inout CaptureDiagnostics
    ) -> String? {
        guard remainingElements > 0 else { return nil }
        remainingElements -= 1
        diagnostics.visitedNodes += 1

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
            &childrenValue
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
            &selectedValue
        )
        diagnostics.selectedResults[selectedResult.rawValue, default: 0] += 1
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
            &textValue
        )
        diagnostics.markerTextResults[markerTextResult.rawValue, default: 0] += 1
        guard markerTextResult == .success else {
            return .empty
        }
        return textResult(textValue as? String)
    }

    private struct CaptureDiagnostics {
        var focus: [String] = []
        var scans: [String] = []
        var parentNodes = 0
        var visitedNodes = 0
        var selectedResults: [Int32: Int] = [:]
        var markerResults: [Int32: Int] = [:]
        var markerTextResults: [Int32: Int] = [:]
        var childrenResults: [Int32: Int] = [:]

        func counts(_ values: [Int32: Int]) -> String {
            values.keys.sorted().map { "\($0):\(values[$0] ?? 0)" }.joined(separator: ",")
        }
    }

#if DEBUG
    private static func recordCapture(
        id: String,
        result: String,
        textLength: Int,
        latestError: AXError?,
        diagnostics: CaptureDiagnostics
    ) {
        DebugAXTrace.record("capture_finished", fields: [
            "capture_id": id,
            "result": result,
            "text_length": "\(textLength)",
            "latest_error": "\(latestError?.rawValue ?? 0)",
            "focus": diagnostics.focus.joined(separator: ","),
            "parent_nodes": "\(diagnostics.parentNodes)",
            "visited_nodes": "\(diagnostics.visitedNodes)",
            "scans": diagnostics.scans.joined(separator: ";"),
            "selected": diagnostics.counts(diagnostics.selectedResults),
            "marker": diagnostics.counts(diagnostics.markerResults),
            "marker_text": diagnostics.counts(diagnostics.markerTextResults),
            "children": diagnostics.counts(diagnostics.childrenResults),
        ])
    }
#endif

    private static func textResult(_ text: String?) -> SelectedTextResult {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        return .text(text)
    }
}
