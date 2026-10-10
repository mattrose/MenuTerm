import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut that works no matter which app is frontmost.
///
/// Uses Carbon's hot key API, which doesn't require Accessibility permission.
final class GlobalHotKey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// - Parameters:
    ///   - keyCode: A virtual key code, such as `kVK_Space`.
    ///   - modifiers: Carbon modifier flags, such as `controlKey | optionKey`.
    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hot key events on the main thread.
                MainActor.assumeIsolated {
                    hotKey.action()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x5452_4D4C), id: 1) // 'TRML'
        RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

enum MenuBarPanel {
    /// Opens or closes the menu bar extra's panel, just like clicking its icon.
    ///
    /// SwiftUI doesn't provide a way to present a `MenuBarExtra` programmatically,
    /// so this finds the status item's button in the app's status bar window and clicks it.
    static func toggle() {
        let statusBarWindows = NSApplication.shared.windows.filter {
            $0.className.contains("NSStatusBarWindow")
        }
        guard let button = statusBarWindows.lazy.compactMap({ findButton(in: $0.contentView) }).first else {
            return
        }
        button.performClick(nil)
        NSApplication.shared.activate()
    }

    private static func findButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(in: subview) {
                return button
            }
        }
        return nil
    }
}
