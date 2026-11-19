import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var timers: [Timer] = []
    private var welcome: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            others.first?.activate()
            NSApp.terminate(nil)
            return
        }

        setupMainMenu()
        _ = ClipStore.shared
        ClipStore.shared.purge(retention: Settings.shared.retention)
        Sync.shared.configure()
        ClipboardMonitor.shared.start()
        HotKeys.reload()
        ShelfController.shared.setup()
        setupStatusItem()

        timers.append(Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { _ = ClipStore.shared.purge(retention: Settings.shared.retention) }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { ClipStore.shared.importInbox() }
        })

        if !Settings.shared.onboarded { showWelcome() }
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ShelfController.shared.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipStore.shared.saveNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ShelfController.shared.show()
        return false
    }

    // MARK: Menus

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Clipbay", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Clipbay", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Clipbay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let fmtItem = NSMenuItem()
        let fmt = NSMenu(title: "Format")
        fmt.addItem(withTitle: "Bold", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "b").tag = Int(NSFontTraitMask.boldFontMask.rawValue)
        fmt.addItem(withTitle: "Italic", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "i").tag = Int(NSFontTraitMask.italicFontMask.rawValue)
        fmt.addItem(withTitle: "Underline", action: #selector(NSText.underline(_:)), keyEquivalent: "u")
        fmtItem.submenu = fmt
        main.addItem(fmtItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Clipbay")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared
        let open = menu.addItem(withTitle: "Open Clipbay", action: #selector(openShelf), keyEquivalent: "")
        open.target = self
        open.toolTip = s.activateHotKey.display
        menu.addItem(withTitle: "Open Paste Stack", action: #selector(openStack), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if s.isPaused {
            menu.addItem(withTitle: s.pauseDescription, action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(withTitle: "Resume Clipbay", action: #selector(resume), keyEquivalent: "").target = self
        } else {
            let pause = NSMenuItem(title: "Pause Clipbay", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, secs) in [("For 15 Minutes", 900.0), ("For 1 Hour", 3600.0), ("For 8 Hours", 28800.0), ("Until Resumed", -1.0)] {
                let it = sub.addItem(withTitle: title, action: #selector(pauseFor(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = secs
            }
            pause.submenu = sub
            menu.addItem(pause)
        }
        menu.addItem(.separator())
        if !Paster.isTrusted {
            menu.addItem(withTitle: "Allow Direct Paste (Accessibility)…", action: #selector(grantAX), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Clipbay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func openShelf() { DispatchQueue.main.async { ShelfController.shared.show() } }
    @objc func openStack() { PasteStack.shared.start(captureSelection: false) }
    @objc func resume() { Settings.shared.resume() }
    @objc func pauseFor(_ sender: NSMenuItem) {
        let secs = sender.representedObject as? Double ?? -1
        Settings.shared.pause(for: secs < 0 ? nil : secs)
    }
    @objc func grantAX() { Paster.ensureAccessibility(); Paster.openAccessibilitySettings() }
    @objc func showSettings() { SettingsController.shared.show() }
    @objc func showAbout() { SettingsController.shared.show(tab: .about) }

    // MARK: Welcome

    private func showWelcome() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: WelcomeView { [weak self] in
            Settings.shared.onboarded = true
            self?.welcome?.close()
            if !CommandLine.arguments.contains("--dock") { NSApp.setActivationPolicy(.accessory) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ShelfController.shared.show() }
        })
        w.center()
        welcome = w
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    var done: () -> Void
    @State private var trusted = Paster.isTrusted

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("Welcome to Clipbay").font(.system(size: 26, weight: .bold))
            Text("Everything you copy is saved. Open your clipboard anywhere with")
                .foregroundStyle(.secondary)
            Text(Settings.shared.activateHotKey.display)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 10) {
                Label("Pick an item and press ↩ to paste it straight into the app you’re using.", systemImage: "arrow.turn.down.left")
                Label("Pin snippets, links and images to colored pinboards.", systemImage: "pin")
                Label("Press ⇧⌘C to collect a Paste Stack, then ⌘V them one by one.", systemImage: "square.stack.3d.up")
            }
            .font(.callout)
            .frame(maxWidth: 420, alignment: .leading)
            HStack(spacing: 10) {
                Image(systemName: trusted ? "checkmark.circle.fill" : "hand.raised.fill").foregroundStyle(trusted ? .green : .orange)
                Text(trusted ? "Direct paste is enabled" : "Allow Accessibility so Clipbay can paste for you")
                    .font(.callout)
                if !trusted {
                    Button("Allow…") { Paster.ensureAccessibility(); Paster.openAccessibilitySettings() }
                }
            }
            Button("Get Started", action: done)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(width: 520, height: 460)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in trusted = Paster.isTrusted }
    }
}
