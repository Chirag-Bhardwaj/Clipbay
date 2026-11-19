import AppKit

if CommandLine.arguments.contains("--mcp") {
    MCPServer.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Snapshot.run(dir: CommandLine.arguments[i + 1])
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // --dock keeps a Dock icon (useful for UI automation/testing tools that only see regular apps).
    app.setActivationPolicy(CommandLine.arguments.contains("--dock") ? .regular : .accessory)
    withExtendedLifetime(delegate) { app.run() }
}
