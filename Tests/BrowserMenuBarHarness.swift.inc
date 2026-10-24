extension BrowserMenuBar {
    func verifyOrganization() -> Bool {
        let flat=NSMenu(), grouped=NSMenu()
        buildSettingsItems(flat);rebuildMenu(grouped)
        func controls(_ menu:NSMenu) -> [String] {
            menu.items.flatMap { item -> [String] in
                if let child=item.submenu {return controls(child)}
                if let action=item.action {return [item.title+"|"+NSStringFromSelector(action)+"|"+String(item.tag)]}
                if let view=item.view {return view.subviews.compactMap { ($0 as? NSSlider).map {"slider:"+String($0.tag)} }}
                return []
            }.sorted()
        }
        guard controls(flat)==controls(grouped) else {print("FAIL: menu lost settings");return false}
        let categories=["Tabs & Search","Profiles & Fuse","Appearance","Widgets & Backgrounds","Pets & Indicators","History & Passwords"]
        guard grouped.items.filter({$0.submenu != nil}).map(\.title)==categories,
              grouped.items.first?.title=="Show Browser",grouped.items[1].title=="Add Widget…",
              grouped.items.last?.title=="Quit Webby" else {return false}
        let focused=makeTabSettingsMenu()
        guard focused.items.contains(where:{$0.title=="Tab Layout"}),
              focused.items.contains(where:{$0.title=="Restore Tabs After Restart"}),
              focused.items.filter({$0.view != nil}).count==4 else{return false}
        // Opening the menu again must rebuild valid ownership, actions and current checkmarks.
        menuWillOpen(grouped)
        guard controls(flat)==controls(grouped) else{return false}
        print("PASS: grouped menus preserve every action/slider, focused tab settings, repeated opening")
        return true
    }
}
