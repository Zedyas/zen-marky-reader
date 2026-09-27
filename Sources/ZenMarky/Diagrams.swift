import Foundation
import WebKit

// Draws Mermaid diagrams (`.mermaid` elements) with the bundled library. It runs in
// the app's own script world, which WebKit keeps apart from the page, so the
// document's scripts stay disabled and nothing is downloaded.
@MainActor
enum Diagrams {
    private static let world = WKContentWorld.world(name: "diagrams")
    private static var library: String?
    // One draw at a time per web view, so a redraw for a new appearance or for
    // printing cannot interleave with a draw that is still running.
    private static var queue: [ObjectIdentifier: Task<Int, Never>] = [:]

    // Keeps each block's source markup (which may contain <br> line breaks) so a later
    // call can draw it again, for example in the other appearance.
    // Natural size keeps labels readable on screen, with wide diagrams scrolling sideways;
    // printing fits them to the page width instead.
    private static let drawScript = """
    const nodes = [...document.querySelectorAll('.mermaid')];
    for (const node of nodes) {
      if (node.dataset.source === undefined) node.dataset.source = node.innerHTML;
      else node.innerHTML = node.dataset.source;
      node.removeAttribute('data-processed');
    }
    const size = { useMaxWidth: fitWidth };
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'neutral', fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
      flowchart: size, er: size, sequence: size, class: size, state: size, gantt: size });
    await mermaid.run({ nodes, suppressErrors: true });
    return nodes.length;
    """

    // Returns the number of blocks drawn; pages without diagrams return 0 without loading the library.
    @discardableResult
    static func render(in webView: WKWebView, dark: Bool, fitWidth: Bool = false) async -> Int {
        let key = ObjectIdentifier(webView)
        let previous = queue[key]
        let task = Task {
            _ = await previous?.value
            return await draw(in: webView, dark: dark, fitWidth: fitWidth)
        }
        queue[key] = task
        let drawn = await task.value
        if queue[key] == task { queue[key] = nil }
        return drawn
    }

    private static func draw(in webView: WKWebView, dark: Bool, fitWidth: Bool) async -> Int {
        // An element with id="mermaid" is also a global name, so the check looks for the library's API.
        let state = try? await webView.callAsyncJavaScript(
            "return [document.querySelectorAll('.mermaid').length, typeof globalThis.mermaid?.run === 'function']",
            contentWorld: world) as? [Any]
        guard let count = state?.first as? Int, count > 0 else { return 0 }
        if state?.last as? Bool != true {
            if library == nil, let url = DocumentRenderer.resourcesDirectory?.appendingPathComponent("mermaid.min.js") {
                library = try? String(contentsOf: url, encoding: .utf8)
            }
            guard let library else { return 0 }
            // The trailing value keeps WebKit from trying to return the library object.
            _ = try? await webView.evaluateJavaScript(library + "\n;0", in: nil, contentWorld: world)
        }
        let drawn = try? await webView.callAsyncJavaScript(drawScript, arguments: ["dark": dark, "fitWidth": fitWidth], contentWorld: world)
        return drawn as? Int ?? 0
    }
}
