import SwiftUI
import Carbon.HIToolbox

@main struct MenutermApp: App {
    /// Owned by the app so the shell keeps running while the menu bar panel is closed.
    @State private var terminalSession = TerminalSession()

    /// ⌃⌥Space toggles the terminal panel from anywhere.
    private let hotKey = GlobalHotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey) {
        MenuBarPanel.toggle()
    }

    var body: some Scene {
        MenuBarExtra("Terminal", systemImage: "apple.terminal") {
            VStack(spacing: 0) {
                TerminalView(session: terminalSession)

                Divider()

                HStack {
                    Spacer()
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(width: 720, height: 470)
        }
        .menuBarExtraStyle(.window)
    }
}
