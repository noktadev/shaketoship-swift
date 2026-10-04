import Foundation

struct FeedbackDevContext: Codable, Equatable, Sendable {
  let os: String
  let device: String
  let appVersion: String
  let build: String
  let locale: String
  let batteryPercent: Int?
  let storageFreeBytes: Int64?
  let lowPower: Bool
  let screenWidth: Int
  let screenHeight: Int
  let screenCount: Int
  let tapCount: Int

  static func counts(events: [FeedbackEvent]) -> (screens: Int, taps: Int) {
    let screens = events.filter { $0.screen != nil }.count
    return (screens, events.count - screens)
  }
  static func timeline(events: [FeedbackEvent]) -> [String] {
    ["0:00 Recording started"] + events.sorted { $0.t < $1.t }.prefix(12).map { event in
      let seconds = max(0, Int(event.t))
      let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
      switch event {
      case let .screen(_, name): return "\(time) Screen: \(name)"
      case let .tap(_, tap): return "\(time) Tap: \(tap.element ?? "Screen")"
      }
    }
  }
}

#if canImport(UIKit)
import UIKit
extension FeedbackDevContext {
  @MainActor static func current(events: [FeedbackEvent]) -> Self {
    let device = UIDevice.current
    let monitoring = device.isBatteryMonitoringEnabled
    device.isBatteryMonitoringEnabled = true
    let battery = device.batteryLevel
    device.isBatteryMonitoringEnabled = monitoring
    let screen = ShakeToShip.hostWindow?.windowScene?.screen ?? UIScreen.main
    let size = screen.bounds.size
    let volume = try? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    let counts = counts(events: events)
    return Self(os: device.systemName + " " + device.systemVersion, device: device.model,
      appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
      build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown",
      locale: Locale.current.identifier, batteryPercent: battery < 0 ? nil : Int(battery * 100),
      storageFreeBytes: volume?.volumeAvailableCapacityForImportantUsage,
      lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
      screenWidth: Int(size.width), screenHeight: Int(size.height),
      screenCount: counts.screens, tapCount: counts.taps)
  }
}
#endif
