#if os(iOS)
  import CoreMedia
  import Foundation
  import ObjectiveC
  import ReplayKit

  /// Capture handler with the nullability ReplayKit actually uses.
  ///
  /// `RPScreenRecorder.h` declares the handler as
  ///
  ///     - (void)startCaptureWithHandler:
  ///         (nullable void (^)(CMSampleBufferRef sampleBuffer,
  ///                            RPSampleBufferType bufferType,
  ///                            NSError *_Nullable error))captureHandler
  ///
  /// `sampleBuffer` carries NO nullability annotation, and the declaration sits
  /// inside the header's `NS_ASSUME_NONNULL_BEGIN` region. The Swift importer
  /// therefore types it non-optional `CMSampleBuffer`, while the framework does
  /// pass NULL when it cannot produce a frame - notably alongside a non-nil
  /// `error`. Bridging that NULL into a non-optional makes the thunk release a
  /// NULL pointer, which aborts the process:
  ///
  ///     EXC_BREAKPOINT: *** CFRelease() called with NULL ***
  ///     CFRelease.cold.2
  ///     __56-[RPScreenRecorder captureHandlerWithSample:timingData:]_block_invoke
  ///
  /// The abort happens in the bridging thunk, BEFORE any Swift handler body
  /// runs, so an `error != nil` guard inside the handler cannot prevent it.
  typealias FeedbackCaptureBlock = @Sendable @convention(block) (CMSampleBuffer?, RPSampleBufferType, Error?) ->
    Void

  typealias FeedbackCaptureCompletionBlock = @Sendable @convention(block) (Error?) -> Void

  /// Calls `-startCaptureWithHandler:completionHandler:` with an honestly typed
  /// handler, so a NULL sample buffer arrives as `nil` instead of aborting.
  enum FeedbackReplayKitStart {
    private typealias StartCaptureIMP = @convention(c) (
      AnyObject, Selector, FeedbackCaptureBlock?, FeedbackCaptureCompletionBlock?
    ) -> Void

    static func startCapture(
      on recorder: RPScreenRecorder,
      handler: @escaping FeedbackCaptureBlock,
      completion: @escaping FeedbackCaptureCompletionBlock
    ) {
      let selector = NSSelectorFromString("startCaptureWithHandler:completionHandler:")

      // `method(for:)` resolves against the receiver's real class, so this is
      // the same implementation normal message dispatch would reach. Only the
      // declared block types differ - which is the entire point.
      guard recorder.responds(to: selector), let imp = recorder.method(for: selector) else {
        // The selector is public API since iOS 11 and cannot realistically be
        // missing. If it ever is, fall back to the imported API rather than
        // silently refusing to record.
        recorder.startCapture(
          handler: { @Sendable sample, bufferType, error in handler(sample, bufferType, error) },
          completionHandler: { error in completion(error) })
        return
      }

      let call = unsafeBitCast(imp, to: StartCaptureIMP.self)
      call(recorder, selector, handler, completion)
    }
  }
#endif
