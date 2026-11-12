// Command-line harness for OCRCore.
// Usage: ocr_cli <image-path>      prints the recognized text
//        ocr_cli --clean-up        reads text on stdin, prints it cleaned up
// Exits non-zero on error.
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "--clean-up" {
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    print(TextCleanup.cleanUp(input).text, terminator: "")
    exit(0)
}
guard arguments.count == 2 else {
    fail("usage: \(arguments.first ?? "ocr_cli") <image-path>", code: 2)
}

do {
    let text = try OCRCore.recognizeText(at: URL(fileURLWithPath: arguments[1]))
    print(text)
} catch {
    fail("error: \(error.localizedDescription)", code: 1)
}
