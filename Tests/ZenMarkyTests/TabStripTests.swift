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

    @Test func testADroppedTabJoinsTheGroupItLandsIn() {
        func drop(at x: CGFloat) -> (index: Int, group: TabGroup?) {
            StripLayout.tabDrop(at: x, items: items, frames: frames, groups: groups)
        }
        // Chip a: the left half is before the group, the right half is first in it.
        #expect(drop(at: 20).index == 0 && drop(at: 20).group == nil)
        #expect(drop(at: 80).index == 0 && drop(at: 80).group === a)
        // The same gap after group a's last tab is inside the group from the tab's side and outside from the next tab's.
        #expect(drop(at: 280).index == 2 && drop(at: 280).group === a)
        #expect(drop(at: 320).index == 2 && drop(at: 320).group == nil)
        // A collapsed group is passed over, and past the end is ungrouped.
        #expect(drop(at: 480).index == 5 && drop(at: 480).group == nil)
        #expect(drop(at: 900).index == 5 && drop(at: 900).group == nil)
    }

    @Test func testADroppedGroupNeverLandsInsideAnother() {
        func drop(at x: CGFloat) -> Int { StripLayout.groupDrop(at: x, items: items, frames: frames, groups: groups) }
        // Group a covers 0–300, so its middle is 150.
        #expect(drop(at: 120) == 0)
        #expect(drop(at: 250) == 2)
        #expect(drop(at: 320) == 2)
        #expect(drop(at: 380) == 3)
    }
}
