import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional correction of recognized text with the language model that ships
/// with macOS 26 and later (Apple Intelligence). The model runs on the Mac;
/// nothing is sent over the network.
///
/// The text is corrected in parts. A part is kept as it was if the model
/// fails on it or returns something that is clearly not a correction (much
/// shorter or longer than what went in).
enum AITextFixer {
    struct Result {
        let text: String
        /// Parts the model could not correct and that were left unchanged.
        let partsLeftUnchanged: Int
        let parts: Int
    }

    /// True if the on-device model exists on this Mac and is ready to use.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Characters per part. Small enough to leave the model room for its
    /// answer, large enough to give it context for each word.
    private static let partLength = 1200
    /// A corrected part may differ from the original by this share of its
    /// word count; beyond that the model has dropped or invented text.
    private static let allowedWordCountChange = 0.2

    private static let instructions = """
    You correct text produced by OCR (optical character recognition) of a printed page. \
    The input has misread words: letters are missing or swapped, for example "goverment" \
    for "government", "Tertory" for "Territory", "wamors" for "warriors". Stray symbols \
    such as "o", "•" or "1•" at the ends of lines come from a decorative border.
    Rules: Fix misread words. Remove stray symbols. Add sentence-ending periods that are \
    missing. Join the lines of a paragraph into one line. Do not rephrase, summarize, \
    reorder, translate, explain or add anything. Keep names, numbers and dates as they are. \
    Reply with the corrected text only.
    """

    /// Corrects `text`. `progress` is called with (parts done, parts in all).
    /// Checks for task cancellation between parts.
    static func fix(_ text: String, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Result {
        let parts = split(text)
        var corrected: [String] = []
        var unchanged = 0
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            progress(index, parts.count)
            if let fixed = await fixPart(part) {
                corrected.append(fixed)
                continue
            }
            // The model sometimes fails on a long part; try it as two halves.
            let lines = part.components(separatedBy: "\n")
            guard lines.count > 1 else {
                corrected.append(part)
                unchanged += 1
                continue
            }
            let halves = [lines[..<(lines.count / 2)], lines[(lines.count / 2)...]]
                .map { $0.joined(separator: "\n") }
            var failed = false
            for half in halves {
                try Task.checkCancellation()
                if let fixed = await fixPart(half) {
                    corrected.append(fixed)
                } else {
                    corrected.append(half)
                    failed = true
                }
            }
            if failed { unchanged += 1 }
        }
        try Task.checkCancellation()
        return Result(text: corrected.joined(separator: "\n"), partsLeftUnchanged: unchanged, parts: parts.count)
    }

    /// Splits text into runs of whole lines of about `partLength` characters.
    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current: [String] = []
        var length = 0
        for line in text.components(separatedBy: "\n") {
            if length + line.count > partLength, !current.isEmpty {
                parts.append(current.joined(separator: "\n"))
                current = []
                length = 0
            }
            current.append(line)
            length += line.count + 1
        }
        if !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts
    }

    /// Returns the corrected part, or nil if it should be left as it is.
    private static func fixPart(_ part: String) async -> String? {
        let wordsIn = wordCount(part)
        guard wordsIn > 0 else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // A new session per part: parts are independent, and a fresh
            // session keeps each request well inside the context window.
            let session = LanguageModelSession(instructions: instructions)
            guard let response = try? await session.respond(
                to: part, options: GenerationOptions(temperature: 0)
            ) else { return nil }

            let lines = response.content
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let fixed = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            let change = abs(Double(wordCount(fixed) - wordsIn)) / Double(wordsIn)
            return change <= allowedWordCountChange ? fixed : nil
        }
        #endif
        return nil
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
