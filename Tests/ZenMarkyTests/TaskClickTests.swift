import Foundation
import Testing
import WebKit
@testable import ZenMarky

// Clicking a task checkbox must reach the app as a link activation carrying the
// source line, even though page scripts are disabled. This is the contract the
// file write depends on.
struct TaskClickTests {
    @MainActor
    private final class NavigationRecorder: NSObject, WKNavigationDelegate {
        var loaded = false
        var activated: URL?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated else { decisionHandler(.allow); return }
            activated = action.request.url
            decisionHandler(.cancel)
        }
    }

    @MainActor
    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition(), "Timed out waiting for the web view")
    }

    @Test @MainActor func testClickingATaskCheckboxRequestsAToggleForItsSourceLine() async throws {
        let html = try DocumentRenderer().render("# Title\n\n- [x] Done\n- [ ] Open task", format: .markdown)
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let recorder = NavigationRecorder()
        webView.navigationDelegate = recorder
        webView.loadHTMLString(html, baseURL: URL(string: "marky-local://document/"))
        try await wait { recorder.loaded }
        _ = try await webView.evaluateJavaScript("document.querySelector('a.task-toggle[aria-checked=\"false\"]').click(); 0")
        try await wait { recorder.activated != nil }
        #expect(recorder.activated.flatMap(PageAction.init) == .toggleTask(line: 3))
        #expect(PageAction(URL(string: "marky-local://document/?marky-task:3")!) == nil)

        // The in-place update must work repeatedly on the same page: check, then uncheck.
        let state = "document.querySelector('a.task-toggle[href=\"marky-task:3\"]').getAttribute('aria-checked')"
        #expect(try await webView.evaluateJavaScript(TaskList.checkboxUpdateScript(line: 3)) as? Bool == true)
        #expect(try await webView.evaluateJavaScript(state) as? String == "true")
        #expect(try await webView.evaluateJavaScript(TaskList.checkboxUpdateScript(line: 3)) as? Bool == true)
        #expect(try await webView.evaluateJavaScript(state) as? String == "false")
        #expect(try await webView.evaluateJavaScript(TaskList.checkboxUpdateScript(line: 9)) as? Bool == false)
    }
}
