import SwiftUI
import AppKit

/// Bridges the AppKit terminal view into SwiftUI.
struct TerminalView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> TerminalNSView {
        TerminalNSView(session: session)
    }

    func updateNSView(_ nsView: TerminalNSView, context: Context) {}
}

/// Draws a `TerminalBuffer` and forwards keyboard input to the shell.
final class TerminalNSView: NSView {
    private let session: TerminalSession
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private let cellSize: CGSize
    private let padding: CGFloat = 6

    private let defaultForeground = NSColor(white: 0.9, alpha: 1)
    private let defaultBackground = NSColor(white: 0.1, alpha: 1)

    /// The current text selection, stored as boundaries between cells in reading order
    /// (`row * columns + column`). The anchor is where the drag started; the head follows the mouse.
    private var selection: (anchor: Int, head: Int)?

    /// The selected cells as a half-open range of linear cell indices, or `nil` if nothing is selected.
    private var selectedRange: Range<Int>? {
        guard let selection, selection.anchor != selection.head else { return nil }
        return min(selection.anchor, selection.head)..<max(selection.anchor, selection.head)
    }

    init(session: TerminalSession) {
        self.session = session
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        cellSize = CGSize(width: width, height: ceil(font.ascender - font.descender + font.leading))
        super.init(frame: .zero)
        session.onUpdate = { [weak self] in
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.makeFirstResponder(self)
        updateGridSize()
        session.start()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridSize()
    }

    private func updateGridSize() {
        let columns = max(Int((bounds.width - padding * 2) / cellSize.width), 2)
        let rows = max(Int((bounds.height - padding * 2) / cellSize.height), 2)
        if columns != session.buffer.columns || rows != session.buffer.rows {
            // Selection boundaries depend on the grid width, so they're invalid after a resize.
            selection = nil
        }
        session.resize(columns: columns, rows: rows)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        defaultBackground.setFill()
        bounds.fill()

        let buffer = session.buffer
        for (row, line) in buffer.lines.enumerated() {
            let y = padding + CGFloat(row) * cellSize.height

            // Draw the line in runs of identically-styled cells.
            var runStart = 0
            while runStart < line.count {
                let runAttributes = line[runStart].attributes
                var runEnd = runStart + 1
                while runEnd < line.count, line[runEnd].attributes == runAttributes {
                    runEnd += 1
                }

                let (foreground, background) = colors(for: runAttributes)
                let runRect = NSRect(
                    x: padding + CGFloat(runStart) * cellSize.width,
                    y: y,
                    width: CGFloat(runEnd - runStart) * cellSize.width,
                    height: cellSize.height
                )
                if background != defaultBackground {
                    background.setFill()
                    runRect.fill()
                }

                let text = String(line[runStart..<runEnd].map(\.character))
                if !text.allSatisfy({ $0 == " " }) {
                    let attributed = NSAttributedString(string: text, attributes: [
                        .font: runAttributes.isBold ? boldFont : font,
                        .foregroundColor: foreground,
                    ])
                    attributed.draw(at: runRect.origin)
                }
                runStart = runEnd
            }
        }

        if let range = selectedRange {
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.5).setFill()
            for row in (range.lowerBound / buffer.columns)...((range.upperBound - 1) / buffer.columns) {
                let rowStart = row * buffer.columns
                let startColumn = max(range.lowerBound - rowStart, 0)
                let endColumn = min(range.upperBound - rowStart, buffer.columns)
                NSRect(
                    x: padding + CGFloat(startColumn) * cellSize.width,
                    y: padding + CGFloat(row) * cellSize.height,
                    width: CGFloat(endColumn - startColumn) * cellSize.width,
                    height: cellSize.height
                ).fill(using: .sourceOver)
            }
        }

        if buffer.isCursorVisible {
            let cursorRect = NSRect(
                x: padding + CGFloat(buffer.cursorColumn) * cellSize.width,
                y: padding + CGFloat(buffer.cursorRow) * cellSize.height,
                width: cellSize.width,
                height: cellSize.height
            )
            defaultForeground.withAlphaComponent(window?.isKeyWindow == true ? 0.6 : 0.25).setFill()
            cursorRect.fill(using: .sourceOver)
        }
    }

    private func colors(for attributes: TerminalAttributes) -> (foreground: NSColor, background: NSColor) {
        var foregroundColor = attributes.foreground
        // Bold text uses the bright variant of the standard colors, like most terminals.
        if attributes.isBold, case .indexed(let index) = foregroundColor, index < 8 {
            foregroundColor = .indexed(index + 8)
        }
        let foreground = nsColor(for: foregroundColor) ?? defaultForeground
        let background = nsColor(for: attributes.background) ?? defaultBackground
        return attributes.isInverse ? (background, foreground) : (foreground, background)
    }

    private func nsColor(for color: TerminalColor) -> NSColor? {
        switch color {
        case .default:
            return nil
        case .rgb(let red, let green, let blue):
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        case .indexed(let index):
            return Self.paletteColor(index)
        }
    }

    private static let ansiPalette: [(Int, Int, Int)] = [
        (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
        (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
        (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
        (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
    ]

    /// Maps an xterm 256-color palette index to a color.
    private static func paletteColor(_ index: Int) -> NSColor {
        let rgb: (Int, Int, Int)
        switch index {
        case 0..<16:
            rgb = ansiPalette[index]
        case 16..<232:
            // 6×6×6 color cube.
            let cubeIndex = index - 16
            let levels = [0, 95, 135, 175, 215, 255]
            rgb = (levels[cubeIndex / 36], levels[(cubeIndex / 6) % 6], levels[cubeIndex % 6])
        default:
            // Grayscale ramp.
            let level = 8 + (min(index, 255) - 232) * 10
            rgb = (level, level, level)
        }
        return NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
    }

    // MARK: - Selection

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            selectWord(at: point)
        } else {
            let boundary = selectionBoundary(at: point)
            selection = (boundary, boundary)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = selection?.anchor else { return }
        selection = (anchor, selectionBoundary(at: convert(event.locationInWindow, from: nil)))
        needsDisplay = true
    }

    /// Converts a point to the nearest boundary between cells, so dragging across
    /// half of a character is enough to include it.
    private func selectionBoundary(at point: NSPoint) -> Int {
        let buffer = session.buffer
        let row = min(max(Int((point.y - padding) / cellSize.height), 0), buffer.rows - 1)
        let column = min(max(Int(((point.x - padding) / cellSize.width).rounded()), 0), buffer.columns)
        return row * buffer.columns + column
    }

    /// Selects the run of non-whitespace characters under the point.
    private func selectWord(at point: NSPoint) {
        let buffer = session.buffer
        let row = min(max(Int((point.y - padding) / cellSize.height), 0), buffer.rows - 1)
        let column = min(max(Int((point.x - padding) / cellSize.width), 0), buffer.columns - 1)
        let line = buffer.lines[row]
        guard !line[column].character.isWhitespace else {
            selection = nil
            return
        }
        var start = column
        while start > 0, !line[start - 1].character.isWhitespace {
            start -= 1
        }
        var end = column + 1
        while end < line.count, !line[end].character.isWhitespace {
            end += 1
        }
        selection = (row * buffer.columns + start, row * buffer.columns + end)
    }

    private func selectedText() -> String? {
        guard let range = selectedRange else { return nil }
        let buffer = session.buffer
        var lines: [String] = []
        for row in (range.lowerBound / buffer.columns)...((range.upperBound - 1) / buffer.columns) {
            let rowStart = row * buffer.columns
            let startColumn = max(range.lowerBound - rowStart, 0)
            let endColumn = min(range.upperBound - rowStart, buffer.columns)
            var text = String(buffer.lines[row][startColumn..<endColumn].map(\.character))
            // Trailing blank cells are padding, not content.
            while text.last == " " {
                text.removeLast()
            }
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Input

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // As a menu bar–only app there's no Edit menu, so handle ⌘C and ⌘V here.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers {
            case "c" where selectedRange != nil:
                copy(nil)
                return true
            case "v":
                paste(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Let Command shortcuts (Close, Quit, etc.) go through the menu system.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if selection != nil {
            selection = nil
            needsDisplay = true
        }
        guard session.isRunning else {
            session.start()
            return
        }

        if let sequence = escapeSequence(for: event) {
            session.send(sequence)
        } else if let characters = event.characters, !characters.isEmpty {
            // On macOS, `characters` already contains control codes for Control-key combos.
            session.send(characters)
        }
    }

    private func escapeSequence(for event: NSEvent) -> String? {
        // Programs like vim request "application cursor keys", which use ESC O instead of ESC [.
        let cursorPrefix = session.buffer.applicationCursorKeys ? "\u{1B}O" : "\u{1B}["
        switch event.specialKey {
        case .upArrow: return cursorPrefix + "A"
        case .downArrow: return cursorPrefix + "B"
        case .rightArrow: return cursorPrefix + "C"
        case .leftArrow: return cursorPrefix + "D"
        case .home: return cursorPrefix + "H"
        case .end: return cursorPrefix + "F"
        case .pageUp: return "\u{1B}[5~"
        case .pageDown: return "\u{1B}[6~"
        case .deleteForward: return "\u{1B}[3~"
        case .backTab: return "\u{1B}[Z"
        default: return nil
        }
    }

    @objc func paste(_ sender: Any?) {
        guard session.isRunning, let text = NSPasteboard.general.string(forType: .string) else { return }
        if session.buffer.bracketedPasteMode {
            session.send("\u{1B}[200~" + text + "\u{1B}[201~")
        } else {
            session.send(text)
        }
    }
}
