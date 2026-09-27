import AppKit

// A Chrome-style tab group: a named, colored run of neighboring tabs in one window.
// Its tabs share the object, so a new name or color reaches all of them at once.
final class TabGroup: Equatable {
    var name: String
    var color: GroupColor
    var collapsed: Bool

    init(name: String = "", color: GroupColor, collapsed: Bool = false) {
        self.name = name
        self.color = color
        self.collapsed = collapsed
    }

    static func == (lhs: TabGroup, rhs: TabGroup) -> Bool { lhs === rhs }
}

// Muted tones that keep chip text readable on the white and paper pages, in light and dark.
enum GroupColor: String, Codable, CaseIterable {
    // New groups take the first color not in use, so grey comes last.
    case blue, teal, green, yellow, orange, red, purple, grey

    var title: String { rawValue.capitalized }

    var color: NSColor {
        let (light, dark): (UInt32, UInt32) = switch self {
        case .grey: (0x6B7280, 0xA8AFBA)
        case .blue: (0x3B6FB6, 0x8AB4F0)
        case .teal: (0x237F86, 0x6FCBCF)
        case .green: (0x3F7F4F, 0x8FCB98)
        case .yellow: (0x946F10, 0xE3C265)
        case .orange: (0xB25A26, 0xF0A36E)
        case .red: (0xB23A48, 0xF08C96)
        case .purple: (0x7652B0, 0xBBA2EE)
        }
        return NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    // A filled circle for menus and the group editor. The chosen color is a dot inside a ring.
    func swatch(size: CGFloat, chosen: Bool = false) -> NSImage {
        let color = color
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.set()
            if chosen {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 1.5
                ring.stroke()
                NSBezierPath(ovalIn: rect.insetBy(dx: 4.5, dy: 4.5)).fill()
            } else {
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            }
            return true
        }
    }
}

// One piece of the strip, left to right: a group's chip, or the tab at an index of the window's list.
enum StripItem: Equatable {
    case chip(TabGroup)
    case tab(Int)
}

// The strip's order and drop rules, kept apart from the views so they can be tested.
// Lists hold each tab's group, or nil for a tab outside any group.
enum StripLayout {
    // Moves each group's tabs next to the group's first tab, keeping their order.
    static func keepingGroupsTogether<Tab>(_ tabs: [Tab], group: (Tab) -> TabGroup?) -> [Tab] {
        var result: [Tab] = []
        var placed: [TabGroup] = []
        for tab in tabs {
            guard let owner = group(tab) else { result.append(tab); continue }
            guard !placed.contains(owner) else { continue }
            placed.append(owner)
            result += tabs.filter { group($0) === owner }
        }
        return result
    }

    // A chip before each group's tabs. A collapsed group shows only its chip.
    static func items(_ groups: [TabGroup?]) -> [StripItem] {
        var items: [StripItem] = []
        for (index, group) in groups.enumerated() {
            if let group, index == 0 || groups[index - 1] !== group { items.append(.chip(group)) }
            if group?.collapsed != true { items.append(.tab(index)) }
        }
        return items
    }

    // Where a dragged tab lands when released at x, measured against the items at rest.
    // Over a tab, it goes to that side of the tab and into the tab's group. Over a chip's
    // left half it goes before the group; over the right half, first in the group, or
    // after the group when it is collapsed.
    static func tabDrop(at x: CGFloat, items: [StripItem], frames: [NSRect], groups: [TabGroup?]) -> (index: Int, group: TabGroup?) {
        guard let hit = frames.firstIndex(where: { x < $0.maxX }) else { return (groups.count, nil) }
        let left = x < frames[hit].midX
        switch items[hit] {
        case .tab(let index):
            return (left ? index : index + 1, groups[index])
        case .chip(let group):
            let span = span(of: group, in: groups)
            if left { return (span.lowerBound, nil) }
            return group.collapsed ? (span.upperBound + 1, nil) : (span.lowerBound, group)
        }
    }

    // Where a dragged group lands: before or after the group or ungrouped tab under x,
    // by which half of it x is over, so a group never lands inside another.
    static func groupDrop(at x: CGFloat, items: [StripItem], frames: [NSRect], groups: [TabGroup?]) -> Int {
        guard let hit = frames.firstIndex(where: { x < $0.maxX }) else { return groups.count }
        let target: TabGroup
        switch items[hit] {
        case .tab(let index):
            guard let group = groups[index] else { return x < frames[hit].midX ? index : index + 1 }
            target = group
        case .chip(let group):
            target = group
        }
        let covered = zip(items, frames).filter { item, _ in
            switch item {
            case .chip(let group): group === target
            case .tab(let index): groups[index] === target
            }
        }.map(\.1)
        let span = span(of: target, in: groups)
        let middle = ((covered.first?.minX ?? 0) + (covered.last?.maxX ?? 0)) / 2
        return x < middle ? span.lowerBound : span.upperBound + 1
    }

    // The group's first and last index; its tabs sit together, so everything between is in it.
    private static func span(of group: TabGroup, in groups: [TabGroup?]) -> ClosedRange<Int> {
        groups.firstIndex { $0 === group }! ... groups.lastIndex { $0 === group }!
    }
}

// What a drag or a Move to New Window command carries: one tab, or a whole group with its tabs.
enum MovingTabs {
    case tab(ReaderTab)
    case group(TabGroup, [ReaderTab])

    var tabs: [ReaderTab] {
        switch self {
        case .tab(let tab): [tab]
        case .group(_, let tabs): tabs
        }
    }
}

// The row under the toolbar with group chips, tabs, and a new tab button. Tabs and chips
// move by drag and drop, which also carries them between windows; a drag released
// outside every window opens a new window there.
@MainActor
final class TabStripView: NSView, NSDraggingSource {
    static let height: CGFloat = 32
    private static let pasteboardType = NSPasteboard.PasteboardType("com.zedyas.zenmarky.tab")
    private static let margin: CGFloat = 8
    private static let addWidth: CGFloat = 28
    private static let tabWidths: ClosedRange<CGFloat> = 48...220
    // The strip a drag started from, kept alive until the drag ends even if its window closes.
    private static var dragSource: TabStripView?

    weak var controller: ReaderWindowController?
    // What this strip is dragging out, hidden from its layout meanwhile.
    private var moving: MovingTabs?
    // Where a drag hovering over this strip would land; the layout opens a gap there.
    private var drop: Drop?
    // The layout without the gap. Drops are measured against it, so an opening gap
    // does not move the target under the pointer.
    private var resting = Resting()
    private var buttons: [ObjectIdentifier: TabButton] = [:]
    private var chips: [ObjectIdentifier: GroupChip] = [:]
    private let addButton = NSButton()
    private var editor: NSPopover?

    private struct Drop: Equatable {
        var index: Int
        var group: TabGroup?
        var width: CGFloat?
    }

    private struct Resting {
        var items: [StripItem] = []
        var frames: [NSRect] = []
        var groups: [TabGroup?] = []
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: Self.height))
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        addButton.isBordered = false
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addTab)
        addButton.toolTip = "New Tab (⌘T)"
        addSubview(addButton)
        registerForDraggedTypes([Self.pasteboardType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Empty parts of the strip move the window, like the rest of the title bar.
    override var mouseDownCanMoveWindow: Bool { true }

    @objc private func addTab() { controller?.addNewTab() }

    // Matches the views to the window's tabs and groups, then lays them out.
    func reload() {
        guard let controller else { return }
        let tabs = controller.tabs
        let groups = controller.groups
        for (tab, button) in zip(tabs, sync(&buttons, with: tabs) { TabButton(tab: $0, strip: self) }) {
            button.show(selected: tab === controller.selectedTab)
        }
        for (group, chip) in zip(groups, sync(&chips, with: groups) { GroupChip(group: $0, strip: self) }) {
            chip.show(label: controller.label(for: group), hiddenTabs: group.collapsed ? controller.tabs(in: group).count : 0)
        }
        arrange(animated: window?.isVisible == true)
    }

    // Reuses the view made for each object, makes views for new ones, and removes the rest.
    private func sync<Object: AnyObject, View: NSView>(_ views: inout [ObjectIdentifier: View], with objects: [Object], make: (Object) -> View) -> [View] {
        let kept = Set(objects.map(ObjectIdentifier.init))
        for (id, view) in views where !kept.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
        }
        return objects.map { object in
            if let view = views[ObjectIdentifier(object)] { return view }
            let view = make(object)
            view.isHidden = true
            addSubview(view)
            views[ObjectIdentifier(object)] = view
            return view
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        arrange(animated: false)
    }

    // Places chips and tabs left to right. Chips fit their label and tabs share the
    // rest of the width, within limits. A drag over the strip opens a gap where it would land.
    private func arrange(animated: Bool) {
        guard let controller else { return }
        let tabs: [ReaderTab?] = controller.tabs.filter { moving?.tabs.contains($0) != true }
        resting.groups = tabs.map { $0?.group }
        resting.items = StripLayout.items(resting.groups)
        resting.frames = frames(for: resting.items, gap: nil)
        var shown = tabs
        var groups = resting.groups
        if let drop {
            shown.insert(nil, at: drop.index)
            groups.insert(drop.group, at: drop.index)
        }
        let items = StripLayout.items(groups)
        let frames = frames(for: items, gap: drop)
        var placed: Set<ObjectIdentifier> = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.15 : 0
            for (item, frame) in zip(items, frames) {
                let view: NSView? = switch item {
                case .chip(let group): chips[ObjectIdentifier(group)]
                case .tab(let index): shown[index].flatMap { buttons[ObjectIdentifier($0)] }
                }
                guard let view else { continue }
                placed.insert(ObjectIdentifier(view))
                (view.isHidden ? view : view.animator()).frame = frame
                view.isHidden = false
            }
            let end = frames.last?.maxX ?? Self.margin
            addButton.animator().frame = NSRect(x: end + 2, y: (bounds.height - 24) / 2, width: 24, height: 24)
        }
        let views: [NSView] = Array(buttons.values) + Array(chips.values)
        for view in views where !placed.contains(ObjectIdentifier(view)) { view.isHidden = true }
    }

    private func frames(for items: [StripItem], gap: Drop?) -> [NSRect] {
        let chipWidths = items.map { item -> CGFloat? in
            guard case .chip(let group) = item else { return nil }
            return chips[ObjectIdentifier(group)]?.fittingWidth ?? 0
        }
        let fixed = chipWidths.compactMap { $0 }
        let free = bounds.width - 2 * Self.margin - Self.addWidth - fixed.reduce(0, +)
        let tabWidth = min(max(free / CGFloat(max(items.count - fixed.count, 1)), Self.tabWidths.lowerBound), Self.tabWidths.upperBound)
        var x = Self.margin
        return zip(items, chipWidths).map { item, chipWidth in
            var width = chipWidth ?? tabWidth
            if case .tab(let index) = item, let gap, index == gap.index { width = gap.width ?? tabWidth }
            defer { x += width }
            return NSRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    // MARK: Group editor

    // Chrome's group editor under the chip: name, color, and the group's commands.
    func edit(_ group: TabGroup) {
        guard let controller, let chip = chips[ObjectIdentifier(group)] else { return }
        window?.layoutIfNeeded()
        editor?.close()
        var actions: [(title: String, run: () -> Void)] = [
            ("New Tab in Group", { [weak controller] in controller?.addNewTab(in: group) }),
            ("Ungroup", { [weak controller] in controller?.ungroup(group) }),
            ("Close Group", { [weak controller] in controller?.closeGroup(group) })
        ]
        if controller.tabs(in: group).count < controller.tabs.count {
            actions.append(("Move Group to New Window", { [weak controller] in
                guard let controller else { return }
                controller.moveToNewWindow(.group(group, controller.tabs(in: group)))
            }))
        }
        let content = GroupEditor(group: group, actions: actions) { [weak self] in self?.reload() }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        content.popover = popover
        popover.show(relativeTo: chip.bounds, of: chip, preferredEdge: .minY)
        editor = popover
    }

    // MARK: Dragging out

    func beginDrag(_ moving: MovingTabs, from view: NSView, with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString("tab", forType: Self.pasteboardType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(view.bounds, contents: view.snapshot)
        self.moving = moving
        Self.dragSource = self
        view.beginDraggingSession(with: [dragging], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = false
        arrange(animated: true)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    // Released outside every window, the tabs open in a new window there. Released
    // anywhere else but a strip, nothing moves.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { Self.dragSource = nil }
        guard let moving else { return }
        self.moving = nil
        let overWindow = NSApp.windows.contains { $0.windowController is ReaderWindowController && $0.isVisible && $0.frame.contains(screenPoint) }
        if operation.isEmpty, !overWindow {
            // Puts the new window's strip under the pointer.
            controller?.moveToNewWindow(moving, at: NSPoint(x: screenPoint.x - 80, y: screenPoint.y + 64))
        }
        reload()
    }

    // MARK: Dropping in

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let source = sender.draggingSource as? TabStripView, let moving = source.moving else { return [] }
        let x = convert(sender.draggingLocation, from: nil).x
        let next: Drop
        switch moving {
        case .tab:
            let slot = StripLayout.tabDrop(at: x, items: resting.items, frames: resting.frames, groups: resting.groups)
            next = Drop(index: slot.index, group: slot.group)
        case .group(let group, _):
            let index = StripLayout.groupDrop(at: x, items: resting.items, frames: resting.frames, groups: resting.groups)
            next = Drop(index: index, width: source.chips[ObjectIdentifier(group)]?.fittingWidth)
        }
        if next != drop {
            drop = next
            arrange(animated: true)
        }
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        drop = nil
        arrange(animated: true)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let moving = (sender.draggingSource as? TabStripView)?.moving, let drop, let controller else { return false }
        self.drop = nil
        controller.drop(moving, at: drop.index, in: drop.group)
        return true
    }
}

private func movedEnough(from start: NSEvent, to event: NSEvent) -> Bool {
    hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y) > 4
}

private extension NSView {
    var snapshot: NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }
}

// One tab: its title and a close button. It is selected on mouse down, as in Chrome,
// so a drag starts from the tab already shown.
@MainActor
private final class TabButton: NSView {
    let tab: ReaderTab
    private weak var strip: TabStripView?
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var selected = false
    private var hovered = false { didSet { refresh() } }
    private var pressed: NSEvent?

    init(tab: ReaderTab, strip: TabStripView) {
        self.tab = tab
        self.strip = strip
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: TabStripView.height))
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: bounds.width - 40, height: 16)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.frame = NSRect(x: bounds.width - 26, y: (bounds.height - 16) / 2, width: 16, height: 16)
        closeButton.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.toolTip = "Close Tab (⌘W)"
        addSubview(label)
        addSubview(closeButton)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(selected: Bool) {
        self.selected = selected
        label.stringValue = tab.title ?? ""
        toolTip = tab.readerDocument.map { ($0.url.path as NSString).abbreviatingWithTildeInPath } ?? tab.title
        setAccessibilityLabel(tab.title)
        setAccessibilitySelected(selected)
        refresh()
    }

    private func refresh() {
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        closeButton.isHidden = !(selected || hovered)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected || hovered {
            NSColor.labelColor.withAlphaComponent(selected ? 0.09 : 0.05).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 4), xRadius: 7, yRadius: 7).fill()
        }
        // A group's tabs sit on a line in its color that continues from the chip.
        if let group = tab.group {
            group.color.color.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        pressed = event
        strip?.controller?.select(tab)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, movedEnough(from: pressed, to: event) else { return }
        self.pressed = nil
        strip?.beginDrag(.tab(tab), from: self, with: pressed)
    }

    override func mouseUp(with event: NSEvent) { pressed = nil }

    // A middle click closes the tab.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { strip?.controller?.close([tab]) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { strip?.controller?.menu(for: tab) }

    override func accessibilityPerformPress() -> Bool {
        strip?.controller?.select(tab)
        return true
    }

    @objc private func closeTab() { strip?.controller?.close([tab]) }
}

// A group's chip: its name in its color, or a dot when it has no name. A click collapses
// or expands the group, a drag moves the whole group, and a right-click edits it.
// A collapsed chip also shows how many tabs it holds.
@MainActor
private final class GroupChip: NSView {
    let group: TabGroup
    private weak var strip: TabStripView?
    private var hiddenTabs = 0
    private var pressed: NSEvent?

    init(group: TabGroup, strip: TabStripView) {
        self.group = group
        self.strip = strip
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: TabStripView.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(label: String, hiddenTabs: Int) {
        self.hiddenTabs = hiddenTabs
        let state = group.collapsed ? "collapsed" : "expanded"
        toolTip = "\(label). Click to \(group.collapsed ? "expand" : "collapse"); right-click to rename or recolor."
        setAccessibilityLabel("\(label) group, \(state)")
        needsDisplay = true
    }

    private var text: NSAttributedString {
        let color = group.color.color
        let text = NSMutableAttributedString(string: group.name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color])
        if hiddenTabs > 0 {
            let count = (group.name.isEmpty ? "" : "  ") + "\(hiddenTabs)"
            text.append(NSAttributedString(string: count, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: color.withAlphaComponent(0.75)]))
        }
        return text
    }

    private var dotWidth: CGFloat { group.name.isEmpty ? (hiddenTabs > 0 ? 15 : 10) : 0 }

    var fittingWidth: CGFloat { ceil(text.size().width + dotWidth) + 26 }

    override func draw(_ dirtyRect: NSRect) {
        let color = group.color.color
        let capsule = NSRect(x: 3, y: (bounds.height - 20) / 2 + 1, width: bounds.width - 6, height: 20)
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: 10, yRadius: 10).fill()
        var x = capsule.minX + 10
        if group.name.isEmpty {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: capsule.midY - 5, width: 10, height: 10)).fill()
            x += dotWidth
        }
        let text = text
        text.draw(at: NSPoint(x: x, y: capsule.midY - text.size().height / 2))
        if !group.collapsed {
            color.setFill()
            NSRect(x: capsule.minX, y: 0, width: bounds.width - capsule.minX, height: 2).fill()
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { strip?.edit(group); return }
        pressed = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, let controller = strip?.controller, movedEnough(from: pressed, to: event) else { return }
        self.pressed = nil
        strip?.beginDrag(.group(group, controller.tabs(in: group)), from: self, with: pressed)
    }

    override func mouseUp(with event: NSEvent) {
        if pressed != nil { strip?.controller?.toggle(group) }
        pressed = nil
    }

    override func rightMouseDown(with event: NSEvent) { strip?.edit(group) }

    override func accessibilityPerformPress() -> Bool {
        strip?.controller?.toggle(group)
        return true
    }
}

// The chip's editor: a name field, the colors, and the group's commands. Name and
// color changes apply as they are made.
@MainActor
private final class GroupEditor: NSViewController, NSTextFieldDelegate {
    weak var popover: NSPopover?
    private let group: TabGroup
    private let actions: [(title: String, run: () -> Void)]
    private let changed: () -> Void
    private let field = NSTextField()
    private var swatches: [NSButton] = []

    init(group: TabGroup, actions: [(title: String, run: () -> Void)], changed: @escaping () -> Void) {
        self.group = group
        self.actions = actions
        self.changed = changed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        field.placeholderString = "Name this group"
        field.stringValue = group.name
        field.delegate = self
        swatches = GroupColor.allCases.enumerated().map { index, color in
            let button = NSButton(image: color.swatch(size: 20, chosen: color == group.color), target: self, action: #selector(pickColor(_:)))
            button.isBordered = false
            button.tag = index
            button.toolTip = color.title
            button.setAccessibilityLabel(color.title)
            return button
        }
        let colors = NSStackView(views: swatches)
        colors.spacing = 4
        let separator = NSBox()
        separator.boxType = .separator
        let commands = actions.enumerated().map { index, action in
            let button = NSButton(title: action.title, target: self, action: #selector(runAction(_:)))
            button.bezelStyle = .accessoryBarAction
            button.showsBorderOnlyWhileMouseInside = true
            button.alignment = .left
            button.tag = index
            return button
        }
        let stack = NSStackView(views: [field, colors, separator] + commands)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: field)
        stack.setCustomSpacing(10, after: colors)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        field.widthAnchor.constraint(equalToConstant: 212).isActive = true
        for view in [separator] + commands { view.widthAnchor.constraint(equalTo: field.widthAnchor).isActive = true }
        view = stack
        // The popover takes its size from here; without it, it squeezes the stack's margins away.
        preferredContentSize = stack.fittingSize
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ notification: Notification) {
        group.name = field.stringValue.trimmingCharacters(in: .whitespaces)
        changed()
    }

    // Return closes the editor, keeping the name.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        popover?.performClose(nil)
        return true
    }

    @objc private func pickColor(_ sender: NSButton) {
        group.color = GroupColor.allCases[sender.tag]
        for (button, color) in zip(swatches, GroupColor.allCases) {
            button.image = color.swatch(size: 20, chosen: color == group.color)
        }
        changed()
    }

    @objc private func runAction(_ sender: NSButton) {
        popover?.close()
        actions[sender.tag].run()
    }
}

// A menu item that runs a closure, for menus built on each right-click.
final class ActionMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: "")
        self.handler = handler
        target = self
    }

    @objc private func run() { handler?() }
}
