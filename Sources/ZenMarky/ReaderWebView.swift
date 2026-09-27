import AppKit
import WebKit
import UniformTypeIdentifiers

final class ReaderWebView: WKWebView {
    var openFile: ((URL) -> Void)?
    var appearanceChanged: (() -> Void)?

    var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedDocument(sender) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        droppedDocument(sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = droppedDocument(sender) else { return false }
        openFile?(url)
        return true
    }
}

// The first supported document among dragged files, if any.
@MainActor func droppedDocument(_ sender: any NSDraggingInfo) -> URL? {
    let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    return urls?.first(where: { DocumentFormat.of($0) != nil })
}

// Serves images and stylesheets referenced relative to the open document.
// The directory changes when another document opens, so one web view can be reused.
@MainActor
final class LocalResourceHandler: NSObject, WKURLSchemeHandler {
    var directory: URL?

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let request = urlSchemeTask.request.url, let directory,
              let file = LocalResource.resolve(request, within: directory),
              let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image) || file.pathExtension.lowercased() == "css",
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000,
              let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let mimeType = type.conforms(to: .image) ? type.preferredMIMEType ?? "application/octet-stream" : "text/css"
        let response = URLResponse(url: request, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
