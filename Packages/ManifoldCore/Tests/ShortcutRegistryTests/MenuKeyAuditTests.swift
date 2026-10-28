import XCTest
import AppKit
@testable import ShortcutRegistry

/// The menu bar against the registry (2026-10-27, Robbie's checklist item 1): every `.menu` action in its menu with its key,
/// and no other item, hidden ones included, holding that key. `KeyDispatchTests.testEveryMenuActionKeyReachesItsMenuItem`
/// is the dispatch half.
@MainActor
final class MenuKeyAuditTests: XCTestCase {
    private var suite: String!
    private var registry: ShortcutRegistry!

    override func setUp() {
        super.setUp()
        suite = "MenuKeyAuditTests.\(UUID().uuidString)"
        registry = ShortcutRegistry(store: ShortcutStore(defaults: UserDefaults(suiteName: suite)!), layout: USKeyLayout(),
                                    debugTierEnabled: { _ in false })
    }
    override func tearDown() { UserDefaults().removePersistentDomain(forName: suite); super.tearDown() }

    /// A menu bar that is exactly what the registry asks for.
    private func goodMenus() -> [MenuItemSnapshot] {
        registry.definitions.filter { $0.dispatch == .menu && $0.debug == nil }.map { def in
            let want = registry.menuChord(for: def.id).flatMap { MenuKeyAudit.expected($0, layout: USKeyLayout()) }
            return MenuItemSnapshot(menu: MenuKeyAudit.menuHomes[def.id]!, title: def.title,
                                    keyEquivalent: want?.key ?? "", modifiers: want?.modifiers ?? [])
        } + [MenuItemSnapshot(menu: "Manifold", title: "Quit Manifold", keyEquivalent: "q", modifiers: .command)]
    }

    func testEveryMenuActionHasAHomeAndNothingElseDoes() {
        let menuIDs = Set(ShortcutCatalog.all.filter { $0.dispatch == .menu }.map(\.id))
        XCTAssertEqual(Set(MenuKeyAudit.menuHomes.keys), menuIDs)
        XCTAssertEqual(MenuKeyAudit.menuHomes[.scopesTray], "View")
    }

    func testAMenuBarThatMatchesTheRegistryPasses() {
        XCTAssertEqual(MenuKeyAudit.audit(goodMenus(), registry: registry, layout: USKeyLayout()), [])
    }

    /// The bug: SwiftUI's hidden View ▸ Toggle Sidebar holds ⌥⌘S too.
    func testAHiddenItemWithTheSameKeyIsReported() {
        let menus = goodMenus() + [MenuItemSnapshot(menu: "View", title: "Toggle Sidebar", keyEquivalent: "s",
                                                    modifiers: [.command, .option], isHidden: true)]
        XCTAssertEqual(MenuKeyAudit.audit(menus, registry: registry, layout: USKeyLayout()),
                       [.keyTaken(.scopesTray, by: "View ▸ Toggle Sidebar (hidden)")])
    }

    /// …and what it did on the launches where SwiftUI blanked ours: the item is there with no key.
    func testAnItemThatLostItsKeyIsReported() {
        let menus = goodMenus().map { $0.title == "Show/Hide Scopes"
            ? MenuItemSnapshot(menu: "View", title: $0.title, keyEquivalent: "", modifiers: [.command, .option]) : $0 }
        XCTAssertEqual(MenuKeyAudit.audit(menus, registry: registry, layout: USKeyLayout()),
                       [.wrongKey(.scopesTray, found: "no key")])
    }

    func testAMissingOrHiddenItemIsReported() {
        let without = goodMenus().filter { $0.title != "Show/Hide Scopes" }
        XCTAssertEqual(MenuKeyAudit.audit(without, registry: registry, layout: USKeyLayout()), [.missing(.scopesTray, menu: "View")])
        let elsewhere = without + [MenuItemSnapshot(menu: "Window", title: "Show/Hide Scopes", keyEquivalent: "s",
                                                    modifiers: [.command, .option])]
        XCTAssertEqual(MenuKeyAudit.audit(elsewhere, registry: registry, layout: USKeyLayout()), [.missing(.scopesTray, menu: "View")])
    }

    /// The walker reads a real `NSMenu`: submenus, hidden items and the top-level menu's name.
    func testSnapshotOfARealMenuBar() {
        let bar = NSMenu()
        let view = NSMenuItem(title: "View", action: nil, keyEquivalent: ""); view.submenu = NSMenu(title: "View")
        bar.addItem(view)
        let scopes = NSMenuItem(title: "Show/Hide Scopes", action: nil, keyEquivalent: "s")
        scopes.keyEquivalentModifierMask = [.command, .option]
        view.submenu!.addItem(scopes)
        let audio = NSMenuItem(title: "Audio", action: nil, keyEquivalent: ""); audio.submenu = NSMenu(title: "Audio")
        view.submenu!.addItem(audio)
        let sidebar = NSMenuItem(title: "Toggle Sidebar", action: nil, keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .option]; sidebar.isHidden = true
        audio.submenu!.addItem(sidebar)
        let snap = MenuItemSnapshot.all(in: bar)
        XCTAssertEqual(snap.map(\.title), ["Show/Hide Scopes", "Audio", "Toggle Sidebar"])
        XCTAssertEqual(Set(snap.map(\.menu)), ["View"])
        XCTAssertEqual(snap.last?.isHidden, true)
        XCTAssertEqual(snap.first?.modifiers, NSEvent.ModifierFlags([.command, .option]).rawValue)
    }
}
