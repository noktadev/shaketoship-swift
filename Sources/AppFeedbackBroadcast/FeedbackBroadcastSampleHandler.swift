import AppFeedbackCapture
import CoreMedia
import Foundation
import ReplayKit

/// Base class for a customer's broadcast upload extension. This is the code
/// that runs inside the extension process.
///
/// The whole integration is six lines:
///
/// ```swift
/// import AppFeedbackBroadcast
///
/// class SampleHandler: FeedbackBroadcastSampleHandler {}
/// ```
///
/// Configuration comes from the extension's own `Info.plist`
/// (`AppFeedbackHostBundleId`, optionally `AppFeedbackCapSeconds`), written by
/// `shaketoship init`, because an extension has no UI and no user to ask.
///
/// Everything of substance is in `BroadcastCaptureSession`; this type is the
/// ReplayKit lifecycle shim over it. The split is deliberate: it keeps the part
/// worth testing free of the process lifecycle, and it gives subclasses one
/// seam (`makeSession`) instead of three.
///
/// ## Memory
///
/// The extension process is killed by Jetsam at 50 MB. Nothing here retains a
/// sample buffer past the call that delivered it, video is downscaled to 720 px
/// on the long edge by the encoder itself, and a buffer whose destination input
/// is not ready is dropped rather than queued. Actual peak footprint is a
/// device measurement (worst on iPad, where ReplayKit's own pool is large
/// before any of this allocates) and is not claimed by the test suite.
open class FeedbackBroadcastSampleHandler: RPBroadcastSampleHandler {
  private let lock = NSLock()
  private var session: BroadcastCaptureSession?

  /// Builds the session this broadcast records into.
  ///
  /// Resolves the App Group container from the host bundle id in the
  /// extension's `Info.plist`. Overridable so a subclass can point the capture
  /// somewhere else; the test suite uses that to substitute a temp directory
  /// for an App Group no test process has.
  ///
  /// - Throws: `BroadcastCaptureSessionError.missingConfiguration` when the
  ///   Info.plist key is absent, `.containerUnavailable` when the App Group is
  ///   not provisioned for this build. Either way the broadcast is failed
  ///   rather than recorded into a container the host app will never read.
  open func makeSession() throws -> BroadcastCaptureSession {
    guard let config = FeedbackBroadcastConfiguration(bundle: .main) else {
      throw BroadcastCaptureSessionError.missingConfiguration
    }
    guard let container = BroadcastContainer.inAppGroup(hostBundleId: config.hostBundleId) else {
      throw BroadcastCaptureSessionError.containerUnavailable
    }
    return BroadcastCaptureSession(container: container, config: config)
  }

  /// Ends the broadcast after a setup failure. Overridable only so the failure
  /// path is observable in tests: `finishBroadcastWithError` tears the process
  /// down, which is not something a test process survives.
  open func failBroadcast(_ error: Error) {
    finishBroadcastWithError(error)
  }

  open override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    do {
      let session = try makeSession()
      // Mints the directory and publishes a `.recording` manifest before any
      // media exists, so a process killed a moment later still leaves the host
      // app's sweep something to classify.
      try session.start()
      lock.lock()
      self.session = session
      lock.unlock()
    } catch {
      failBroadcast(error)
    }
  }

  /// Called on ReplayKit's delivery queue, for every frame and every audio
  /// packet. Routes and returns; it never retains `sampleBuffer`.
  open override func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType
  ) {
    lock.lock()
    let session = self.session
    lock.unlock()
    session?.process(sampleBuffer, with: sampleBufferType)
  }

  /// The system gives this very little time before tearing the process down,
  /// so the finalize is a bounded wait on an already-incremental write - never
  /// deferred encoding work.
  open override func broadcastFinished() {
    lock.lock()
    let session = self.session
    self.session = nil
    lock.unlock()
    session?.finish()
  }
}
