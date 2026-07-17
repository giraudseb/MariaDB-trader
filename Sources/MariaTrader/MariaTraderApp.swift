import SwiftUI
import AppKit

// Launched as a bare SwiftPM executable (no .app bundle), macOS starts the
// process as a non-activating accessory: the window never comes to front and
// there is no Dock icon. Forcing a regular activation policy and activating
// on launch makes the UI appear.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct MariaTraderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("MariaTrader — MariaDB Availability Demo") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}
