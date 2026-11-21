import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted synchronously on the main thread at ⌘Q; player models save progress in response.
    static let foyerWillTerminate = Notification.Name("foyer.willTerminate")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // SwiftUI doesn't run onDisappear on quit, and library writes are queued off the main thread,
    // so save first and then drain the queue before the process exits.
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: .foyerWillTerminate, object: nil)
        Disk.flush()
    }
}

extension Scene {
    /// A restored player window would reopen a tokenized stream and start playing at launch.
    func playerRestorationDisabled() -> some Scene {
        if #available(macOS 15, *) {
            return self.restorationBehavior(.disabled)
        }
        return self
    }
}
