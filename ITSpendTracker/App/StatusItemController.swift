import AppKit
import Observation
import SwiftUI

/// Menu bar icon that opens the single resizable main window (DEC-029).
/// The icon shows a warning cue while any warning is active (REQ-008).
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var window: NSWindow?
    private static let frameName = "ITSpendTrackerMainWindow"

    init(model: AppModel) {
        self.model = model
        super.init()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleWindow)
        updateIcon()
    }

    /// Re-renders the icon whenever the warning state changes.
    private func updateIcon() {
        withObservationTracking {
            let warnings = model.hasWarnings
            let image = NSImage(systemSymbolName: warnings ? "creditcard.trianglebadge.exclamationmark" : "creditcard",
                                accessibilityDescription: warnings ? String(localized: "IT Spend Tracker: warnings")
                                                                   : String(localized: "IT Spend Tracker"))
            image?.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.setAccessibilityLabel(image?.accessibilityDescription)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    /// Opens or brings the window to the front; hides it when it is already in front.
    @objc private func toggleWindow() {
        if let window, window.isVisible, window.isKeyWindow, NSApp.isActive {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    func showWindow() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Activation is cooperative on current macOS; ordering the window front regardless keeps it
        // from opening behind the app the user was in.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: MainView().environment(model))
        // The window size is the user's, not derived from the SwiftUI content.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "IT Spend Tracker")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 480)
        window.setContentSize(NSSize(width: 960, height: 780))
        if !window.setFrameUsingName(Self.frameName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        statusItem = StatusItemController(model: model)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            LaunchAtLogin.registerOnFirstInstalledLaunch()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusItem?.showWindow()
        return false
    }
}
