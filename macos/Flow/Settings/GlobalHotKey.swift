import Carbon
import Foundation

final class GlobalHotKey {
    private static let signature: OSType = 0x464C4F57 // FLOW
    private let binding: HotKeyBinding
    private let action: () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    init(binding: HotKeyBinding, action: @escaping () -> Void) {
        self.binding = binding
        self.action = action
    }

    deinit { invalidate() }

    func register() throws {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                hotKey.action()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler,
        )
        guard handlerStatus == noErr else { throw RegistrationError.failed }

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let registrationStatus = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKey,
        )
        guard registrationStatus == noErr else {
            invalidate()
            throw RegistrationError.failed
        }
    }

    func invalidate() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
    }

    private enum RegistrationError: Error { case failed }
}
