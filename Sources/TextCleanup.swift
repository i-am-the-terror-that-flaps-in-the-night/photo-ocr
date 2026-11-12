import AppKit
import NaturalLanguage

/// Optional clean-up of recognized text: repairs words the recognizer misread
/// and removes stray marks that a page border left at the ends of lines.
/// Everything runs on-device with the spell checker that ships with macOS.
///
/// The clean-up is deliberately conservative: when in doubt it leaves text as
/// it was, because a wrong real word is harder to spot than a broken one.
/// - Words are only repaired in English text, and only in plain words (not in
///   links, e-mail addresses, file paths, code or anything with digits).
/// - A word is left alone if any English dictionary on the Mac knows it.
/// - A replacement must be the same word with one letter the recognizer
///   dropped or confused, must itself be spelled correctly, and must be the
///   only such suggestion or the spell checker's own first choice.
/// - Marks at line ends are only removed when they repeat down the page, the
///   way a border does, and never when they are plain numbers.
enum TextCleanup {
    struct Result {
        let text: String
        /// Number of words replaced plus stray marks removed.
        let changes: Int
    }

    private static let primaryLanguage = "en_US"
    private static let minimumWordLength = 4
    /// At most this many letters may have been dropped from a word.
    private static let maximumInsertedLetters = 1
    /// Stray marks are removed only if at least this many lines end in them.
    private static let minimumLinesWithBorderMarks = 3

    static func cleanUp(_ text: String) -> Result {
        // Keep "\r" of CRLF line endings out of the way and put it back after.
        var lines = text.components(separatedBy: "\n").map { line -> (body: String, ending: String) in
            line.hasSuffix("\r") ? (String(line.dropLast()), "\r") : (line, "")
        }
        var changes = 0

        // Stray border marks.
        let trimmed = lines.map { removingStrayMarks(from: $0.body) }
        if trimmed.filter({ $0.removed > 0 }).count >= minimumLinesWithBorderMarks {
            for index in lines.indices where trimmed[index].removed > 0 {
                lines[index].body = trimmed[index].text
                changes += trimmed[index].removed
            }
        }

        // Misread words, in English text only.
        if isEnglish(text) {
            var repairer = WordRepairer()
            for index in lines.indices {
                let (repaired, replaced) = repairer.repairingWords(in: lines[index].body)
                lines[index].body = repaired
                changes += replaced
            }
        }

        return Result(text: lines.map { $0.body + $0.ending }.joined(separator: "\n"), changes: changes)
    }

    /// True unless the text is clearly in a language other than English.
    private static func isEnglish(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else {
            return true
        }
        return language == .english || confidence < 0.6
    }

    // MARK: Stray marks

    private static let strongMarks: Set<Character> = ["•", "°", "·"]
    private static let quoteMarks: Set<Character> = ["\"", "“", "”", "!"]
    private static let lookAlikes: Set<Character> = ["o", "O", "0", "1", "I", "l"]

    /// Removes the run of border-mark tokens at the end of a line, together
    /// with the whitespace before it. Returns the line unchanged (and 0) if
    /// there is none, or if removing it would leave the line empty.
    private static func removingStrayMarks(from line: String) -> (text: String, removed: Int) {
        var end = line.endIndex
        var removed = 0
        while true {
            // Skip whitespace (spaces, tabs, non-breaking spaces) backwards.
            var tokenEnd = end
            while tokenEnd > line.startIndex, line[line.index(before: tokenEnd)].isWhitespace {
                tokenEnd = line.index(before: tokenEnd)
            }
            var tokenStart = tokenEnd
            while tokenStart > line.startIndex, !line[line.index(before: tokenStart)].isWhitespace {
                tokenStart = line.index(before: tokenStart)
            }
            guard tokenStart < tokenEnd, isBorderMark(line[tokenStart..<tokenEnd]) else { break }
            // Keep at least one real token on the line.
            let rest = line[line.startIndex..<tokenStart]
            guard rest.contains(where: { !$0.isWhitespace }) else { break }
            end = tokenStart
            removed += 1
        }
        guard removed > 0 else { return (line, 0) }
        var text = String(line[line.startIndex..<end])
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return (text, removed)
    }

    /// A short token made only of border-like characters: a lone "o", quote or
    /// exclamation marks, or look-alikes of a dotted line such as "1•" or "01•".
    /// Plain numbers never count.
    private static func isBorderMark(_ token: Substring) -> Bool {
        guard token.count <= 3 else { return false }
        if token == "o" { return true }
        guard token.allSatisfy({ strongMarks.contains($0) || quoteMarks.contains($0) || lookAlikes.contains($0) })
        else { return false }
        if token.contains(where: { strongMarks.contains($0) }) { return true }
        return token.allSatisfy { quoteMarks.contains($0) }
    }

    // MARK: Words

    private struct WordRepairer {
        private let checker = NSSpellChecker.shared
        /// English dictionaries on this Mac besides the primary one; a word
        /// any of them knows (British spelling, for example) is left alone.
        private let otherEnglish = NSSpellChecker.shared.availableLanguages
            .filter { $0.hasPrefix("en") && $0 != TextCleanup.primaryLanguage }
        /// Decisions per word, so repeated words cost one lookup.
        private var cache: [String: String?] = [:]

        mutating func repairingWords(in line: String) -> (String, Int) {
            var result = ""
            var replaced = 0
            var tokenStart: String.Index?
            // Walk whitespace-separated tokens, keeping the whitespace as is.
            for index in line.indices {
                if line[index].isWhitespace {
                    if let start = tokenStart {
                        replaced += append(line[start..<index], to: &result)
                        tokenStart = nil
                    }
                    result.append(line[index])
                } else if tokenStart == nil {
                    tokenStart = index
                }
            }
            if let start = tokenStart {
                replaced += append(line[start..<line.endIndex], to: &result)
            }
            return (result, replaced)
        }

        /// Appends a token, repairing the words in it if it is plain text.
        /// Returns the number of words replaced.
        private mutating func append(_ token: Substring, to result: inout String) -> Int {
            guard isPlainText(token) else {
                result += token
                return 0
            }
            let source = String(token) as NSString
            let pattern = try! NSRegularExpression(pattern: "\\p{L}+(?:['’]\\p{L}+)*")
            var replaced = 0
            var cursor = 0
            for match in pattern.matches(in: String(token), range: NSRange(location: 0, length: source.length)) {
                result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let word = source.substring(with: match.range)
                if let replacement = replacement(for: word) {
                    result += replacement
                    replaced += 1
                } else {
                    result += word
                }
                cursor = match.range.location + match.range.length
            }
            result += source.substring(from: cursor)
            return replaced
        }

        /// False for links, e-mail addresses, paths, code, identifiers and
        /// anything containing digits: those are left exactly as they are.
        private func isPlainText(_ token: Substring) -> Bool {
            let technical: Set<Character> = ["@", "/", "\\", "_", "=", ":", "#", "`", "<", ">", "{", "}", "[", "]", "~", "|", "+", "*", "%", "&", "$", "^"]
            if token.contains(where: { technical.contains($0) || $0.isNumber }) { return false }
            // A dot inside the token (not at its end) means a domain or file name.
            let inner = token.dropLast().drop(while: { !$0.isLetter })
            if inner.contains(".") { return false }
            // Leading dashes are command-line flags.
            if token.hasPrefix("-") { return false }
            // camelCase and similar.
            var previousWasLower = false
            for character in token {
                if character.isUppercase && previousWasLower { return false }
                previousWasLower = character.isLowercase
            }
            return true
        }

        private mutating func replacement(for word: String) -> String? {
            guard word.count >= TextCleanup.minimumWordLength else { return nil }
            if let cached = cache[word] { return cached }
            let decision = decide(word)
            cache[word] = decision
            return decision
        }

        private func isCorrect(_ word: String, in language: String) -> Bool {
            checker.checkSpelling(
                of: word, startingAt: 0, language: language, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            ).location == NSNotFound
        }

        private func decide(_ word: String) -> String? {
            let language = TextCleanup.primaryLanguage
            guard !isCorrect(word, in: language) else { return nil }
            if otherEnglish.contains(where: { isCorrect(word, in: $0) }) { return nil }

            let range = NSRange(location: 0, length: (word as NSString).length)
            let firstChoice = checker.correction(
                forWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0
            )
            var candidates: [String] = firstChoice.map { [$0] } ?? []
            candidates += (checker.guesses(
                forWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0
            ) ?? []).prefix(5)

            var plausible: [String] = []
            for candidate in candidates
            where isPlausibleRepair(of: word, candidate: candidate)
                && !plausible.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame })
                && isCorrect(candidate, in: language) {
                plausible.append(candidate)
            }
            if plausible.count == 1 { return plausible[0] }
            // Several fit: only trust the spell checker's own first choice.
            if let firstChoice, plausible.first == firstChoice { return firstChoice }
            return nil
        }

        /// True if `candidate` could be `word` with a letter dropped by the
        /// recognizer, either as written or after undoing the usual shape
        /// confusions (ri→n, rn→m, y→u). Adding only an apostrophe does not
        /// count: that is a different word, not a misread one.
        private func isPlausibleRepair(of word: String, candidate: String) -> Bool {
            guard candidate.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }),
                  candidate.caseInsensitiveCompare(word) != .orderedSame
            else { return false }
            let plainWord = plain(word), plainCandidate = plain(candidate)
            if plainCandidate.filter({ $0 != "'" }) == plainWord.filter({ $0 != "'" }) { return false }
            return isSubsequence(plainWord, of: plainCandidate)
                || isSubsequence(shape(of: plainWord), of: shape(of: plainCandidate))
        }

        /// True if `short` appears in `long` in order, with at most
        /// `maximumInsertedLetters` extra letters in `long`.
        private func isSubsequence(_ short: String, of long: String) -> Bool {
            let from = Array(short), to = Array(long)
            let inserted = to.count - from.count
            guard inserted >= 0, inserted <= TextCleanup.maximumInsertedLetters else { return false }
            var index = 0
            for character in to where index < from.count && character == from[index] {
                index += 1
            }
            return index == from.count
        }

        private func plain(_ word: String) -> String {
            word.lowercased().replacingOccurrences(of: "’", with: "'")
        }

        /// Reduces a word to the shapes the recognizer tends to see.
        private func shape(of word: String) -> String {
            word.replacingOccurrences(of: "rn", with: "m")
                .replacingOccurrences(of: "ri", with: "n")
                .replacingOccurrences(of: "y", with: "u")
        }
    }
}
