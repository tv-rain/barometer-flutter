import Foundation
import UIKit

/// Background execution time for active runs. The host begins a task when a run starts and ends
/// it when no run is active; the expiration handler runs, on the main thread, when the operating
/// system is about to suspend the application. Tests replace it.
protocol BackgroundTasks: AnyObject {
  /// Begins a task, or returns nil when the system grants none.
  func begin(expiration: @escaping () -> Void) -> Int?

  /// Ends a task that `begin` returned.
  func end(_ id: Int)
}

/// `UIApplication` background tasks. Both calls may be made on any thread.
final class AppleBackgroundTasks: BackgroundTasks {
  func begin(expiration: @escaping () -> Void) -> Int? {
    let id = UIApplication.shared.beginBackgroundTask(withName: "barometer-run", expirationHandler: expiration)
    return id == .invalid ? nil : id.rawValue
  }

  func end(_ id: Int) {
    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
  }
}
