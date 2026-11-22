import Foundation

/// A Redis command line's words, as redis-cli splits them. Pure.
package enum RedisCommandLine {
    package struct Malformed: Error {
        package var reason: String
    }

    /// A command line as redis-cli splits it: words, "double quotes" with
    /// \n \t \" \\ \xHH, 'single quotes' with \' only.
    package static func words(_ line: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        let chars = Array(line)
        var i = 0
        func hex(_ c: Character) -> UInt8? { c.hexDigitValue.map(UInt8.init) }
        while i < chars.count {
            let c = chars[i]
            if c == "\"" || c == "'" {
                let quote = c
                inWord = true
                i += 1
                var closed = false
                while i < chars.count {
                    let d = chars[i]
                    if d == quote {
                        closed = true
                        i += 1
                        break
                    }
                    if d == "\\", i + 1 < chars.count {
                        let e = chars[i + 1]
                        if quote == "'" {
                            if e == "'" {
                                current.append("'")
                                i += 2
                                continue
                            }
                        } else {
                            switch e {
                            case "n": current.append("\n")
                            case "r": current.append("\r")
                            case "t": current.append("\t")
                            case "x" where i + 3 < chars.count:
                                if let high = hex(chars[i + 2]), let low = hex(chars[i + 3]) {
                                    current.unicodeScalars.append(UnicodeScalar(high << 4 | low))
                                    i += 4
                                    continue
                                }
                                current.append(e)
                            default: current.append(e)
                            }
                            i += 2
                            continue
                        }
                    }
                    current.append(d)
                    i += 1
                }
                guard closed else { throw Malformed(reason: "unbalanced quotes") }
                // A closing quote must end the word, as redis-cli has it.
                if i < chars.count, !chars[i].isWhitespace { throw Malformed(reason: "closing quote must be followed by a space") }
                continue
            }
            if c.isWhitespace {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            } else {
                current.append(c)
                inWord = true
            }
            i += 1
        }
        if inWord { words.append(current) }
        return words
    }
}
