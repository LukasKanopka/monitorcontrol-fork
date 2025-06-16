//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation
import AppKit

class NightShiftObserver {
  static let shared = NightShiftObserver()

  private init() {
    DistributedNotificationCenter.default.addObserver(
      self,
      selector: #selector(self.nightShiftStatusChanged),
      name: NSNotification.Name("com.apple.CoreBrightness.blueLightStatusChanged"),
      object: nil
    )
  }

  @objc private func nightShiftStatusChanged(notification: NSNotification) {
    guard let userInfo = notification.userInfo,
          let status = userInfo["BlueLightStatus"] as? [String: Any],
          let enabled = status["Enabled"] as? Int else {
      return
    }

    let isEnabled = enabled == 1
    // Post a custom notification to be used within the app
    NotificationCenter.default.post(name: .nightShiftStatusChanged, object: nil, userInfo: ["isEnabled": isEnabled])
  }
}

// Also add this extension
extension NSNotification.Name {
    static let nightShiftStatusChanged = NSNotification.Name("nightShiftStatusChanged")
}
