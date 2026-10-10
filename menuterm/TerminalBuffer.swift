import Foundation

/// A color as described by the terminal's escape sequences.
enum TerminalColor: Equatable {
    case `default`
    /// An entry in the 256-color xterm palette (0–15 are the standard ANSI colors).
    case indexed(Int)
    case rgb(UInt8, UInt8, UInt8)
}

/// Visual attributes applied to a cell.
struct TerminalAttributes: Equatable {
    var foreground: TerminalColor = .default
    var background: TerminalColor = .default
    var isBold = false
    var isInverse = false
}

/// A single character position on the terminal screen.
struct TerminalCell: Equatable {
    var character: Character = " "
    var attributes = TerminalAttributes()
}

/// A minimal VT100/xterm-compatible screen model.
///
/// Bytes from the shell are fed into `feed(_:)`, which parses control characters and
/// escape sequences and updates the character grid accordingly.
final class TerminalBuffer {
    private(set) var columns: Int
    private(set) var rows: Int
    private(set) var lines: [[TerminalCell]]
    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    private(set) var isCursorVisible = true
    private(set) var applicationCursorKeys = false
    private(set) var bracketedPasteMode = false

    /// Called when the terminal needs to reply to the program (e.g. cursor position reports).
    var onResponse: ((String) -> Void)?

    private enum ParserState {
        case ground, escape, csi, osc, oscEscape, charset
    }

    private var attributes = TerminalAttributes()
    private var pendingWrap = false
    private var scrollTop = 0
    private var scrollBottom: Int
    private var savedCursor = (row: 0, column: 0)
    private var savedMainScreen: [[TerminalCell]]?
    private var state = ParserState.ground
    private var csiParameters: [UInt8] = []
    private var utf8Bytes: [UInt8] = []
    private var utf8ExpectedLength = 0

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        self.scrollBottom = rows - 1
        self.lines = Array(repeating: Array(repeating: TerminalCell(), count: columns), count: rows)
    }

    func reset() {
        lines = Array(repeating: blankLine(), count: rows)
        cursorRow = 0
        cursorColumn = 0
        isCursorVisible = true
        applicationCursorKeys = false
        bracketedPasteMode = false
        attributes = TerminalAttributes()
        pendingWrap = false
        scrollTop = 0
        scrollBottom = rows - 1
        savedCursor = (0, 0)
        savedMainScreen = nil
        state = .ground
        csiParameters.removeAll()
        utf8Bytes.removeAll()
        utf8ExpectedLength = 0
    }

    func feed(_ bytes: [UInt8]) {
        for byte in bytes {
            process(byte)
        }
    }

    func resize(columns newColumns: Int, rows newRows: Int) {
        guard newColumns > 0, newRows > 0, newColumns != columns || newRows != rows else { return }

        // When shrinking vertically, drop lines from the top so the cursor stays on screen.
        let overflow = max(0, cursorRow - (newRows - 1))
        if overflow > 0 {
            lines.removeFirst(overflow)
            cursorRow -= overflow
        }
        lines = Self.resized(lines, columns: newColumns, rows: newRows)
        savedMainScreen = savedMainScreen.map { Self.resized($0, columns: newColumns, rows: newRows) }

        columns = newColumns
        rows = newRows
        cursorRow = min(cursorRow, rows - 1)
        cursorColumn = min(cursorColumn, columns - 1)
        scrollTop = 0
        scrollBottom = rows - 1
        pendingWrap = false
    }

    private static func resized(_ lines: [[TerminalCell]], columns: Int, rows: Int) -> [[TerminalCell]] {
        var result = Array(lines.prefix(rows))
        while result.count < rows {
            result.append(Array(repeating: TerminalCell(), count: columns))
        }
        return result.map { line in
            if line.count >= columns {
                return Array(line.prefix(columns))
            }
            return line + Array(repeating: TerminalCell(), count: columns - line.count)
        }
    }

    // MARK: - Parsing

    private func process(_ byte: UInt8) {
        switch state {
        case .ground:
            processGround(byte)
        case .escape:
            processEscape(byte)
        case .csi:
            switch byte {
            case 0x30...0x3F:
                csiParameters.append(byte)
            case 0x20...0x2F:
                break // Intermediate bytes aren't needed for the sequences we support.
            case 0x40...0x7E:
                state = .ground
                executeCSI(final: byte)
            case 0x1B:
                state = .escape
            case 0x00..<0x20:
                processControl(byte)
            default:
                state = .ground
            }
        case .osc:
            // Operating system commands (window titles, etc.) are consumed and ignored.
            if byte == 0x07 {
                state = .ground
            } else if byte == 0x1B {
                state = .oscEscape
            }
        case .oscEscape:
            if byte == UInt8(ascii: "\\") {
                state = .ground
            } else {
                processEscape(byte)
            }
        case .charset:
            // Character set designations (e.g. ESC ( B) are ignored.
            state = .ground
        }
    }

    private func processGround(_ byte: UInt8) {
        // Continue a multi-byte UTF-8 sequence.
        if utf8ExpectedLength > 0 {
            if byte & 0xC0 == 0x80 {
                utf8Bytes.append(byte)
                if utf8Bytes.count == utf8ExpectedLength {
                    let string = String(decoding: utf8Bytes, as: UTF8.self)
                    utf8Bytes.removeAll()
                    utf8ExpectedLength = 0
                    if let character = string.first {
                        put(character)
                    }
                }
                return
            }
            utf8Bytes.removeAll()
            utf8ExpectedLength = 0
            put("\u{FFFD}")
        }

        switch byte {
        case 0x00..<0x20:
            processControl(byte)
        case 0x7F:
            break
        case 0x20..<0x80:
            put(Character(UnicodeScalar(byte)))
        case 0xC0...0xDF:
            utf8Bytes = [byte]
            utf8ExpectedLength = 2
        case 0xE0...0xEF:
            utf8Bytes = [byte]
            utf8ExpectedLength = 3
        case 0xF0...0xF7:
            utf8Bytes = [byte]
            utf8ExpectedLength = 4
        default:
            put("\u{FFFD}")
        }
    }

    private func processControl(_ byte: UInt8) {
        switch byte {
        case 0x08: // Backspace
            moveCursor(column: cursorColumn - 1)
        case 0x09: // Tab
            moveCursor(column: (cursorColumn / 8 + 1) * 8)
        case 0x0A, 0x0B, 0x0C: // Line feed, vertical tab, form feed
            lineFeed()
        case 0x0D: // Carriage return
            moveCursor(column: 0)
        case 0x1B:
            state = .escape
        default:
            break
        }
    }

    private func processEscape(_ byte: UInt8) {
        state = .ground
        switch byte {
        case UInt8(ascii: "["):
            csiParameters.removeAll()
            state = .csi
        case UInt8(ascii: "]"):
            state = .osc
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"):
            state = .charset
        case UInt8(ascii: "7"):
            saveCursor()
        case UInt8(ascii: "8"):
            restoreCursor()
        case UInt8(ascii: "D"):
            lineFeed()
        case UInt8(ascii: "E"):
            moveCursor(column: 0)
            lineFeed()
        case UInt8(ascii: "M"):
            reverseIndex()
        case UInt8(ascii: "c"):
            reset()
        default:
            break
        }
    }

    private func executeCSI(final: UInt8) {
        var parameterString = String(decoding: csiParameters, as: UTF8.self)
        let isPrivate = parameterString.hasPrefix("?")
        if isPrivate {
            parameterString.removeFirst()
        } else if let first = parameterString.first, "<=>".contains(first) {
            return // Secondary/tertiary queries aren't supported.
        }
        let params = parameterString
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }

        /// Returns the parameter at `index`, treating missing or zero values as `defaultValue`.
        func arg(_ index: Int, _ defaultValue: Int = 1) -> Int {
            index < params.count && params[index] != 0 ? params[index] : defaultValue
        }

        switch Character(UnicodeScalar(final)) {
        case "A":
            moveCursor(row: cursorRow - arg(0))
        case "B", "e":
            moveCursor(row: cursorRow + arg(0))
        case "C", "a":
            moveCursor(column: cursorColumn + arg(0))
        case "D":
            moveCursor(column: cursorColumn - arg(0))
        case "E":
            moveCursor(row: cursorRow + arg(0), column: 0)
        case "F":
            moveCursor(row: cursorRow - arg(0), column: 0)
        case "G", "`":
            moveCursor(column: arg(0) - 1)
        case "d":
            moveCursor(row: arg(0) - 1)
        case "H", "f":
            moveCursor(row: arg(0) - 1, column: arg(1) - 1)
        case "J":
            eraseInDisplay(mode: params.first ?? 0)
        case "K":
            eraseInLine(mode: params.first ?? 0)
        case "L":
            insertLines(arg(0))
        case "M":
            deleteLines(arg(0))
        case "P":
            deleteCharacters(arg(0))
        case "@":
            insertCharacters(arg(0))
        case "X":
            eraseCharacters(arg(0))
        case "S":
            scrollUp(arg(0))
        case "T":
            scrollDown(arg(0))
        case "m":
            selectGraphicRendition(params)
        case "r":
            let top = arg(0) - 1
            let bottom = arg(1, rows) - 1
            if top < bottom, bottom < rows {
                scrollTop = top
                scrollBottom = bottom
            }
            moveCursor(row: 0, column: 0)
        case "h" where isPrivate:
            setPrivateModes(params, enabled: true)
        case "l" where isPrivate:
            setPrivateModes(params, enabled: false)
        case "s":
            saveCursor()
        case "u":
            restoreCursor()
        case "n":
            if params.first == 6 {
                onResponse?("\u{1B}[\(cursorRow + 1);\(cursorColumn + 1)R")
            } else if params.first == 5 {
                onResponse?("\u{1B}[0n")
            }
        case "c":
            onResponse?("\u{1B}[?1;2c")
        default:
            break
        }
    }

    private func setPrivateModes(_ modes: [Int], enabled: Bool) {
        for mode in modes {
            switch mode {
            case 1:
                applicationCursorKeys = enabled
            case 25:
                isCursorVisible = enabled
            case 2004:
                bracketedPasteMode = enabled
            case 47, 1047, 1049:
                // Alternate screen, used by full-screen programs like vim and less.
                if enabled, savedMainScreen == nil {
                    if mode == 1049 { saveCursor() }
                    savedMainScreen = lines
                    lines = Array(repeating: blankLine(), count: rows)
                } else if !enabled, let mainScreen = savedMainScreen {
                    lines = mainScreen
                    savedMainScreen = nil
                    if mode == 1049 { restoreCursor() }
                }
            default:
                break
            }
        }
    }

    private func selectGraphicRendition(_ params: [Int]) {
        guard !params.isEmpty else {
            attributes = TerminalAttributes()
            return
        }

        var index = 0
        while index < params.count {
            let param = params[index]
            switch param {
            case 0:
                attributes = TerminalAttributes()
            case 1:
                attributes.isBold = true
            case 22:
                attributes.isBold = false
            case 7:
                attributes.isInverse = true
            case 27:
                attributes.isInverse = false
            case 30...37:
                attributes.foreground = .indexed(param - 30)
            case 39:
                attributes.foreground = .default
            case 40...47:
                attributes.background = .indexed(param - 40)
            case 49:
                attributes.background = .default
            case 90...97:
                attributes.foreground = .indexed(param - 90 + 8)
            case 100...107:
                attributes.background = .indexed(param - 100 + 8)
            case 38, 48:
                // Extended colors: 38;5;n (256-color) or 38;2;r;g;b (truecolor).
                var color: TerminalColor?
                if index + 2 < params.count, params[index + 1] == 5 {
                    color = .indexed(min(max(params[index + 2], 0), 255))
                    index += 2
                } else if index + 4 < params.count, params[index + 1] == 2 {
                    color = .rgb(
                        UInt8(clamping: params[index + 2]),
                        UInt8(clamping: params[index + 3]),
                        UInt8(clamping: params[index + 4])
                    )
                    index += 4
                }
                if let color {
                    if param == 38 {
                        attributes.foreground = color
                    } else {
                        attributes.background = color
                    }
                }
            default:
                break
            }
            index += 1
        }
    }

    // MARK: - Screen operations

    private func blankCell() -> TerminalCell {
        TerminalCell(character: " ", attributes: TerminalAttributes(background: attributes.background))
    }

    private func blankLine() -> [TerminalCell] {
        Array(repeating: blankCell(), count: columns)
    }

    private func put(_ character: Character) {
        if pendingWrap {
            cursorColumn = 0
            lineFeed()
        }
        lines[cursorRow][cursorColumn] = TerminalCell(character: character, attributes: attributes)
        if cursorColumn == columns - 1 {
            // Defer wrapping until the next character, matching xterm behavior.
            pendingWrap = true
        } else {
            cursorColumn += 1
        }
    }

    private func moveCursor(row: Int? = nil, column: Int? = nil) {
        if let row {
            cursorRow = min(max(row, 0), rows - 1)
        }
        if let column {
            cursorColumn = min(max(column, 0), columns - 1)
        }
        pendingWrap = false
    }

    private func lineFeed() {
        pendingWrap = false
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func reverseIndex() {
        pendingWrap = false
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private func scrollUp(_ count: Int) {
        for _ in 0..<min(count, scrollBottom - scrollTop + 1) {
            lines.remove(at: scrollTop)
            lines.insert(blankLine(), at: scrollBottom)
        }
    }

    private func scrollDown(_ count: Int) {
        for _ in 0..<min(count, scrollBottom - scrollTop + 1) {
            lines.remove(at: scrollBottom)
            lines.insert(blankLine(), at: scrollTop)
        }
    }

    private func insertLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursorRow) else { return }
        for _ in 0..<min(count, scrollBottom - cursorRow + 1) {
            lines.remove(at: scrollBottom)
            lines.insert(blankLine(), at: cursorRow)
        }
        moveCursor(column: 0)
    }

    private func deleteLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursorRow) else { return }
        for _ in 0..<min(count, scrollBottom - cursorRow + 1) {
            lines.remove(at: cursorRow)
            lines.insert(blankLine(), at: scrollBottom)
        }
        moveCursor(column: 0)
    }

    private func insertCharacters(_ count: Int) {
        let count = min(count, columns - cursorColumn)
        lines[cursorRow].insert(contentsOf: Array(repeating: blankCell(), count: count), at: cursorColumn)
        lines[cursorRow].removeLast(count)
        pendingWrap = false
    }

    private func deleteCharacters(_ count: Int) {
        let count = min(count, columns - cursorColumn)
        lines[cursorRow].removeSubrange(cursorColumn..<(cursorColumn + count))
        lines[cursorRow].append(contentsOf: Array(repeating: blankCell(), count: count))
        pendingWrap = false
    }

    private func eraseCharacters(_ count: Int) {
        let end = min(cursorColumn + count, columns)
        for column in cursorColumn..<end {
            lines[cursorRow][column] = blankCell()
        }
        pendingWrap = false
    }

    private func eraseInLine(mode: Int) {
        let range: Range<Int>
        switch mode {
        case 0: range = cursorColumn..<columns
        case 1: range = 0..<(cursorColumn + 1)
        default: range = 0..<columns
        }
        for column in range {
            lines[cursorRow][column] = blankCell()
        }
        pendingWrap = false
    }

    private func eraseInDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseInLine(mode: 0)
            for row in (cursorRow + 1)..<rows {
                lines[row] = blankLine()
            }
        case 1:
            eraseInLine(mode: 1)
            for row in 0..<cursorRow {
                lines[row] = blankLine()
            }
        default:
            lines = Array(repeating: blankLine(), count: rows)
        }
    }

    private func saveCursor() {
        savedCursor = (cursorRow, cursorColumn)
    }

    private func restoreCursor() {
        moveCursor(row: savedCursor.row, column: savedCursor.column)
    }
}
