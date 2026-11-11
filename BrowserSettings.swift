import AppKit
import SwiftUI

enum BrowserSettingsSection: String, CaseIterable, Identifiable {
    case general, tabs, engines, appearance, profiles, homepage, pets, privacy

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .tabs: return "Tabs & Navigation"
        case .engines: return "Engine Rules"
        case .appearance: return "Appearance"
        case .profiles: return "Profiles"
        case .homepage: return "Homepage & Widgets"
        case .pets: return "Pets & Indicators"
        case .privacy: return "Privacy & Data"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .tabs: return "rectangle.on.rectangle"
        case .engines: return "arrow.triangle.branch"
        case .appearance: return "paintpalette"
        case .profiles: return "person.crop.circle"
        case .homepage: return "square.grid.2x2"
        case .pets: return "pawprint"
        case .privacy: return "lock.shield"
        }
    }


}

@MainActor final class BrowserSettingsModel: ObservableObject {
    @Published var section: BrowserSettingsSection = .general
    @Published var query = ""
    @Published private(set) var items: [BrowserSettingsSection: [NSMenuItem]] = [:]
    @Published private(set) var profileName = ""
    @Published private(set) var palette = BrowserTheme.profile.palette
    @Published private(set) var pet: NSImage?
    @Published var draft: EngineRuleDraft?
    @Published private(set) var rules = BrowserEngineRule.saved

    private var petURL: URL?
    private let catalog: () -> [BrowserSettingsSection: [NSMenuItem]]
    private let profile: () -> String

    init(catalog: @escaping () -> [BrowserSettingsSection: [NSMenuItem]], profile: @escaping () -> String) {
        self.catalog = catalog
        self.profile = profile
    }

    func refresh() {
        profileName = profile()
        palette = BrowserTheme.profile.palette
        let petURL = BrowserTheme.customPetURL
            ?? Bundle.main.url(forResource: BrowserTheme.petID, withExtension: "png", subdirectory: "Pets")
        if petURL != self.petURL {
            self.petURL = petURL
            pet = petURL.flatMap { NSImage(contentsOf: $0) }
        }
        items = catalog()
        rules = BrowserEngineRule.saved
    }

    func open(section: BrowserSettingsSection?, ruleAddress: URL?) {
        if let section { self.section = section; query = "" }
        if let ruleAddress, ruleAddress.host != nil {
            draft = EngineRuleDraft(input: ruleAddress.absoluteString,
                                    engine: BrowserEngineRule.engine(for: ruleAddress) ?? BrowserEngine.defaultEngine)
        }
        refresh()
    }

    func save(_ rule: BrowserEngineRule, replacing original: BrowserEngineRule?) {
        var updated = BrowserEngineRule.saved
        updated.removeAll { $0.id == rule.id || $0.id == original?.id }
        updated.append(rule)
        BrowserEngineRule.saved = updated
        rules = updated
    }

    func remove(_ rule: BrowserEngineRule) {
        let updated = BrowserEngineRule.saved.filter { $0.id != rule.id }
        BrowserEngineRule.saved = updated
        rules = updated
    }

    func perform(_ item: NSMenuItem) {
        guard item.isEnabled, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
        refresh()
    }
}

struct BrowserSettingsPage {
    static let address = "webby://settings"
    static let sidebarMinimumWidth: CGFloat = 730
    let model: BrowserSettingsModel
    let view: NSView

    @MainActor init(model: BrowserSettingsModel) {
        self.model = model
        // The browser owns the viewport size. Keep the SwiftUI content's
        // preferred dimensions out of the browser window's size constraints.
        let container = NSView()
        let host = NSHostingView(rootView: BrowserSettingsView(model: model))
        host.sizingOptions = []
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        view = container
    }
}

struct EngineRuleDraft: Identifiable {
    let id = UUID()
    var original: BrowserEngineRule?
    var input = ""
    var scope: BrowserEngineRule.Scope = .site
    var engine = BrowserEngine.webKit
}

private struct BrowserSettingsView: View {
    @ObservedObject var model: BrowserSettingsModel
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var themeColor: Color { Color(nsColor: BrowserTheme.color(model.palette.primary)) }
    private var themeHighlight: Color { Color(nsColor: BrowserTheme.color(model.palette.accent)) }
    private var panel: Color { Color(nsColor: .controlBackgroundColor) }

    private var query: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= BrowserSettingsPage.sidebarMinimumWidth {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    detail
                }
            } else {
                VStack(spacing: 0) {
                    compactNavigation
                    Divider()
                    detail
                }
            }
        }
        .background {
            panel.overlay {
                RadialGradient(colors: [themeColor.opacity(colorScheme == .dark ? 0.15 : 0.20), .clear],
                               center: .topTrailing, startRadius: 15, endRadius: 580)
            }
        }
        .tint(colorScheme == .dark ? themeColor : .accentColor)
        .onReceive(NotificationCenter.default.publisher(for: .browserThemeChanged)) { _ in model.refresh() }
        .sheet(item: $model.draft) { draft in
            EngineRuleEditor(draft: draft) { rule in
                model.save(rule, replacing: draft.original)
                model.draft = nil
            } cancel: { model.draft = nil }
        }
    }

    private var compactNavigation: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(BrowserSettingsSection.allCases) { section in
                    Button { select(section) } label: { Label(section.title, systemImage: section.symbol) }
                }
            } label: {
                Label(model.section.title, systemImage: model.section.symbol)
            }
            .fixedSize()
            searchField
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private func select(_ section: BrowserSettingsSection) {
        model.section = section
        model.query = ""
        searchFocused = false
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Group {
                    if let pet = model.pet {
                        Image(nsImage: pet).resizable().scaledToFit()
                    } else {
                        Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit()
                    }
                }
                .frame(width: 28, height: 28)
                .padding(6)
                .background(themeColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

                Text("Webby")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .tracking(-0.6)
            }
            .padding(.horizontal, 3)

            searchField

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(BrowserSettingsSection.allCases) { section in
                        let selected = query.isEmpty && model.section == section
                        Button { select(section) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: section.symbol)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(selected ? .primary : .secondary)
                                    .frame(width: 19)
                                Text(section.title)
                                    .fontWeight(selected ? .semibold : .regular)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .background(selected ? themeColor.opacity(0.17) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(SettingsHoverStyle(radius: 9))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            Spacer(minLength: 0)
            Button { select(.profiles) } label: {
                HStack(spacing: 8) {
                    Circle().fill(themeColor).frame(width: 7, height: 7)
                    Text(model.profileName).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(9)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(SettingsHoverStyle(radius: 9))
            .accessibilityLabel("Active profile: " + model.profileName)
            .accessibilityHint("Opens Profiles")
        }
        .padding(15)
        .frame(width: 210)
        .background(.primary.opacity(0.035))
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search settings", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search settings")
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(8)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(
                searchFocused ? Color.accentColor.opacity(0.65) : .primary.opacity(0.09))
        }
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(query.isEmpty ? model.section.title : "Search Results")
                    .font(.system(size: 42, weight: .bold))
                    .tracking(-1.8)
                    .accessibilityAddTraits(.isHeader)

                if query.isEmpty {
                    switch model.section {
                    case .engines:
                        engineChoices(model.items[.engines] ?? [])
                        engineRules
                    case .appearance:
                        let items = model.items[.appearance] ?? []
                        if let editor = items.first, editor.title == "Window Appearance…" {
                            appearancePreview(editor)
                            settingCards(Array(items.dropFirst()), filter: "")
                        } else {
                            settingCards(items, filter: "")
                        }
                    default:
                        settingCards(model.items[model.section] ?? [], filter: "")
                    }
                } else {
                    searchResults
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .id(query.isEmpty ? model.section.rawValue : "search")
    }

    private func appearancePreview(_ editor: NSMenuItem) -> some View {
        Button { model.perform(editor) } label: {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "macwindow").font(.title3)
                    Text("Window Appearance").font(.title3.weight(.semibold))
                    Text("Customize").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                miniature
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(
                LinearGradient(colors: [themeColor.opacity(0.18), themeHighlight.opacity(0.07)],
                               startPoint: .topTrailing, endPoint: .bottomLeading),
                in: RoundedRectangle(cornerRadius: 18)
            )
        }
        .buttonStyle(SettingsHoverStyle(radius: 18))
        .disabled(!editor.isEnabled)
    }

    private var miniature: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.8)).frame(width: 5, height: 5)
                }
                Spacer()
                Capsule().strokeBorder(.white.opacity(0.3)).frame(width: 43, height: 8)
            }
            .padding(7)
            HStack(spacing: 5) {
                VStack(spacing: 4) {
                    Capsule().fill(.white.opacity(0.6)).frame(height: 4)
                    Capsule().fill(.white.opacity(0.26)).frame(height: 4)
                    Spacer(minLength: 0)
                }
                .frame(width: 18)
                .padding(4)
                RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.46))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.12))
                    }
            }
            .padding([.horizontal, .bottom], 5)
        }
        .frame(width: 125, height: 76)
        .background(
            LinearGradient(colors: [themeColor, themeHighlight], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.3)) }
        .shadow(color: .black.opacity(0.18), radius: 9, y: 5)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func engineChoices(_ items: [NSMenuItem]) -> some View {
        if let menu = items.first?.submenu {
            VStack(alignment: .leading, spacing: 10) {
                Text("Default for New Tabs").font(.headline).accessibilityAddTraits(.isHeader)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { engineCards(menu.items) }
                    VStack(spacing: 10) { engineCards(menu.items) }
                }
            }
        }
    }

    @ViewBuilder private func engineCards(_ items: [NSMenuItem]) -> some View {
        ForEach(BrowserEngine.allCases, id: \.self) { engine in
            if let item = items.first(where: { ($0.representedObject as? String) == engine.rawValue }) {
                SettingsEngineTile(engine: engine, selected: item.state == .on) {
                    model.perform(item)
                }
                .disabled(!item.isEnabled)
                .help(item.isEnabled ? "Use " + engine.name + " for new tabs" : "Chromium is unavailable")
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let matches = BrowserSettingsSection.allCases.filter { section in
            (model.items[section] ?? []).contains { itemMatches($0, query) } ||
                (section == .engines && (matchesText("engine rules webkit chromium always open link site", query)
                    || model.rules.contains { matchesText($0.address, query) }))
        }
        if matches.isEmpty {
            ContentUnavailableView("No settings found", systemImage: "magnifyingglass",
                                   description: Text("Try a term like glass, passwords, or tabs."))
        }
        ForEach(matches) { section in
            Text(section.title).font(.headline).accessibilityAddTraits(.isHeader)
            if section == .engines {
                engineChoices(model.items[.engines] ?? [])
                Button("Manage Site & Link Rules") { select(.engines) }
            } else {
                settingCards(model.items[section] ?? [], filter: query)
            }
        }
    }

    private func matchesText(_ value: String, _ filter: String) -> Bool {
        filter.split(whereSeparator: \.isWhitespace).allSatisfy {
            value.localizedCaseInsensitiveContains(String($0))
        }
    }

    private func itemMatches(_ item: NSMenuItem, _ filter: String) -> Bool {
        guard !item.isSeparatorItem else { return false }
        return matchesText(item.title + " " + Self.descriptions[item.title, default: ""], filter) ||
            item.submenu?.items.contains { itemMatches($0, filter) } == true
    }

    private func cards(_ items: [NSMenuItem], filter: String) -> [[NSMenuItem]] {
        var groups: [[NSMenuItem]] = [[]]
        for item in items {
            if item.isSeparatorItem {
                if groups.last?.isEmpty == false { groups.append([]) }
            } else if filter.isEmpty || itemMatches(item, filter) {
                groups[groups.count - 1].append(item)
            }
        }
        return groups.filter { !$0.isEmpty }
    }

    private func settingCards(_ items: [NSMenuItem], filter: String) -> some View {
        ForEach(Array(cards(items, filter: filter).enumerated()), id: \.offset) { _, group in
            card {
                ForEach(Array(group.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().padding(.horizontal, 14) }
                    settingRow(item, filter: filter)
                }
            }
        }
    }

    // Type erase only at submenu boundaries so nested settings stay searchable.
    private func settingRow(_ item: NSMenuItem, filter: String) -> AnyView {
        if let slider = item.view?.subviews.compactMap({ $0 as? NSSlider }).first {
            return AnyView(SettingsSlider(title: item.title, slider: slider))
        }
        if let submenu = item.submenu {
            let actions = submenu.items.filter { $0.action != nil }
            if actions.count > 1, actions.count == submenu.items.filter({ $0.action != nil || $0.submenu != nil }).count,
               Set(actions.compactMap { $0.action.map(NSStringFromSelector) }).count == 1,
               actions.contains(where: { $0.state == .on }) {
                return AnyView(choiceRow(item.title, actions: actions))
            }
            let childFilter = matchesText(item.title, filter) ? "" : filter
            if !filter.isEmpty {
                return AnyView(VStack(alignment: .leading, spacing: 8) {
                    label(item.title)
                    settingCards(submenu.items, filter: childFilter)
                }.padding(.horizontal, 14).padding(.vertical, 11))
            }
            return AnyView(DisclosureGroup {
                settingCards(submenu.items, filter: childFilter).padding(.top, 8)
            } label: {
                label(item.title)
            }.padding(.horizontal, 14).padding(.vertical, 11))
        }
        if let action = item.action, NSStringFromSelector(action).hasPrefix("toggle") {
            return AnyView(HStack(spacing: 16) {
                label(item.title).accessibilityHidden(true)
                Spacer(minLength: 0)
                Toggle(item.title, isOn: Binding(get: { item.state == .on }, set: { _ in model.perform(item) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .disabled(!item.isEnabled)
            .padding(.horizontal, 14).padding(.vertical, 11))
        }
        if item.action != nil {
            return AnyView(Button { model.perform(item) } label: {
                HStack {
                    label(item.title)
                    Spacer()
                    Image(systemName: item.title.hasSuffix("…") ? "arrow.up.right" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14).padding(.vertical, 11)
            }.buttonStyle(.plain).disabled(!item.isEnabled))
        }
        return AnyView(Text(item.title).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 8))
    }

    private func choiceRow(_ title: String, actions: [NSMenuItem]) -> some View {
        HStack(spacing: 16) {
            label(title)
            Spacer(minLength: 0)
            Menu(actions.first(where: { $0.state == .on })?.title ?? "Choose") {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, option in
                    Button { model.perform(option) } label: {
                        if option.state == .on { Label(option.title, systemImage: "checkmark") }
                        else { Text(option.title) }
                    }
                    .disabled(!option.isEnabled)
                }
            }
            .fixedSize()
            .accessibilityLabel(title)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .fontWeight(.medium)
            .fixedSize(horizontal: false, vertical: true)
            .help(Self.descriptions[title, default: title])
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)).allowsHitTesting(false) }
    }

    private var engineRules: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Site & Link Rules").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { model.draft = EngineRuleDraft() } label: { Label("Add Rule", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            if model.rules.isEmpty {
                card {
                    Label("No rules yet", systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
            } else {
                card {
                    ForEach(model.rules.sorted { $0.address.localizedStandardCompare($1.address) == .orderedAscending }) { rule in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.address).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(rule.address)
                                Text(rule.scope.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label {
                                Text(rule.engine.name).font(.caption.weight(.medium))
                            } icon: {
                                SettingsEngineLogo(engine: rule.engine, size: 17)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.primary.opacity(0.06), in: Capsule())
                            Button {
                                model.draft = EngineRuleDraft(original: rule, input: rule.address, scope: rule.scope, engine: rule.engine)
                            } label: { Image(systemName: "pencil") }
                            .help("Edit rule").accessibilityLabel("Edit rule for " + rule.address)
                            Button {
                                model.remove(rule)
                            } label: { Image(systemName: "minus.circle") }
                            .help("Remove rule").accessibilityLabel("Remove rule for " + rule.address)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                Text("All profiles · Exact links take priority")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Rules apply to all profiles. WebKit and Chromium keep separate sign-ins.")
        }
    }

    private static let descriptions = [
        "Default Rendering Engine": "Used for new tabs when no engine rule matches.",
        "Tab Layout": "Place tabs across the top or in a vertical sidebar.",
        "Restore Tabs After Restart": "Reopen your tabs when you launch Webby again.",
        "Offload Idle Tabs": "Free memory from unused tabs. They reload when selected.",
        "Glass Effect on Web Pages": "Allow compatible pages to blend into the WebKit backdrop.",
        "Fuse All Profile Tabs": "Show tabs from every profile in a single tab list."
    ]
}

private struct SettingsHoverStyle: ButtonStyle {
    var radius: CGFloat
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.09 : hovered ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: radius))
            .onHover { hovered = $0 }
    }
}

private struct SettingsEngineLogo: View {
    let engine: BrowserEngine
    let size: CGFloat

    private static let images: [BrowserEngine: NSImage] = Dictionary(
        uniqueKeysWithValues: BrowserEngine.allCases.compactMap { engine in
            guard let url = Bundle.main.url(forResource: engine.name, withExtension: "png", subdirectory: "SettingsAssets"),
                  let image = NSImage(contentsOf: url) else { return nil }
            return (engine, image)
        }
    )

    var body: some View {
        Group {
            if let image = Self.images[engine] {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: engine == .webKit ? "safari" : "globe")
                    .resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SettingsEngineTile: View {
    let engine: BrowserEngine
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    private var color: Color { engine == .webKit ? Color.cyan : Color.blue }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsEngineLogo(engine: engine, size: 45)
                    .shadow(color: color.opacity(0.35), radius: 12)
                Text(engine.name)
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize()
                Spacer(minLength: 3)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? color : Color.secondary.opacity(0.45))
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(
                LinearGradient(colors: [color.opacity(selected ? 0.23 : 0.12), .primary.opacity(0.035)],
                               startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? color.opacity(0.65) : Color.primary.opacity(0.09))
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(SettingsHoverStyle(radius: 16))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SettingsSlider: View {
    let title: String
    let slider: NSSlider
    @State private var value: Double

    init(title: String, slider: NSSlider) {
        self.title = title
        self.slider = slider
        _value = State(initialValue: slider.doubleValue)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).fontWeight(.medium)
            Spacer()
            Slider(value: $value, in: slider.minValue...slider.maxValue)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value * 100).rounded())) percent")
                .frame(width: 130)
            Text("\(Int((value * 100).rounded()))%")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .onChange(of: slider.doubleValue) { _, newValue in value = newValue }
        .onChange(of: value) { _, newValue in
            slider.doubleValue = newValue
            if let action = slider.action { NSApp.sendAction(action, to: slider.target, from: slider) }
        }
    }
}

private struct EngineRuleEditor: View {
    @State var draft: EngineRuleDraft
    let save: (BrowserEngineRule) -> Void
    let cancel: () -> Void

    var body: some View {
        let candidate = BrowserEngineRule(input: draft.input, scope: draft.scope, engine: draft.engine)
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.original == nil ? "Add Engine Rule" : "Edit Engine Rule")
                .font(.title2.weight(.semibold))
            Picker("Match", selection: $draft.scope) {
                ForEach(BrowserEngineRule.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            TextField(draft.scope == .site ? "example.com" : "https://example.com/page", text: $draft.input)
                .textFieldStyle(.roundedBorder)
                .help(draft.scope == .site ? "Includes subdomains" : "Includes the query and fragment")
                .accessibilityLabel(draft.scope == .site ? "Website domain" : "Exact URL")
            Text("Open with").font(.headline)
            HStack(spacing: 10) {
                ForEach(BrowserEngine.allCases, id: \.self) { engine in
                    SettingsEngineTile(engine: engine, selected: draft.engine == engine) { draft.engine = engine }
                        .disabled(engine == .chromium && !WBChromiumAvailable())
                }
            }
            if candidate == nil && !draft.input.isEmpty {
                Text(draft.scope == .site ? "Enter a website domain." : "Enter a full HTTP or HTTPS URL.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save Rule") { if let candidate { save(candidate) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(candidate == nil || (draft.engine == .chromium && !WBChromiumAvailable()))
            }
        }
        .padding(22)
        .frame(width: 450)
    }
}
