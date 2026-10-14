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

/// Display-only policy: recorded titles identify a moment; OCR excerpts explain
/// a match, but never become invented titles or clutter unfiltered browsing.
struct LibraryResultTextPresentation {
    let title: String
    let appContext: String?
    let domainContext: String?
    let cleanedSnippet: String?
    let excerpt: String?
    let matches: [Range<String.Index>]

    init(
        title: String?,
        appLabel: String,
        domain: String?,
        snippet: String?,
        allowsUnmarkedExcerpt: Bool
    ) {
        let recordedTitle = SearchSnippet.parse(title)?.text
        let displayTitle = recordedTitle ?? appLabel
        self.title = displayTitle
        appContext = Self.same(displayTitle, appLabel) ? nil : appLabel
        let site = SearchSnippet.parse(domain)?.text
        domainContext = site.flatMap { Self.same(displayTitle, $0) ? nil : $0 }

        let parsed = SearchSnippet.parse(snippet)
        cleanedSnippet = parsed?.text
        // FTS can return the title itself, or its truncated prefix, as the
        // snippet. Neither provides information beyond the existing identity.
        if let parsed,
            allowsUnmarkedExcerpt || !parsed.matches.isEmpty,
            !Self.repeatsIdentity(parsed.text, identities: [self.title, appLabel, site].compactMap { $0 })
        {
            excerpt = parsed.text
            matches = parsed.matches
        } else {
            excerpt = nil
            matches = []
        }
    }

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static func repeatsIdentity(_ text: String, identities: [String]) -> Bool {
        let content = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{2026} ."))
        guard !content.isEmpty else { return true }
        return identities.contains {
            $0.range(of: content, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
