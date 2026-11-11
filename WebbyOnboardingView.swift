import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func geist(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font {
    Font(WebbyTypography.font(ofSize: size, weight: weight))
}

struct WebbyOnboardingView: View {
    @ObservedObject var model: WebbyOnboarding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var allThemes = false
    @State private var widgetCatalog = false
    @State private var welcomeEntered = false
    @State private var welcomeSettled = false
    @State private var websitePreview = false
    @State private var selectedWidget: WebbyWidget?
    @State private var resizeStart: OnboardingWidgetFrame?
    @Namespace private var tabMotion

    private let paper = Color(nsColor: BrowserTheme.color("#10121A"))
    private var step: WebbyOnboardingStep { model.draft.step }
    private var theme: PetGradientProfile { BrowserTheme.onboardingProfile(model.draft.theme, colors: model.draft.customColors) }
    private var accent: Color { Color(nsColor: BrowserTheme.color(theme.palette.highlight)) }
    private var atmosphere: Color { Color(nsColor: BrowserTheme.color(theme.palette.primary)) }
    private var moves: Bool { !reduceMotion && model.draft.animatedDetails }
    private var selectedWidgets: [WebbyWidget] {
        var seen: Set<WebbyWidget> = []
        let retained = (model.draft.widgetFrames ?? [:]).keys.sorted()
        return (model.draft.widgets + retained).compactMap(WebbyWidget.init(rawValue:)).filter { seen.insert($0).inserted }
    }
    private var selectedName: String { model.draft.currentSpace?.name.nonEmpty ?? "Personal" }
    private var glass: OnboardingGlassSettings { model.draft.glass ?? .init() }
    private var widgetLayout: [String: OnboardingWidgetFrame] {
        WidgetCanvas.onboardingLayout(kinds: selectedWidgets, existing: model.draft.widgetFrames ?? [:],
                                      edits: model.draft.widgetEdits ?? [:])
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 900 || geometry.size.height < 485
            VStack(spacing: 0) {
                header
                if compact {
                    ScrollView {
                        VStack(spacing: 24) {
                            stepContent.frame(maxWidth: 490)
                            preview.frame(maxWidth: 660).aspectRatio(1.58, contentMode: .fit)
                        }.padding(24)
                    }
                } else {
                    HStack(spacing: 48) {
                        ScrollView {
                            stepContent.padding(.vertical, 28)
                                .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 145), alignment: .center)
                        }
                        .frame(width: min(420, geometry.size.width * 0.34))
                        preview.aspectRatio(1.58, contentMode: .fit)
                            .frame(maxWidth: 820, maxHeight: max(260, geometry.size.height - 146))
                    }
                    .padding(.horizontal, 42)
                    .frame(maxWidth: 1360, maxHeight: .infinity)
                }
                footer
            }
        }
        .background {
            ZStack {
                paper
                if !reduceTransparency {
                    RadialGradient(colors: [atmosphere.opacity(0.23), paper], center: .trailing,
                                   startRadius: 40, endRadius: 740)
                }
            }.ignoresSafeArea()
        }
        .foregroundStyle(.white)
        .font(geist(14))
        .tint(accent)
        .preferredColorScheme(.dark)
        .animation(moves ? .easeOut(duration: 0.38) : nil, value: model.draft.theme)
        .animation(moves ? .easeInOut(duration: 0.30) : nil, value: model.draft.layout)
        .animation(moves ? .easeOut(duration: 0.24) : nil, value: model.draft.widgets)
        .animation(moves ? .easeInOut(duration: 0.42) : nil, value: model.reveal)
        .onChange(of: WallpaperSettings(onboarding: model.draft)) { _, _ in model.refreshWallpaper() }
        .onChange(of: model.draft.theme) { _, _ in model.refreshWallpaper() }
        .onChange(of: model.draft.customColors) { _, _ in model.refreshWallpaper() }
        .onChange(of: step) { _, _ in selectAvailableWidget() }
        .onChange(of: selectedWidgets) { _, _ in selectAvailableWidget() }
        .task {
            if moves {
                withAnimation(.easeOut(duration: 0.65)) { welcomeEntered = true }
                try? await Task.sleep(for: .milliseconds(530))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.45)) { welcomeSettled = true }
            } else { welcomeEntered = true; welcomeSettled = true }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "globe")
                .font(.system(size: 20, weight: .medium)).foregroundStyle(accent)
                .accessibilityHidden(true)
            Spacer()
            HStack(spacing: 4) {
                ForEach(WebbyOnboardingStep.allCases, id: \.self) { item in
                    Capsule().fill(item.rawValue <= step.rawValue ? accent : .white.opacity(0.13))
                        .frame(width: item == step ? 16 : 7, height: 3)
                }
            }
            .accessibilityLabel("Step \(step.rawValue + 1) of \(WebbyOnboardingStep.allCases.count)")
            Spacer()
            if !model.firstRun {
                Menu("Jump to") {
                    Button("Glass & Wallpaper") { model.jump(to: .background) }
                    Button("Widgets") { model.jump(to: .canvas) }
                    Button("Theme") { model.jump(to: .signature) }
                    Button("Browser Layout") { model.jump(to: .layout) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(model.busy != nil)
            }
            Button { model.skip() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.075), in: Circle())
            }
            .buttonStyle(.plain).accessibilityLabel("Skip setup").help("Skip setup")
            .keyboardShortcut(.cancelAction)
            .disabled(model.busy != nil)
        }
        .padding(.horizontal, 30).padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button(action: model.back) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.plain).disabled(model.busy != nil)
            }
            Spacer()
            if step == .welcome {
                Button("Skip setup", action: model.skip).buttonStyle(.plain).foregroundStyle(.secondary)
            } else if step == .tour {
                Button("Skip tour", action: model.skipTour).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button(step == .links && !model.defaultBrowser ? "Maybe later" : step.action, action: model.next)
                .buttonStyle(OnboardingPrimaryStyle(color: accent, animated: moves))
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy != nil)
        }
        .padding(.horizontal, 30).padding(.vertical, 16)
        .background(paper.opacity(0.92))
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(step.title)
                .font(geist(step == .welcome || step == .ready ? 54 : 43, .semibold))
                .tracking(-1.6)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            controls.disabled(model.busy != nil)
            if let busy = model.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy) }
                    .font(geist(13)).accessibilityElement(children: .combine)
            }
            if let feedback = step == .migration ? model.importFeedback : model.feedback {
                Text(feedback).font(geist(13, .medium)).foregroundStyle(.white.opacity(0.88))
                    .textSelection(.enabled)
            }
            if step == .migration {
                ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue, systemImage: "exclamationmark.circle")
                        .font(geist(12)).foregroundStyle(Color(nsColor: .systemOrange))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(step)
        .transition(.opacity)
        .animation(moves ? .easeOut(duration: 0.32) : nil, value: step)
        .opacity(model.reveal ? 0 : 1)
    }

    @ViewBuilder private var controls: some View {
        switch step {
        case .welcome: EmptyView()
        case .migration: migration
        case .spaces: spaces
        case .signature: signature
        case .layout: layout
        case .background: background
        case .canvas: canvas
        case .tour: tour
        case .links: links
        case .ready: EmptyView()
        }
    }

    private var migration: some View {
        VStack(alignment: .leading, spacing: 12) {
            choice("Start fresh", "", "sparkles",
                   selected: !model.importExpanded) { model.importExpanded = false }
            choice("Import from Chrome", model.scanning ? "Checking for profiles…" :
                   (model.sources.isEmpty ? "No Chrome profiles found" : ""),
                   "arrow.down.app", selected: model.importExpanded) { model.importExpanded.toggle() }
                .disabled(model.sources.isEmpty || model.busy != nil)
            if model.importExpanded && !model.sources.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.sources, id: \.directory) { source in
                        Toggle(source.name, isOn: Binding(get: { model.selectedSources.contains(source.directory) },
                            set: { if $0 { model.selectedSources.insert(source.directory) } else { model.selectedSources.remove(source.directory) } }))
                    }
                    Divider()
                    Text("Copies bookmarks and history. Passwords go to Keychain.")
                        .font(geist(12)).foregroundStyle(.secondary)
                    Toggle("Copy saved passwords", isOn: $model.importOptions.passwords)
                    Toggle("Copy website cookies and sign-ins", isOn: $model.importOptions.cookies)
                    Text("Cookies apply to WebKit. Importing saves immediately.")
                        .font(geist(11)).foregroundStyle(.secondary)
                    Button(model.issues.isEmpty ? "Import selected" : "Try remaining profiles again", action: model.importChrome)
                        .buttonStyle(.bordered).disabled(model.selectedSources.isEmpty)
                }.padding(14).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                    .disabled(model.busy != nil)
            }
        }
    }

    private var spaces: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($model.draft.spaces) { $space in
                HStack {
                    Button {
                        model.selectSpace(space.id)
                    } label: {
                        Image(systemName: model.draft.selectedSpace == space.id ? "largecircle.fill.circle" : "circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Personalize " + space.name)
                    TextField("Space name", text: $space.name).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Name for " + space.name)
                    if space.isNew {
                        Button { model.removeSpace(space.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove draft space " + space.name)
                    }
                }
            }
            Button { model.addSpace() } label: { Label("Add another space", systemImage: "plus.circle") }
                .buttonStyle(.bordered)
            if model.draft.spaces.count == 1 {
                Menu("Name suggestions") {
                    ForEach(["Personal", "Work", "Study", "Creative", "Development"], id: \.self) { name in
                        Button(name) { model.draft.spaces[0].name = name }
                    }
                }
            }
            Divider()
            Toggle("Fuse your tabs", isOn: $model.draft.fuse).toggleStyle(.switch)
                .disabled(model.draft.spaces.count < 2)

        }
    }

    private var signature: some View {
        let curated = ["aqua-wisp", "ghost", "macintosh", "crt-pal", "fireball", "lil-finder", "noir-webling", "stacky"]
        let themes = allThemes ? BrowserTheme.presets : curated.compactMap { id in BrowserTheme.presets.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 85), spacing: 7)], spacing: 7) {
                ForEach(themes, id: \.id) { item in
                    Button {
                        model.draft.theme = item.id
                        model.draft.customColors = nil
                        model.draft.petPath = nil
                        model.draft.themeChanged = true
                    } label: {
                        VStack(spacing: 4) {
                            Image(nsImage: OnboardingArtwork.pet(item.id)).resizable().scaledToFit().frame(width: 46, height: 46)
                            Text(item.name).font(geist(10, .medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(.white.opacity(model.draft.theme == item.id ? 0.13 : 0.045),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topTrailing) {
                            if model.draft.theme == item.id {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(accent).padding(5)
                            }
                        }
                    }
                    .buttonStyle(OnboardingChoiceStyle(selected: model.draft.theme == item.id, accent: accent))
                    .accessibilityAddTraits(model.draft.theme == item.id ? .isSelected : [])
                }
            }
            Button(allThemes ? "Show curated themes" : "See all \(BrowserTheme.presets.count)") { allThemes.toggle() }
                .buttonStyle(.borderless)
            DisclosureGroup("Customize colors") {
                HStack {
                    ForEach(0..<3) { index in
                        ColorPicker("Stop \(index + 1)", selection: colorStop(index), supportsOpacity: false)
                    }
                }.padding(.vertical, 7)
            }
            Button("Choose your own character…") { model.chooseFile(.pet) }.buttonStyle(.bordered)
            if let path = model.draft.petPath { Text(URL(fileURLWithPath: path).lastPathComponent).font(geist(11)).foregroundStyle(.secondary) }
            Menu("App icon · " + (model.draft.iconMode == "indicator" ? "Animated indicator" : model.draft.iconMode == "image" ? "Custom image" : "Profile pet")) {
                Button("Profile pet") { model.draft.iconMode = "pet"; model.draft.iconPath = nil }
                Button("Animated indicator") { model.draft.iconMode = "indicator"; model.draft.iconPath = nil }
                Button("Choose image, GIF, or SVG…") { model.chooseFile(.icon) }
            }
            Toggle("Animated details in setup", isOn: $model.draft.animatedDetails)
        }
    }

    private func colorStop(_ index: Int) -> Binding<Color> {
        Binding(get: {
            let colors = model.draft.customColors ?? [theme.palette.primary, theme.palette.secondary, theme.palette.highlight]
            return Color(nsColor: BrowserTheme.color(colors[index]))
        }, set: { color in
            var colors = model.draft.customColors ?? [theme.palette.primary, theme.palette.secondary, theme.palette.highlight]
            colors[index] = BrowserTheme.hex(NSColor(color))
            model.draft.customColors = colors
            model.draft.themeChanged = true
        })
    }

    private var layout: some View {
        VStack(alignment: .leading, spacing: 10) {
            choice("Vertical · Top", "", "sidebar.left",
                   selected: model.draft.layout == "top") { model.draft.layout = "top" }
            choice("Vertical · Bottom", "", "rectangle.bottomthird.inset.filled",
                   selected: model.draft.layout == "bottom") { model.draft.layout = "bottom" }
            choice("Horizontal", "", "rectangle.topthird.inset.filled",
                   selected: model.draft.layout == "horizontal") { model.draft.layout = "horizontal" }
            Picker("Address bar", selection: $model.draft.address) {
                Text("Glass strip").tag("strip")
                Text("Tab pane").tag("tabBar")
            }
            Picker("Default search", selection: $model.draft.search) {
                ForEach(BrowserSearchEngine.allCases, id: \.self) { engine in Text(engine.name).tag(engine.rawValue) }
            }
            DisclosureGroup("More browsing preferences") {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("Restore tabs after restart", isOn: $model.draft.restoreTabs)
                    Picker("Offload idle tabs", selection: $model.draft.offloadMinutes) {
                        ForEach([0, 5, 15, 30, 60], id: \.self) { minutes in
                            Text(minutes == 0 ? "Never" : "After \(minutes) minutes").tag(minutes)
                        }
                    }
                    Toggle("Link Glances on Hover", isOn: $model.draft.glances)
                    Toggle("Subtle action sounds", isOn: $model.draft.sounds)
                }.padding(.top, 8)
            }
        }
    }

    private var background: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Appearance", selection: $model.editingGlass) {
                Text("Glass").tag(true)
                Text("Wallpaper").tag(false)
            }.pickerStyle(.segmented).labelsHidden()
            if model.editingGlass { glassControls } else { wallpaperChoices }
        }
    }

    private var glassControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            Picker("Preview", selection: $websitePreview) {
                Text("New tab").tag(false)
                Text("Webpage").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            percent("Window transparency", value: glassSetting(\.background))
            percent("Toolbar transparency", value: glassSetting(\.toolbar), limit: 0.85)
            if model.draft.layout != "horizontal" {
                percent("Sidebar transparency", value: glassSetting(\.sidebar), limit: 0.85)
            }
            percent("Widget glass opacity", value: glassSetting(\.widgets))
                .onChange(of: glass.widgets) { _, _ in websitePreview = false }
            Toggle("WebKit page glass", isOn: glassSetting(\.pages))
                .toggleStyle(.switch)
                .onChange(of: glass.pages) { _, _ in websitePreview = true }
        }
    }

    private func glassSetting<T>(_ path: WritableKeyPath<OnboardingGlassSettings, T>) -> Binding<T> {
        Binding(get: { glass[keyPath: path] }, set: { value in
            var settings = glass
            settings[keyPath: path] = value
            model.draft.glass = settings
        })
    }

    private func percent(_ title: String, value: Binding<Double>, limit: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(geist(13, .medium))
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit().font(geist(11)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...limit) { Text(title) }.labelsHidden()
        }
    }

    private var wallpaperChoices: some View {
        VStack(alignment: .leading, spacing: 11) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 93), spacing: 7)], spacing: 8) {
                wallpaperTile("None", colors: ["#171A23", "#303542"], selected: model.draft.background == "clean") {
                    model.selectBackground("clean")
                }
                ForEach(OnboardingWallpaperDesign.allCases, id: \.self) { design in
                    wallpaperTile(design.name, colors: design.colors(profile: [theme.palette.shadow, theme.palette.secondary, theme.palette.primary]),
                                  selected: model.draft.background == "atmosphere" && (model.draft.wallpaperDesign ?? .profile) == design) {
                        model.selectWallpaperDesign(design)
                    }
                }
            }
            Button {
                model.chooseFile(.wallpaper)
            } label: {
                Label(model.draft.backgroundPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose a file…",
                      systemImage: "photo.on.rectangle").lineLimit(1)
            }.buttonStyle(.bordered)
            if model.draft.background != "clean" {
                Picker("Effect", selection: backgroundSetting($model.draft.effect)) {
                    ForEach(Array(["Original", "Dither", "ASCII", "Halftone", "Scanlines", "Haze"].enumerated()), id: \.offset) { index, title in
                        Text(title).tag(index)
                    }
                }
                percent("Wallpaper opacity", value: backgroundSetting($model.draft.opacity))
                DisclosureGroup("More wallpaper controls") { wallpaperControls.padding(.vertical, 7) }
                Toggle("Save as a new wallpaper pair", isOn: backgroundSetting($model.draft.saveLook))
            }
        }
    }

    private func wallpaperTile(_ title: String, colors: [String], selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: colors.map { Color(nsColor: BrowserTheme.color($0)) },
                                         startPoint: .bottomLeading, endPoint: .topTrailing))
                    .frame(height: 43)
                    .overlay(alignment: .topTrailing) {
                        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent).padding(5) }
                    }
                Text(title).font(geist(10, .medium)).lineLimit(1)
            }.padding(5)
        }.buttonStyle(OnboardingChoiceStyle(selected: selected, accent: accent))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func backgroundSetting<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: { value in
            model.draft.backgroundChanged = true
            binding.wrappedValue = value
        })
    }

    private var wallpaperControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Fade direction", selection: backgroundSetting($model.draft.fade)) {
                ForEach(Array(["None", "Down", "Up", "Left", "Right", "Edges", "Center"].enumerated()), id: \.offset) { index, title in
                    Text(title).tag(index)
                }
            }
            Slider(value: backgroundSetting($model.draft.fadeStart), in: 0...0.9) { Text("Fade start") }
            Slider(value: backgroundSetting($model.draft.fadeEnd), in: 0.02...1) { Text("Fade end") }
            Slider(value: backgroundSetting($model.draft.blur), in: 0...40) { Text("Blur") }
            Slider(value: backgroundSetting($model.draft.pageOpacity)) { Text("Webpage visibility") }
            Picker("Fit", selection: backgroundSetting($model.draft.fit)) {
                Text("Fill").tag(0); Text("Fit").tag(1); Text("Stretch").tag(2)
            }
            Toggle("Soften detail", isOn: backgroundSetting($model.draft.soften))
            Toggle("New tab only", isOn: backgroundSetting($model.draft.homeOnly))
            Toggle("Extend across the window", isOn: backgroundSetting($model.draft.fullWindow))
            if model.draft.fullWindow {
                Picker("Tab frost", selection: backgroundSetting($model.draft.frostScope)) {
                    Text("Individual tabs").tag(0); Text("Entire tab pane").tag(1)
                }
                Slider(value: backgroundSetting($model.draft.frostStrength)) { Text("Tab frost strength") }
            }
            Toggle("Animate supported backgrounds", isOn: backgroundSetting($model.draft.wallpaperMotion))
        }
    }

    private let presets: [(String, [WebbyWidget])] = [
        ("Minimal", []), ("Everyday", [.weather, .note, .calendar]),
        ("Workspace", [.calendar, .note, .downloads, .clipboard]),
        ("Developer", [.ide, .githubPRs, .codex, .systemMonitor, .calculator])
    ]

    private var canvas: some View {
        VStack(alignment: .leading, spacing: 11) {
            Picker("Widget layout", selection: Binding(get: { model.draft.widgetPreset }, set: { name in
                guard let widgets = presets.first(where: { $0.0 == name })?.1 else { return }
                model.draft.widgetPreset = name
                model.draft.widgets = widgets.map(\.rawValue)
                model.draft.widgetsChanged = true
            })) {
                if !presets.contains(where: { $0.0 == model.draft.widgetPreset }) {
                    Text(model.draft.widgetPreset).tag(model.draft.widgetPreset)
                }
                ForEach(presets, id: \.0) { name, _ in Text(name).tag(name) }
            }
            if !selectedWidgets.isEmpty {
                Picker("Resize", selection: $selectedWidget) {
                    Text("Choose a widget").tag(nil as WebbyWidget?)
                    ForEach(selectedWidgets, id: \.self) { widget in Text(widget.title).tag(Optional(widget)) }
                }
                if let selectedWidget, widgetLayout[selectedWidget.rawValue] != nil {
                    percent("Width", value: widgetDimension(selectedWidget, path: \.width))
                    percent("Height", value: widgetDimension(selectedWidget, path: \.height))
                    if model.draft.widgetEdits?[selectedWidget.rawValue] != nil {
                        Button("Reset size") { model.draft.widgetEdits?.removeValue(forKey: selectedWidget.rawValue) }
                            .buttonStyle(.plain).foregroundStyle(accent)
                    }
                }
            }
            DisclosureGroup("Customize widgets", isExpanded: $widgetCatalog) {
                VStack(alignment: .leading, spacing: 14) {
                    widgetGroup("Everyday", [.weather, .calendar, .note, .music, .calculator, .battery, .stocks])
                    widgetGroup("Your Mac", [.systemMonitor, .downloads, .clipboard])
                    widgetGroup("Connected", [.gmail, .drive, .chatgpt, .githubPRs, .githubContributions, .githubRecent,
                                               .githubRepos, .githubIssues, .githubStars, .githubNews])
                    widgetGroup("Build", [.ide, .codex, .codexUsage])
                }.padding(.vertical, 7)
            }
        }
    }

    private func widgetGroup(_ title: String, _ widgets: [WebbyWidget]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased()).font(geist(10, .semibold)).tracking(1.7).foregroundStyle(.secondary)
            ForEach(widgets, id: \.self) { widget in
                let retained = model.draft.widgetFrames?[widget.rawValue] != nil
                let available = widget != .gmail && widget != .drive && !retained
                Toggle(isOn: Binding(get: { retained || model.draft.widgets.contains(widget.rawValue) }, set: { on in
                    model.draft.widgets.removeAll { $0 == widget.rawValue }
                    if on { model.draft.widgets.append(widget.rawValue) }
                    model.draft.widgetPreset = "Custom"
                    model.draft.widgetsChanged = true
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(widget.title, systemImage: widget.symbol)
                        if !available { Text(retained ? "On your canvas" : "Unavailable").font(geist(10)).foregroundStyle(.secondary) }
                    }
                }.disabled(!available)
            }
        }
    }

    private let demos: [(String, String, String, String)] = [
        ("Two tabs. One view.", "Put pages side by side, with up to four panes.", "⌘S", "Try splitting"),
        ("A browser, wherever you are.", "Summon a compact browser from almost anywhere. You can change its shortcut later.", "⌥Space", "Preview Mini Webby"),
        ("All your profiles, together.", "See tabs from multiple spaces together while keeping their original ownership.", "⌘⇧F", "Preview Fuse"),
        ("Built to work.", "Open a native terminal or a local coding workbench. The workbench may need runtime setup.", "⌘⇧I", "Preview the workbench")
    ]

    private var tour: some View {
        let demo = demos[model.demo]
        return VStack(alignment: .leading, spacing: 12) {
            Text(demo.0).font(geist(22, .semibold))
            Text(demo.2).font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(7).background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
            Button(model.demoPlaying ? "Reset demo" : demo.3) {
                withAnimation(moves ? .easeInOut(duration: 0.42) : nil) { model.demoPlaying.toggle() }
            }.buttonStyle(.bordered)
            HStack {
                Button { changeDemo(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: []).accessibilityLabel("Previous demonstration")
                Text("\(model.demo + 1) / \(demos.count)").monospacedDigit().font(geist(11))
                Button { changeDemo(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: []).accessibilityLabel("Next demonstration")
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }

    private func changeDemo(_ delta: Int) {
        model.demoPlaying = false
        model.demo = (model.demo + delta + demos.count) % demos.count
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.defaultBrowser {
                Label("Webby is your default browser", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
            } else {
                Button("Make Webby my default", action: model.requestDefaultBrowser)
                    .buttonStyle(OnboardingPrimaryStyle(color: accent, animated: moves))
                    .disabled(model.busy != nil)
            }
            if let status = model.linkStatus {
                Text(status).font(geist(12))
                if !model.defaultBrowser {
                    Button("Open Desktop & Dock Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }.buttonStyle(.borderless)
                }
            }
            if model.draft.spaces.count > 1 {
                Picker("Open links from other apps using", selection: $model.draft.externalProfile) {
                    Text("Last-used profile").tag(nil as UUID?)
                    ForEach(model.draft.spaces) { space in Text(space.name).tag(Optional(space.id)) }
                }
            }
        }
    }

    private func choice(_ title: String, _ detail: String, _ icon: String,
                        selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(accent)
                    .frame(width: 30, height: 30).background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(geist(13, .semibold))
                    if !detail.isEmpty {
                        Text(detail).font(geist(11)).foregroundStyle(.white.opacity(0.67))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 5)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? accent : .white.opacity(0.30))
                    .accessibilityHidden(true)
            }.padding(10).background(.white.opacity(selected ? 0.085 : 0.04), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(OnboardingChoiceStyle(selected: selected, accent: accent))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var preview: some View {
        browserFrame
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22).strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.055)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .shadow(color: .black.opacity(0.6), radius: 32, x: 0, y: 21)
            .scaleEffect(model.reveal ? 1.08 : 1)
            .allowsHitTesting(step == .canvas)
            .accessibilityLabel("Webby preview")
    }

    private var browserFrame: some View {
        let horizontal = model.draft.layout == "horizontal"
        return ZStack {
            previewBackdrop(showWallpaper: model.draft.fullWindow, opacity: model.draft.opacity)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(Array([Color(red: 0.97, green: 0.39, blue: 0.35), .orange, .green].enumerated()), id: \.offset) { _, color in
                        Circle().fill(color.opacity(0.75)).frame(width: 6, height: 6)
                    }
                    Spacer(minLength: 4)
                    if model.draft.address == "strip" || horizontal {
                        Label("Search or enter a URL", systemImage: "magnifyingglass")
                            .font(geist(9, .medium)).foregroundStyle(.white.opacity(0.65))
                            .frame(maxWidth: 230).frame(height: 23)
                            .background(.white.opacity(0.065), in: Capsule())
                            .overlay { Capsule().strokeBorder(.white.opacity(0.08)) }
                    }
                    Spacer(minLength: 4)
                    Image(nsImage: OnboardingArtwork.icon(id: model.draft.theme, theme: theme,
                        petPath: model.draft.petPath, iconMode: model.draft.iconMode, iconPath: model.draft.iconPath))
                        .resizable().scaledToFit().frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 13).frame(height: 39)
                .background { surface(glass.toolbar) }
                if horizontal {
                    tabStrip(vertical: false).padding(.horizontal, 9).padding(.vertical, 5)
                        .background { surface(glass.toolbar, pane: true) }
                }
                Rectangle().fill(.white.opacity(0.075)).frame(height: 1)
                HStack(spacing: 0) {
                    if !horizontal {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 5) {
                                Image(systemName: model.draft.fuse ? "square.stack.3d.up.fill" : "person.crop.circle")
                                    .foregroundStyle(accent)
                                Text(model.draft.fuse ? "Fuse" : selectedName).font(geist(10, .semibold)).lineLimit(1)
                            }.padding(.bottom, 4)
                            if model.draft.address == "tabBar" {
                                Label("Search", systemImage: "magnifyingglass").font(geist(8))
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                    .background(.white.opacity(0.065), in: Capsule())
                            }
                            if model.draft.layout == "bottom" { Spacer(minLength: 2) }
                            tabStrip(vertical: true)
                            if model.draft.layout != "bottom" { Spacer(minLength: 2) }
                        }
                        .padding(10).frame(width: 100)
                        .background { surface(glass.sidebar, pane: true) }
                        Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
                    }
                    previewPage.padding(6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paper)
    }

    private func surface(_ transparency: Double, pane: Bool = false) -> some View {
        ZStack {
            if pane && model.draft.fullWindow && model.draft.frostScope == 1 && !reduceTransparency {
                Rectangle().fill(.ultraThinMaterial).opacity(model.draft.frostStrength)
            }
            Rectangle().fill(Color(nsColor: BrowserTheme.color("#1A1D26")).opacity(1 - transparency * 0.88))
        }
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }

    private func previewBackdrop(showWallpaper: Bool, opacity: Double) -> some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: BrowserTheme.color("#0A0C13"))
                LinearGradient(colors: [atmosphere.opacity(0.52), .clear, accent.opacity(0.22)],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                if showWallpaper, let image = model.wallpaperImage {
                    Image(decorative: image, scale: 1).resizable()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .opacity(opacity)
                }
            }
        }
    }

    private func tabStrip(vertical: Bool) -> some View {
        let arrangement = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5)) :
            AnyLayout(HStackLayout(alignment: .center, spacing: 6))
        let examples = step == .migration || step == .tour || model.draft.fuse
        return arrangement {
            tabChip("New Tab", icon: "sparkle", selected: true, vertical: vertical)
            if examples { tabChip("Reading List", icon: "book.closed", selected: false, vertical: vertical) }
            if model.draft.fuse || (step == .tour && model.demo == 2 && model.demoPlaying) {
                tabChip(model.draft.spaces.first(where: { $0.id != model.draft.selectedSpace })?.name ?? "Work · demo",
                        icon: "circle.hexagongrid.fill", selected: false, vertical: vertical)
            }
            if !vertical { Spacer(minLength: 2) }
        }
    }

    private func tabChip(_ name: String, icon: String, selected: Bool, vertical: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(selected ? accent : .white.opacity(0.68))
            Text(name).lineLimit(1)
            if vertical { Spacer(minLength: 0) }
        }
        .font(geist(9, .medium)).padding(.horizontal, 6).frame(height: 24)
        .background {
            if model.draft.fullWindow && model.draft.frostScope == 0 && !reduceTransparency {
                RoundedRectangle(cornerRadius: 5).fill(.ultraThinMaterial).opacity(model.draft.frostStrength)
            }
            RoundedRectangle(cornerRadius: 5).fill(.white.opacity(selected ? 0.13 : 0.04))
        }
        .matchedGeometryEffect(id: icon, in: tabMotion)
    }

    private var previewPage: some View {
        GeometryReader { geometry in
            let page = step == .background && model.editingGlass && websitePreview
            let showWidgets = !selectedWidgets.isEmpty && step != .welcome
            ZStack {
                if !model.draft.fullWindow {
                    previewBackdrop(showWallpaper: !page || !model.draft.homeOnly,
                                    opacity: page ? model.draft.pageOpacity : model.draft.opacity)
                }
                Rectangle().fill(paper.opacity(max(0, (model.wallpaperImage == nil ? 0.77 : 0.38) - glass.background * 0.35)))
                if page {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Reading List", systemImage: "book.closed").font(geist(20, .semibold))
                        ForEach(0..<5) { line in
                            Capsule().fill(.white.opacity(0.12)).frame(height: 4)
                                .padding(.trailing, CGFloat(line % 3) * 27)
                        }
                    }
                    .padding(25).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background { Color(nsColor: BrowserTheme.color("#141721")).opacity(glass.pages ? 0.18 : 1) }
                } else if step == .tour && model.demoPlaying && (model.demo == 0 || model.demo == 3) {
                    HStack(spacing: 7) {
                        demoPane(model.demo == 0 ? "Reading List" : "Workbench", model.demo == 0 ? "book.closed" : "chevron.left.forwardslash.chevron.right")
                        demoPane(model.demo == 0 ? "Research" : "Terminal", model.demo == 0 ? "doc.text" : "terminal")
                    }.padding(12)
                } else if step == .migration && model.importExpanded {
                    demoPane("Bookmarks", "bookmark").padding(18)
                } else {
                    VStack(spacing: 7) {
                        OnboardingIndicator(profile: theme, animated: step == .welcome && moves)
                            .frame(width: step == .welcome ? 115 : 54, height: step == .welcome ? 73 : 34)
                            .scaleEffect(step == .welcome && !welcomeEntered && moves ? 0.55 : 1)
                            .accessibilityHidden(true)
                        previewSearch
                            .opacity(step == .welcome && !welcomeSettled && moves ? 0 : 1)
                    }
                    .position(x: geometry.size.width / 2, y: geometry.size.height * (showWidgets ? 0.18 : 0.49))
                    if showWidgets || (step == .background && model.editingGlass) {
                        previewWidgets(in: geometry.size, sample: !showWidgets)
                    }
                    if step == .tour && model.demo == 1 && model.demoPlaying {
                        VStack(alignment: .leading, spacing: 11) {
                            Label("Mini Webby", systemImage: "macwindow").font(geist(13, .semibold))
                            previewSearch
                        }
                        .padding(15).frame(width: min(205, geometry.size.width - 26))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
                        .shadow(radius: 13).transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)) }
    }

    private var previewSearch: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(accent)
            Text(BrowserSearchEngine(rawValue: model.draft.search)?.name ?? "Google").lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "return").foregroundStyle(.secondary)
        }
        .font(geist(11)).padding(.horizontal, 10).frame(height: 30).frame(maxWidth: 270)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(accent.opacity(0.27)) }
    }

    private func demoPane(_ title: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(geist(11, .semibold)).foregroundStyle(accent)
            ForEach(0..<3) { line in
                Capsule().fill(.white.opacity(0.12)).frame(height: 4).padding(.trailing, CGFloat(line * 9))
            }
            Spacer(minLength: 4)
        }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    private func previewWidgets(in size: CGSize, sample: Bool) -> some View {
        let widgets = sample ? [.note] : Array(selectedWidgets.prefix(12))
        let frames = sample ? ["note": OnboardingWidgetFrame(CGRect(x: 270, y: 445, width: 460, height: 162),
                                                            in: CGSize(width: 1000, height: 700))] : widgetLayout
        return ZStack(alignment: .topLeading) {
            ForEach(widgets, id: \.self) { widget in
                if let normalized = frames[widget.rawValue] {
                    let frame = normalized.rect(in: size)
                    let focused = step == .canvas && selectedWidget == widget
                    widgetCard(widget, frame: frame, focused: focused)
                        .overlay(alignment: .bottomTrailing) {
                            if focused {
                                Image(systemName: "arrow.down.right")
                                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.black)
                                    .frame(width: 20, height: 20)
                                    .background(accent, in: Circle()).padding(3)
                                    .accessibilityHidden(true)
                                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("widgetPreview"))
                                        .onChanged { value in
                                            if resizeStart == nil { resizeStart = normalized }
                                            guard var resized = resizeStart else { return }
                                            resized.width = min(1 - resized.x, max(0.08, resized.width + value.translation.width / max(1, size.width)))
                                            resized.height = min(1 - resized.y, max(0.08, resized.height + value.translation.height / max(1, size.height)))
                                            setWidgetSize(resized, for: widget)
                                        }.onEnded { _ in resizeStart = nil })
                            }
                        }
                        .position(x: frame.midX, y: frame.midY)
                        .zIndex(focused ? 1 : 0)
                        .transition(.opacity)
                }
            }
        }.frame(width: size.width, height: size.height)
            .coordinateSpace(name: "widgetPreview")
    }

    private func widgetCard(_ widget: WebbyWidget, frame: CGRect, focused: Bool) -> some View {
        Button {
            if step == .canvas { selectedWidget = widget }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(widget.title, systemImage: widget.symbol)
                    .font(geist(10, .semibold)).lineLimit(1)
                if frame.height > 53 { widgetDetail(widget) }
            }
            .padding(7).frame(width: max(1, frame.width), height: max(1, frame.height), alignment: .topLeading)
            .clipped()
            .background {
                RoundedRectangle(cornerRadius: 9).fill(.ultraThinMaterial).opacity(glass.widgets)
                RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.055 + glass.widgets * 0.1))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? accent : .white.opacity(0.12))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(focused ? .isSelected : [])
        .allowsHitTesting(step == .canvas)
    }

    private func selectAvailableWidget() {
        guard step == .canvas else { return }
        if selectedWidget.map({ selectedWidgets.contains($0) }) != true {
            selectedWidget = selectedWidgets.first
        }
    }

    private func widgetDimension(_ widget: WebbyWidget, path: WritableKeyPath<OnboardingWidgetFrame, Double>) -> Binding<Double> {
        Binding(get: { widgetLayout[widget.rawValue]?[keyPath: path] ?? 0 }, set: { value in
            guard var frame = widgetLayout[widget.rawValue] else { return }
            let available = path == \.width ? 1 - frame.x : 1 - frame.y
            frame[keyPath: path] = min(max(0.08, available), max(0.08, value))
            setWidgetSize(frame, for: widget)
        })
    }

    private func setWidgetSize(_ frame: OnboardingWidgetFrame, for widget: WebbyWidget) {
        var edits = model.draft.widgetEdits ?? [:]
        edits[widget.rawValue] = frame
        model.draft.widgetEdits = edits
    }

    @ViewBuilder private func widgetDetail(_ widget: WebbyWidget) -> some View {
        switch widget {
        case .calculator:
            VStack(alignment: .trailing, spacing: 4) {
                Text("0").font(geist(15, .semibold))
                HStack(spacing: 3) {
                    ForEach(["7", "8", "9", "÷"], id: \.self) { key in
                        Text(key).font(geist(8)).frame(maxWidth: .infinity).padding(3)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
            .padding(.top, 5).accessibilityHidden(true)
        case .note:
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<3) { row in
                    Capsule().fill(.white.opacity(0.14)).frame(height: 2).padding(.trailing, CGFloat(row * 8))
                }
            }
            .padding(.top, 8).accessibilityHidden(true)
        default:
            Image(systemName: widget.symbol).font(.system(size: 20, weight: .light))
                .foregroundStyle(accent.opacity(0.56)).padding(.top, 7).accessibilityHidden(true)
        }
    }


}

private extension String {
    var nonEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

private struct OnboardingPrimaryStyle: ButtonStyle {
    let color: Color
    let animated: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(geist(13, .semibold)).foregroundStyle(Color.black.opacity(0.84))
            .padding(.horizontal, 17).frame(minHeight: 36)
            .background(color, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.37)) }
            .scaleEffect(configuration.isPressed && animated ? 0.97 : 1)
            .animation(animated ? .easeOut(duration: 0.15) : nil, value: configuration.isPressed)
    }
}

private struct OnboardingChoiceStyle: ButtonStyle {
    let selected: Bool
    let accent: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? accent.opacity(0.56) : .white.opacity(0.12)) }
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct OnboardingIndicator: NSViewRepresentable {
    let profile: PetGradientProfile
    let animated: Bool
    final class Host: NSView {
        let engine = NotchIndicatorEngine()
        var palette: String?
        var didAnimate = false
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            engine.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            let scale = min(bounds.width / 28, bounds.height / 18)
            engine.layer.setAffineTransform(.init(scaleX: scale, y: scale))
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.wantsLayer = true
        view.layer?.addSublayer(view.engine.layer)
        return view
    }

    func updateNSView(_ view: Host, context: Context) {
        let palette = profile.gradients.ambient.stops.map(\.color).joined()
        guard view.palette != palette || (view.didAnimate && !animated) else { return }
        view.palette = palette
        view.engine.setProfile(profile, wave: false)
        if animated && !view.didAnimate {
            view.didAnimate = true
            view.engine.showScene("search")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak view] in view?.engine.showOnboardingStill() }
        } else {
            view.didAnimate = false
            view.engine.showOnboardingStill()
        }
    }

    static func dismantleNSView(_ view: Host, coordinator: ()) { view.engine.hide() }
}

@MainActor private enum OnboardingArtwork {
    private static let pets = NSCache<NSString, NSImage>()
    private static let icons = NSCache<NSString, NSImage>()

    static func pet(_ id: String) -> NSImage {
        if let image = pets.object(forKey: id as NSString) { return image }
        let image = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "Pets")
            .flatMap(NSImage.init(contentsOf:)) ?? NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil) ?? NSImage()
        pets.setObject(image, forKey: id as NSString)
        return image
    }

    static func icon(id: String, theme: PetGradientProfile, petPath: String?, iconMode: String?, iconPath: String?) -> NSImage {
        let key = ([id, petPath ?? "", iconMode ?? "", iconPath ?? ""] + theme.gradients.ambient.stops.map(\.color)).joined(separator: "|") as NSString
        if let image = icons.object(forKey: key) { return image }
        icons.countLimit = 32
        let image: NSImage
        if iconMode == "indicator" { image = WebbyIconSettings.indicatorImage(profile: theme, time: 0) }
        else if iconMode == "image", let path = iconPath, let custom = NSImage(contentsOfFile: path) { image = custom }
        else { image = WebbyIcon.image(profile: theme, petID: id, customPetURL: petPath.map { URL(fileURLWithPath: $0) }) }
        icons.setObject(image, forKey: key)
        return image
    }
}

struct WebbyExploreItem: Identifiable {
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void
    var id: String { title }
    init(_ title: String, _ detail: String, _ icon: String, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.action = action
    }
}

@MainActor enum WebbyExplorePanel {
    static func show(_ items: [WebbyExploreItem], over parent: NSWindow) {
        guard parent.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 545),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Explore Webby"
        let view = VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Explore Webby").font(geist(26, .semibold))
                Spacer()
                Button("Done") { [weak sheet, weak parent] in
                    if let sheet { parent?.endSheet(sheet) }
                }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        Button {
                            parent.endSheet(sheet)
                            item.action()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.icon).frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(geist(14, .semibold))
                                    Text(item.detail).font(geist(12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(20)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        sheet.contentViewController = host
        parent.beginSheet(sheet) { _ in sheet.contentViewController = nil }
    }
}
