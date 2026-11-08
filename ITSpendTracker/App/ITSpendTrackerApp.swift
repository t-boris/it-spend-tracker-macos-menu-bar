import SwiftUI

@main
struct ITSpendTrackerApp: App {
    // The menu bar icon and the main window are managed in AppKit (DEC-029).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
