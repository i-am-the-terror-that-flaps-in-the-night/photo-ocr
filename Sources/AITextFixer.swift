import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional correction of recognized text with the language model that ships
/// with macOS 26 and later (Apple Intelligence). The model runs on the Mac;
/// nothing is sent over the network.
///
/// The text is corrected in parts of a few sentences each, one after another.
/// Measured on a photographed two-page worksheet: the system model answers
/// one request at a time, so running parts in parallel saves nothing, while
/// smaller parts show the first result about twice as soon for the same
/// total time. Parts with nothing to fix are passed through without asking
/// the model, which is where most of the time is saved on clean text.
///
/// A part is kept as it was if the model fails on it or returns something
/// that is clearly not a correction (much shorter or longer than the input).
enum AITextFixer {
    struct Part: Sendable {
        let text: String
        /// False if the part has nothing for the model to fix.
        let needsFixing: Bool
    }

    struct Result: Sendable {
        let text: String
        /// Parts the model was asked to fix.
        let partsSent: Int
        /// Of those, parts it could not fix and that were left unchanged.
        let partsLeftUnchanged: Int
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

    /// Target characters per part. Parts end at the end of a sentence where
    /// possible, so the model never sees half a sentence and finishes it.
    private static let partLength = 600
    /// Hard limit; a part is cut here even in the middle of a sentence.
    private static let maximumPartLength = 1000
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
    reorder, translate, explain or add anything. If you cannot tell what a word was, \
    leave it as it is. Keep names, numbers and dates as they are. \
    Reply with the corrected text only.
    """

    /// Splits text into parts of whole lines, preferring to end each part
    /// where a sentence ends: a line ending in punctuation, or a line followed
    /// by one that starts with a capital letter (OCR often drops the period).
    static func split(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var parts: [String] = []
        var current: [String] = []
        var length = 0
        for (index, line) in lines.enumerated() {
            if length + line.count > maximumPartLength, !current.isEmpty {
                parts.append(current.joined(separator: "\n"))
                current = []
                length = 0
            }
            current.append(line)
            length += line.count + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            let endsSentence = trimmed.isEmpty
                || trimmed.last.map { ".!?:".contains($0) } == true
                || next.first?.isUppercase == true
            if length >= partLength && endsSentence {
                parts.append(current.joined(separator: "\n"))
                current = []
                length = 0
            }
        }
        if !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts
    }

    /// Corrects the parts one after another. `update` is called with the text
    /// so far (corrected parts, the part being written, then the untouched
    /// rest) as the model writes, and with the part number being worked on.
    /// Checks for task cancellation between parts.
    static func fix(
        _ parts: [Part],
        update: @escaping @Sendable (_ text: String, _ partNumber: Int, _ partsToSend: Int) -> Void
    ) async throws -> Result {
        let toSend = parts.filter(\.needsFixing).count
        var done: [String] = []
        var sent = 0
        var unchanged = 0

        func rest(after index: Int) -> [String] {
            Array(parts[(index + 1)...].map(\.text))
        }

        for (index, part) in parts.enumerated() {
            guard part.needsFixing else {
                done.append(part.text)
                continue
            }
            try Task.checkCancellation()
            sent += 1
            let before = done
            let fixed = await fixPart(part.text) { partial in
                update((before + [partial] + rest(after: index)).joined(separator: "\n"), sent, toSend)
            }
            if let fixed {
                done.append(fixed)
            } else {
                done.append(part.text)
                unchanged += 1
            }
            update((done + rest(after: index)).joined(separator: "\n"), sent, toSend)
        }
        try Task.checkCancellation()
        return Result(text: done.joined(separator: "\n"), partsSent: sent, partsLeftUnchanged: unchanged)
    }

    /// Returns the corrected part, or nil if it should be left as it is.
    /// `partial` receives the answer as the model writes it.
    private static func fixPart(_ part: String, partial: @escaping (String) -> Void) async -> String? {
        let wordsIn = wordCount(part)
        guard wordsIn > 0 else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // A new session per part: parts are independent, and a fresh
            // session keeps each request well inside the context window.
            let session = LanguageModelSession(instructions: instructions)
            let stream = session.streamResponse(to: part, options: GenerationOptions(temperature: 0))
            var latest = ""
            do {
                for try await snapshot in stream {
                    if Task.isCancelled { return nil }
                    latest = snapshot.content
                    partial(latest)
                }
            } catch {
                return nil
            }

            let fixed = latest
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
