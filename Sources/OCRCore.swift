import CoreGraphics
import CoreImage
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

    /// Text lines shorter than this many pixels are too small for Vision to
    /// read reliably; such images are enlarged and read again.
    private static let smallTextLineHeight: CGFloat = 16
    private static let enlargement: CGFloat = 2
    /// Never enlarge beyond this many pixels on the long side.
    private static let maxEnlargedSide: CGFloat = 8000

    /// Runs Vision text recognition on an already decoded image.
    static func recognizeText(in image: LoadedImage) throws -> String {
        var lines = try recognizeLines(in: image)

        // Small text (a low-resolution photo, or a whole spread in one shot)
        // is read far more accurately after enlarging the image.
        // Text too small to be detected at all gets the same second chance.
        let height = medianLineHeight(of: lines, in: image)
        if height.map({ $0 < smallTextLineHeight }) ?? true,
           let enlarged = enlarge(image),
           let retried = try? recognizeLines(in: enlarged) {
            let before = lines.reduce(0) { $0 + $1.text.count }
            let after = retried.reduce(0) { $0 + $1.text.count }
            // Keep the first pass if the second one lost a lot of text.
            if after * 5 >= before * 4 {
                lines = retried
            }
        }

        // Vision returns observations in reading order, also for tilted or
        // rotated text and for columns, so keep that order. Drop lines with no
        // letter or digit: those are borders, bullets and specks.
        return lines
            .map(\.text)
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .joined(separator: "\n")
    }

    private struct Line {
        let text: String
        /// Height of the line as a fraction of the upright image's height.
        let relativeHeight: CGFloat
    }

    private static func recognizeLines(in image: LoadedImage) throws -> [Line] {
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

        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return Line(text: text, relativeHeight: observation.boundingBox.height)
        }
    }

    /// Median height of the recognized lines in pixels, or nil without lines.
    private static func medianLineHeight(of lines: [Line], in image: LoadedImage) -> CGFloat? {
        guard !lines.isEmpty else { return nil }
        let sideways: Bool
        switch image.orientation {
        case .left, .leftMirrored, .right, .rightMirrored: sideways = true
        default: sideways = false
        }
        let uprightHeight = CGFloat(sideways ? image.cgImage.width : image.cgImage.height)
        let heights = lines.map { $0.relativeHeight * uprightHeight }.sorted()
        return heights[heights.count / 2]
    }

    private static func enlarge(_ image: LoadedImage) -> LoadedImage? {
        let longSide = CGFloat(max(image.cgImage.width, image.cgImage.height))
        guard longSide * enlargement <= maxEnlargedSide else { return nil }
        let scaled = CIImage(cgImage: image.cgImage).applyingFilter(
            "CILanczosScaleTransform",
            parameters: [kCIInputScaleKey: enlargement, kCIInputAspectRatioKey: 1.0]
        )
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return LoadedImage(cgImage: cgImage, orientation: image.orientation)
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
