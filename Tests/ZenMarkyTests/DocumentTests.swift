import Foundation
import Testing
@testable import ZenMarky

struct DocumentTests {
    @Test @MainActor func testMarkdownRendersStructureAndTaskLists() throws {
        let renderer = try DocumentRenderer()
        let html = try renderer.render("""
        # Hello
        **Bold** and *italic* and `code`.

        - [x] Done
        - [ ] Next

        | Name | Value |
        | --- | --- |
        | One | Two |

        ```swift
        let a = 1
        ```
        """, format: .markdown)
        for expected in ["<h1 id=\"hello\">", "<strong>Bold</strong>", "<em>italic</em>", "<code>code</code>", "<table>", "<th>Name</th>", "href=\"marky-task:3\" role=\"checkbox\" aria-checked=\"true\"", "href=\"marky-task:4\" role=\"checkbox\" aria-checked=\"false\"", "language-swift"] {
            #expect(html.contains(expected), "Missing expected markup: \(expected)")
        }
        #expect(try renderer.render("", format: .markdown).contains("This document is empty."))
    }

    @Test @MainActor func testUntrustedMarkdownCannotInjectHTMLOrExecutableLinks() throws {
        let html = try DocumentRenderer().render("""
        <script>alert('bad')</script>
        <img src=x onerror=alert(1)>
        [bad](javascript:alert(1))
        ![bad](data:text/html;base64,SGVsbG8=)
        """, format: .markdown)
        #expect(!(html.contains("<script>")))
        #expect(!(html.contains("<img src=x")))
        #expect(!(html.contains("href=\"javascript:")))
        #expect(!(html.contains("src=\"data:text/html")))
        #expect(html.contains("&lt;script&gt;"))
    }

    @Test @MainActor func testOnlyExplicitTasksBecomeCheckboxes() throws {
        let html = try DocumentRenderer().render("""
        - Ordinary bullet
        - **Bold bullet**
          - Nested bullet
        - [A link](https://example.com)
        - [x] Completed task
        - [ ] Open task

        1. Numbered item
        """, format: .markdown)
        #expect(html.contains("<li>Ordinary bullet</li>"))
        #expect(html.contains("<li><strong>Bold bullet</strong>"))
        #expect(html.contains("<li>Nested bullet</li>"))
        #expect(html.contains("<li><a href=\"https://example.com\">A link</a></li>"))
        #expect(html.contains("<ol>\n<li>Numbered item</li>"))
        #expect(html.components(separatedBy: "class=\"task-toggle\"").count - 1 == 2)
    }

    @Test func testTogglingFlipsOnlyTheTaskMarkerOnTheGivenLine() {
        let source = "# Plan\r\n\r\n- [ ] first\r\n  - [x] nested [x] not this\r\n- plain [ ] not a task\r\n1. [X] numbered"
        #expect(TaskList.toggling(line: 2, in: source) == "# Plan\r\n\r\n- [x] first\r\n  - [x] nested [x] not this\r\n- plain [ ] not a task\r\n1. [X] numbered")
        #expect(TaskList.toggling(line: 3, in: source) == "# Plan\r\n\r\n- [ ] first\r\n  - [ ] nested [x] not this\r\n- plain [ ] not a task\r\n1. [X] numbered")
        #expect(TaskList.toggling(line: 5, in: source)?.hasSuffix("1. [ ] numbered") == true)
        #expect(TaskList.toggling(line: 0, in: source) == nil)
        #expect(TaskList.toggling(line: 4, in: source) == nil)
        #expect(TaskList.toggling(line: 9, in: source) == nil)
    }

    @Test @MainActor func testHTMLDocumentsGetTheContentPolicyBeforeAnyResource() throws {
        let renderer = try DocumentRenderer()
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(DocumentRenderer.contentSecurityPolicy)\">"
        let full = try renderer.render("<!doctype html><html><HEAD lang=\"en\"><link rel=stylesheet href=a.css></HEAD><body>Hi</body></html>", format: .html)
        #expect(full.contains("<HEAD lang=\"en\">\(policy)<link"))
        let headless = try renderer.render("<html><body>Hi</body></html>", format: .html)
        #expect(headless.hasPrefix("<html><head>\(policy)</head><body>"))
        let fragment = try renderer.render("<p>Just a paragraph</p>", format: .html)
        #expect(fragment.hasPrefix(policy))
        #expect(DocumentRenderer.contentSecurityPolicy.contains("default-src 'none'"))
    }

    @Test func testFileValidationAndContentsRemainUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Read me.MD")
        let content = "# Café\n\nこんにちは 👋"
        try content.write(to: file, atomically: true, encoding: .utf8)
        let document = try ReaderDocument(url: file)
        #expect(document.text == content)
        #expect(document.format == .markdown)
        #expect(try String(contentsOf: file, encoding: .utf8) == content)
        let page = directory.appendingPathComponent("page.htm")
        try "<p>hi</p>".write(to: page, atomically: true, encoding: .utf8)
        #expect(try ReaderDocument(url: page).format == .html)
        #expect(throws: (any Error).self) { try ReaderDocument(url: directory.appendingPathComponent("file.txt")) }
        #expect(throws: (any Error).self) { try ReaderDocument(url: directory.appendingPathComponent("missing.md")) }
        let binary = directory.appendingPathComponent("invalid.md")
        try Data([0xFF, 0xFE, 0xFF]).write(to: binary)
        #expect(throws: (any Error).self) { try ReaderDocument(url: binary) }
        let large = directory.appendingPathComponent("large.md")
        try Data(repeating: 65, count: 10_000_001).write(to: large)
        #expect(throws: (any Error).self) { try ReaderDocument(url: large) }
    }

    @Test func testWritingKeepsTheByteOrderMarkAndFollowsSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("real"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("real/tasks.md")
        let bom = Data([0xEF, 0xBB, 0xBF])
        try (bom + Data("- [ ] task\r\n".utf8)).write(to: file)
        let link = directory.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        var document = try ReaderDocument(url: link)
        #expect(document.url.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        #expect(document.text == "- [ ] task\r\n")
        document.text = try #require(TaskList.toggling(line: 0, in: document.text))
        try document.write()
        #expect(try Data(contentsOf: file) == bom + Data("- [x] task\r\n".utf8))

        #expect(TaskList.sameLine(0, in: "- [ ] task\nmore", and: "- [ ] task\nedited elsewhere"))
        #expect(!TaskList.sameLine(0, in: "- [ ] task", and: "inserted\n- [ ] task"))
        #expect(!TaskList.sameLine(1, in: "- [ ] task", and: "- [ ] task"))
    }

    @Test func testRecentListKeepsNewestFirstWithoutDuplicates() {
        var paths: [String] = []
        for index in 1...12 { paths = RecentDocuments.noting("/f\(index).md", in: paths) }
        #expect(paths.count == RecentDocuments.limit)
        #expect(paths.first == "/f12.md" && paths.last == "/f3.md")
        paths = RecentDocuments.noting("/f5.md", in: paths)
        #expect(paths.first == "/f5.md" && paths.filter { $0 == "/f5.md" }.count == 1 && paths.count == RecentDocuments.limit)
    }

    @Test func testLocalResourcesCannotEscapeDocumentDirectory() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = container.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("images/photo one.png"))
        try Data([1]).write(to: container.appendingPathComponent("secret.png"))
        let valid = URL(string: "marky-local://document/images/photo%20one.png")!
        #expect(LocalResource.resolve(valid, within: root)?.lastPathComponent == "photo one.png")
        #expect(LocalResource.resolve(URL(string: "marky-local://document/../secret.png")!, within: root) == nil)
        #expect(LocalResource.resolve(URL(string: "marky-local://document/%2e%2e/secret.png")!, within: root) == nil)
        #expect(LocalResource.resolve(URL(string: "https://example.com/image.png")!, within: root) == nil)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
        #expect(LocalResource.resolve(URL(string: "marky-local://document/outside/secret.png")!, within: root) == nil)
    }

    // Front matter shows as one line of pairs, and task lines still point at the file's lines.
    @Test @MainActor func testFrontMatterBecomesOneLineAndKeepsTaskLines() throws {
        let html = try DocumentRenderer().render("""
        ---
        title: "Plan: v2"
        tags: [reader, "mac"]
        owners:
          - JJ
        nested:
          key: skipped
        ---
        # Plan

        - [ ] First
        """, format: .markdown)
        #expect(html.contains("<dl class=\"front-matter\"><div><dt>title</dt><dd>Plan: v2</dd></div><div><dt>tags</dt><dd>reader, mac</dd></div><div><dt>owners</dt><dd>JJ</dd></div></dl>"))
        #expect(!html.contains("<hr>"))
        #expect(!html.contains("skipped"))
        #expect(html.contains("href=\"marky-task:10\""))

        // A file that opens with a divider is not front matter; nothing between the dividers is lost.
        let dividers = try DocumentRenderer().render("---\n\nIntro\n\n---\n\nMore", format: .markdown)
        #expect(dividers.components(separatedBy: "<hr>").count == 3)
        #expect(dividers.contains("Intro"))
    }

    @Test @MainActor func testCodeBlocksGetCopyLinksAndMermaidStaysSource() throws {
        let html = try DocumentRenderer().render("""
        ```swift
        let a = 1
        ```

        ```mermaid
        flowchart LR
          A --> B
        ```

            indented
        """, format: .markdown)
        #expect(html.contains("href=\"marky-copy:0\""))
        #expect(html.contains("href=\"marky-copy:1\""))
        #expect(!html.contains("marky-copy:2"))
        #expect(html.contains("<pre class=\"mermaid\">flowchart LR\n  A --&gt; B\n</pre>"))
        #expect(PageAction(URL(string: "marky-copy:1")!) == .copyCode(block: 1))
    }

    @Test func testSessionSkipsMissingFilesAndEmptyGroupsAndWindows() {
        let session = ReaderSession(windows: [
            .init(files: ["/a.md", "/gone.md", "/b.md"], selected: "/b.md", frame: "", groups: [
                .init(name: "Docs", color: .blue, collapsed: false, files: ["/a.md", "/gone.md"]),
                .init(name: "", color: .red, collapsed: true, files: ["/gone.md"])
            ]),
            .init(files: ["/gone.md"], selected: "/gone.md", frame: "")
        ])
        let kept = session.existing { $0 != "/gone.md" }
        #expect(kept.windows == [.init(files: ["/a.md", "/b.md"], selected: "/b.md", frame: "", groups: [
            .init(name: "Docs", color: .blue, collapsed: false, files: ["/a.md"])
        ])])
    }
}
