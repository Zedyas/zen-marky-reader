import Foundation
import Testing
import WebKit
@testable import ZenMarky

// Mermaid blocks must be drawn by the bundled library while the page's own
// scripts, including the CDN import such files usually carry, stay blocked.
struct DiagramTests {
    @MainActor
    private final class LoadRecorder: NSObject, WKNavigationDelegate {
        var loaded = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    }

    @Test @MainActor func testMermaidBlocksDrawWhilePageScriptsStayBlocked() async throws {
        let html = DocumentRenderer.securing("""
        <!doctype html><html><head><title>Diagram</title></head><body>
        <h1 id="mermaid">A heading whose id is also a global name</h1>
        <pre class="mermaid">
        erDiagram
          CUSTOMER ||--o{ ORDER : places
        </pre>
        <pre class="mermaid">flowchart LR
          A["first line<br>second line"] --> B</pre>
        <script>document.title = 'page script ran'</script>
        <script type="module">import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs'; document.title = 'module ran';</script>
        </body></html>
        """)
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // As in the app; without a handler WebKit hands the base URL to macOS to open.
        let resources = LocalResourceHandler()
        configuration.setURLSchemeHandler(resources, forURLScheme: "marky-local")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let recorder = LoadRecorder()
        webView.navigationDelegate = recorder
        webView.loadHTMLString(html, baseURL: URL(string: "marky-local://document/"))
        for _ in 0..<100 where !recorder.loaded { try await Task.sleep(for: .milliseconds(50)) }
        #expect(recorder.loaded)

        #expect(await Diagrams.render(in: webView, dark: false) == 2)
        #expect(try await webView.evaluateJavaScript("document.querySelectorAll('.mermaid svg').length") as? Int == 2)
        #expect(try await webView.evaluateJavaScript("document.title") as? String == "Diagram")
        // Drawing again, as an appearance change does, starts from the kept source.
        #expect(await Diagrams.render(in: webView, dark: true) == 2)
        #expect(try await webView.evaluateJavaScript("document.querySelectorAll('.mermaid svg').length") as? Int == 2)
        #expect(try await webView.evaluateJavaScript("document.querySelectorAll('.mermaid .nodeLabel br').length") as? Int == 1)
    }
}
