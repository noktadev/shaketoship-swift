import Foundation
import Testing

@testable import AppFeedback

/// #474: island-first indicator. The pure model identifier -> Dynamic Island
/// decision picks which in-app indicator shows (none on island devices while a
/// Live Activity runs, slim top bar otherwise). Fails SAFE: any model not in the
/// known-island allowlist - including the 16e and phones newer than this table -
/// shows the recording bar rather than risk no on-screen indicator.
@Suite struct FeedbackDeviceCapabilityTests {
  @Test func islandModelsHaveIsland() {
    // 14 Pro / Pro Max, 15 / Plus / Pro / Pro Max, 16 / Plus / Pro / Pro Max.
    for id in ["iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5",
               "iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone17,2",
               "iPhone17,3", "iPhone17,4"] {
      #expect(FeedbackDeviceCapability.hasDynamicIsland(identifier: id), "\(id)")
    }
  }

  @Test func preIslandModelsDoNot() {
    // iPhone 14 / Plus (no island), 13-era, SE, and older families.
    for id in ["iPhone14,7", "iPhone14,8", "iPhone14,2", "iPhone14,6", "iPhone12,8"] {
      #expect(FeedbackDeviceCapability.hasDynamicIsland(identifier: id) == false, "\(id)")
    }
  }

  /// iPhone 16e (iPhone17,5) sits in an island generation but has NO Dynamic
  /// Island, so it must show the bar - the exact regression a major-version
  /// heuristic caused.
  @Test func iPhone16eHasNoIsland() {
    #expect(FeedbackDeviceCapability.hasDynamicIsland(identifier: "iPhone17,5") == false)
  }

  /// Fail-safe: an identifier newer than this table is unknown, so it shows the
  /// bar rather than gamble that it has an island.
  @Test func unknownFuturePhoneFailsSafeToShowingBar() {
    #expect(FeedbackDeviceCapability.hasDynamicIsland(identifier: "iPhone99,1") == false)
    #expect(FeedbackDeviceCapability.hasDynamicIsland(identifier: "iPhone20,3") == false)
  }

  @Test func nonPhoneHasNoIsland() {
    for id in ["iPad13,1", "x86_64", "arm64", ""] {
      #expect(FeedbackDeviceCapability.hasDynamicIsland(identifier: id) == false, "\(id)")
    }
  }
}
