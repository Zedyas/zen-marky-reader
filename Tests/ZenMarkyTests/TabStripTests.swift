import Foundation
import Testing
@testable import ZenMarky

struct TabStripTests {
    // Group a holds tabs 0 and 1, tab 2 has no group, and collapsed group b holds tabs 3 and 4.
    // At rest the strip reads: chip a, tab 0, tab 1, tab 2, chip b, each item 100 points wide.
    let a = TabGroup(color: .blue)
    let b = TabGroup(color: .red, collapsed: true)
    var groups: [TabGroup?] { [a, a, nil, b, b] }
    var items: [StripItem] { StripLayout.items(groups) }
    var frames: [NSRect] { items.indices.map { NSRect(x: CGFloat($0) * 100, y: 0, width: 100, height: 34) } }

    @Test func testChipsLeadGroupsAndCollapsedGroupsShowOnlyTheirChip() {
        #expect(items == [.chip(a), .tab(0), .tab(1), .tab(2), .chip(b)])
    }

    @Test func testATabLeavingItsGroupsMiddleMovesAfterTheGroup() {
        let tabs: [(name: String, group: TabGroup?)] = [("first", a), ("left", nil), ("last", a)]
        #expect(StripLayout.keepingGroupsTogether(tabs) { $0.group }.map(\.name) == ["first", "last", "left"])
    }

    @Test func testATabLandsBetweenAnyTabsButNotInACollapsedGroup() {
        let slots = StripLayout.tabSlots(groups).map { "\($0.index)\($0.group === a ? "a" : $0.group == nil ? "" : "?")" }
        // Before chip a or after it; inside a; at a's end in it or after it; then around the collapsed group b.
        #expect(slots == ["0", "0a", "1a", "2a", "2", "3", "5"])
    }

    @Test func testAGroupLandsOnlyBetweenGroups() {
        #expect(StripLayout.groupSlots(groups).map(\.index) == [0, 2, 3, 5])
    }

    @Test func testATabAtAGroupsEndLeavesItOnlyWhenMovedPastTheMargin() {
        let slots = StripLayout.tabSlots(groups)
        let positions: [CGFloat] = [0, 40, 140, 240, 240, 340, 380]
        func pick(_ x: CGFloat, from current: StripSlot?) -> StripSlot {
            StripLayout.pick(slots, at: positions, x: x, current: current)
        }
        let (inside, outside) = (StripSlot(index: 2, group: a), StripSlot(index: 2))
        // The nearest gap wins elsewhere, so chip a's middle divides before it from inside it.
        #expect(pick(15, from: nil) == StripSlot(index: 0))
        #expect(pick(25, from: nil) == StripSlot(index: 0, group: a))
        // At a's end the slot held is kept within 8 points either side.
        #expect(pick(245, from: inside) == inside)
        #expect(pick(235, from: outside) == outside)
        #expect(pick(250, from: inside) == outside)
        #expect(pick(230, from: outside) == inside)
    }
}
