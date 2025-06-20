//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import AVFoundation
import Cocoa
import Foundation
import MediaKeyTap
import os.log
import ServiceManagement
import Settings
import SimplyCoreAudio
import Sparkle
// ADD THIS IMPORT
import CoreBrightness

class AppDelegate: NSObject, NSApplicationDelegate {
  let statusItem: NSStatusItem = {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.behavior = .removalAllowed
    return item
  }()
  var mediaKeyTap = MediaKeyTapManager()
  var keyboardShortcuts = KeyboardShortcutsManager()
  let coreAudio = SimplyCoreAudio()
  var accessibilityObserver: NSObjectProtocol!
  var statusItemObserver: NSObjectProtocol!
  var statusItemVisibilityChangedByUser = true
  var reconfigureID: Int = 0 // dispatched reconfigure command ID
  var sleepID: Int = 0 // sleep event ID
  var safeMode = false
  var jobRunning = false
  var startupActionWriteCounter: Int = 0
  var audioPlayer: AVAudioPlayer?
  let updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: UpdaterDelegate(), userDriverDelegate: nil)

  // ADD THIS NEW PROPERTY
  var brightnessBeforeNightShift: [CGDirectDisplayID: Float] = [:]

  var settingsPaneStyle: Settings.Style {
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      return Settings.Style.toolbarItems
    } else {
      return Settings.Style.segmentedControl
    }
  }

  lazy var settingsWindowController: SettingsWindowController = .init(
    panes: [
      mainPrefsVc!,
      menuslidersPrefsVc!,
      keyboardPrefsVc!,
      displaysPrefsVc!,
      aboutPrefsVc!,
    ],
    style: self.settingsPaneStyle,
    animated: true
  )

  func applicationDidFinishLaunching(_: Notification) {
    app = self
    self.subscribeEventListeners()
    self.showSafeModeAlertIfNeeded()

    // ADD THIS LINE
    _ = NightShiftObserver.shared

    if !prefs.bool(forKey: PrefKey.appAlreadyLaunched.rawValue) {
      self.showOnboardingWindow()
    } else {
      self.checkPermissions()
    }
    self.setPrefsBuildNumber()
    self.setDefaultPrefs()
    self.setMenu()
    CGDisplayRegisterReconfigurationCallback({ _, _, _ in app.displayReconfigured() }, nil)
    self.configure(firstrun: true)
    DisplayManager.shared.createGammaActivityEnforcer()
    self.updaterController.startUpdater()
  }

  @objc func quitClicked(_: AnyObject) {
    os_log("Quit clicked", type: .info)
    menu.closeMenu()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      NSApplication.shared.terminate(self)
    }
  }

  @objc func prefsClicked(_: AnyObject) {
    os_log("Settings clicked", type: .info)
    self.settingsWindowController.show()
  }

  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    app.prefsClicked(self)
    return true
  }

  func applicationWillTerminate(_: Notification) {
    os_log("Goodbye!", type: .info)
    DisplayManager.shared.resetSwBrightnessForAllDisplays(noPrefSave: true)
    self.updateStatusItemVisibility(true)
  }

  private func setPrefsBuildNumber() {
    let currentBuildNumber = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
    let previousBuildNumber: Int = (Int(prefs.string(forKey: PrefKey.buildNumber.rawValue) ?? "0") ?? 0)
    if self.safeMode || ((previousBuildNumber < MIN_PREVIOUS_BUILD_NUMBER) && previousBuildNumber > 0) || (previousBuildNumber > currentBuildNumber), let bundleID = Bundle.main.bundleIdentifier {
      if !self.safeMode {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Incompatible previous version", comment: "Shown in the alert dialog")
        alert.informativeText = NSLocalizedString("Settings for an incompatible previous app version detected. Default settings are reloaded.", comment: "Shown in the alert dialog")
        alert.runModal()
      }
      prefs.removePersistentDomain(forName: bundleID)
    }
    prefs.set(currentBuildNumber, forKey: PrefKey.buildNumber.rawValue)
  }

  func setDefaultPrefs() {
    if !prefs.bool(forKey: PrefKey.appAlreadyLaunched.rawValue) {
      // Only settings that are not false, 0 or "" by default are set here. Assumes pre-wiped database.
      prefs.set(true, forKey: PrefKey.appAlreadyLaunched.rawValue)
      prefs.set(true, forKey: PrefKey.SUEnableAutomaticChecks.rawValue)

      // ADD THIS LINE
      prefs.set(0.2, forKey: PrefKey.nightShiftDimmingLevel.rawValue) // Default to 20% brightness
    }
  }

  @objc func displayReconfigured() {
    DisplayManager.shared.resetSwBrightnessForAllDisplays(noPrefSave: true)
    CGDisplayRestoreColorSyncSettings()
    self.reconfigureID += 1
    self.updateMediaKeyTap()
    os_log("Bumping reconfigureID to %{public}@", type: .info, String(self.reconfigureID))
    _ = DisplayManager.shared.destroyAllShades()
    if self.sleepID == 0 {
      let dispatchedReconfigureID = self.reconfigureID
      os_log("Display to be reconfigured with reconfigureID %{public}@", type: .info, String(dispatchedReconfigureID))
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        self.configure(dispatchedReconfigureID: dispatchedReconfigureID)
      }
    }
  }

  func configure(dispatchedReconfigureID: Int = 0, firstrun: Bool = false) {
    guard self.sleepID == 0, dispatchedReconfigureID == self.reconfigureID else {
      return
    }
    os_log("Request for configuration with reconfigreID %{public}@", type: .info, String(dispatchedReconfigureID))
    self.reconfigureID = 0
    DisplayManager.shared.gammaInterferenceCounter = 0
    DisplayManager.shared.configureDisplays()
    DisplayManager.shared.addDisplayCounterSuffixes()
    DisplayManager.shared.updateArm64AVServices()
    if firstrun && prefs.integer(forKey: PrefKey.startupAction.rawValue) != StartupAction.write.rawValue {
      DisplayManager.shared.resetSwBrightnessForAllDisplays(prefsOnly: true)
    }
    DisplayManager.shared.setupOtherDisplays(firstrun: firstrun)
    self.updateMenusAndKeys()
    if !firstrun || prefs.integer(forKey: PrefKey.startupAction.rawValue) == StartupAction.write.rawValue {
      if !prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue) {
        DisplayManager.shared.restoreSwBrightnessForAllDisplays(async: !prefs.bool(forKey: PrefKey.disableSmoothBrightness.rawValue))
      }
    }
    displaysPrefsVc?.loadDisplayList()
    self.job(start: true)
  }

  func updateMenusAndKeys() {
    menu.updateMenus()
    self.updateMediaKeyTap()
  }

  func checkPermissions(firstAsk: Bool = false) {
    let permissionsRequired: Bool = [KeyboardVolume.media.rawValue, KeyboardVolume.both.rawValue].contains(prefs.integer(forKey: PrefKey.keyboardVolume.rawValue)) || [KeyboardBrightness.media.rawValue, KeyboardBrightness.both.rawValue].contains(prefs.integer(forKey: PrefKey.keyboardBrightness.rawValue))
    if !MediaKeyTapManager.readPrivileges(prompt: false), permissionsRequired {
      MediaKeyTapManager.acquirePrivileges(firstAsk: firstAsk)
    }
  }

  private func subscribeEventListeners() {
    NotificationCenter.default.addObserver(self, selector: #selector(self.audioDeviceChanged), name: Notification.Name.defaultOutputDeviceChanged, object: nil) // subscribe Audio output detector (SimplyCoreAudio)
    DistributedNotificationCenter.default.addObserver(self, selector: #selector(self.displayReconfigured), name: NSNotification.Name(rawValue: kColorSyncDisplayDeviceProfilesNotification.takeRetainedValue() as String), object: nil) // ColorSync change
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.sleepNotification), name: NSWorkspace.screensDidSleepNotification, object: nil) // sleep and wake listeners
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.wakeNotification), name: NSWorkspace.screensDidWakeNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.sleepNotification), name: NSWorkspace.willSleepNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.wakeNotification), name: NSWorkspace.didWakeNotification, object: nil)
    _ = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(rawValue: NSNotification.Name.accessibilityApi.rawValue), object: nil, queue: nil) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.updateMediaKeyTap() } } // listen for accessibility status changes
    self.statusItemObserver = statusItem.observe(\.isVisible, options: [.old, .new]) { _, _ in self.statusItemVisibilityChanged() }

    // ADD THIS LINE
    NotificationCenter.default.addObserver(self, selector: #selector(self.handleNightShiftChange), name: .nightShiftStatusChanged, object: nil)
  }

  @objc private func sleepNotification() {
    self.sleepID += 1
    os_log("Sleeping with sleep %{public}@", type: .info, String(self.sleepID))
    self.updateMediaKeyTap()
  }

  @objc private func wakeNotification() {
    if self.sleepID != 0 {
      os_log("Waking up from sleep %{public}@", type: .info, String(self.sleepID))
      let dispatchedSleepID = self.sleepID
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { // Some displays take time to recover...
        self.soberNow(dispatchedSleepID: dispatchedSleepID)
      }
    }
  }

  private func soberNow(dispatchedSleepID: Int) {
    if self.sleepID == dispatchedSleepID {
      os_log("Sober from sleep %{public}@", type: .info, String(self.sleepID))
      self.sleepID = 0
      if self.reconfigureID != 0 {
        let dispatchedReconfigureID = self.reconfigureID
        os_log("Displays need reconfig after sober with reconfigureID %{public}@", type: .info, String(dispatchedReconfigureID))
        self.configure(dispatchedReconfigureID: dispatchedReconfigureID)
      } else if Arm64DDC.isArm64 {
        os_log("Displays don't need reconfig after sober but might need AVServices update", type: .info)
        DisplayManager.shared.updateArm64AVServices()
        self.job(start: true)
      }
      self.startupActionWriteRepeatAfterSober()
      self.updateMediaKeyTap()
    }
  }

  private func startupActionWriteRepeatAfterSober(dispatchedCounter: Int = 0) {
    let counter = dispatchedCounter == 0 ? 10 : dispatchedCounter
    self.startupActionWriteCounter = dispatchedCounter == 0 ? counter : self.startupActionWriteCounter
    guard prefs.integer(forKey: PrefKey.startupAction.rawValue) == StartupAction.write.rawValue, self.startupActionWriteCounter == counter else {
      return
    }
    os_log("Sober write action repeat for DDC - %{public}@", type: .info, String(counter))
    DisplayManager.shared.restoreOtherDisplays()
    self.startupActionWriteCounter = counter - 1
    if counter > 1 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        self.startupActionWriteRepeatAfterSober(dispatchedCounter: counter - 1)
      }
    }
  }

  private func job(start: Bool = false) {
    guard !(self.jobRunning && start) else {
      return
    }
    if self.sleepID == 0, self.reconfigureID == 0 {
      if !self.jobRunning {
        os_log("MonitorControl job started.", type: .info)
        self.jobRunning = true
      }
      var refreshedSomething = false
      for display in DisplayManager.shared.displays {
        let delta = display.refreshBrightness()
        if delta != 0 {
          refreshedSomething = true
          if prefs.bool(forKey: PrefKey.enableBrightnessSync.rawValue) {
            for targetDisplay in DisplayManager.shared.displays where targetDisplay != display {
              os_log("Updating delta from display %{public}@ to display %{public}@", type: .info, String(display.identifier), String(targetDisplay.identifier))
              let newValue = max(0, min(1, targetDisplay.getBrightness() + delta))
              _ = targetDisplay.setBrightness(newValue)
              if let slider = targetDisplay.sliderHandler[.brightness] {
                slider.setValue(newValue, displayID: targetDisplay.identifier)
              }
            }
          }
        }
      }
      let nextRefresh = refreshedSomething ? 0.1 : 1.0
      DispatchQueue.main.asyncAfter(deadline: .now() + nextRefresh) {
        self.job()
      }
    } else {
      self.jobRunning = false
      os_log("MonitorControl job died because of sleep or reconfiguration.", type: .info)
    }
  }

  func handleListenForChanged() {
    self.checkPermissions()
    self.updateMediaKeyTap()
  }

  func settingsReset() {
    os_log("Resetting all settings.")
    if !prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue) {
      DisplayManager.shared.resetSwBrightnessForAllDisplays(async: false)
    }
    if let bundleID = Bundle.main.bundleIdentifier {
      prefs.removePersistentDomain(forName: bundleID)
    }
    app.updateStatusItemVisibility(true)
    self.setDefaultPrefs()
    self.checkPermissions()
    self.updateMediaKeyTap()
    self.configure(firstrun: true)
  }

  @objc func audioDeviceChanged() {
    if let defaultDevice = self.coreAudio.defaultOutputDevice {
      os_log("Default output device changed to “%{public}@”.", type: .info, defaultDevice.name)
      os_log("Can device set its own volume? %{public}@", type: .info, defaultDevice.canSetVirtualMainVolume(scope: .output).description)
    }
    self.updateMediaKeyTap()
  }

  func updateMediaKeyTap() {
    MediaKeyTap.useAlternateBrightnessKeys = !prefs.bool(forKey: PrefKey.disableAltBrightnessKeys.rawValue)
    self.mediaKeyTap.updateMediaKeyTap()
  }

  func setStartAtLogin(enabled: Bool) {
    let identifier = "\(Bundle.main.bundleIdentifier!)Helper" as CFString
    SMLoginItemSetEnabled(identifier, enabled)
  }

  func getSystemSettings() -> [String: AnyObject]? {
    var propertyListFormat = PropertyListSerialization.PropertyListFormat.xml
    let plistPath = NSString(string: "~/Library/Preferences/.GlobalPreferences.plist").expandingTildeInPath
    guard let plistXML = FileManager.default.contents(atPath: plistPath) else {
      return nil
    }
    do {
      return try PropertyListSerialization.propertyList(from: plistXML, options: .mutableContainersAndLeaves, format: &propertyListFormat) as? [String: AnyObject]
    } catch {
      os_log("Error reading system prefs plist: %{public}@", type: .info, error.localizedDescription)
      return nil
    }
  }

  func macOS10() -> Bool {
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      return false
    } else {
      return true
    }
  }

  func playVolumeChangedSound() {
    guard let settings = app.getSystemSettings(), let hasSoundEnabled = settings["com.apple.sound.beep.feedback"] as? Int, hasSoundEnabled == 1 else {
      return
    }
    do {
      self.audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"))
      self.audioPlayer?.volume = 1
      self.audioPlayer?.play()
    } catch {
      os_log("%{public}@", type: .error, error.localizedDescription)
    }
  }

  private func setMenu() {
    menu = MenuHandler()
    menu.delegate = menu
    self.statusItem.button?.image = NSImage(named: "status")
    self.statusItem.menu = menu
  }

  private func showSafeModeAlertIfNeeded() {
    if NSEvent.modifierFlags.contains(NSEvent.ModifierFlags.shift) {
      self.safeMode = true
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("Safe Mode Activated", comment: "Shown in the alert dialog")
      alert.informativeText = NSLocalizedString("Shift was pressed during launch. MonitorControl started in safe mode. Default settings are reloaded, DDC read is blocked.", comment: "Shown in the alert dialog")
      alert.runModal()
    }
  }

  private func showOnboardingWindow() {
    onboardingVc?.showWindow(self)
    onboardingVc?.window?.center()
    NSApp.activate(ignoringOtherApps: true)
    // ADD THIS NEW FUNCTION AT THE END OF THE FILE, BEFORE THE FINAL '}'
    @objc func handleNightShiftChange(notification: NSNotification? = nil, force: Bool = false) {
      var isEnabled: Bool?
  
      if let notification = notification, let userInfo = notification.userInfo {
          isEnabled = userInfo["isEnabled"] as? Bool
      } else if force {
          var status: ObjCBool = false
          let client = CBBlueLightClient()
          if client.getBlueLightStatus(&status) {
              isEnabled = status.boolValue
          }
      }
  
      guard let nightShiftEnabled = isEnabled, prefs.bool(forKey: PrefKey.dimOnNightShift.rawValue) else {
          // If the feature is disabled, try to restore brightness just in case it was enabled before.
          if !prefs.bool(forKey: PrefKey.dimOnNightShift.rawValue) {
              for display in DisplayManager.shared.getAllDisplays() {
                  if let originalBrightness = self.brightnessBeforeNightShift[display.identifier] {
                      _ = display.setBrightness(originalBrightness, slow: true)
                  }
              }
              self.brightnessBeforeNightShift.removeAll()
          }
          return
      }
  
      let dimmingLevel = prefs.float(forKey: PrefKey.nightShiftDimmingLevel.rawValue)
  
      if nightShiftEnabled {
          // Night Shift is ON, dim the displays
          for display in DisplayManager.shared.getAllDisplays() {
              // Only save the brightness if it hasn't been saved already
              if self.brightnessBeforeNightShift[display.identifier] == nil {
                  self.brightnessBeforeNightShift[display.identifier] = display.getBrightness()
              }
              _ = display.setBrightness(dimmingLevel, slow: true)
          }
      } else {
          // Night Shift is OFF, restore brightness
          for display in DisplayManager.shared.getAllDisplays() {
              if let originalBrightness = self.brightnessBeforeNightShift[display.identifier] {
                  _ = display.setBrightness(originalBrightness, slow: true)
              }
          }
          self.brightnessBeforeNightShift.removeAll()
      }
    }
  }
  
  private func statusItemVisibilityChanged() {
    if !self.statusItem.isVisible, self.statusItemVisibilityChangedByUser {
      prefs.set(MenuIcon.hide.rawValue, forKey: PrefKey.menuIcon.rawValue)
    }
  }
  
  func updateStatusItemVisibility(_ visible: Bool) {
    statusItemVisibilityChangedByUser = false
    statusItem.isVisible = visible
    statusItemVisibilityChangedByUser = true
  }
}
