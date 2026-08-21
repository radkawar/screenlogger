import Foundation

/// Parses FTS5 snippet markers without interpreting captured punctuation.
enum SearchSnippet {
    private static let matchStart: Character = "\u{1F}"
    private static let matchEnd: Character = "\u{1E}"

    static func parse(_ raw: String?) -> (text: String, matches: [Range<String.Index>])? {
        guard let raw, !raw.isEmpty else { return nil }

        var text = ""
        text.reserveCapacity(raw.count)
        var matchOffsets: [Range<Int>] = []
        var openOffset: Int?
        var utf16Count = 0
        var lastWasSpace = true

        for character in raw {
            if character == matchStart {
                openOffset = utf16Count
                continue
            }
            if character == matchEnd {
                if let start = openOffset, start < utf16Count {
                    matchOffsets.append(start..<utf16Count)
                }
                openOffset = nil
                continue
            }
            if character.isWhitespace {
                if lastWasSpace { continue }
                text.append(" ")
                utf16Count += 1
                lastWasSpace = true
                continue
            }
            text.append(character)
            utf16Count += character.utf16.count
            lastWasSpace = false
        }

        if text.last == " " {
            text.removeLast()
            utf16Count -= 1
        }
        guard !text.isEmpty else { return nil }

        let matches = matchOffsets.compactMap { offsets -> Range<String.Index>? in
            guard offsets.upperBound <= utf16Count else { return nil }
            let lower = String.Index(utf16Offset: offsets.lowerBound, in: text)
            let upper = String.Index(utf16Offset: offsets.upperBound, in: text)
            return lower < upper ? lower..<upper : nil
        }
        return (text, matches)
    }
}
