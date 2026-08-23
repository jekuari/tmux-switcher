import AppKit

/// Tracks whether a specific application (identified by bundle ID) is the frontmost app.
///
/// Notifications for app activation/deactivation are posted on
/// `NSWorkspace.shared.notificationCenter`, NOT `NotificationCenter.default` — using the
/// default center here is a classic silent no-op (it compiles, it "works", it just never
/// fires), so we're careful to register on the workspace's own center.
@MainActor
final class FocusWatcher {
    var onFrontmostChanged: ((Bool) -> Void)?

    private(set) var isTargetFrontmost: Bool = false
    private(set) var targetApp: NSRunningApplication?

    private let targetBundleID: String
    private var activateObserver: NSObjectProtocol?
    private var deactivateObserver: NSObjectProtocol?

    init(targetBundleID: String) {
        self.targetBundleID = targetBundleID
    }

    func start() {
        guard activateObserver == nil, deactivateObserver == nil else { return }

        let center = NSWorkspace.shared.notificationCenter

        activateObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Registered with `queue: .main`, so this block always runs on the
            // main thread; assuming main-actor isolation is safe.
            MainActor.assumeIsolated {
                self?.handle(notification: notification, activated: true)
            }
        }

        deactivateObserver = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Registered with `queue: .main`, so this block always runs on the
            // main thread; assuming main-actor isolation is safe.
            MainActor.assumeIsolated {
                self?.handle(notification: notification, activated: false)
            }
        }

        // Seed initial state immediately rather than waiting for the first notification,
        // otherwise we'd report the wrong focus state until the user next switches apps.
        let frontmost = NSWorkspace.shared.frontmostApplication
        targetApp = (frontmost?.bundleIdentifier == targetBundleID) ? frontmost : targetApp
        isTargetFrontmost = frontmost?.bundleIdentifier == targetBundleID
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let activateObserver {
            center.removeObserver(activateObserver)
            self.activateObserver = nil
        }
        if let deactivateObserver {
            center.removeObserver(deactivateObserver)
            self.deactivateObserver = nil
        }
    }

    // MARK: - Handling

    private func handle(notification: Notification, activated: Bool) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        guard app.bundleIdentifier == targetBundleID else { return }

        targetApp = app
        let newValue = activated
        guard newValue != isTargetFrontmost else { return }
        isTargetFrontmost = newValue
        onFrontmostChanged?(newValue)
    }
}
