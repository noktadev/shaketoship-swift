#if canImport(UIKit)
import AVFoundation
import os

/// The part of `AVAudioSession` the review preview uses. A seam so tests can prove
/// the policy without a live audio route.
protocol FeedbackAudioSessioning: AnyObject {
  var category: AVAudioSession.Category { get }
  var mode: AVAudioSession.Mode { get }
  var categoryOptions: AVAudioSession.CategoryOptions { get }
  func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
    options: AVAudioSession.CategoryOptions) throws
  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: FeedbackAudioSessioning {}

/// Makes the review preview audible.
///
/// The SDK never configured a session for review playback, so the preview used
/// whatever the process had. A host that has not played audio yet (Lock In sets
/// `.playback` only when a clip plays) is still in the process default,
/// `.soloAmbient`, which the Ring/Silent switch mutes. After a microphone capture
/// the session can also be left in a record category that routes to the receiver.
/// While the preview plays, the session is `.playback`; when it stops, the session
/// is deactivated with `.notifyOthersOnDeactivation` and the host's category returns.
@MainActor
final class FeedbackPreviewAudio {
  private let session: any FeedbackAudioSessioning
  private var saved: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
  private(set) var isActive = false
  private static let logger = Logger(subsystem: "ShakeToShip", category: "review-audio")

  init(session: any FeedbackAudioSessioning = AVAudioSession.sharedInstance()) {
    self.session = session
  }

  func begin() {
    guard !isActive else { return }
    saved = (session.category, session.mode, session.categoryOptions)
    do {
      try session.setCategory(.playback, mode: .moviePlayback, options: [])
      try session.setActive(true, options: [])
      isActive = true
    } catch {
      Self.logger.error("review audio could not start: \(String(describing: error), privacy: .public)")
      restoreCategory()
    }
    #if DEBUG
    if let live = session as? AVAudioSession {
      let outputs = live.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
      print("[ShakeToShip] review audio: saved=\(saved?.0.rawValue ?? "nil") now=\(live.category.rawValue) mode=\(live.mode.rawValue) route=\(outputs)")
    }
    #endif
  }

  func end() {
    guard isActive else { return }
    isActive = false
    do { try session.setActive(false, options: [.notifyOthersOnDeactivation]) } catch {
      Self.logger.notice("review audio deactivation failed: \(String(describing: error), privacy: .public)")
    }
    restoreCategory()
  }

  private func restoreCategory() {
    guard let saved else { return }
    self.saved = nil
    try? session.setCategory(saved.0, mode: saved.1, options: saved.2)
  }
}
#endif
