extension BrowserMenuBar {
    func verifyOrganization() -> Bool {
        let flat = NSMenu()
        buildSettingsItems(flat)
        let status = NSMenu()
        rebuildMenu(status)

        func controls(_ items: [NSMenuItem]) -> [String] {
            items.flatMap { item -> [String] in
                if let child = item.submenu { return controls(child.items) }
                if let action = item.action {
                    return [item.title + "|" + NSStringFromSelector(action) + "|" + String(item.tag)]
                }
                if let view = item.view {
                    return view.subviews.compactMap { ($0 as? NSSlider).map { "slider:" + String($0.tag) } }
                }
                return []
            }.sorted()
        }

        let catalog = settingsCatalog()
        let visibleSettings = controls(BrowserSettingsSection.allCases.flatMap { catalog[$0] ?? [] })
        let shortcuts = controls(status.items.filter { $0.title == "Add Widget…" })
        let source = controls(flat.items)
        guard source.allSatisfy({ visibleSettings.contains($0) || shortcuts.contains($0) }),
              catalog[.engines]?.first?.title == "Default Rendering Engine",
              status.items.filter({ !$0.isSeparatorItem }).map(\.title) ==
                ["Show Browser", "Settings…", "Add Widget…", "Quit Webby"],
              makeTabSettingsMenu().items.first?.title == "Tabs & Navigation Settings…" else { return false }
        print("PASS: searchable settings catalog preserves controls, with a dedicated engine page and simple shortcuts")
        return true
    }

}
