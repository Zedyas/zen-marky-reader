import AppKit
import UniformTypeIdentifiers

@main
enum ZenMarky {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

// Owns the open windows, the shared renderer, and the preferences every window follows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var controllers: [ReaderWindowController] = []
    private var renderer: DocumentRenderer?
    private var preferences = ReaderPreferences() {
        didSet {
            preferences.save()
            NSApp.appearance = preferences.appearance
            for controller in controllers { controller.preferences = preferences }
        }
    }
    private var quitPending = false

    // Runs before Finder hands over files, so those open as tabs next to the restored ones.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = preferences.appearance
        restoreSession()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        for path in CommandLine.arguments.dropFirst() where !path.hasPrefix("-") {
            open(URL(fileURLWithPath: path))
        }
        // Files handed over by Finder arrive before this point and already have windows.
        if controllers.isEmpty { newWindow(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    // Scroll offsets are read from the pages first, which is asynchronous, so quitting
    // waits for them. A page that stops responding cannot hold up quitting for more
    // than two seconds; the offsets read by then are saved.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitPending = true
        Task {
            for controller in controllers { await controller.storeScroll() }
            finishQuit()
        }
        // The common modes include the one AppKit runs while it waits for the reply.
        let limit = Timer(timeInterval: 2, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.finishQuit() } }
        RunLoop.main.add(limit, forMode: .common)
        return .terminateLater
    }

    private func finishQuit() {
        guard quitPending else { return }
        quitPending = false
        saveSession()
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // Records each window's files in tab order, front window first.
    private func saveSession() {
        let front = NSApp.orderedWindows
        var saved: [(depth: Int, window: ReaderSession.Window)] = []
        var session = ReaderSession()
        var seen: Set<NSWindow> = []
        for window in controllers.compactMap(\.window) where !seen.contains(window) {
            let tabs = window.tabGroup?.windows ?? [window]
            seen.formUnion(tabs)
            let path = { (tab: NSWindow) in (tab.windowController as? ReaderWindowController)?.readerDocument?.url.path }
            let files = tabs.compactMap(path)
            guard !files.isEmpty else { continue }
            let selected = window.tabGroup?.selectedWindow ?? window
            saved.append((front.firstIndex(of: selected) ?? front.count, ReaderSession.Window(files: files, selected: path(selected), frame: NSStringFromRect(selected.frame))))
            for file in files { session.scrollOffsets[file] = ReaderWindowController.scrollPositions[URL(fileURLWithPath: file)] }
        }
        session.windows = saved.sorted { $0.depth < $1.depth }.map(\.window)
        session.save()
    }

    // Reopens the files from the last session, back window first so the front one ends
    // up in front. Files that no longer exist are skipped.
    private func restoreSession() {
        guard let session = ReaderSession.load()?.existing() else { return }
        for (path, offset) in session.scrollOffsets {
            ReaderWindowController.scrollPositions[URL(fileURLWithPath: path)] = offset
        }
        for saved in session.windows.reversed() {
            var last: ReaderWindowController?
            var selected: ReaderWindowController?
            for path in saved.files {
                let controller = makeWindow(tabbedWith: last?.window)
                if last == nil { controller.window?.setFrame(NSRectFromString(saved.frame), display: false) }
                controller.open(URL(fileURLWithPath: path))
                if path == saved.selected { selected = controller }
                last = controller
            }
            (selected ?? last)?.window?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    private var frontController: ReaderWindowController? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? ReaderWindowController
    }

    // Opens the file in the window that asked, a welcome window that is free, or a
    // new tab or window according to the placement. A file that is already open
    // is brought to the front instead of being opened twice.
    func open(_ url: URL, from source: ReaderWindowController? = nil, placement: OpenPlacement = .preferred) {
        let resolved = url.resolvingSymlinksInPath()
        if let existing = controllers.first(where: { $0.documentURL == resolved }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        // At launch the app is not active yet, so there is no key window; fall back to the last window made.
        let source = source ?? frontController ?? controllers.last
        let target: ReaderWindowController
        if placement == .current, let source {
            target = source
        } else if let source, source.documentURL == nil {
            target = source
        } else {
            let asTab = placement == .tab || (placement == .preferred && preferences.opensInTabs)
            target = makeWindow(tabbedWith: asTab ? source?.window : nil)
        }
        target.open(resolved)
        target.window?.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    private func makeWindow(tabbedWith anchor: NSWindow?) -> ReaderWindowController {
        do {
            if renderer == nil { renderer = try DocumentRenderer() }
        } catch {
            NSAlert(error: error).runModal()
        }
        guard let renderer else { fatalError("The document renderer could not load.") }
        let controller = ReaderWindowController(renderer: renderer, preferences: preferences)
        controller.openRequest = { [weak self, weak controller] url, placement in self?.open(url, from: controller, placement: placement) }
        controller.closed = { [weak self, weak controller] in self?.controllers.removeAll { $0 === controller } }
        controllers.append(controller)
        if let anchor, let window = controller.window {
            anchor.addTabbedWindow(window, ordered: .above)
        } else if let front = frontController?.window, let window = controller.window {
            window.cascadeTopLeft(from: front.cascadeTopLeft(from: .zero))
        }
        controller.showWindow(nil)
        return controller
    }

    @objc func newWindow(_ sender: Any?) { makeWindow(tabbedWith: nil) }
    @objc func newTab(_ sender: Any?) { makeWindow(tabbedWith: frontController?.window) }
    // The tab bar's plus button sends this through the responder chain.
    @objc func newWindowForTab(_ sender: Any?) { newTab(sender) }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentFormat.extensions.keys.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        let source = frontController
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { self?.open(url, from: source) }
        }
        if let window = source?.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    @objc func selectPlacement(_ sender: NSMenuItem) { preferences.opensInTabs = sender.tag == 1 }

    // ⌘1 through ⌘9 select a tab of the front window by position.
    @objc func selectTab(_ sender: NSMenuItem) {
        guard let windows = frontController?.window?.tabGroup?.windows, windows.indices.contains(sender.tag) else { return }
        windows[sender.tag].makeKeyAndOrderFront(nil)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }

    @objc func clearRecentDocuments(_ sender: Any?) {
        RecentDocuments.clear()
        for controller in controllers where controller.readerDocument == nil { controller.refreshWelcome() }
    }

    // The shortcut list is a bundled Markdown page shown in the reader itself.
    @objc func showShortcuts(_ sender: Any?) {
        if let url = DocumentRenderer.resourcesDirectory?.appendingPathComponent("Shortcuts.md") { open(url) }
    }

    // The Open Recent menu is rebuilt from the stored list each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = RecentDocuments.urls
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            item.toolTip = url.deletingLastPathComponent().path
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentDocuments(_:)), keyEquivalent: "")
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }

    @objc func selectReaderStyle(_ sender: NSMenuItem) { preferences.bookStyle = sender.tag == 1 }
    @objc func toggleFrontMatter(_ sender: NSMenuItem) { preferences.showsFrontMatter.toggle() }

    @objc func selectAppearance(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        preferences.appearanceMode = mode
    }

    // Checkmarks for the settings, wherever their menu items appear: the menu bar or the Aa button.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(selectReaderStyle(_:)): item.state = (item.tag == 1) == preferences.bookStyle ? .on : .off
        case #selector(selectAppearance(_:)): item.state = item.representedObject as? String == preferences.appearanceMode ? .on : .off
        case #selector(selectPlacement(_:)): item.state = (item.tag == 1) == preferences.opensInTabs ? .on : .off
        case #selector(toggleFrontMatter(_:)): item.state = preferences.showsFrontMatter ? .on : .off
        default: break
        }
        return true
    }

    private func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String, in parent: NSMenu = main) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            parent.addItem(item)
            return submenu
        }
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
            return item
        }
        let app = menu("Zen Marky Reader")
        add(app, "About Zen Marky Reader", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Hide Zen Marky Reader", #selector(NSApplication.hide(_:)), "h")
        app.addItem(.separator())
        add(app, "Quit Zen Marky Reader", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        add(file, "New Window", #selector(newWindow(_:)), "n")
        add(file, "New Tab", #selector(newTab(_:)), "t")
        add(file, "Open…", #selector(openDocument(_:)), "o")
        let recent = menu("Open Recent", in: file)
        recent.delegate = self
        recent.autoenablesItems = false
        let placement = menu("Open Files In", in: file)
        add(placement, "New Tab", #selector(selectPlacement(_:))).tag = 1
        add(placement, "New Window", #selector(selectPlacement(_:)))
        file.addItem(.separator())
        add(file, "Reload", #selector(ReaderWindowController.reloadDocument(_:)), "r")
        add(file, "Show in Finder", #selector(ReaderWindowController.revealDocument(_:)))
        file.addItem(.separator())
        add(file, "Export as PDF…", #selector(ReaderWindowController.exportPDF(_:)))
        add(file, "Print…", #selector(ReaderWindowController.printDocument(_:)), "p")
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        let edit = menu("Edit")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Find…", #selector(ReaderWindowController.showFind(_:)), "f")
        add(edit, "Find Next", #selector(ReaderWindowController.findNext(_:)), "g")
        add(edit, "Find Previous", #selector(ReaderWindowController.findPrevious(_:)), "g", modifiers: [.command, .shift])
        let view = menu("View")
        add(view, "Zoom In", #selector(ReaderWindowController.zoomIn(_:)), "=")
        add(view, "Zoom Out", #selector(ReaderWindowController.zoomOut(_:)), "-")
        add(view, "Actual Size", #selector(ReaderWindowController.actualSize(_:)), "0")
        view.addItem(.separator())
        add(view, "Show Outline", #selector(ReaderWindowController.showOutline(_:)), "o", modifiers: [.command, .option])
        view.addItem(.separator())
        let style = menu("Reader Style", in: view)
        add(style, "Native", #selector(selectReaderStyle(_:)))
        add(style, "Book", #selector(selectReaderStyle(_:))).tag = 1
        let appearance = menu("Appearance", in: view)
        for (mode, title) in ReaderPreferences.appearanceModes {
            add(appearance, title, #selector(selectAppearance(_:))).representedObject = mode
        }
        add(view, "Show Front Matter", #selector(toggleFrontMatter(_:)))
        view.addItem(.separator())
        add(view, "Show Tab Bar", #selector(NSWindow.toggleTabBar(_:)), "t", modifiers: [.command, .shift])
        add(view, "Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "\\", modifiers: [.command, .shift])
        let windows = menu("Window")
        add(windows, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windows, "Zoom", #selector(NSWindow.performZoom(_:)))
        windows.addItem(.separator())
        add(windows, "Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", modifiers: [.command, .shift])
        add(windows, "Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", modifiers: [.command, .shift])
        for index in 0..<9 {
            let item = add(windows, index == 8 ? "Show Last Tab" : "Show Tab \(index + 1)", #selector(selectTab(_:)), "\(index + 1)")
            item.tag = index
            item.isHidden = index > 0 && index < 8  // ⌘2–⌘8 work without cluttering the menu
        }
        add(windows, "Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:)))
        add(windows, "Merge All Windows", #selector(NSWindow.mergeAllWindows(_:)))
        windows.addItem(.separator())
        add(windows, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = windows
        let help = menu("Help")
        add(help, "Keyboard Shortcuts", #selector(showShortcuts(_:)), "/")
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }
}
