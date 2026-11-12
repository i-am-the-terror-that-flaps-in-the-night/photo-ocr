import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Display image

/// Makes a downsampled, fully decoded, upright copy for the image pane, so a
/// 48 MP photo is not decoded at draw time on the main thread.
/// A free function (not main-actor isolated): call it off the main thread.
func makeDisplayImage(from data: Data) -> OCRCore.LoadedImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 2000,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    return OCRCore.LoadedImage(cgImage: thumbnail, orientation: .up)
}

// MARK: - Model

@MainActor
final class OCRViewModel: ObservableObject {
    @Published var image: OCRCore.LoadedImage?
    @Published var text: String = ""
    @Published var isRecognizing = false
    @Published var errorMessage: String?
    @Published var noTextFound = false
    /// True while a drag hovers over the window. Kept here rather than in
    /// @State because @State needs a compiler plugin that ships only with Xcode.
    @Published var isDropTargeted = false

    private var pasteMonitor: Any?

    /// Base name suggested when saving, taken from the opened file if any.
    private var suggestedName = "Recognized Text"
    /// Incremented for every load so a slow earlier run cannot overwrite a newer one.
    private var generation = 0

    // MARK: Loading

    func load(url: URL) {
        suggestedName = url.deletingPathExtension().lastPathComponent
        start { try OCRCore.readFile(at: url) }
    }

    func load(data: Data) {
        suggestedName = "Recognized Text"
        start { data }
    }

    private func start(_ provideData: @escaping @Sendable () throws -> Data) {
        generation += 1
        let token = generation
        image = nil
        text = ""
        errorMessage = nil
        noTextFound = false
        isRecognizing = true

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let data = try provideData()
                let loaded = try OCRCore.loadImage(from: data)
                await self?.show(makeDisplayImage(from: data) ?? loaded, token: token)
                let recognized = try OCRCore.recognizeText(in: loaded)
                await self?.finish(text: recognized, token: token)
            } catch {
                await self?.fail(error, token: token)
            }
        }
    }

    private func show(_ loaded: OCRCore.LoadedImage, token: Int) {
        guard token == generation else { return }
        image = loaded
    }

    private func finish(text recognized: String, token: Int) {
        guard token == generation else { return }
        isRecognizing = false
        text = recognized
        noTextFound = recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func fail(_ error: Error, token: Int) {
        guard token == generation else { return }
        isRecognizing = false
        errorMessage = error.localizedDescription
    }

    // MARK: Open, paste, drop

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    /// Loads an image or image file from the clipboard.
    /// Returns false if the clipboard holds neither, so the caller can let a
    /// normal text paste go through.
    func pasteFromClipboard() -> Bool {
        let pasteboard = NSPasteboard.general

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let url = urls.first {
            guard Self.isImageFile(url) else { return false }
            load(url: url)
            return true
        }

        // Image data wins over an accompanying string (URL, caption).
        for type in pasteboard.types ?? [] {
            guard let utType = UTType(type.rawValue), utType.conforms(to: .image),
                  let data = pasteboard.data(forType: type)
            else { continue }
            load(data: data)
            return true
        }
        // No image: leave the paste to the text box.
        return false
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, error in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                let message = error?.localizedDescription
                Task { @MainActor [weak self] in
                    if let url {
                        self?.load(url: url)
                    } else {
                        self?.report(message ?? "The dropped item could not be read.")
                    }
                }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, error in
                let message = error?.localizedDescription
                Task { @MainActor [weak self] in
                    if let data {
                        self?.load(data: data)
                    } else {
                        self?.report(message ?? "The dropped image could not be read.")
                    }
                }
            }
            return true
        }
        return false
    }

    /// Cmd+V normally goes to the focused text box. Catch it first and use it
    /// to load an image when the clipboard holds one; otherwise let it through.
    func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Ignore Caps Lock and similar flags; accept "v" from either
            // property so non-Latin keyboard layouts work too.
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard modifiers == .command,
                  event.characters?.lowercased() == "v"
                      || event.charactersIgnoringModifiers?.lowercased() == "v",
                  let window = event.window,
                  !(window is NSPanel),
                  window.attachedSheet == nil
            else { return event }
            let handled = MainActor.assumeIsolated { self?.pasteFromClipboard() ?? false }
            return handled ? nil : event
        }
    }

    private func report(_ message: String) {
        generation += 1
        isRecognizing = false
        errorMessage = message
    }

    private static func isImageFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    // MARK: Copy and save

    func copyText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func saveWithPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = suggestedName + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Could not save the text: \(error.localizedDescription)"
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @ObservedObject var model: OCRViewModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                imagePane
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                textPane
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = model.errorMessage {
                Divider()
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .onDrop(of: [.fileURL, .image], isTargeted: $model.isDropTargeted) { providers in
            model.handleDrop(providers)
        }
        .onAppear { model.installPasteMonitor() }
        // "Open With" in Finder, or a photo dropped on the Dock icon.
        .onOpenURL { url in
            if url.isFileURL { model.load(url: url) }
        }
    }

    private var imagePane: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let loaded = model.image {
                Image(decorative: loaded.cgImage, scale: 1, orientation: loaded.orientation.swiftUIOrientation)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            } else if !model.isRecognizing {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44))
                    Text("Drop a photo here")
                        .font(.title3)
                    Text("or click Open…, or paste an image with ⌘V")
                    Button("Open…") { model.openWithPanel() }
                        .padding(.top, 4)
                }
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            }
            if model.isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
            }
        }
    }

    private var textPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Open…") { model.openWithPanel() }
                Spacer()
                if model.isRecognizing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Recognizing…")
                        .foregroundColor(.secondary)
                } else if model.noTextFound && model.text.isEmpty {
                    Text("No text found")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Copy") { model.copyText() }
                    .disabled(model.text.isEmpty)
                Button("Save…") { model.saveWithPanel() }
                    .disabled(model.text.isEmpty)
            }
            .padding(8)
            Divider()
            TextEditor(text: $model.text)
                .font(.body)
                .padding(4)
                // The text view would otherwise take file and image drops itself.
                .onDrop(of: [.fileURL, .image], isTargeted: $model.isDropTargeted) { providers in
                    model.handleDrop(providers)
                }
        }
    }
}

private extension CGImagePropertyOrientation {
    var swiftUIOrientation: Image.Orientation {
        switch self {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        }
    }
}

// MARK: - App

@main
struct PhotoOCRApp: App {
    @StateObject private var model = OCRViewModel()

    var body: some Scene {
        Window("Photo OCR", id: "main") {
            ContentView(model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.openWithPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
