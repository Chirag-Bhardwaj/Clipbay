import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    static let shared = SettingsController()
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(tab: SettingsTab = .general) {
        SettingsTabState.shared.tab = tab
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Clipbay Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        HotKeyCenter.shared.suspended = false
        if !CommandLine.arguments.contains("--dock") { NSApp.setActivationPolicy(.accessory) }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, shortcuts, privacy, sync, intelligence, about
    var id: String { rawValue }
    var label: String { rawValue == "intelligence" ? "Intelligence" : rawValue.capitalized }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .privacy: return "hand.raised"
        case .sync: return "icloud"
        case .intelligence: return "sparkles"
        case .about: return "info.circle"
        }
    }
}

@MainActor @Observable
final class SettingsTabState {
    static let shared = SettingsTabState()
    var tab: SettingsTab = .general
}

struct SettingsView: View {
    @Bindable var tabs = SettingsTabState.shared
    var body: some View {
        TabView(selection: $tabs.tab) {
            ForEach(SettingsTab.allCases) { t in
                Group {
                    switch t {
                    case .general: GeneralSettings()
                    case .shortcuts: ShortcutSettings()
                    case .privacy: PrivacySettings()
                    case .sync: SyncSettings()
                    case .intelligence: IntelligenceSettings()
                    case .about: AboutSettings()
                    }
                }
                .tabItem { Label(t.label, systemImage: t.icon) }
                .tag(t)
            }
        }
        .frame(width: 640, height: 500)
    }
}

struct GeneralSettings: View {
    @Bindable var s = Settings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var pendingRetention: Retention?
    @State private var pendingCount = 0
    @State private var confirmErase = false
    @State private var accessibility = Paster.isTrusted

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Picker("Paste items", selection: $s.pasteToActiveApp) {
                    Text("To active app").tag(true)
                    Text("To clipboard").tag(false)
                }
                Toggle("Always paste as plain text", isOn: $s.alwaysPlainText)
                Toggle("Play sound on copy", isOn: $s.soundsEnabled)
            }
            Section {
                HStack {
                    Image(systemName: accessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibility ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text(accessibility ? "Direct paste is enabled" : "Accessibility access needed")
                        Text("Clipbay sends ⌘V to the active app to paste for you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !accessibility {
                        Button("Grant Access…") { Paster.ensureAccessibility(); Paster.openAccessibilitySettings() }
                    }
                }
            }
            Section("History") {
                Picker("Keep history", selection: Binding(get: { s.retention }, set: { newValue in
                    let n = ClipStore.shared.purge(retention: newValue, dryRun: true)
                    if n > 0 { pendingCount = n; pendingRetention = newValue } else { s.retention = newValue }
                })) {
                    ForEach(Retention.allCases) { Text($0.label).tag($0) }
                }
                Text("Pinned items are kept forever. \(ClipStore.shared.items.count.formatted()) items stored.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Fetch link previews", isOn: $s.fetchLinkPreviews)
                Toggle("Recognize text in images (searchable)", isOn: $s.ocrEnabled)
                Button("Erase History…", role: .destructive) { confirmErase = true }
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in accessibility = Paster.isTrusted }
        .alert("Shorten history?", isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } })) {
            Button("Delete \(pendingCount) Items", role: .destructive) {
                if let r = pendingRetention { s.retention = r; ClipStore.shared.purge(retention: r) }
                pendingRetention = nil
            }
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            Text("\(pendingCount) unpinned items are older than the new limit and will be deleted. This can’t be undone.")
        }
        .alert("Erase clipboard history?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) { ClipStore.shared.eraseHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All unpinned items will be deleted. Pinboards and their items are kept. This can’t be undone.")
        }
    }
}

struct ShortcutSettings: View {
    @Bindable var s = Settings.shared
    var body: some View {
        Form {
            Section("Global shortcuts") {
                LabeledContent("Activate Clipbay") { ShortcutRecorder(combo: $s.activateHotKey) }
                LabeledContent("Activate Paste Stack") { ShortcutRecorder(combo: $s.stackHotKey) }
                LabeledContent("Paste entire stack") { ShortcutRecorder(combo: $s.pasteAllHotKey) }
            }
            Section("In Clipbay") {
                Picker("Quick Paste (1–9)", selection: $s.quickPasteModifier) {
                    ForEach(ModifierChoice.allCases) { Text($0.label).tag($0) }
                }
                Picker("Plain Text mode (with ↩)", selection: $s.plainTextModifier) {
                    ForEach(ModifierChoice.allCases) { Text($0.label).tag($0) }
                }
                Button("Reset to Defaults") {
                    s.activateHotKey = Settings.defaultActivate
                    s.stackHotKey = Settings.defaultStack
                    s.pasteAllHotKey = Settings.defaultPasteAll
                    s.quickPasteModifier = .command
                    s.plainTextModifier = .shift
                }
            }
            Section("Reference") {
                ShortcutTable()
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutTable: View {
    let rows: [(String, String)] = [
        ("← →", "Select previous / next item"), ("⇧← ⇧→", "Extend selection"), ("⌘↑ ⌘↓", "First / last item"),
        ("↩", "Paste selected"), ("⇧↩", "Paste as plain text"), ("⌘1 … ⌘9", "Quick paste"),
        ("⌘C", "Copy selected"), ("Space", "Quick Look"), ("⌘O", "Open link or file"),
        ("⌘E", "Edit"), ("⌘R", "Rename"), ("⌘N", "New text item"), ("⌫", "Delete"), ("⌘Z", "Undo delete"),
        ("⌘F", "Search / show filters"), ("⇥", "Switch between search and items"), ("⌘G", "Show item in its list"),
        ("⌘← ⌘→", "Previous / next pinboard"), ("⇧⌘N", "New pinboard"), ("⌘P", "Add to Paste Stack"),
        ("⌘T", "Pause / resume"), ("⌘,", "Settings"), ("⎋", "Close"),
    ]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(rows, id: \.0) { r in
                GridRow {
                    Text(r.0).font(.system(.body, design: .rounded)).fontWeight(.semibold).frame(width: 90, alignment: .leading)
                    Text(r.1).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }
}

struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type shortcut…" : combo.display)
                .frame(minWidth: 110)
                .foregroundStyle(recording ? Color.accentColor : .primary)
        }
        .onDisappear { stop() }
    }

    func start() {
        recording = true
        HotKeyCenter.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let c = KeyCombo(event: e)
            if c.modifiers != 0 { combo = c; stop() }
            return nil
        }
    }

    func stop() {
        recording = false
        HotKeyCenter.shared.suspended = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

struct PrivacySettings: View {
    @Bindable var s = Settings.shared
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                Toggle("Ignore confidential content (passwords)", isOn: $s.ignoreConfidential)
                Toggle("Ignore transient content", isOn: $s.ignoreTransient)
            } footer: {
                Text("Password managers mark copied passwords as confidential. Transient content is temporary data generated by apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignore applications") {
                Text("Don’t save content copied from these apps. Existing items stay until you delete them.")
                    .font(.caption).foregroundStyle(.secondary)
                List(selection: $selection) {
                    ForEach(s.ignoredApps) { app in
                        HStack {
                            if let icon = AppIcons.icon(app.bundleID) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                            Text(app.name)
                            Spacer()
                            Text(app.bundleID).font(.caption).foregroundStyle(.tertiary)
                        }
                        .tag(app.bundleID)
                    }
                }
                .frame(minHeight: 140)
                HStack(spacing: 4) {
                    Button { addApp() } label: { Image(systemName: "plus") }
                    Button { s.ignoredApps.removeAll { $0.bundleID == selection }; selection = nil } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                    Spacer()
                    Menu("Add Running App") {
                        ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier!) {
                                add(bundleID: app.bundleIdentifier!, name: app.localizedName ?? app.bundleIdentifier!)
                            }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
    }

    func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let b = Bundle(url: url)?.bundleIdentifier {
                add(bundleID: b, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            }
        }
    }

    func add(bundleID: String, name: String) {
        guard !s.ignoredApps.contains(where: { $0.bundleID == bundleID }) else { return }
        s.ignoredApps.append(IgnoredApp(bundleID: bundleID, name: name))
    }
}

struct SyncSettings: View {
    @Bindable var s = Settings.shared
    var body: some View {
        Form {
            Section {
                Toggle("Sync with iCloud Drive", isOn: $s.syncEnabled)
                    .disabled(!Paths.iCloudDriveAvailable)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !Paths.iCloudDriveAvailable {
                        Text("iCloud Drive isn’t turned on for this Mac. Turn it on in System Settings › Apple Account › iCloud.")
                            .foregroundStyle(.orange)
                    }
                    Text("History and pinboards are stored in your private iCloud Drive (iCloud Drive › Clipbay) and merged across every Mac signed in to the same Apple Account. Nothing goes to any other server.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Section("Storage") {
                LabeledContent("Location", value: ClipStore.shared.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                LabeledContent("Status", value: Sync.shared.status)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ClipStore.shared.root]) }
            }
        }
        .formStyle(.grouped)
    }
}

struct IntelligenceSettings: View {
    @Bindable var s = Settings.shared
    @State private var copied = false

    var exe: String { Bundle.main.executablePath ?? "/Applications/Clipbay.app/Contents/MacOS/Clipbay" }
    var claudeCommand: String { "claude mcp add clipbay -- \"\(exe)\" --mcp" }
    var jsonConfig: String {
        """
        {
          "mcpServers": {
            "clipbay": { "command": "\(exe)", "args": ["--mcp"] }
          }
        }
        """
    }

    var body: some View {
        Form {
            Section {
                Toggle("Suggestions", isOn: $s.suggestionsEnabled)
            } footer: {
                Text("Shows a Suggestions list ranked by what you usually paste into the app you’re working in. Computed on this Mac only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Enable MCP (connect AI tools)", isOn: $s.mcpEnabled)
            } footer: {
                Text("Lets AI tools like Claude Code, Claude Desktop, Cursor or VS Code search your clipboard history, read items, save new items and list pinboards. Tools run Clipbay locally over stdio; turn this off to block them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if s.mcpEnabled {
                Section("Claude Code") {
                    HStack {
                        Text(claudeCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button(copied ? "Copied" : "Copy") { copy(claudeCommand) }
                    }
                }
                Section("Other tools (JSON config)") {
                    HStack(alignment: .top) {
                        Text(jsonConfig).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Copy") { copy(jsonConfig) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    func copy(_ t: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(t, forType: .string)
        copied = true
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Clipbay").font(.title).bold()
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .foregroundStyle(.secondary)
            Text("Everything you copy, one keystroke away.").font(.callout)
            Text("Press \(Settings.shared.activateHotKey.display) anywhere to open your clipboard.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
