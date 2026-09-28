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
        let srgb = { (hex: UInt32) in
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return .adaptive(light: srgb(light), dark: srgb(dark))
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

extension NSColor {
    // A color that follows the light or dark appearance it is drawn in.
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}

// One piece of the strip, left to right: a group's chip, or the tab at an index of the window's list.
enum StripItem: Equatable {
    case chip(TabGroup)
    case tab(Int)
}

// A place a moving tab or group can land: before the tab at an index of the window's
// list without the moving tabs, and in a group or none.
struct StripSlot: Equatable {
    var index: Int
    var group: TabGroup?
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

    // Where a moving tab can land, left to right. After a group's last tab it can stay in
    // the group or leave it; both slots open the gap in the same place. Before a group
    // it lands outside, and after the chip it is the group's first tab. Collapsed groups
    // take no tabs.
    static func tabSlots(_ groups: [TabGroup?]) -> [StripSlot] {
        var slots: [StripSlot] = []
        for index in 0...groups.count {
            let left = index > 0 ? groups[index - 1] : nil
            let right = index < groups.count ? groups[index] : nil
            if let left, left === right {
                if !left.collapsed { slots.append(StripSlot(index: index, group: left)) }
                continue
            }
            if let left, !left.collapsed { slots.append(StripSlot(index: index, group: left)) }
            slots.append(StripSlot(index: index))
            if let right, !right.collapsed { slots.append(StripSlot(index: index, group: right)) }
        }
        return slots
    }

    // A moving group lands only between groups and ungrouped tabs.
    static func groupSlots(_ groups: [TabGroup?]) -> [StripSlot] {
        (0...groups.count).filter { index in
            index == 0 || index == groups.count || groups[index - 1] == nil || groups[index - 1] !== groups[index]
        }.map { StripSlot(index: $0) }
    }

    // The slot whose gap would open nearest x, the moving block's left edge; positions are
    // each slot's gap edge. Where a group ends, the block leaves the group once it is more
    // than `margin` points past the gap and rejoins once it is that far before it; in
    // between it keeps the slot it had.
    static func pick(_ slots: [StripSlot], at positions: [CGFloat], x: CGFloat, current: StripSlot?, margin: CGFloat = 8) -> StripSlot {
        let best = positions.indices.min { abs(positions[$0] - x) < abs(positions[$1] - x) }!
        guard best + 1 < slots.count, positions[best + 1] == positions[best] else { return slots[best] }
        let (inside, outside, place) = (slots[best], slots[best + 1], positions[best])
        if x < place - margin { return inside }
        if x > place + margin { return outside }
        if let current, current == inside || current == outside { return current }
        return x < place ? inside : outside
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

// The system tab bar's measures and colors, read from the bar AppKit draws for window
// tabs, so the strip matches it in light and dark.
@MainActor
private enum StripStyle {
    // Tabs outside the shown one sit on a band that darkens the window color.
    static let band = NSColor.adaptive(light: NSColor(genericGamma22White: 0.949, alpha: 1), dark: NSColor(genericGamma22White: 0, alpha: 0.45))
    static let hover = NSColor.adaptive(light: NSColor(genericGamma22White: 0.898, alpha: 1), dark: NSColor(genericGamma22White: 0, alpha: 0.15))
    static let divider = NSColor.adaptive(light: NSColor(genericGamma22White: 0.878, alpha: 1), dark: NSColor(genericGamma22White: 0.067, alpha: 1))
    static let buttonHover = NSColor.adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.12))

    // Shades a piece of the strip over the window's background, with the edge where the
    // band meets the toolbar. The shown tab has no shade, so it joins the page; the window
    // may tint its background from the desktop, which only the window itself draws.
    static func fill(_ rect: NSRect, in view: NSView, shade: NSColor?) {
        guard let shade else { return }
        shade.setFill()
        rect.fill(using: .sourceOver)
        // A soft shadow in light mode and a dark line in dark mode, in half-point rows.
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let rows: [CGFloat] = dark ? [1, 0.25] : [0.14, 0.085, 0.055, 0.03, 0.015, 0.01, 0.005]
        for (row, alpha) in rows.enumerated() {
            NSColor(white: 0, alpha: alpha).setFill()
            NSRect(x: rect.minX, y: rect.maxY - CGFloat(row + 1) / 2, width: rect.width, height: 0.5).fill(using: .sourceOver)
        }
    }

    static func divider(at x: CGFloat, in view: NSView) {
        divider.setFill()
        NSRect(x: x, y: 0, width: 1, height: view.bounds.height).fill()
    }

    // Titles dim, as the system's do, when the window is not the main one.
    static func titleColor(selected: Bool, in view: NSView) -> NSColor {
        view.window?.isMainWindow == false ? .tertiaryLabelColor : selected ? .labelColor : .secondaryLabelColor
    }
}

// The row under the toolbar, drawn like the system tab bar: tabs share the width equally
// on a darker band, the shown tab takes the window color, and a new tab button sits at
// the right end. Group chips sit before their tabs. A tab or chip dragged along the
// strip slides the others aside; pulled away from it, it becomes a drag that other
// windows' strips take, and released outside every window it opens a new window there.
@MainActor
final class TabStripView: NSView, NSDraggingSource {
    static let height: CGFloat = 28
    private static let pasteboardType = NSPasteboard.PasteboardType("com.zedyas.zenmarky.tab")
    private static let addWidth: CGFloat = 28
    private static let minTabWidth: CGFloat = 48
    // How far the pointer can stray from the strip while carrying tabs before they tear off.
    private static let tearOff = NSSize(width: 24, height: 56)
    // The drag in progress and the strip it started from, which it keeps alive until
    // the drag ends even if the strip's window closes.
    private static var drag: (source: TabStripView, moving: MovingTabs)? {
        didSet {
            for window in NSApp.windows { (window.windowController as? ReaderWindowController)?.updateTabBar() }
        }
    }
    static var isDragging: Bool { drag != nil }

    weak var controller: ReaderWindowController?
    // Tabs carried along this strip by the pointer.
    private var lift: Lift?
    // What this strip is moving, left out of its layout meanwhile.
    private var moving: MovingTabs? { lift?.moving ?? (Self.drag?.source === self ? Self.drag?.moving : nil) }
    // Where the moving tabs would land; the layout opens a gap there.
    private var drop: Drop?
    // Each tab's width in the last layout, which carried tabs keep.
    private var tabWidth: CGFloat = 0
    private var buttons: [ObjectIdentifier: TabButton] = [:]
    private var chips: [ObjectIdentifier: GroupChip] = [:]
    private let addButton = StripButton(kind: .add, label: "New Tab")
    // The band where moving tabs would land.
    private let gapView = BandView()
    // The window's background behind carried tabs, so the tabs they pass do not show through.
    private var backdrop: NSView? { didSet { oldValue?.removeFromSuperview() } }
    private var editor: NSPopover?

    // The width moving tabs take: some tabs' share of the strip, plus a chip's width.
    private struct Room: Equatable {
        var tabs: Int
        var chip: CGFloat
    }

    private struct Drop: Equatable {
        var slot: StripSlot
        var room: Room
    }

    private struct Lift {
        let moving: MovingTabs
        let views: [NSView]
        // The pointer's distance from the left edge of the carried views.
        let grab: CGFloat
        var x: CGFloat
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: Self.height))
        wantsLayer = true
        addButton.toolTip = "New Tab (⌘T)"
        addButton.run = { [weak self] in self?.controller?.addNewTab() }
        addSubview(gapView)
        addSubview(addButton)
        // Above tabs that overflow a narrow window, and above carried tabs.
        addButton.wantsLayer = true
        addButton.layer?.zPosition = 2
        registerForDraggedTypes([Self.pasteboardType])
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The page's text cursor would otherwise linger over the strip.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

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
        // A carried tab closed mid-drag ends the lift; other changes move its gap.
        if let lift {
            if lift.moving.tabs.allSatisfy(tabs.contains) {
                drop = nearestDrop(for: lift.moving, room: room(for: lift.moving), x: lift.x, centered: false)
            } else {
                self.lift = nil
                drop = nil
                backdrop = nil
            }
        }
        addButton.needsDisplay = true
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
            // Clicks follow view order, not drawing order, so the new tab button stays on top.
            addSubview(view, positioned: .below, relativeTo: addButton)
            views[ObjectIdentifier(object)] = view
            return view
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        arrange(animated: false)
    }

    // Places chips and tabs left to right, with a gap where moving tabs would land, and
    // the carried tabs under the pointer.
    private func arrange(animated: Bool) {
        guard let controller else { return }
        let tabs: [ReaderTab?] = controller.tabs.filter { moving?.tabs.contains($0) != true }
        if let drop, drop.slot.index > tabs.count { self.drop = nil }
        var shown = tabs
        var groups = tabs.map { $0?.group }
        if let drop {
            shown.insert(nil, at: drop.slot.index)
            groups.insert(drop.slot.group, at: drop.slot.index)
        }
        let items = StripLayout.items(groups)
        let (frames, tabWidth) = layout(items, gap: drop.map { ($0.slot.index, $0.room) })
        self.tabWidth = tabWidth
        var placed: Set<ObjectIdentifier> = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.15 : 0
            for (item, frame) in zip(items, frames) {
                let view: NSView? = switch item {
                case .chip(let group): chips[ObjectIdentifier(group)]
                case .tab(let index): shown[index].map { buttons[ObjectIdentifier($0)] } ?? gapView
                }
                guard let view else { continue }
                if view === gapView { gapView.line = drop?.slot.group?.color }
                placed.insert(ObjectIdentifier(view))
                (view.isHidden ? view : view.animator()).frame = frame
                view.isHidden = false
            }
        }
        addButton.frame = NSRect(x: bounds.width - Self.addWidth, y: 0, width: Self.addWidth, height: bounds.height)
        for view in lift?.views ?? [] { placed.insert(ObjectIdentifier(view)) }
        placeLifted()
        let views: [NSView] = Array(buttons.values) + Array(chips.values) + [gapView]
        for view in views where !placed.contains(ObjectIdentifier(view)) { view.isHidden = true }
    }

    // Chips fit their label, and tabs share the rest of the width equally. A gap takes the
    // room of the tabs and chip it stands for.
    private func layout(_ items: [StripItem], gap: (index: Int, room: Room)?) -> (frames: [NSRect], tabWidth: CGFloat) {
        let chipWidths = items.map { item -> CGFloat? in
            guard case .chip(let group) = item else { return nil }
            return chips[ObjectIdentifier(group)]?.fittingWidth ?? 0
        }
        let fixed = chipWidths.compactMap { $0 }
        let tabCount = items.count - fixed.count + (gap.map { $0.room.tabs - 1 } ?? 0)
        let free = bounds.width - Self.addWidth - fixed.reduce(0, +) - (gap?.room.chip ?? 0)
        let tabWidth = max(free / CGFloat(max(tabCount, 1)), Self.minTabWidth)
        var x: CGFloat = 0
        let frames = zip(items, chipWidths).map { item, chipWidth in
            var width = chipWidth ?? tabWidth
            if case .tab(let index) = item, let gap, index == gap.index { width = CGFloat(gap.room.tabs) * tabWidth + gap.room.chip }
            defer { x += width }
            // Whole points keep titles and dividers sharp.
            return NSRect(x: x.rounded(), y: 0, width: (x + width).rounded() - x.rounded(), height: bounds.height)
        }
        return (frames, tabWidth)
    }

    // MARK: Carrying tabs along the strip

    var isLifting: Bool { lift != nil }

    // Starts carrying the tabs from where the mouse went down on them.
    func startLift(_ moving: MovingTabs, pressedAt event: NSEvent) {
        guard let controller, lift == nil, let index = controller.tabs.firstIndex(of: moving.tabs[0]) else { return }
        let views: [NSView] = switch moving {
        case .tab(let tab): [buttons[ObjectIdentifier(tab)]].compactMap { $0 }
        case .group(let group, let tabs):
            [chips[ObjectIdentifier(group)]].compactMap { $0 } + (group.collapsed ? [] : tabs.compactMap { buttons[ObjectIdentifier($0)] })
        }
        guard let first = views.first else { return }
        for view in subviews where view !== addButton { view.layer?.zPosition = 0 }
        for view in views {
            view.wantsLayer = true
            view.layer?.zPosition = 1
        }
        backdrop = makeBackdrop()
        let x = first.frame.minX
        lift = Lift(moving: moving, views: views, grab: convert(event.locationInWindow, from: nil).x - x, x: x)
        let group: TabGroup? = if case .tab(let tab) = moving { tab.group } else { nil }
        drop = Drop(slot: StripSlot(index: index, group: group), room: room(for: moving))
        arrange(animated: true)
    }

    // Moves the carried tabs with the pointer, or hands them to a drag once the pointer
    // strays too far from the strip.
    func moveLift(with event: NSEvent) {
        guard var lift else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -Self.tearOff.width, dy: -Self.tearOff.height).contains(point) else {
            self.lift = nil
            drop = nil
            backdrop = nil
            beginDrag(lift.moving, showing: lift.views, with: event)
            return
        }
        let width = lift.views.reduce(0) { $0 + $1.frame.width }
        lift.x = min(max(point.x - lift.grab, 0), max(bounds.width - width, 0))
        self.lift = lift
        let next = nearestDrop(for: lift.moving, room: room(for: lift.moving), x: lift.x, centered: false)
        if next != drop {
            drop = next
            arrange(animated: true)
        } else {
            placeLifted()
        }
    }

    // Puts the carried tabs down where the gap is.
    func endLift() {
        guard let lift else { return }
        let drop = drop
        self.lift = nil
        self.drop = nil
        backdrop = nil
        if let drop { controller?.drop(lift.moving, at: drop.slot.index, in: drop.slot.group) } else { reload() }
    }

    // Lays the carried chip and tabs side by side from the lift's left edge. A carried tab
    // shows the group it would land in.
    private func placeLifted() {
        guard let lift, let drop else { return }
        var x = lift.x
        for view in lift.views {
            let width = (view as? GroupChip)?.fittingWidth ?? tabWidth
            view.frame = NSRect(x: x.rounded(), y: 0, width: (x + width).rounded() - x.rounded(), height: bounds.height)
            view.isHidden = false
            x += width
        }
        backdrop?.frame = NSRect(x: lift.x.rounded(), y: 0, width: x.rounded() - lift.x.rounded(), height: bounds.height)
        if case .tab = lift.moving, let button = lift.views.first as? TabButton { button.line = drop.slot.group?.color }
    }

    // A copy of the effect view the window draws its background with, or the plain color
    // when it has none.
    private func makeBackdrop() -> NSView {
        let view: NSView
        if let effect = window?.contentView?.superview?.subviews.first(where: { $0 is NSVisualEffectView }) as? NSVisualEffectView {
            let copy = NSVisualEffectView()
            copy.material = effect.material
            copy.blendingMode = effect.blendingMode
            copy.state = effect.state
            view = copy
        } else {
            view = BandView(shade: nil)
        }
        addSubview(view, positioned: .below, relativeTo: addButton)
        view.wantsLayer = true
        view.layer?.zPosition = 0.5
        return view
    }

    private func room(for moving: MovingTabs) -> Room {
        guard case .group(let group, let tabs) = moving else { return Room(tabs: 1, chip: 0) }
        return Room(tabs: group.collapsed ? 0 : tabs.count, chip: chips[ObjectIdentifier(group)]?.fittingWidth ?? 0)
    }

    // The drop nearest a moving block with its left edge at x, or its middle when centered.
    private func nearestDrop(for moving: MovingTabs, room: Room, x: CGFloat, centered: Bool) -> Drop {
        let groups = (controller?.tabs ?? []).filter { !moving.tabs.contains($0) }.map(\.group)
        let slots = if case .group = moving { StripLayout.groupSlots(groups) } else { StripLayout.tabSlots(groups) }
        let gaps = slots.map { slot in
            var withGap = groups
            withGap.insert(slot.group, at: slot.index)
            let items = StripLayout.items(withGap)
            return layout(items, gap: (slot.index, room)).frames[items.firstIndex(of: .tab(slot.index))!]
        }
        let left = centered ? x - (gaps.first?.width ?? 0) / 2 : x
        return Drop(slot: StripLayout.pick(slots, at: gaps.map(\.minX), x: left, current: drop?.slot), room: room)
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

    // The drag shows the carried views as they were, on the window color, since the
    // shown tab has no fill of its own. The image is centered on the pointer, where
    // strips open their gap.
    private func beginDrag(_ moving: MovingTabs, showing views: [NSView], with event: NSEvent) {
        var frame = views.dropFirst().reduce(views[0].frame) { $0.union($1.frame) }
        let shots = views.map { ($0.frame.offsetBy(dx: -frame.minX, dy: -frame.minY), $0.snapshot) }
        let point = convert(event.locationInWindow, from: nil)
        frame.origin = NSPoint(x: point.x - frame.width / 2, y: point.y - frame.height / 2)
        let background = window?.backgroundColor ?? .windowBackgroundColor
        let image = NSImage(size: frame.size, flipped: false) { rect in
            background.setFill()
            rect.fill()
            for (place, shot) in shots { shot.draw(in: place) }
            return true
        }
        let item = NSPasteboardItem()
        item.setString("tab", forType: Self.pasteboardType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(frame, contents: image)
        Self.drag = (self, moving)
        beginDraggingSession(with: [dragging], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    // Released outside every window, the tabs open in a new window there. Released
    // anywhere else but a strip, nothing moves.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // The local copy keeps this strip alive to the end of this method.
        guard let drag = Self.drag, drag.source === self else { return }
        Self.drag = nil
        let moving = drag.moving
        let overWindow = NSApp.windows.contains { $0.windowController is ReaderWindowController && $0.isVisible && $0.frame.contains(screenPoint) }
        if operation.isEmpty, !overWindow {
            // Puts the new window's strip under the pointer.
            controller?.moveToNewWindow(moving, at: NSPoint(x: screenPoint.x - 80, y: screenPoint.y + 64))
        }
    }

    // MARK: Dropping in

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let (source, moving) = Self.drag else { return [] }
        let x = convert(sender.draggingLocation, from: nil).x
        let next = nearestDrop(for: moving, room: source.room(for: moving), x: x, centered: true)
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
        guard let moving = Self.drag?.moving, let drop, let controller else { return false }
        self.drop = nil
        controller.drop(moving, at: drop.slot.index, in: drop.slot.group)
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

// A plain piece of the strip: the band, or the window's own background color when unshaded.
// In a group's run of tabs it carries the group's line.
@MainActor
private final class BandView: NSView {
    var line: GroupColor? { didSet { if line != oldValue { needsDisplay = true } } }
    private let shade: NSColor?

    init(shade: NSColor? = StripStyle.band) {
        self.shade = shade
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        if shade == nil {
            window?.backgroundColor.setFill()
            bounds.fill()
        }
        StripStyle.fill(bounds, in: self, shade: shade)
        if let line {
            line.color.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        }
    }
}

// One tab: a centered title, and a close button at the left under the pointer. It is
// selected on mouse down, as the system's tabs are, so a drag carries the shown tab.
@MainActor
private final class TabButton: NSView {
    let tab: ReaderTab
    // The color of the group it is in or would land in, drawn as a line along its bottom.
    var line: GroupColor? { didSet { if line != oldValue { needsDisplay = true } } }
    private weak var strip: TabStripView?
    private let label = NSTextField(labelWithString: "")
    private let closeButton = StripButton(kind: .close, label: "Close Tab")
    private var selected = false
    private var hovered = false { didSet { refresh() } }
    private var pressed: NSEvent?

    init(tab: ReaderTab, strip: TabStripView) {
        self.tab = tab
        self.strip = strip
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: TabStripView.height))
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        closeButton.frame = NSRect(x: 4, y: 6, width: 16, height: 16)
        closeButton.toolTip = "Close Tab (⌘W)"
        closeButton.run = { [weak self] in
            guard let self else { return }
            self.strip?.controller?.close([self.tab])
        }
        addSubview(label)
        addSubview(closeButton)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXTabButton"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(selected: Bool) {
        self.selected = selected
        line = tab.group?.color
        label.stringValue = tab.title ?? ""
        toolTip = tab.readerDocument.map { ($0.url.path as NSString).abbreviatingWithTildeInPath } ?? tab.title
        setAccessibilityLabel(tab.title)
        setAccessibilityValue(selected ? 1 : 0)
        refresh()
    }

    private func refresh() {
        label.textColor = StripStyle.titleColor(selected: selected, in: self)
        closeButton.isHidden = !hovered || strip?.isLifting == true
        placeLabel()
        needsDisplay = true
    }

    // A wide tab keeps its title centered, with room for the close button on both sides.
    // A narrow one gives the title its whole width until the close button shows.
    private func placeLabel() {
        let (left, right): (CGFloat, CGFloat) = bounds.width >= 96 ? (24, 24) : (closeButton.isHidden ? 6 : 22, 6)
        label.frame = NSRect(x: left, y: 6, width: max(bounds.width - left - right, 0), height: 16)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        placeLabel()
    }

    override func draw(_ dirtyRect: NSRect) {
        StripStyle.fill(bounds, in: self, shade: selected ? nil : hovered ? StripStyle.hover : StripStyle.band)
        StripStyle.divider(at: bounds.maxX - 1, in: self)
        // A group's tabs sit on a line in its color that continues from the chip.
        if let line {
            line.color.setFill()
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

    // The group's only tab carries its group along.
    override func mouseDragged(with event: NSEvent) {
        guard let strip, let controller = strip.controller else { return }
        if strip.isLifting { strip.moveLift(with: event); return }
        guard let pressed, movedEnough(from: pressed, to: event) else { return }
        self.pressed = nil
        let moving: MovingTabs = if let group = tab.group, controller.tabs(in: group).count == 1 { .group(group, [tab]) } else { .tab(tab) }
        strip.startLift(moving, pressedAt: pressed)
        strip.moveLift(with: event)
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        pressed = nil
        strip?.endLift()
    }

    // A middle click closes the tab.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { strip?.controller?.close([tab]) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { strip?.controller?.menu(for: tab) }

    override func accessibilityPerformPress() -> Bool {
        strip?.controller?.select(tab)
        return true
    }
}

// A group's chip: a segment tinted with its color, holding its name, or a dot when it
// has no name. A click collapses or expands the group, a drag moves the whole group,
// and a right-click edits it. A collapsed chip also shows how many tabs it holds.
@MainActor
private final class GroupChip: NSView {
    let group: TabGroup
    private weak var strip: TabStripView?
    private var hiddenTabs = 0
    private var pressed: NSEvent?
    private var hovered = false { didSet { needsDisplay = true } }

    init(group: TabGroup, strip: TabStripView) {
        self.group = group
        self.strip = strip
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: TabStripView.height))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
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

    private var dotWidth: CGFloat { group.name.isEmpty ? (hiddenTabs > 0 ? 13 : 8) : 0 }

    var fittingWidth: CGFloat { max(ceil(text.size().width + dotWidth) + 24, 28) }

    override func draw(_ dirtyRect: NSRect) {
        let color = group.color.color
        StripStyle.fill(bounds, in: self, shade: hovered ? StripStyle.hover : StripStyle.band)
        color.withAlphaComponent(0.2).setFill()
        bounds.fill(using: .sourceOver)
        StripStyle.divider(at: bounds.maxX - 1, in: self)
        let text = text
        let size = text.size()
        var x = ((bounds.width - 1 - size.width - dotWidth) / 2).rounded()
        if group.name.isEmpty {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - 4, width: 8, height: 8)).fill()
            x += dotWidth
        }
        text.draw(at: NSPoint(x: x, y: bounds.midY - size.height / 2))
        if !group.collapsed {
            color.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { strip?.edit(group); return }
        pressed = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let strip, let controller = strip.controller else { return }
        if strip.isLifting { strip.moveLift(with: event); return }
        guard let pressed, movedEnough(from: pressed, to: event) else { return }
        self.pressed = nil
        strip.startLift(.group(group, controller.tabs(in: group)), pressedAt: pressed)
        strip.moveLift(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if pressed != nil { strip?.controller?.toggle(group) }
        pressed = nil
        strip?.endLift()
    }

    override func rightMouseDown(with event: NSEvent) { strip?.edit(group) }

    override func accessibilityPerformPress() -> Bool {
        strip?.controller?.toggle(group)
        return true
    }
}

// The strip's small buttons, drawn as the system tab bar's: a tab's close button, which
// shades a rounded square under the pointer, and the new tab button, a band segment
// that lightens under the pointer.
@MainActor
private final class StripButton: NSView {
    enum Kind { case close, add }

    var run: (() -> Void)?
    private let kind: Kind
    private let image: NSImage?
    private var hovered = false { didSet { needsDisplay = true } }

    init(kind: Kind, label: String) {
        self.kind = kind
        image = switch kind {
        case .close: NSImage(systemSymbolName: "xmark", accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        case .add: NSImage(named: NSImage.addTemplateName)
        }
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isHidden: Bool { didSet { if isHidden { hovered = false } } }

    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .close:
            if hovered {
                StripStyle.buttonHover.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
            }
        case .add:
            StripStyle.fill(bounds, in: self, shade: hovered ? StripStyle.hover : StripStyle.band)
            StripStyle.divider(at: 0, in: self)
        }
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let size = kind == .add ? NSSize(width: 14, height: 13) : image.size
        let rect = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        // Recolors the template image inside its own layer, so the tint stays off the background.
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        image.draw(in: rect)
        (kind == .add ? StripStyle.titleColor(selected: false, in: self) : NSColor.secondaryLabelColor).setFill()
        rect.fill(using: .sourceIn)
        context.endTransparencyLayer()
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { run?() }
    }

    override func accessibilityPerformPress() -> Bool {
        run?()
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
