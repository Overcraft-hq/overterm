import Foundation

/// Text shown so that nothing in it is out of sight.
package enum VisibleText {
    /// What a write's confirmation shows: every character visible — a
    /// control character or a direction override as its code, a long run
    /// of blank space said as such — so nothing that runs is out of sight.
    /// Pure, for any queue: Activity's text for agents is made off the
    /// main thread.
    package nonisolated static func displayed(_ text: String) -> String {
        var out = ""
        var blank = ""
        func flushBlank() {
            if blank.count > 4 {
                let lines = blank.filter(\.isNewline).count
                out += lines > 0 ? " ⟨\(blank.count) blank characters, \(lines) line breaks⟩ " : " ⟨\(blank.count) spaces⟩ "
            } else {
                out += blank
            }
            blank = ""
        }
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\n" || scalar == "\t" {
                blank.unicodeScalars.append(scalar)
                continue
            }
            flushBlank()
            let hidden =
                scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
                || (0x2028...0x2029).contains(scalar.value)
            out += hidden ? "\\u{\(String(scalar.value, radix: 16, uppercase: true))}" : String(scalar)
        }
        flushBlank()
        return out
    }
}
