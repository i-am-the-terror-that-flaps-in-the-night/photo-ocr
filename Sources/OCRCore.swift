import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Errors thrown by `OCRCore`.
enum OCRError: LocalizedError {
    case fileUnreadable(path: String, reason: String)
    case notAnImage
    case recognitionFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .fileUnreadable(let path, let reason):
            return "Could not read the file at \(path): \(reason)"
        case .notAnImage:
            return "The data is not an image that can be decoded (supported: JPEG, PNG, HEIC and other system formats)."
        case .recognitionFailed(let reason):
            return "Text recognition failed: \(reason)"
        }
    }
}

/// Pure OCR logic. Has no UI dependencies and no actor isolation, so every
/// function here can be called from any thread. The calls are synchronous and
/// can take a few seconds: do not call them on the main thread.
enum OCRCore {
    /// A decoded image together with the orientation stored in its metadata.
    struct LoadedImage {
        let cgImage: CGImage
        let orientation: CGImagePropertyOrientation
    }

    /// Recognizes printed text in the image file at `url`.
    /// Returns one line per recognized text line, in reading order.
    /// Returns an empty string if no text was found.
    static func recognizeText(at url: URL) throws -> String {
        try recognizeText(in: readFile(at: url))
    }

    /// Reads a file, turning failures into `OCRError.fileUnreadable`.
    static func readFile(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw OCRError.fileUnreadable(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Recognizes printed text in encoded image data (JPEG, PNG, HEIC, ...).
    static func recognizeText(in data: Data) throws -> String {
        try recognizeText(in: loadImage(from: data))
    }

    /// Decodes the first image in `data` and reads its EXIF/TIFF orientation.
    static func loadImage(from data: Data) throws -> LoadedImage {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw OCRError.notAnImage
        }

        var orientation = CGImagePropertyOrientation.up
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = properties[kCGImagePropertyOrientation] as? NSNumber,
           let parsed = CGImagePropertyOrientation(rawValue: raw.uint32Value) {
            orientation = parsed
        }
        return LoadedImage(cgImage: cgImage, orientation: orientation)
    }

    /// Runs Vision text recognition on an already decoded image.
    static func recognizeText(in image: LoadedImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        do {
            try perform(request, on: image)
        } catch {
            // The accurate recognizer needs a neural network that is not
            // available everywhere (for example an Intel build running under
            // Rosetta). The fast recognizer has no such requirement.
            request.recognitionLevel = .fast
            do {
                try perform(request, on: image)
            } catch {
                throw OCRError.recognitionFailed(reason: error.localizedDescription)
            }
        }

        // Vision returns observations in reading order, also for tilted or
        // rotated text and for columns, so keep that order.
        let lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        return lines.joined(separator: "\n")
    }

    private static func perform(_ request: VNRecognizeTextRequest, on image: LoadedImage) throws {
        // A handler performs its requests once, so each attempt gets a new one.
        let handler = VNImageRequestHandler(
            cgImage: image.cgImage,
            orientation: image.orientation,
            options: [:]
        )
        try handler.perform([request])
    }
}
