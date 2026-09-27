import AppKit
import UniformTypeIdentifiers
import WebKit

struct ReaderPreferences {
    var bookStyle = UserDefaults.standard.bool(forKey: "bookStyle")
    var appearanceMode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"
    var opensInTabs = UserDefaults.standard.object(forKey: "opensInTabs") as? Bool ?? true
    var showsFrontMatter = UserDefaults.standard.bool(forKey: "showsFrontMatter")

    static let appearanceModes = [("system", "System"), ("light", "Light"), ("dark", "Dark")]

    // Classes on the Markdown page's body; reader.css keys the reader style and front matter off them.
    var bodyClass: String { (bookStyle ? "book" : "native") + (showsFrontMatter ? " show-front-matter" : "") }

    // Applied to the whole app, so panels match the reader windows.
    var appearance: NSAppearance? {
        switch appearanceMode {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    func save() {
        UserDefaults.standard.set(bookStyle, forKey: "bookStyle")
        UserDefaults.standard.set(appearanceMode, forKey: "appearanceMode")
        UserDefaults.standard.set(opensInTabs, forKey: "opensInTabs")
        UserDefaults.standard.set(showsFrontMatter, forKey: "showsFrontMatter")
    }
}

// Where a newly opened file goes relative to the window the request came from.
enum OpenPlacement {
    case current, preferred, tab, window
}

struct Heading {
    let level: Int
    let text: String
}

// One window per document. Menu and toolbar actions reach it through the
// responder chain, so the app delegate only coordinates windows and preferences.
@MainActor
final class ReaderWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate, WKNavigationDelegate, NSUserInterfaceValidations {
    private(set) var readerDocument: ReaderDocument?
    // The file shown or being loaded. It is set before the page's scroll offset is read,
    // so the app never opens the same file twice or reuses a window that is switching.
    private(set) var documentURL: URL?
    var preferences: ReaderPreferences { didSet { applyAppearance() } }
    var openRequest: ((URL, OpenPlacement) -> Void)?
    var closed: (() -> Void)?

    private let renderer: DocumentRenderer
    private let localResources = LocalResourceHandler()
    private var webView: ReaderWebView?
    private let readerContainer = NSView()
    private let findBar = FindBar()
    private var findCount = 0
    private var findIndex = 0
    private var headings: [Heading] = [] { didSet { outlineButton.isEnabled = headings.count >= 2 } }
    private let outlineButton = NSButton()
    private var zoom: CGFloat = 1
    private var watcher: FileWatcher?
    private var pendingChange: Task<Void, Never>?
    private var isClosed = false
    private let openID = NSToolbarItem.Identifier("open")
    private let reloadID = NSToolbarItem.Identifier("reload")
    private let outlineID = NSToolbarItem.Identifier("outline")
    private let appearanceID = NSToolbarItem.Identifier("appearance")

    // Scroll offsets by file, so reloads, reopened files, and the next launch
    // return to where they were.
    static var scrollPositions: [URL: Double] = [:]

    private static let headingSelector = "h1,h2,h3,h4,h5,h6"

    // Matches the Book Reader page colors in reader.css so the unified title bar
    // and the page read as one surface.
    private static let paperColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.141, green: 0.137, blue: 0.125, alpha: 1)
            : NSColor(srgbRed: 0.988, green: 0.980, blue: 0.965, alpha: 1)
    }

    init(renderer: DocumentRenderer, preferences: ReaderPreferences) {
        self.renderer = renderer
        self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "New Tab"
        window.minSize = NSSize(width: 440, height: 360)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        // The title bar shows the window color, so the page and the bar are one surface.
        window.titlebarAppearsTransparent = true
        window.tabbingIdentifier = "reader"
        window.delegate = self
        let toolbar = NSToolbar(identifier: "ReaderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.center()
        // Restores the saved frame when there is one, so it must come after center().
        window.setFrameAutosaveName("ReaderWindow")
        findBar.onSearch = { [weak self] text, forward in self?.find(text, forward: forward) }
        findBar.onClose = { [weak self] in self?.closeFind() }
        applyAppearance()
        showWelcome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        pendingChange?.cancel()
        watcher = nil
        Task { await storeScroll() }
        closed?()
    }

    // The recent list may have changed while another window was in front.
    func windowDidBecomeKey(_ notification: Notification) { refreshWelcome() }

    func refreshWelcome() {
        if readerDocument == nil { showWelcome() }
    }

    private func showWelcome() {
        let root = DropView()
        root.openFile = { [weak self] in self?.openRequest?($0, .preferred) }
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let tip = NSTextField(labelWithString: "Drop a .md or .html file here, or press ⌘O.")
        tip.font = .systemFont(ofSize: 14)
        tip.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, tip])
        stack.orientation = .vertical
        stack.spacing = 14
        let recents = RecentDocuments.urls.prefix(5)
        if !recents.isEmpty {
            let heading = NSTextField(labelWithString: "Recent".uppercased())
            heading.font = .systemFont(ofSize: 11, weight: .medium)
            heading.textColor = .tertiaryLabelColor
            let list = NSStackView(views: [heading] + recents.map { url in
                let row = RecentRow(url: url)
                row.onOpen = { [weak self] in self?.openRequest?(url, .current) }
                return row
            })
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 2
            list.setCustomSpacing(6, after: heading)
            list.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 0)
            stack.addArrangedSubview(list)
            stack.setCustomSpacing(30, after: tip)
            list.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -24)
        ])
        window?.contentView = root
    }

    private func makeReader() -> ReaderWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(localResources, forURLScheme: "marky-local")
        let reader = ReaderWebView(frame: .zero, configuration: configuration)
        reader.navigationDelegate = self
        reader.allowsMagnification = true
        reader.openFile = { [weak self] in self?.openRequest?($0, .preferred) }
        // Diagrams take their colors when drawn, so they are drawn again in the new appearance.
        reader.appearanceChanged = { [weak reader] in
            guard let reader else { return }
            Task { await Diagrams.render(in: reader, dark: reader.isDark) }
        }
        reader.registerForDraggedTypes([.fileURL])
        reader.translatesAutoresizingMaskIntoConstraints = false
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        readerContainer.addSubview(reader)
        readerContainer.addSubview(findBar)
        NSLayoutConstraint.activate([
            reader.topAnchor.constraint(equalTo: readerContainer.topAnchor),
            reader.bottomAnchor.constraint(equalTo: readerContainer.bottomAnchor),
            reader.leadingAnchor.constraint(equalTo: readerContainer.leadingAnchor),
            reader.trailingAnchor.constraint(equalTo: readerContainer.trailingAnchor),
            findBar.topAnchor.constraint(equalTo: readerContainer.topAnchor, constant: 10),
            findBar.trailingAnchor.constraint(equalTo: readerContainer.trailingAnchor, constant: -14)
        ])
        webView = reader
        return reader
    }

    // Loads the file into this window, replacing whatever it showed before. The
    // current scroll offset is stored first so a reload or a later return keeps it.
    // An empty window loads at once, so the app sees it as taken straight away.
    func open(_ url: URL) {
        documentURL = url.resolvingSymlinksInPath()
        guard readerDocument != nil else { load(url); return }
        Task { await storeScroll(); load(url) }
    }

    private func load(_ url: URL) {
        guard let window, !isClosed else { return }
        do {
            let next = try ReaderDocument(url: url)
            let html = try renderer.render(next.text, format: next.format, bodyClass: preferences.bodyClass)
            let reader = makeReader()
            localResources.directory = next.url.deletingLastPathComponent()
            // Reader pages are transparent over the window color. HTML files get the
            // white canvas a browser would give them, so unstyled pages stay readable in dark mode.
            reader.setValue(next.format == .html, forKey: "drawsBackground")
            reader.pageZoom = zoom
            if window.contentView !== readerContainer { window.contentView = readerContainer }
            readerDocument = next
            documentURL = next.url
            headings = []
            closeFind()
            window.title = next.url.lastPathComponent
            window.subtitle = ""
            window.representedURL = next.url
            watch(next.url)
            applyAppearance()
            reader.loadHTMLString(html, baseURL: URL(string: "marky-local://document/"))
            RecentDocuments.note(next.url)
        } catch {
            // The window keeps showing its file. After a failed live reload the old watcher
            // may point at a replaced file, so the current path is watched again.
            documentURL = readerDocument?.url
            if let shown = readerDocument { watch(shown.url) }
            presentError(error, title: "Couldn't open \(url.lastPathComponent)")
        }
    }

    func storeScroll() async {
        guard let url = readerDocument?.url, let webView else { return }
        if let offset = try? await webView.evaluateJavaScript("window.scrollY") as? Double {
            Self.scrollPositions[url] = offset
        }
    }

    // MARK: Live reload

    private func watch(_ url: URL) {
        watcher = FileWatcher(url: url) { [weak self] in self?.fileChanged() }
    }

    // Editors often save in several steps, so the file is checked once events stop.
    private func fileChanged() {
        pendingChange?.cancel()
        pendingChange = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.reloadIfChanged()
        }
    }

    // Re-renders when the text differs from what is shown, which also skips the app's
    // own checkbox writes. A file that is gone keeps its last render with a notice.
    private func reloadIfChanged() {
        guard let shown = readerDocument else { return }
        guard FileManager.default.fileExists(atPath: shown.url.path) else {
            watcher = nil
            window?.subtitle = "Moved or deleted"
            return
        }
        if let current = try? ReaderDocument(url: shown.url), current.text == shown.text {
            watch(shown.url)
        } else {
            open(shown.url)
        }
    }

    // Draws any diagrams first, since they change the page height, then collects the
    // outline, adds link destinations as tooltips, and restores the scroll offset.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = readerDocument?.url, let reader = webView as? ReaderWebView else { return }
        Task { await Diagrams.render(in: reader, dark: reader.isDark); finishLoad(url) }
    }

    private func finishLoad(_ url: URL) {
        guard let webView, readerDocument?.url == url else { return }
        let offset = Self.scrollPositions[url] ?? 0
        webView.evaluateJavaScript("""
        (() => {
          for (const a of document.links) {
            if (!a.title && !a.classList.contains('task-toggle')) a.title = a.getAttribute('href');
          }
          if (\(offset) > 0) window.scrollTo(0, \(offset));
          return [...document.querySelectorAll('\(Self.headingSelector)')].map(h => ({ level: +h.tagName[1], text: h.textContent.trim().slice(0, 80) }));
        })()
        """) { [weak self] result, _ in
            let items = result as? [[String: Any]] ?? []
            self?.headings = items.compactMap { item in
                guard let level = item["level"] as? Int, let text = item["text"] as? String else { return nil }
                return Heading(level: level, text: text)
            }
            self?.window?.toolbar?.validateVisibleItems()
        }
    }

    private func presentError(_ error: any Error, title: String) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // Writes the flipped task marker to the file, then updates the rendered
    // checkbox in place so the scroll position and zoom are kept. The file is
    // re-read first so edits made elsewhere since it was opened are not overwritten.
    private func toggleTask(line: Int) {
        guard let rendered = readerDocument, rendered.format == .markdown else { return }
        do {
            var current = try ReaderDocument(url: rendered.url)
            guard TaskList.sameLine(line, in: rendered.text, and: current.text) else {
                open(rendered.url)
                throw DocumentError.documentChanged
            }
            guard let text = TaskList.toggling(line: line, in: current.text) else { throw DocumentError.taskNotFound }
            // Edits made elsewhere may have moved other tasks, so the page is rendered again
            // instead of updating one box; otherwise later clicks would use stale line numbers.
            let changedElsewhere = current.text != rendered.text
            current.text = text
            try current.write()
            readerDocument = current
            if changedElsewhere { open(current.url); return }
            webView?.evaluateJavaScript(TaskList.checkboxUpdateScript(line: line)) { [weak self] updated, error in
                // The file is already written; a failed in-place update falls back to a full render.
                if error != nil || updated as? Bool != true { self?.open(current.url) }
            }
        } catch {
            presentError(error, title: "Couldn't update \(rendered.url.lastPathComponent)")
        }
    }

    // Copies a code block's text as shown, without the final line break, and marks
    // the button as done for a moment.
    private func copyCode(block: Int) {
        let target = "document.querySelectorAll('.code-block')[\(block)]"
        webView?.evaluateJavaScript("(() => { const block = \(target); if (!block) return null; block.classList.add('copied'); return block.querySelector('pre').textContent; })()") { [weak self] text, _ in
            guard let text = text as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text.hasSuffix("\n") ? String(text.dropLast()) : text, forType: .string)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                _ = try? await self?.webView?.evaluateJavaScript("\(target)?.classList.remove('copied'); 0")
            }
        }
    }

    // MARK: Outline

    // Asks the page which heading is on screen, then shows the outline as a menu
    // under the toolbar button or, from the keyboard, at the top of the page.
    @objc func showOutline(_ sender: Any?) {
        guard let webView, headings.count >= 2 else { return }
        webView.evaluateJavaScript("""
        (() => { let current = -1; document.querySelectorAll('\(Self.headingSelector)').forEach((h, i) => { if (h.getBoundingClientRect().top <= 8) current = i; }); return current; })()
        """) { [weak self] result, _ in
            guard let self else { return }
            let current = result as? Int ?? -1
            let menu = NSMenu()
            menu.font = .menuFont(ofSize: 13)
            let top = headings.map(\.level).min() ?? 1
            for (index, heading) in headings.enumerated() {
                let item = NSMenuItem(title: heading.text, action: #selector(selectHeading(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.indentationLevel = heading.level - top
                item.state = index == current ? .on : .off
                menu.addItem(item)
            }
            // Drops down from the toolbar button; with the toolbar hidden, from the page's top-left corner.
            let anchor: NSView = outlineButton.window != nil && window?.toolbar?.isVisible == true ? outlineButton : webView
            let below = anchor === outlineButton ? 4.0 : -12.0
            let x = anchor === outlineButton ? 0.0 : 16.0
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: anchor.isFlipped ? anchor.bounds.maxY + below : -below), in: anchor)
        }
    }

    @objc private func selectHeading(_ sender: NSMenuItem) {
        webView?.evaluateJavaScript("document.querySelectorAll('\(Self.headingSelector)')[\(sender.tag)].scrollIntoView({ block: 'start' })")
    }

    // MARK: Find

    @objc func showFind(_ sender: Any?) {
        guard readerDocument != nil else { return }
        findBar.isHidden = false
        window?.makeFirstResponder(findBar.field)
        findBar.field.selectText(nil)
    }

    @objc func findNext(_ sender: Any?) { find(findBar.field.stringValue, forward: true) }
    @objc func findPrevious(_ sender: Any?) { find(findBar.field.stringValue, forward: false) }

    private func closeFind() {
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        findBar.field.stringValue = ""
        findBar.count.stringValue = ""
        findCount = 0
        findIndex = 0
        webView?.evaluateJavaScript("window.getSelection().removeAllRanges()")
        if let webView { window?.makeFirstResponder(webView) }
    }

    // WebKit selects and scrolls to the next match; the total comes from the page text.
    private func find(_ text: String, forward: Bool) {
        guard let webView, !text.isEmpty else {
            findBar.count.stringValue = ""
            findCount = 0
            findIndex = 0
            webView?.evaluateJavaScript("window.getSelection().removeAllRanges()")
            return
        }
        let query = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast()
        webView.evaluateJavaScript("""
        (() => { const t = document.body.innerText.toLowerCase(), q = \(query).toLowerCase(); let n = 0, i = 0; while ((i = t.indexOf(q, i)) !== -1) { n++; i += q.length; } return n; })()
        """) { [weak self] result, _ in
            guard let self else { return }
            let total = result as? Int ?? 0
            if total != findCount { findCount = total; findIndex = 0 }
            guard total > 0 else { findBar.count.stringValue = "None"; return }
            let configuration = WKFindConfiguration()
            configuration.backwards = !forward
            configuration.caseSensitive = false
            configuration.wraps = true
            webView.find(text, configuration: configuration) { [weak self] found in
                guard let self, found.matchFound else { return }
                findIndex = forward ? findIndex % total + 1 : (findIndex + total - 2) % total + 1
                findBar.count.stringValue = "\(findIndex) of \(total)"
            }
        }
    }

    // MARK: Actions

    @objc func reloadDocument(_ sender: Any?) {
        if let url = readerDocument?.url { open(url) }
    }

    @objc func printDocument(_ sender: Any?) { runPrint(savingTo: nil) }

    @objc func exportPDF(_ sender: Any?) {
        guard let window, let url = readerDocument?.url else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            // Starts after the save sheet has closed, so the print run can use the window.
            DispatchQueue.main.async { self?.runPrint(savingTo: destination) }
        }
    }

    // Printing and PDF export share one path, so the PDF has the same pages as a
    // printout. The print stylesheet in reader.css sets light colors and page breaks.
    private func runPrint(savingTo destination: URL?) {
        guard let webView, let window, let document = readerDocument else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.topMargin = 48
        info.bottomMargin = 48
        info.leftMargin = 54
        info.rightMargin = 54
        if let destination {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
        }
        let operation = webView.printOperation(with: info)
        operation.jobTitle = document.url.deletingPathExtension().lastPathComponent
        operation.showsPrintPanel = destination == nil
        operation.showsProgressPanel = destination == nil
        // WebKit's print view starts with a zero frame, which prints blank pages.
        operation.view?.frame = webView.bounds
        // Pages print light, so diagrams are drawn light first and redrawn for the screen afterwards.
        Task {
            await Diagrams.render(in: webView, dark: false, fitWidth: true)
            operation.runModal(for: window, delegate: self, didRun: #selector(printFinished(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    @objc private func printFinished(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let webView else { return }
        Task { await Diagrams.render(in: webView, dark: webView.isDark) }
    }

    @objc func revealDocument(_ sender: Any?) {
        if let url = readerDocument?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc func zoomIn(_ sender: Any?) { zoom = min(zoom + 0.1, 2); webView?.pageZoom = zoom }
    @objc func zoomOut(_ sender: Any?) { zoom = max(zoom - 0.1, 0.7); webView?.pageZoom = zoom }
    @objc func actualSize(_ sender: Any?) { zoom = 1; webView?.pageZoom = zoom }

    // Document commands stay disabled on the welcome screen.
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action else { return true }
        if action == #selector(showOutline(_:)) { return headings.count >= 2 }
        let needsDocument: [Selector] = [#selector(reloadDocument(_:)), #selector(revealDocument(_:)), #selector(printDocument(_:)), #selector(exportPDF(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)), #selector(showFind(_:)), #selector(findNext(_:)), #selector(findPrevious(_:))]
        return needsDocument.contains(action) ? readerDocument != nil : true
    }

    private func applyAppearance() {
        guard let window else { return }
        window.backgroundColor = preferences.bookStyle && readerDocument?.format != .html ? Self.paperColor : .textBackgroundColor
        if readerDocument?.format == .markdown {
            webView?.evaluateJavaScript("document.body.className = '\(preferences.bodyClass)'")
        }
    }

    // MARK: Toolbar

    // The outline is navigation, so it sits at the leading edge before the title, as
    // Finder and Preview place theirs. Reload, Open, and the appearance settings sit at the trailing edge.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [outlineID, .flexibleSpace, reloadID, openID, appearanceID] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [outlineID, reloadID, openID, appearanceID, .flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case appearanceID:
            let button = NSPopUpButton(frame: .zero, pullsDown: true)
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            let menu = NSMenu()
            let heading = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
            heading.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: "Appearance")
            menu.addItem(heading)
            for (tag, title) in ["Native Reader", "Book Reader"].enumerated() {
                let choice = NSMenuItem(title: title, action: #selector(AppDelegate.selectReaderStyle(_:)), keyEquivalent: "")
                choice.tag = tag
                menu.addItem(choice)
            }
            menu.addItem(.separator())
            for (mode, title) in ReaderPreferences.appearanceModes {
                let choice = NSMenuItem(title: title, action: #selector(AppDelegate.selectAppearance(_:)), keyEquivalent: "")
                choice.representedObject = mode
                menu.addItem(choice)
            }
            button.menu = menu
            button.toolTip = "Reader style and appearance"
            button.setAccessibilityLabel("Reader style and appearance")
            item.view = button
            item.label = "Appearance"
        case outlineID:
            item.label = "Outline"
            item.isNavigational = true
            outlineButton.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Outline")
            outlineButton.bezelStyle = .texturedRounded
            outlineButton.target = self
            outlineButton.action = #selector(showOutline(_:))
            outlineButton.toolTip = "Jump to a heading (⌥⌘O)"
            outlineButton.isEnabled = headings.count >= 2
            item.view = outlineButton
        case reloadID:
            item.label = "Reload"
            item.toolTip = "Reload the file (⌘R)"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload the file")
            item.action = #selector(reloadDocument(_:))
        case openID:
            item.label = "Open"
            item.toolTip = "Open a Markdown or HTML file (⌘O)"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open a Markdown or HTML file")
            item.action = #selector(AppDelegate.openDocument(_:))
        default:
            return nil
        }
        return item
    }

    // MARK: Navigation policy

    // Only the document itself may load in the web view. Links open outside or
    // switch documents; anything else a page could trigger (meta refresh, forms) is dropped.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if action.navigationType != .linkActivated {
            decisionHandler(scheme == "marky-local" || scheme == "about" ? .allow : .cancel)
            return
        }
        if scheme == "marky-local", url.path == "/", url.fragment != nil {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if let pageAction = PageAction(url) {
            switch pageAction {
            case .toggleTask(let line): toggleTask(line: line)
            case .copyCode(let block): copyCode(block: block)
            }
        } else if ["https", "http", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        } else if let directory = readerDocument?.url.deletingLastPathComponent(), let local = LocalResource.resolve(url, within: directory), DocumentFormat.of(local) != nil {
            // A plain click follows the link here; ⌘-click opens it in a new tab.
            openRequest?(local, action.modifierFlags.contains(.command) ? .tab : .current)
        }
    }
}

@MainActor
private final class DropView: NSView {
    var openFile: ((URL) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { droppedDocument(sender) == nil ? [] : .copy }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = droppedDocument(sender) else { return false }
        openFile?(url)
        return true
    }
}

// One recent file on the welcome screen: name on the left, folder on the right.
@MainActor
private final class RecentRow: NSView {
    var onOpen: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    init(url: URL) {
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        let folder = NSTextField(labelWithString: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .tertiaryLabelColor
        folder.lineBreakMode = .byTruncatingHead
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [name, folder])
        stack.distribution = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(equalToConstant: 330),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(url.lastPathComponent)
        toolTip = url.path
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

// Search field with the match position and arrows, floating over the page.
@MainActor
private final class FindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    let count = NSTextField(labelWithString: "")
    var onSearch: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        field.placeholderString = "Find"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.widthAnchor.constraint(equalToConstant: 190).isActive = true
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .secondaryLabelColor
        let previous = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous match")!, target: self, action: #selector(previousMatch))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next match")!, target: self, action: #selector(nextMatch))
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        for button in [previous, next, done] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
        }
        let stack = NSStackView(views: [field, count, previous, next, done])
        stack.spacing = 6
        stack.setCustomSpacing(10, after: count)
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        self.shadow = shadow
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    func controlTextDidChange(_ notification: Notification) { onSearch?(field.stringValue, true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): onClose?()
        case #selector(NSResponder.insertNewline(_:)): onSearch?(field.stringValue, !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
        default: return false
        }
        return true
    }

    @objc private func previousMatch() { onSearch?(field.stringValue, false) }
    @objc private func nextMatch() { onSearch?(field.stringValue, true) }
    @objc private func close() { onClose?() }
}
