import AppKit

struct ReaderPreferences {
    var bookStyle = UserDefaults.standard.bool(forKey: "bookStyle")
    var appearanceMode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"
    var opensInTabs = UserDefaults.standard.object(forKey: "opensInTabs") as? Bool ?? true
    var showsFrontMatter = UserDefaults.standard.bool(forKey: "showsFrontMatter")
    // Without it, the tab strip shows only when a window has two tabs or a group.
    var showsTabBar = UserDefaults.standard.bool(forKey: "showsTabBar")

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
        UserDefaults.standard.set(showsTabBar, forKey: "showsTabBar")
    }
}

// Where a newly opened file goes relative to the tab the request came from.
enum OpenPlacement {
    case current, preferred, tab, window
}

// What a window needs from the app delegate, which makes tabs and windows and keeps the window list.
@MainActor
protocol ReaderWindowOwner: AnyObject {
    func makeTab() -> ReaderTab
    func openWindow(with tabs: [ReaderTab], topLeft: NSPoint?)
    func windowClosed(_ controller: ReaderWindowController)
}

extension NSToolbarItem.Identifier {
    static let outline = Self("outline")
    static let reload = Self("reload")
    static let open = Self("open")
    static let appearance = Self("appearance")
}

// One window: the toolbar, the tab strip, and the tabs, of which one is shown.
// Document commands from the menu and toolbar pass on to the shown tab, so the app
// delegate only coordinates windows and preferences.
@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    private(set) var tabs: [ReaderTab] = []
    private(set) var selectedTab: ReaderTab?
    var preferences: ReaderPreferences {
        didSet {
            for tab in tabs { tab.preferences = preferences }
            updateTabBar()
            showSelection()
        }
    }

    private weak var app: ReaderWindowOwner?
    private let strip = TabStripView()
    // Holds the tabs' views, below the strip when it shows.
    private let tabArea = NSView()
    private let outlineButton = NSButton()

    init(preferences: ReaderPreferences, app: ReaderWindowOwner) {
        self.preferences = preferences
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.minSize = NSSize(width: 440, height: 360)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        // The title bar shows the window color, so the page and the bar are one surface.
        window.titlebarAppearsTransparent = true
        // The strip below the toolbar replaces the system's window tabs.
        window.tabbingMode = .disallowed
        window.delegate = self
        // The strip sits at the top of the content rather than in the title bar, where
        // AppKit draws a separator line over accessories that only its own tab bar can hide.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 720))
        window.contentView = content
        tabArea.frame = content.bounds
        tabArea.autoresizingMask = [.width, .height]
        strip.frame = NSRect(x: 0, y: content.bounds.height - TabStripView.height, width: content.bounds.width, height: TabStripView.height)
        strip.autoresizingMask = [.width, .minYMargin]
        content.addSubview(tabArea)
        content.addSubview(strip)
        let toolbar = NSToolbar(identifier: "ReaderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        strip.controller = self
        window.center()
        // Restores the saved frame when there is one, so it must come after center().
        window.setFrameAutosaveName("ReaderWindow")
        updateTabBar()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        for tab in tabs { tab.close() }
        app?.windowClosed(self)
    }

    // The recent list may have changed while another window was in front.
    func windowDidBecomeKey(_ notification: Notification) { selectedTab?.refreshWelcome() }

    // Tab titles dim while another window is in front.
    func windowDidBecomeMain(_ notification: Notification) { strip.reload() }
    func windowDidResignMain(_ notification: Notification) { strip.reload() }

    // Menu and toolbar commands this controller does not handle go to the shown tab.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let selectedTab, selectedTab.responds(to: action) { return selectedTab }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    // MARK: Tabs

    // The window's groups, left to right.
    var groups: [TabGroup] {
        var groups: [TabGroup] = []
        for case let group? in tabs.map(\.group) where !groups.contains(group) { groups.append(group) }
        return groups
    }

    func tabs(in group: TabGroup) -> [ReaderTab] { tabs.filter { $0.group === group } }

    private var visibleTabs: [ReaderTab] { tabs.filter { $0.group?.collapsed != true } }

    // Moves the tabs here from wherever they are, at an index of this window's list
    // without them. A tab moved within this window stays shown. A window the tabs
    // leave shows another tab in place of a shown one that left, or closes when empty.
    func insert(_ moving: [ReaderTab], at index: Int) {
        let shown = selectedTab
        let sources = Set(moving.compactMap(\.windowController)).map { ($0, $0.remove(moving)) }
        tabs.insert(contentsOf: moving, at: min(index, tabs.count))
        for tab in moving { attach(tab) }
        tabs = StripLayout.keepingGroupsTogether(tabs) { $0.group }
        if let shown, tabs.contains(shown) { select(shown) }
        for (source, shownIndex) in sources where source !== self {
            if source.tabs.isEmpty { source.close() } else if let shownIndex { source.showTab(near: shownIndex) }
        }
        if selectedTab == nil { showTab(near: index) }
        updateTabBar()
    }

    // Adds a tab at the end, or right after the tab it was opened from and in that tab's group.
    func add(_ tab: ReaderTab, nextTo opener: ReaderTab? = nil) {
        let index = opener.flatMap { tabs.firstIndex(of: $0) }
        tab.group = index == nil ? nil : opener?.group
        insert([tab], at: index.map { $0 + 1 } ?? tabs.count)
    }

    func addNewTab(in group: TabGroup? = nil) {
        guard let tab = app?.makeTab() else { return }
        add(tab, nextTo: group.flatMap { tabs(in: $0).last })
        select(tab)
    }

    // Shows the tab, opening its group if it was collapsed.
    func select(_ tab: ReaderTab) {
        guard tabs.contains(tab) else { return }
        tab.group?.collapsed = false
        if selectedTab !== tab {
            selectedTab?.view.isHidden = true
            selectedTab = tab
            tab.view.isHidden = false
            window?.makeFirstResponder(tab.focusView)
            tab.refreshWelcome()
        }
        showSelection()
        updateTabBar()
    }

    // Closes the tabs, and the window when none are left.
    func close(_ closing: [ReaderTab]) {
        for tab in closing where tabs.contains(tab) { tab.close() }
        let shownIndex = remove(closing)
        if tabs.isEmpty { close(); return }
        if let shownIndex { showTab(near: shownIndex) }
        updateTabBar()
    }

    private func attach(_ tab: ReaderTab) {
        tab.view.isHidden = true
        tab.view.frame = tabArea.bounds
        tab.view.autoresizingMask = [.width, .height]
        tabArea.addSubview(tab.view)
        tab.changed = { [weak self, weak tab] in
            guard let self, let tab else { return }
            updateTabBar()
            if tab === selectedTab { showSelection() }
        }
    }

    // Takes those of the tabs that are here out of this window without closing them.
    // Returns where the shown tab was among the tabs left, if it was one of them.
    private func remove(_ leaving: [ReaderTab]) -> Int? {
        let shownIndex = selectedTab.flatMap { shown in
            leaving.contains(shown) ? tabs.prefix(while: { $0 !== shown }).filter { !leaving.contains($0) }.count : nil
        }
        for tab in leaving where tabs.contains(tab) {
            tabs.removeAll { $0 === tab }
            tab.view.removeFromSuperview()
            tab.changed = nil
        }
        if shownIndex != nil { selectedTab = nil }
        return shownIndex
    }

    // Shows the visible tab nearest the position, preferring the right side as Chrome
    // does, or a new tab when every tab left is in a collapsed group.
    private func showTab(near index: Int) {
        let visible = { (tab: ReaderTab) in tab.group?.collapsed != true }
        let bound = min(index, tabs.count)
        if let next = tabs[bound...].first(where: visible) ?? tabs[..<bound].last(where: visible) { select(next) } else { addNewTab() }
    }

    // The window title, toolbar, and background follow the shown tab.
    private func showSelection() {
        guard let window, let tab = selectedTab else { return }
        window.title = tab.title ?? ""
        window.subtitle = tab.status
        window.representedURL = tab.readerDocument?.url
        window.backgroundColor = tab.pageColor
        outlineButton.isEnabled = tab.hasOutline
        window.toolbar?.validateVisibleItems()
    }

    // While a tab is dragged, every window shows its strip so it can take the drop.
    // The strip is shown before it reloads, so it lays out at its real width.
    func updateTabBar() {
        strip.isHidden = !(preferences.showsTabBar || tabs.count > 1 || tabs.contains { $0.group != nil } || TabStripView.isDragging)
        if let content = window?.contentView {
            tabArea.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - (strip.isHidden ? 0 : TabStripView.height))
        }
        strip.reload()
    }

    // MARK: Groups

    // A group's name, or its tabs' titles when it has none, as Chrome labels unnamed groups.
    func label(for group: TabGroup) -> String {
        guard group.name.isEmpty else { return group.name }
        let members = tabs(in: group)
        let first = members.first?.title ?? "Group"
        return members.count > 1 ? "\(first) and \(members.count - 1) more" : first
    }

    // Starts a group with the tab and opens its editor, as Chrome does.
    func newGroup(with tab: ReaderTab) {
        let used = Set(groups.map(\.color))
        let group = TabGroup(color: GroupColor.allCases.first { !used.contains($0) } ?? .blue)
        tab.group = group
        regroup()
        strip.edit(group)
    }

    // Puts the tab at the end of the group.
    func add(_ tab: ReaderTab, to group: TabGroup) {
        tabs.removeAll { $0 === tab }
        let end = tabs.lastIndex { $0.group === group }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: end)
        tab.group = group
        if tab === selectedTab { group.collapsed = false }
        regroup()
    }

    func removeFromGroup(_ tab: ReaderTab) {
        tab.group = nil
        regroup()
    }

    func ungroup(_ group: TabGroup) {
        for tab in tabs(in: group) { tab.group = nil }
        regroup()
    }

    func closeGroup(_ group: TabGroup) { close(tabs(in: group)) }

    // Collapsing the group that holds the shown tab shows the nearest tab outside it,
    // or a new tab when there is none.
    func toggle(_ group: TabGroup) {
        group.collapsed.toggle()
        if group.collapsed, let shown = selectedTab, shown.group === group, let index = tabs.firstIndex(of: shown) {
            showTab(near: index)
        }
        updateTabBar()
    }

    // A tab that leaves its group's middle moves to just after the group.
    private func regroup() {
        tabs = StripLayout.keepingGroupsTogether(tabs) { $0.group }
        updateTabBar()
    }

    // MARK: Moving

    // Tabs dropped on this window's strip. A dropped tab joins the group it lands in.
    func drop(_ moving: MovingTabs, at index: Int, in group: TabGroup?) {
        switch moving {
        case .tab(let tab):
            tab.group = group
            insert([tab], at: index)
            select(tab)
        case .group(_, let members):
            // The group's shown tab stays shown when the group moves to another window.
            let shown = members.first { $0 === $0.windowController?.selectedTab }
            insert(members, at: index)
            if let shown { select(shown) }
        }
        window?.makeKeyAndOrderFront(nil)
    }

    // Opens the tabs in a new window, with its top-left corner at the point if given.
    // Moving every tab moves this window instead. A tab moved on its own leaves its group.
    func moveToNewWindow(_ moving: MovingTabs, at point: NSPoint? = nil) {
        guard moving.tabs.count < tabs.count else {
            if let point { window?.setFrameTopLeftPoint(point) }
            return
        }
        if case .tab(let tab) = moving { tab.group = nil }
        app?.openWindow(with: moving.tabs, topLeft: point)
    }

    // The tab's right-click menu.
    func menu(for tab: ReaderTab) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionMenuItem("Add Tab to New Group") { [weak self] in self?.newGroup(with: tab) })
        let others = groups.filter { $0 !== tab.group }
        if !others.isEmpty {
            let item = NSMenuItem(title: "Add Tab to Group", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for group in others {
                let choice = ActionMenuItem(label(for: group)) { [weak self] in self?.add(tab, to: group) }
                choice.image = group.color.swatch(size: 12)
                submenu.addItem(choice)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        if tab.group != nil {
            menu.addItem(ActionMenuItem("Remove from Group") { [weak self] in self?.removeFromGroup(tab) })
        }
        menu.addItem(.separator())
        let move = ActionMenuItem("Move Tab to New Window") { [weak self] in self?.moveToNewWindow(.tab(tab)) }
        move.isEnabled = tabs.count > 1
        menu.addItem(move)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Close Tab") { [weak self] in self?.close([tab]) })
        let closeOthers = ActionMenuItem("Close Other Tabs") { [weak self] in self?.close(self?.tabs.filter { $0 !== tab } ?? []) }
        closeOthers.isEnabled = tabs.count > 1
        menu.addItem(closeOthers)
        return menu
    }

    // This window's files in tab order with their groups, for the next launch. Empty tabs are left out.
    var savedWindow: ReaderSession.Window? {
        let path = { (tab: ReaderTab) in tab.readerDocument?.url.path }
        let files = tabs.compactMap(path)
        guard let window, !files.isEmpty else { return nil }
        let saved = groups.map { group in
            ReaderSession.Group(name: group.name, color: group.color, collapsed: group.collapsed, files: tabs(in: group).compactMap(path))
        }
        return ReaderSession.Window(files: files, selected: selectedTab.flatMap(path), frame: NSStringFromRect(window.frame), groups: saved.filter { !$0.files.isEmpty })
    }

    // MARK: Menu actions

    @objc func closeTab(_ sender: Any?) {
        if let selectedTab { close([selectedTab]) }
    }

    @objc func nextTab(_ sender: Any?) { cycleTabs(by: 1) }
    @objc func previousTab(_ sender: Any?) { cycleTabs(by: -1) }

    // Tabs hidden in a collapsed group are skipped, as in Chrome.
    private func cycleTabs(by step: Int) {
        let visible = visibleTabs
        guard let selectedTab, let index = visible.firstIndex(of: selectedTab) else { return }
        select(visible[(index + step + visible.count) % visible.count])
    }

    // ⌘1 through ⌘8 select a visible tab by position; ⌘9 selects the last.
    @objc func selectTab(_ sender: NSMenuItem) {
        let visible = visibleTabs
        let index = sender.tag == 8 ? visible.count - 1 : sender.tag
        if visible.indices.contains(index) { select(visible[index]) }
    }

    @objc func detachTab(_ sender: Any?) {
        if let selectedTab { moveToNewWindow(.tab(selectedTab)) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(nextTab(_:)), #selector(previousTab(_:)): visibleTabs.count > 1
        case #selector(detachTab(_:)): tabs.count > 1
        default: true
        }
    }

    // MARK: Toolbar

    // The outline is navigation, so it sits at the leading edge before the title, as
    // Finder and Preview place theirs. Reload, Open, and the appearance settings sit at the trailing edge.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.outline, .flexibleSpace, .reload, .open, .appearance] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.outline, .reload, .open, .appearance, .flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case .appearance:
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
        case .outline:
            item.label = "Outline"
            item.isNavigational = true
            outlineButton.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Outline")
            outlineButton.bezelStyle = .texturedRounded
            // No target, so the click travels the responder chain to the shown tab.
            outlineButton.action = #selector(ReaderTab.showOutline(_:))
            outlineButton.toolTip = "Jump to a heading (⌥⌘O)"
            outlineButton.isEnabled = selectedTab?.hasOutline == true
            item.view = outlineButton
        case .reload:
            item.label = "Reload"
            item.toolTip = "Reload the file (⌘R)"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload the file")
            item.action = #selector(ReaderTab.reloadDocument(_:))
        case .open:
            item.label = "Open"
            item.toolTip = "Open a Markdown or HTML file (⌘O)"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open a Markdown or HTML file")
            item.action = #selector(AppDelegate.openDocument(_:))
        default:
            return nil
        }
        return item
    }
}
