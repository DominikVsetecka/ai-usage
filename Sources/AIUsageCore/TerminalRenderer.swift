import Foundation
import SwiftTerm

private final class HeadlessDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

// Feeds raw PTY output through a proper VT100/ANSI terminal emulator and extracts
// the rendered screen as plain text. This correctly handles cursor movements,
// screen-clear sequences, and partial-line overwrites that a regex-based stripper
// cannot reconstruct.
struct TerminalRenderer {
    private let cols: Int
    private let rows: Int

    init(cols: Int = 160, rows: Int = 50) {
        self.cols = cols
        self.rows = rows
    }

    func render(_ raw: String) -> String {
        let delegate = HeadlessDelegate()
        let options = TerminalOptions(cols: cols, rows: rows, convertEol: true)
        let terminal = Terminal(delegate: delegate, options: options)
        terminal.silentLog = true  // suppress "Info: Unhandled DECSET…" for unknown escape sequences
        terminal.feed(text: raw)
        return extractText(from: terminal)
    }

    private func extractText(from terminal: Terminal) -> String {
        var lines: [String] = []
        for row in 0..<rows {
            guard let line = terminal.getLine(row: row) else {
                lines.append("")
                continue
            }
            var text = ""
            for col in 0..<cols {
                let ch = line[col].getCharacter()
                text.append(ch == "\0" ? " " : ch)
            }
            lines.append(text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\0")))
        }
        return lines
            .reversed()
            .drop(while: { $0.isEmpty })
            .reversed()
            .joined(separator: "\n")
    }
}
