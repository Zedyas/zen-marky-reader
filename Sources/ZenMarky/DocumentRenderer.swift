import Foundation
import JavaScriptCore

@MainActor
final class DocumentRenderer {
    // Applies to every page. Scripts never run (the web view also disables them),
    // remote loads are limited to HTTPS images, and local files come only through
    // the marky-local scheme, which is confined to the document's directory.
    static let contentSecurityPolicy = "default-src 'none'; img-src https: data: marky-local:; style-src 'unsafe-inline' marky-local:; base-uri 'none'; form-action 'none'"

    private let context: JSContext
    private let stylesheet: String

    // The bundled Resources folder, inside the app bundle or the package's resource bundle.
    // For this flat bundle, Foundation reports the inner Resources folder as the resource
    // directory on macOS 14 and 15 but the bundle itself on later versions, so the folder
    // is found by a file it holds.
    static var resourcesDirectory: URL? {
        let bundledResources = Bundle.main.resourceURL?.appendingPathComponent("ZenMarky_ZenMarky.bundle")
        let bundle = bundledResources.flatMap(Bundle.init(url:)) ?? Bundle.module
        let stylesheet = bundle.url(forResource: "reader", withExtension: "css")
            ?? bundle.url(forResource: "reader", withExtension: "css", subdirectory: "Resources")
        return stylesheet?.deletingLastPathComponent()
    }

    init() throws {
        guard let context = JSContext(), let resources = Self.resourcesDirectory else {
            throw DocumentError.rendererUnavailable
        }
        self.context = context
        // markdown-it's entity table uses the browser atob API, which a bare
        // JavaScriptCore context does not provide.
        let decodeBase64: @convention(block) (String) -> String? = { value in
            guard let data = Data(base64Encoded: value) else { return nil }
            return String(data: data, encoding: .isoLatin1)
        }
        context.setObject(decodeBase64, forKeyedSubscript: "atob" as NSString)
        stylesheet = try String(contentsOf: resources.appendingPathComponent("reader.css"), encoding: .utf8)
        for name in ["markdown-it.min.js", "renderer.js"] {
            let script = try String(contentsOf: resources.appendingPathComponent(name), encoding: .utf8)
            context.evaluateScript(script)
            guard context.exception == nil else { throw DocumentError.rendererUnavailable }
        }
    }

    func render(_ text: String, format: DocumentFormat, bodyClass: String = "native") throws -> String {
        if text.allSatisfy(\.isWhitespace) {
            return readerPage(body: "<p class=\"empty-document\">This document is empty.</p>", bodyClass: bodyClass)
        }
        switch format {
        case .markdown: return readerPage(body: try renderMarkdown(text), bodyClass: bodyClass)
        case .html: return Self.securing(text)
        }
    }

    private func renderMarkdown(_ markdown: String) throws -> String {
        context.exception = nil
        guard let render = context.objectForKeyedSubscript("renderMarkdown"),
              let html = render.call(withArguments: [markdown])?.toString(),
              context.exception == nil else { throw DocumentError.rendererUnavailable }
        return html
    }

    private func readerPage(body: String, bodyClass: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        \(Self.policyTag)
        <style>\(stylesheet)</style></head><body class="\(bodyClass)"><main aria-label="Document">\(body)</main></body></html>
        """
    }

    private static let policyTag = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"

    // Inserts the policy as early as possible so it governs everything the
    // document loads. The head is preferred; a missing head or html element
    // is handled so hand-written fragments still get the policy.
    static func securing(_ html: String) -> String {
        if let head = html.firstRange(of: /<head\b[^>]*>/.ignoresCase()) {
            return html.replacingCharacters(in: head.upperBound..<head.upperBound, with: policyTag)
        }
        if let root = html.firstRange(of: /<html\b[^>]*>/.ignoresCase()) {
            return html.replacingCharacters(in: root.upperBound..<root.upperBound, with: "<head>\(policyTag)</head>")
        }
        return policyTag + html
    }
}
