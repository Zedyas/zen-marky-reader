import AppKit
import Testing
@testable import ZenMarky

@MainActor
private final class Owner: ReaderWindowOwner {
    let renderer = try! DocumentRenderer()
    func makeTab() -> ReaderTab { ReaderTab(renderer: renderer, preferences: ReaderPreferences()) }
    func openWindow(with tabs: [ReaderTab], topLeft: NSPoint?) {}
    func windowClosed(_ controller: ReaderWindowController) {}
}

@MainActor
struct WindowTabsTests {
    @Test func testMovesAndClosesKeepTheShownTabAndCollapsedGroups() {
        _ = NSApplication.shared
        let owner = Owner()
        let window = ReaderWindowController(preferences: ReaderPreferences(), app: owner)
        let group = TabGroup(color: .blue, collapsed: true)
        let (shown, first, second) = (owner.makeTab(), owner.makeTab(), owner.makeTab())
        first.group = group
        second.group = group
        window.insert([shown, first, second], at: 0)
        #expect(window.selectedTab === shown)

        // Moving the shown tab past the collapsed group, then the group back past it, changes neither.
        window.drop(.tab(shown), at: 2, in: nil)
        window.drop(.group(group, [first, second]), at: 1, in: nil)
        #expect(window.tabs == [shown, first, second])
        #expect(window.selectedTab === shown)
        #expect(group.collapsed)

        // Closing the only visible tab opens a new one instead of the collapsed group.
        window.close([shown])
        #expect(window.tabs.count == 3)
        #expect(group.collapsed)
        #expect(window.selectedTab.map { $0.group == nil } == true)
        window.close()
    }
}
