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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, ReaderWindowOwner {
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

    private var tabs: [ReaderTab] { controllers.flatMap(\.tabs) }

    // Runs before Finder hands over files, so those open as tabs next to the restored ones.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tabs live in the app's own strip, so the system's window tabs and their menu items are off.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.appearance = preferences.appearance
        restoreSession()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        // ⌃⇥ and ⌃⇧⇥ switch tabs, as they did with the system's tabs. The window uses them
        // to move keyboard focus before menu shortcuts see them, so they are caught here.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 48, event.modifierFlags.contains(.control), let front = self?.frontController else { return event }
            if event.modifierFlags.contains(.shift) { front.previousTab(nil) } else { front.nextTab(nil) }
            return nil
        }
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
            for tab in tabs { await tab.storeScroll() }
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

    // Records each window's files and groups in tab order, front window first.
    private func saveSession() {
        let front = NSApp.orderedWindows
        let depth = { (controller: ReaderWindowController) in controller.window.flatMap(front.firstIndex(of:)) ?? front.count }
        var session = ReaderSession()
        session.windows = controllers.sorted { depth($0) < depth($1) }.compactMap(\.savedWindow)
        for file in session.windows.flatMap(\.files) {
            session.scrollOffsets[file] = ReaderTab.scrollPositions[URL(fileURLWithPath: file)]
        }
        session.save()
    }

    // Reopens the files from the last session, back window first so the front one ends
    // up in front. Files that no longer exist are skipped.
    private func restoreSession() {
        guard let session = ReaderSession.load()?.existing() else { return }
        for (path, offset) in session.scrollOffsets {
            ReaderTab.scrollPositions[URL(fileURLWithPath: path)] = offset
        }
        for saved in session.windows.reversed() {
            let groups = saved.groups.map { TabGroup(name: $0.name, color: $0.color, collapsed: $0.collapsed) }
            let tabs = saved.files.map { path in
                let tab = makeTab()
                tab.group = saved.groups.firstIndex { $0.files.contains(path) }.map { groups[$0] }
                return tab
            }
            let controller = makeWindow()
            controller.window?.setFrame(NSRectFromString(saved.frame), display: false)
            controller.insert(tabs, at: 0)
            for (tab, path) in zip(tabs, saved.files) { tab.open(URL(fileURLWithPath: path)) }
            if let index = saved.files.firstIndex(where: { $0 == saved.selected }) { controller.select(tabs[index]) }
            controller.window?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    private var frontController: ReaderWindowController? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? ReaderWindowController
    }

    // Opens the file in the tab that asked, an empty tab that is free, or a new tab or
    // window according to the placement. A file that is already open is brought to the
    // front instead of being opened twice.
    func open(_ url: URL, from source: ReaderTab? = nil, placement: OpenPlacement = .preferred) {
        let resolved = url.resolvingSymlinksInPath()
        if let existing = tabs.first(where: { $0.documentURL == resolved }) {
            show(existing)
            return
        }
        // At launch the app is not active yet, so there is no key window; fall back to the last window made.
        let source = source ?? frontController?.selectedTab ?? controllers.last?.selectedTab
        let target: ReaderTab
        if placement == .current, let source {
            target = source
        } else if let source, source.documentURL == nil {
            target = source
        } else if let window = source?.windowController, placement == .tab || (placement == .preferred && preferences.opensInTabs) {
            target = makeTab()
            // A link opened in a new tab goes next to its page, in the same group.
            window.add(target, nextTo: placement == .tab ? source : nil)
        } else {
            target = makeTab()
            openWindow(with: [target], topLeft: nil)
        }
        target.open(resolved)
        show(target)
    }

    private func show(_ tab: ReaderTab) {
        tab.windowController?.select(tab)
        tab.windowController?.window?.makeKeyAndOrderFront(nil)
    }

    func makeTab() -> ReaderTab {
        do {
            if renderer == nil { renderer = try DocumentRenderer() }
        } catch {
            NSAlert(error: error).runModal()
        }
        guard let renderer else { fatalError("The document renderer could not load.") }
        let tab = ReaderTab(renderer: renderer, preferences: preferences)
        tab.openRequest = { [weak self, weak tab] url, placement in self?.open(url, from: tab, placement: placement) }
        return tab
    }

    private func makeWindow() -> ReaderWindowController {
        let controller = ReaderWindowController(preferences: preferences, app: self)
        if let front = frontController?.window, let window = controller.window {
            window.cascadeTopLeft(from: front.cascadeTopLeft(from: .zero))
        }
        controllers.append(controller)
        return controller
    }

    func openWindow(with tabs: [ReaderTab], topLeft: NSPoint?) {
        let controller = makeWindow()
        if let topLeft { controller.window?.setFrameTopLeftPoint(topLeft) }
        controller.insert(tabs, at: 0)
        controller.showWindow(nil)
    }

    func windowClosed(_ controller: ReaderWindowController) {
        controllers.removeAll { $0 === controller }
    }

    @objc func newWindow(_ sender: Any?) { openWindow(with: [makeTab()], topLeft: nil) }

    @objc func newTab(_ sender: Any?) {
        if let front = frontController { front.addNewTab() } else { newWindow(sender) }
    }

    // Reader windows close their shown tab first; this closes panels such as About.
    @objc func closeTab(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }

    // Moves every tab into the front window, groups included.
    @objc func mergeWindows(_ sender: Any?) {
        guard let front = frontController else { return }
        for other in controllers where other !== front { front.insert(other.tabs, at: front.tabs.count) }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentFormat.extensions.keys.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        let source = frontController
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { self?.open(url, from: source?.selectedTab) }
        }
        if let window = source?.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    @objc func selectPlacement(_ sender: NSMenuItem) { preferences.opensInTabs = sender.tag == 1 }

    @objc func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }

    @objc func clearRecentDocuments(_ sender: Any?) {
        RecentDocuments.clear()
        for tab in tabs { tab.refreshWelcome() }
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
    @objc func toggleShowsTabBar(_ sender: NSMenuItem) { preferences.showsTabBar.toggle() }

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
        case #selector(toggleShowsTabBar(_:)): item.state = preferences.showsTabBar ? .on : .off
        case #selector(mergeWindows(_:)): return controllers.count > 1
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
        add(file, "Reload", #selector(ReaderTab.reloadDocument(_:)), "r")
        add(file, "Show in Finder", #selector(ReaderTab.revealDocument(_:)))
        file.addItem(.separator())
        add(file, "Export as PDF…", #selector(ReaderTab.exportPDF(_:)))
        add(file, "Print…", #selector(ReaderTab.printDocument(_:)), "p")
        file.addItem(.separator())
        add(file, "Close Tab", #selector(closeTab(_:)), "w")
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", modifiers: [.command, .shift])
        let edit = menu("Edit")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Find…", #selector(ReaderTab.showFind(_:)), "f")
        add(edit, "Find Next", #selector(ReaderTab.findNext(_:)), "g")
        add(edit, "Find Previous", #selector(ReaderTab.findPrevious(_:)), "g", modifiers: [.command, .shift])
        let view = menu("View")
        add(view, "Zoom In", #selector(ReaderTab.zoomIn(_:)), "=")
        add(view, "Zoom Out", #selector(ReaderTab.zoomOut(_:)), "-")
        add(view, "Actual Size", #selector(ReaderTab.actualSize(_:)), "0")
        view.addItem(.separator())
        add(view, "Show Outline", #selector(ReaderTab.showOutline(_:)), "o", modifiers: [.command, .option])
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
        add(view, "Always Show Tab Bar", #selector(toggleShowsTabBar(_:)), "t", modifiers: [.command, .shift])
        let windows = menu("Window")
        add(windows, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windows, "Zoom", #selector(NSWindow.performZoom(_:)))
        windows.addItem(.separator())
        // NSWindow has its own actions for these names, so the strip's use different ones.
        add(windows, "Show Previous Tab", #selector(ReaderWindowController.previousTab(_:)), "[", modifiers: [.command, .shift])
        add(windows, "Show Next Tab", #selector(ReaderWindowController.nextTab(_:)), "]", modifiers: [.command, .shift])
        for index in 0..<9 {
            let item = add(windows, index == 8 ? "Show Last Tab" : "Show Tab \(index + 1)", #selector(ReaderWindowController.selectTab(_:)), "\(index + 1)")
            item.tag = index
            item.isHidden = index > 0 && index < 8  // ⌘2–⌘8 work without cluttering the menu
        }
        add(windows, "Move Tab to New Window", #selector(ReaderWindowController.detachTab(_:)))
        add(windows, "Merge All Windows", #selector(mergeWindows(_:)))
        windows.addItem(.separator())
        add(windows, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = windows
        let help = menu("Help")
        add(help, "Keyboard Shortcuts", #selector(showShortcuts(_:)), "/")
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }
}
