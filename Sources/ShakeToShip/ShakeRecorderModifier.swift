import Foundation

#if canImport(UIKit)
import SwiftUI
import UIKit

#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

extension View {
  /// Attaches the shake-to-record feedback recorder to a root view.
  ///
  /// Passing `nil` is a provably-inert passthrough: no `ShakeDetector` responder
  /// is in the hierarchy, no `FeedbackReviewWindowPresenter` exists, no recorder
  /// is ever constructed, and the outbox sweep never runs. The per-app resolver
  /// returns a non-nil config only when the feature is gated on - in DEBUG (dev
  /// workflow), or in Release when `remoteFlag && rolloutBucket && settingsOptIn`
  /// - so a non-cohort user installs nothing.
  ///
  /// On the simulator AND Mac Catalyst the whole thing is a compile-time no-op
  /// with a one-time console warning: ReplayKit is non-functional on the
  /// simulator, and Catalyst is only ever the hostless kit test runner
  /// (ActivityKit is unavailable there), never a shipping surface.
  public func shakeToShip(config: ShakeToShipConfig?) -> some View {
    #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    return self.onAppear {
      print("[ShakeToShip] Simulator/Catalyst: feedback recorder disabled (ReplayKit is non-functional).")
    }
    #else
    return Group {
      if FeedbackGate.shouldAttach(config: config), let config {
        AnyView(modifier(ShakeRecorderModifier(config: config)))
      } else {
        AnyView(self)
      }
    }
    #endif
  }
}

#if !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)

/// Root-view modifier: shake while idle → confirm → record; shake while
/// recording → stop → upload. Small red-dot HUD while recording.
///
/// NOT unit tested - device-only ReplayKit + UIKit responder chain. Kept thin;
/// all testable logic lives in `FeedbackTrail` / `FeedbackUploader` and the
/// pure shake-gate decisions in `FeedbackGate` / `FeedbackPromptGate`.
struct ShakeRecorderModifier: ViewModifier {
  let config: ShakeToShipConfig

  @State private var isRecording = false
  @State private var showConfirm = false
  @State private var errorMessage: String?
  /// One logical feedback session; its capture is segmented whenever the app
  /// backgrounds because ReplayKit cannot keep an in-app capture running there.
  @State private var recordingSession: FeedbackRecordingSession?
  @State private var sessionId: String?
  @State private var capTask: Task<Void, Never>?
  @State private var didRetryOutbox = false
  /// Auto-dismissing upload-result toast; nil = hidden. Cancellable dismiss timer.
  @State private var hud: FeedbackHUDState?
  @State private var hudTask: Task<Void, Never>?
  /// "Shake again to stop" hint (#1092), shown the moment a recording starts
  /// and auto-cleared after `FeedbackShakeHintGate.visibleDuration` or the
  /// instant recording stops - see `FeedbackShakeHintGate` for the pure
  /// show/clear decision this state var only tracks the result of.
  @State private var shakeStopHintVisible = false
  @State private var shakeStopHintTask: Task<Void, Never>?
  /// True while a start or a stop/finalize/upload is in flight. Rejects a new
  /// start so a slow upload's epilogue cannot clobber a fresh recording.
  @State private var busy = false
  /// Owns the overlay review window; nil window = no review pending.
  @State private var reviewPresenter = FeedbackReviewWindowPresenter()
  /// Live Activity handle while recording (iOS 16.2+). Stored as `Any?` to avoid
  /// an availability-annotated stored property; cast at use sites.
  @State private var activityBox: Any?
  /// #943: the Live Activity request runs off the MainActor now, so its handle
  /// arrives asynchronously. `liveActivityGeneration` is bumped by every start
  /// AND every end, so a request whose recording (or capture segment) finished
  /// while it was still in flight is recognised as orphaned and ended on
  /// arrival instead of leaking an undismissable banner.
  @State private var liveActivityGeneration = 0
  /// True only while a start request is in flight; keeps the fallback recording
  /// bar from flashing on an island device during that window.
  @State private var liveActivityPending = false
  /// Active capture time excludes background pauses, preserving the configured
  /// ReplayKit duration cap across any number of resumed segments.
  @State private var capturedDuration: TimeInterval = 0
  @State private var captureSegmentStartedAt: TimeInterval?
  /// Monotonic time (systemUptime) of the last prompt dismissal; arms the
  /// 60s cooldown that stops a walking-with-phone nag loop.
  @State private var lastDismissedAt: TimeInterval?
  /// Prompts surfaced this app session; silent past the rate cap until relaunch.
  @State private var promptsShown = 0
  /// How the current prompt was resolved, read in the sheet's onDismiss so a
  /// swipe-to-dismiss is treated the same as "Not now".
  @State private var promptOutcome: PromptOutcome = .pending
  /// Start-race guard (#453): a start awaits ReplayKit before `isRecording`
  /// flips, so a scene deactivation during that window is recorded here and a
  /// start completing afterwards immediately stops.
  @State private var startGuard = FeedbackStartGuard()
  /// Distinguishes a temporary background from the modifier being removed
  /// while ReplayKit start is in flight. Removal must terminate, not resume.
  @State private var terminatePendingStart = false
  /// #472: a finalized interrupted partial could not be presented yet (no scene
  /// / a review already up). Kept armed so `didBecomeActive` retries the offer
  /// until it is presented or the user answers it. Disk is the durable source of
  /// truth; this just guarantees a retry even if a lifecycle tick is missed.
  @State private var pendingInterruptedOffer = false
  /// #472: single-flight guard for the off-main offer scan so concurrent
  /// lifecycle ticks (foreground + didBecomeActive + stop epilogue) cannot each
  /// spawn a scan and race to present the same partial twice.
  @State private var offerScanInFlight = false

  private enum PromptOutcome { case pending, record, dismiss }

  private enum StopReason {
    case user, cap, interruption
    /// Funnel `reason` string per the analytics contract.
    var funnelReason: String {
      switch self {
      case .user: return "user"
      case .cap: return "cap"
      case .interruption: return "interruption"
      }
    }
  }

  /// #474: island-first. An island device relies on the Live Activity as the
  /// SOLE in-app indicator (no bar) - but ONLY while that Live Activity is
  /// actually running. Show the slim top bar whenever the device has no
  /// island OR no Live Activity is live (`activityBox == nil`: the user has
  /// Live Activities disabled, the request failed, the OS predates them, or -
  /// like dotself - the app ships no widget target). That guarantees every
  /// recording has a visible indicator AND a stop affordance (tap to stop),
  /// alongside shake-to-stop and the Live Activity STOP button.
  ///
  /// #943: `liveActivityPending` covers the new window where the request is
  /// still in flight. Without it an island device would show the bar for the
  /// frame or two before the handle lands and then yank it away.
  private var recordingBarVisible: Bool {
    isRecording && (!FeedbackDeviceCapability.current || (activityBox == nil && !liveActivityPending))
  }

  func body(content: Content) -> some View {
    content
      .background(ShakeDetector { handleShake() })
      .overlay(alignment: .top) {
        if recordingBarVisible {
          FeedbackRecordingBar(microphoneAllowed: config.capabilities.contains(.microphone)) {
            Task { await stopRecording(.user) }
          }
          .ignoresSafeArea(edges: .top)
        }
      }
      // Toast sits top-center; the recording bar is only shown on non-island
      // devices and never at the same moment as a post-upload toast.
      .overlay(alignment: .top) {
        if let hud { FeedbackToast(state: hud).padding(.top, 8) }
      }
      // #1092: transient "shake again to stop" hint, near the recording
      // indicator. Non-blocking - no buttons, `allowsHitTesting(false)` so
      // taps always reach the app below - and auto-dismisses on its own
      // timer (`FeedbackShakeHintGate`). Sits lower when the recording bar is
      // showing so it reads as attached to that indicator rather than
      // overlapping it; on island devices (bar hidden, Live Activity is the
      // indicator) it sits just under the status bar instead.
      .overlay(alignment: .top) {
        if isRecording, shakeStopHintVisible {
          FeedbackShakeStopHint()
            .padding(.top, recordingBarVisible ? 56 : 8)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.2), value: shakeStopHintVisible)
        }
      }
      .sheet(isPresented: $showConfirm, onDismiss: resolvePrompt) {
        FeedbackPromptSheet(
          onRecord: {
            promptOutcome = .record
            showConfirm = false
          },
          onDismiss: {
            promptOutcome = .dismiss
            showConfirm = false
          }
        )
        .presentationDetents([.height(240)])
      }
      .alert(
        "Feedback error",
        isPresented: Binding(
          get: { errorMessage != nil },
          set: { if !$0 { errorMessage = nil } })
      ) {
        Button("OK") { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
      .onReceive(
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
      ) { _ in
        // ReplayKit cannot capture while the app is backgrounded. Close only
        // the current MOV segment and keep the logical feedback session open.
        // #453: also record the deactivation so a start still awaiting ReplayKit
        // (isRecording not yet true) aborts the moment it completes.
        startGuard.deactivate()
        if isRecording { Task { await pauseRecording() } }
      }
      // #472: on return, offer to send a recording the background interruption
      // finalized while the app was away ("your recording stopped when you left
      // - send it?"). Guarded so it never interrupts a live capture/review.
      // #453: re-arm the start guard so a legitimate post-foreground start works.
      .onReceive(
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
      ) { _ in
        startGuard.activate()
        if recordingSession != nil {
          Task { await resumeRecording() }
        } else {
          offerPendingInterrupted()
        }
      }
      // #472 finding 4: the finalization of an interruption can land AFTER
      // willEnterForeground fires (the stop path is async), so the marker may not
      // exist yet at that first scan. `didBecomeActive` fires later in the cycle
      // - re-run the offer here so a just-written partial is still surfaced, and
      // re-arm the start guard for good measure.
      .onReceive(
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
      ) { _ in
        startGuard.activate()
        if recordingSession != nil {
          Task { await resumeRecording() }
        } else {
          offerPendingInterrupted()
        }
      }
      // Gate flipped OFF (opt-in toggled, flag refresh) while a capture is live:
      // removing the modifier must not leak a running ReplayKit session. The
      // interruption path finalizes to the outbox without UI and stays
      // unconfirmed, so it is purged once stale, never uploaded.
      .onDisappear {
        terminatePendingStart = true
        startGuard.deactivate()
        if recordingSession != nil { Task { await stopRecording(.interruption) } }
      }
      .onAppear {
        // #453: a fresh appear is an active scene - allow starts.
        terminatePendingStart = false
        startGuard.activate()
        endStaleLiveActivities()
        retryOutboxOnce()
        // Catch a partial finalized while the app was fully suspended: the
        // foreground notification does not fire on cold launch.
        offerPendingInterrupted()
        // Beta-only visible entry point (#584 option C): a non-shake trigger
        // (Settings "Send feedback now") drives the exact same handleShake()
        // path a physical shake does, so cooldown/rate-cap/busy suppression
        // and the confirm-sheet flow are never duplicated.
        FeedbackManualTrigger.register { handleShake() }
      }
      .onDisappear {
        // Gate flipped off / view torn down: unregister so a stale closure
        // cannot fire into a modifier instance that no longer exists.
        FeedbackManualTrigger.unregister()
      }
  }

  private func handleShake() {
    let action = FeedbackPromptGate.action(
      isRecording: isRecording,
      busy: busy,
      reviewPresenting: reviewPresenter.isPresenting,
      promptPresenting: showConfirm,
      promptsShown: promptsShown,
      lastDismissedAt: lastDismissedAt,
      now: ProcessInfo.processInfo.systemUptime)
    switch action {
    case .stopRecording:
      Task { await stopRecording(.user) }
    case .showPrompt:
      promptsShown += 1
      promptOutcome = .pending
      showConfirm = true
      config.onFunnelEvent?(.promptShown)
    case .ignore:
      break
    }
  }

  /// Resolve the prompt once its sheet has dismissed. Runs for every close -
  /// "Record & report", "Not now", or a swipe - so a swipe is treated as a
  /// dismissal (arms the cooldown) and recording starts only on an explicit
  /// "Record & report".
  private func resolvePrompt() {
    switch promptOutcome {
    case .record:
      Task { await startRecording() }
    case .dismiss, .pending:
      lastDismissedAt = ProcessInfo.processInfo.systemUptime
      config.onFunnelEvent?(.promptDismissed)
    }
    promptOutcome = .pending
  }

  private func startRecording() async {
    // Reject double-start (double-tapped "Record" / shake while consent pending)
    // and start while a prior stop is still finalizing.
    guard !busy, !isRecording, recordingSession == nil else { return }
    // #453: reserve this start's generation BEFORE anything else. `begin()`
    // returns nil when the scene is inactive - i.e. this start was queued (e.g.
    // from the prompt sheet's onDismiss) but a backgrounding / onDisappear ran
    // before it did. Refuse it: there is no teardown event left to stop such a
    // capture, so it would record while the app believes it is idle.
    guard let startToken = startGuard.begin() else { return }
    busy = true
    let id = UUID().uuidString
    let dir = outboxRoot().appendingPathComponent(id, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let rec = FeedbackRecorder(
      plan: FeedbackGate.capturePlan(for: config, microphoneMuted: FeedbackMicrophonePreference().isMuted),
      maxDuration: config.maxDuration,
      onInterruption: { Task { @MainActor in await pauseRecording() } })
    let lifecycle = FeedbackRecordingSession(directory: dir, capture: rec)
    do {
      try await lifecycle.start()
      // Timestamp alignment: seed the trail (t=0) only AFTER startCapture's
      // completion fires, as close to first-frame time as practical, so the
      // ReplayKit consent/startup latency is not baked into every event offset.
      let seeded = Feedback.shared.startSession(
        sessionId: id, app: config.app, build: buildNumber(), startedAt: iso8601Now(),
        userRef: FeedbackUserRef.resolve(configured: config.userRef))
      recordingSession = lifecycle
      sessionId = id
      isRecording = true
      capturedDuration = 0
      captureSegmentStartedAt = ProcessInfo.processInfo.systemUptime
      config.onFunnelEvent?(.recordingStarted)
      FeedbackHaptics.impact()
      showShakeStopHint()
      startLiveActivity(startedAt: Date(), screenCount: seeded)
      // Stop from the Live Activity STOP button (intent runs in-process): route
      // to the normal user-stop path. The handler is async so `signal()` (and
      // thus `StopFeedbackIntent.perform()`) awaits the real stop/finalize
      // instead of returning before it completes.
      FeedbackLiveActivityStop.register { await stopRecording(.user) }
      // Tap capture lives exactly as long as the recording: attached here,
      // removed in stopRecording BEFORE the review sheet is presented, so the
      // sheet's own taps are never recorded.
      FeedbackTapCapture.install()
      // Throttled by construction: the trail fires once per new screen event.
      Feedback.shared.setActiveEventHandler { count in
        Task { @MainActor in updateLiveActivity(screenCount: count) }
      }
      armCaptureCap(after: config.maxDuration)
    } catch {
      try? FileManager.default.removeItem(at: dir)
      errorMessage = startFailureMessage(for: error)
    }
    busy = false
    // #453: the scene deactivated while we were awaiting ReplayKit - this start
    // is stale, so tear it down immediately (finalized+unconfirmed like any other
    // interruption). Runs after `busy = false` so stopRecording proceeds cleanly.
    if isRecording, startGuard.shouldAbort(startedEpoch: startToken) {
      if terminatePendingStart {
        await stopRecording(.interruption)
      } else {
        await pauseRecording()
      }
    }
  }

  /// Cleanly closes the current capture segment without ending the feedback
  /// trail or review session. A foreground lifecycle event resumes it.
  private func pauseRecording() async {
    guard !busy, isRecording, let lifecycle = recordingSession, let id = sessionId else { return }
    busy = true
    isRecording = false
    hideShakeStopHint()
    accumulateCaptureDuration()
    capTask?.cancel()
    capTask = nil
    FeedbackTapCapture.remove()
    FeedbackLiveActivityStop.unregister()
    endLiveActivity()

    let dir = outboxRoot().appendingPathComponent(id, isDirectory: true)
    var pauseError: Error?
    await withFeedbackBackgroundTask("afb.pause") {
      do {
        try await lifecycle.pause()
      } catch {
        pauseError = error
        return
      }
      // #669 MUST-FIX 1: persist events.json + the `.interrupted` marker
      // synchronously, under this same background-task assertion, so a
      // background app kill during the pause window still lets the launch
      // sweep discover + offer this partial - the same durability the old
      // hard `stopRecording(.interruption)` path gave a backgrounded session
      // before pause/resume existed.
      let segments = await lifecycle.snapshotSegments()
      let trail = Feedback.shared.snapshot()
      let session = FeedbackSession(
        session_id: trail.session_id, app: trail.app, build: trail.build,
        started_at: trail.started_at, user_ref: trail.user_ref, events: trail.events,
        segments: segments)
      writeFeedbackPauseDurability(in: dir, session: session)
    }
    if pauseError != nil {
      busy = false
      await stopRecording(.interruption)
      return
    }
    busy = false
    // A quick app-switch can foreground before ReplayKit finishes closing the
    // segment. Resume here so neither foreground notification race can strand
    // the logical session in `.paused` (#491-style late completion).
    if UIApplication.shared.applicationState == .active {
      await resumeRecording()
    }
  }

  /// Starts the next ReplayKit segment in the same logical session after the
  /// app returns. Failure falls back to the durable interrupted-session offer.
  private func resumeRecording() async {
    guard !busy, !isRecording, let lifecycle = recordingSession, let id = sessionId else { return }
    guard await lifecycle.state == .paused else { return }
    busy = true
    do {
      try await lifecycle.resume()
      isRecording = true
      // #669 MUST-FIX 1: the session is live again - clear the
      // pause-durability marker so the launch sweep / foreground offer scan
      // stop treating this dir as an interrupted partial while it is still
      // open in-process.
      clearFeedbackPauseDurability(
        in: outboxRoot().appendingPathComponent(id, isDirectory: true))
      captureSegmentStartedAt = ProcessInfo.processInfo.systemUptime
      FeedbackTapCapture.install()
      FeedbackLiveActivityStop.register { await stopRecording(.user) }
      // #669 CHEAP SHOULD-FIX 4: carry the accumulated screen count into the
      // resumed Live Activity instead of resetting the visible counter to 0.
      let screenCount = Feedback.shared.snapshot().events.count(where: { $0.screen != nil })
      startLiveActivity(
        startedAt: Date().addingTimeInterval(-capturedDuration), screenCount: screenCount)
      armCaptureCap(after: max(0, config.maxDuration - capturedDuration))
    } catch {
      busy = false
      await stopRecording(.interruption)
      return
    }
    busy = false
  }

  private func stopRecording(_ reason: StopReason) async {
    guard let lifecycle = recordingSession, let id = sessionId else { return }
    // Capture locals and clear @State BEFORE any await: a recording started
    // during this stop's slow upload must not be clobbered by the epilogue.
    capTask?.cancel()
    capTask = nil
    recordingSession = nil
    sessionId = nil
    if isRecording { accumulateCaptureDuration() }
    isRecording = false
    hideShakeStopHint()
    busy = true

    let duration = capturedDuration
    capturedDuration = 0
    captureSegmentStartedAt = nil
    FeedbackHaptics.impact()
    FeedbackLiveActivityStop.unregister()
    Feedback.shared.setActiveEventHandler(nil)
    FeedbackTapCapture.remove()
    endLiveActivity()

    let dir = outboxRoot().appendingPathComponent(id, isDirectory: true)
    let session = Feedback.shared.stop()
    // Hold a background-task assertion so a backgrounded app still gets ~30s to
    // finish the finalize instead of being suspended mid-write (#341).
    await withFeedbackBackgroundTask("afb.stop") {
      do {
        let segments = try await lifecycle.finalize()
        guard let firstSegment = segments.first else {
          throw FeedbackRecorderError.emptyRecording
        }
        // Only count a genuinely captured session in the funnel: emit AFTER a
        // successful stop, so an emptyRecording / writeFailed throw below (or an
        // interruption) never inflates the "recorded" metric.
        config.onFunnelEvent?(.recordingStopped(durationSeconds: duration, reason: reason.funnelReason))
        let outDir = dir
        let segmentedSession = FeedbackSession(
          session_id: session.session_id,
          app: session.app,
          build: session.build,
          started_at: session.started_at,
          user_ref: session.user_ref,
          events: session.events,
          segments: segments)
        let data = try JSONEncoder().encode(segmentedSession)
        try data.write(to: outDir.appendingPathComponent("events.json"))
        if reason == .interruption {
          // A call/background interruption cannot reliably present UI. Leave the
          // finalized but UNCONFIRMED session in the outbox and tag it
          // `.interrupted` (#472) so the next foreground offers to send it. The
          // launch sweep still never auto-uploads it (no `.confirmed` marker) and
          // preserves it until the offer is accepted or discarded.
          //
          // #472 finding 5: the marker is what makes the finalized partial
          // DISCOVERABLE - if its write fails, the recording would be silently
          // stranded. `writeFeedbackInterruptedMarker` already retries once; on a
          // hard failure, retry durably while we still hold the background-task
          // assertion so a transient disk hiccup does not lose the partial.
          var marked = writeFeedbackInterruptedMarker(in: outDir)
          if !marked {
            for _ in 0..<3 {
              if writeFeedbackInterruptedMarker(in: outDir) { marked = true; break }
              try? await Task.sleep(nanoseconds: 100_000_000)
            }
          }
          // #472 PARTIAL-5: a terminal marker-write failure would silently strand
          // the finalized partial (the offer scan is marker-gated). Surface it on
          // the diagnostic funnel seam instead of swallowing it. Fail safe: keep
          // the finalized dir on disk (never delete here) so a later re-mark or a
          // manual recovery can still find the recording rather than lose it.
          if !marked { config.onFunnelEvent?(.markerFailure(operation: "interrupted-write")) }
        } else {
          // Present the review sheet instead of auto-uploading. Upload/Discard
          // (confirmUpload/discard) own the outbox from here. Presented in a
          // dedicated overlay window - a host app's own covers/sheets suppressed
          // the previous fullScreenCover on dotself (#406). When no scene is
          // available (backgrounded stop), the session stays finalized but
          // UNCONFIRMED in the outbox, exactly like the interruption path above.
          let data = FeedbackReviewData(
            id: id,
            movURL: outDir.appendingPathComponent(firstSegment.file),
            dir: outDir,
            events: session.events)
          _ = reviewPresenter.present(
            data: data,
            onUpload: { Task { await confirmUpload(data) } },
            onDiscard: { discard(data) },
            onOptOut: config.onOptOut)
        }
      } catch FeedbackRecorderError.emptyRecording {
        // Nothing captured (immediate stop / interruption before first frame):
        // discard silently per spec "no partial files" - no alert, no sheet.
        try? FileManager.default.removeItem(at: dir)
      } catch {
        // Writer failed / finalize error: surface alert, discard dir, do NOT
        // enqueue an upload of a corrupt MOV.
        try? FileManager.default.removeItem(at: dir)
        errorMessage = "Recording failed: \(error.localizedDescription)"
      }
    }
    busy = false
    // #472 finding 4: serialize the resend offer with finalization. Now that the
    // interruption's marker is on disk AND `busy` has cleared, offer immediately
    // if the app is already foreground (a quick out-and-back). If it is still
    // backgrounded the presentation is a no-op and the disk marker keeps the
    // partial pending for the next didBecomeActive.
    if reason == .interruption { offerPendingInterrupted() }
  }

  private func accumulateCaptureDuration() {
    guard let started = captureSegmentStartedAt else { return }
    capturedDuration += max(0, ProcessInfo.processInfo.systemUptime - started)
    captureSegmentStartedAt = nil
  }

  private func armCaptureCap(after duration: TimeInterval) {
    capTask?.cancel()
    capTask = Task {
      if duration > 0 {
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      }
      if !Task.isCancelled { await stopRecording(.cap) }
    }
  }

  /// Review-sheet Upload: mark the session user-confirmed, then flush. The
  /// `.confirmed` marker is written BEFORE the flush so a crash/kill mid-upload
  /// still lets the launch sweep retry (the marker gates the sweep).
  ///
  /// If the marker cannot be written (retried once), the upload still runs, but
  /// a failure is then terminal for this launch: the sweep would purge the
  /// unmarked dir once stale, so the toast must NOT promise a retry.
  private func confirmUpload(_ data: FeedbackReviewData) async {
    let config = config
    config.onFunnelEvent?(.reviewUploaded)
    let root = outboxRoot()
    // #472 finding 5: the user chose Upload, so this partial is no longer a
    // pending resend offer. Clear the `.interrupted` marker (no-op for a normal
    // review that never had one) so that even if the `.confirmed` write AND the
    // upload both fail, the next foreground does not ask for consent all over
    // again - the session becomes an ordinary unconfirmed dir, purged when stale.
    let interruptedMarker = data.dir.appendingPathComponent(feedbackInterruptedMarker)
    if FileManager.default.fileExists(atPath: interruptedMarker.path) {
      do {
        try FileManager.default.removeItem(at: interruptedMarker)
      } catch {
        // #472 PARTIAL-5: surface the terminal removal failure on the diagnostic
        // seam rather than swallowing it. Fail safe: leaving `.interrupted` in
        // place only risks a redundant re-offer (never data loss), and the
        // `.confirmed` write below still makes the session flush + drop out of the
        // pending scan on the common path.
        config.onFunnelEvent?(.markerFailure(operation: "interrupted-clear"))
      }
    }
    let confirmed = writeFeedbackConfirmedMarker(in: data.dir)
    await withFeedbackBackgroundTask("afb.upload") {
      let uploader = FeedbackUploader(
        config: config, transport: URLSessionTransport(),
        fileManager: .default, outboxRoot: root)
      let ok = await uploader.flush(sessionId: data.id)
      if ok {
        FeedbackHaptics.success()
        showHUD(.uploaded)
      } else {
        FeedbackHaptics.warning()
        showHUD(confirmed ? .queued : .unqueued)
      }
      config.onFunnelEvent?(.uploadResult(outcome: ok ? "uploaded" : (confirmed ? "queued" : "unqueued")))
    }
    // A second interrupted partial may still be waiting - offer it now that this
    // review has closed, instead of waiting for the next foreground.
    offerPendingInterrupted()
  }

  /// Review-sheet Discard: delete the session dir, no upload. A failed delete
  /// is surfaced (alert) instead of being swallowed behind a success haptic -
  /// the files are still in the outbox and the user should know. The window
  /// teardown happens in the presenter wrapper (a UIKit op outside any SwiftUI
  /// presentation transaction), so `errorMessage` can be set directly here.
  private func discard(_ data: FeedbackReviewData) {
    config.onFunnelEvent?(.reviewDiscarded)
    do {
      try FileManager.default.removeItem(at: data.dir)
      FeedbackHaptics.light()
    } catch {
      errorMessage = "Could not discard recording: \(error.localizedDescription)"
    }
    // Offer the next pending interrupted partial (if any) now this one is gone.
    offerPendingInterrupted()
  }

  /// #472: offer to send a recording the interruption path finalized while the
  /// app was backgrounded. Presents the normal review sheet with an explanatory
  /// note; Upload confirms + flushes, Discard deletes. Guarded so it never
  /// interrupts a live capture, a pending prompt, or an open review.
  private func offerPendingInterrupted() {
    // Fast MainActor pre-check: never interrupt a live capture, a pending
    // prompt, or an open review. (Re-checked via the planner after the off-main
    // scan below, since state can change across the await.)
    guard recordingSession == nil, !isRecording, !busy, !showConfirm,
      !reviewPresenter.isPresenting
    else { return }
    // #472 NEW-2: single-flight. Concurrent lifecycle ticks (foreground +
    // didBecomeActive + a stop/review epilogue) must not each spawn a scan and
    // race to present the same partial twice.
    guard !offerScanInFlight else { return }
    offerScanInFlight = true
    let root = outboxRoot()
    // #472 finding 7: the scan enumerates the outbox and stats each dir -
    // blocking filesystem work that must NOT run on the MainActor from a SwiftUI
    // lifecycle callback. Do it on a detached utility task, then hop back and let
    // `FeedbackOfferPlanner` decide present vs re-arm vs drop.
    Task { @MainActor in
      defer { offerScanInFlight = false }
      let scan = await Task.detached(priority: .utility) {
        pendingInterruptedSessions(root: root)
      }.value
      switch FeedbackOfferPlanner.decide(
        scanResult: scan,
        busy: busy,
        presentationPossible: recordingSession == nil && !isRecording && !showConfirm
          && !reviewPresenter.isPresenting,
        scanInFlight: false,  // this task IS the in-flight scan; guarded above.
        now: Date())
      {
      case .drop:
        // Nothing pending, or the candidate is no longer pending on disk: clear
        // any armed retry so we stop re-scanning.
        pendingInterruptedOffer = false
      case .rearm:
        // A capture/prompt/review began while the scan ran: keep armed, retry
        // on a later tick.
        pendingInterruptedOffer = true
      case .present(let pending):
        let offer = Self.reviewData(for: pending)
        // #472 PARTIAL-4: `present` returns false when no scene is available
        // (still backgrounded). Keep the offer armed so the next didBecomeActive
        // retries; clear it only once the sheet is actually on screen (the user
        // now owns the Upload/Discard decision).
        let presented = reviewPresenter.present(
          data: offer,
          onUpload: { Task { await confirmUpload(offer) } },
          onDiscard: { discard(offer) },
          onOptOut: config.onOptOut)
        pendingInterruptedOffer = !presented
      }
    }
  }

  /// Builds the review data for a pending interrupted partial the planner chose
  /// to present: loads + decodes its `events.json` and tags the explanatory note.
  private static func reviewData(for pending: FeedbackPendingInterrupted) -> FeedbackReviewData {
    let eventsURL = pending.dir.appendingPathComponent("events.json")
    let events =
      (try? JSONDecoder().decode(FeedbackSession.self, from: Data(contentsOf: eventsURL)))?
      .events ?? []
    return FeedbackReviewData(
      id: pending.sessionId,
      movURL: pending.dir.appendingPathComponent("recording.mov"),
      dir: pending.dir,
      events: events,
      note: "Your recording stopped when you left the app. Send it?")
  }

  /// Fixed user-facing copy for a start failure - never surfaces a raw ReplayKit
  /// or localized error string (#472 finding 6).
  private func startFailureMessage(for error: Error) -> String {
    if let error = error as? FeedbackRecorderError {
      switch error {
      case .recorderBusy, .resetFailed:
        return "Screen recording is busy right now. Close anything else recording your screen, then try again."
      case .unavailableOnSimulator, .captureNotPermitted:
        // .captureNotPermitted is fixed copy, never the raw error - and a
        // later chunk hides the Record affordance entirely when the
        // capability is absent, so this path should not be reachable in
        // practice.
        return "Screen recording isn't available here."
      case .setupFailed, .alreadyRecording, .notRecording, .emptyRecording, .writeFailed:
        return "Couldn't start recording. Please try again."
      }
    }
    return "Couldn't start recording. Please try again."
  }

  /// Requests the Live Activity without blocking the start path (#943). Fire and
  /// forget: the recording is already live, and the banner is an indicator, not
  /// a precondition. The generation token makes the late arrival safe - if the
  /// recording stopped or the segment was replaced while the request was in
  /// flight, the activity that lands is nobody's and is ended immediately.
  private func startLiveActivity(startedAt: Date, screenCount: Int) {
    #if os(iOS)
    if #available(iOS 16.2, *) {
      liveActivityGeneration &+= 1
      let token = liveActivityGeneration
      liveActivityPending = true
      Task { @MainActor in
        let activity = await FeedbackLiveActivityController.start(
          startedAt: startedAt, screenCount: screenCount,
          // #557: a missing banner is now reported instead of silently swallowed,
          // so the next "not visible for me" report names its own cause.
          onFailure: { config.onFunnelEvent?(.liveActivityStartFailed(reason: $0.rawValue)) })
        guard liveActivityGeneration == token else {
          // A newer start, or an end, superseded this request. Never publish it:
          // `endLiveActivity` has already run, so storing the handle would strand
          // a banner whose STOP button routes into a finished recording.
          if let activity { FeedbackLiveActivityController.end(activity) }
          return
        }
        liveActivityPending = false
        activityBox = activity
      }
    }
    #endif
  }

  private func updateLiveActivity(screenCount: Int) {
    #if os(iOS)
    if #available(iOS 16.2, *),
      let activity = activityBox as? Activity<FeedbackRecordingAttributes> {
      FeedbackLiveActivityController.update(activity, screenCount: screenCount)
    }
    #endif
  }

  private func endLiveActivity() {
    #if os(iOS)
    if #available(iOS 16.2, *),
      let activity = activityBox as? Activity<FeedbackRecordingAttributes> {
      FeedbackLiveActivityController.end(activity)
    }
    #endif
    // #943: invalidate any request still in flight, so the handle it eventually
    // returns is ended on arrival rather than published into a stopped
    // recording. Clearing `pending` here also lets the fallback bar appear for
    // whatever remains of a capture whose banner never materialised.
    liveActivityGeneration &+= 1
    liveActivityPending = false
    activityBox = nil
  }

  /// A crash mid-recording strands its Live Activity: the system keeps the
  /// banner (timer still counting) but the STOP intent handler died with the
  /// process, so it is undismissable. Sweep on appear - guarded so it cannot
  /// touch a recording this process owns.
  private func endStaleLiveActivities() {
    #if os(iOS)
    guard recordingSession == nil, !isRecording, activityBox == nil else { return }
    if #available(iOS 16.2, *) {
      FeedbackLiveActivityController.endStale()
    }
    #endif
  }

  private func retryOutboxOnce() {
    guard !didRetryOutbox else { return }
    didRetryOutbox = true
    let config = config
    Task {
      await withFeedbackBackgroundTask("afb.retry") {
        let uploader = FeedbackUploader(
          config: config, transport: URLSessionTransport(),
          fileManager: .default, outboxRoot: outboxRoot())
        let result = await uploader.retryOutbox()
        // Only surface a toast when the launch sweep actually moved something.
        // Queued wins over flushed: "uploaded" must never mask retained files.
        // Same haptics as the stop-flush path: warning for queued, success for
        // uploaded.
        if result.queued > 0 {
          FeedbackHaptics.warning()
          showHUD(.queued)
        } else if result.flushed > 0 {
          FeedbackHaptics.success()
          showHUD(.uploaded)
        }
      }
    }
  }

  /// Shows the result toast and (re)arms a 2.5s auto-dismiss.
  private func showHUD(_ state: FeedbackHUDState) {
    hud = state
    hudTask?.cancel()
    hudTask = Task {
      try? await Task.sleep(nanoseconds: 2_500_000_000)
      if !Task.isCancelled { hud = nil }
    }
  }

  /// Shows the "shake again to stop" hint (#1092) and arms its auto-dismiss.
  /// Called right after a start succeeds; `hideShakeStopHint` (called from
  /// every stop/pause path) always wins if it races the timer, matching
  /// `FeedbackShakeHintGate`'s "stop always clears" rule.
  private func showShakeStopHint() {
    shakeStopHintVisible = FeedbackShakeHintGate.reduce(
      isVisible: shakeStopHintVisible, event: .recordingStarted)
    shakeStopHintTask?.cancel()
    shakeStopHintTask = Task {
      let nanoseconds = UInt64(FeedbackShakeHintGate.visibleDuration * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      if !Task.isCancelled {
        shakeStopHintVisible = FeedbackShakeHintGate.reduce(
          isVisible: shakeStopHintVisible, event: .timerElapsed)
      }
    }
  }

  /// Clears the "shake again to stop" hint immediately - called from every
  /// path where recording stops (user/cap/interruption stop, or a pause),
  /// so the hint never outlives an active capture.
  private func hideShakeStopHint() {
    shakeStopHintTask?.cancel()
    shakeStopHintTask = nil
    shakeStopHintVisible = FeedbackShakeHintGate.reduce(
      isVisible: shakeStopHintVisible, event: .recordingStopped)
  }

  /// Runs `work` while holding a UIKit background-task assertion so a
  /// backgrounded app is granted ~30s to finish instead of being suspended
  /// mid-upload. The expiration handler captures only the task-id var + app
  /// local (never actor/view `self`) per the Swift 6 isolation rule (86f71c7b),
  /// and the assertion is ended in every exit path.
  @MainActor
  private func withFeedbackBackgroundTask(
    _ name: String, _ work: () async -> Void
  ) async {
    let app = UIApplication.shared
    var taskId: UIBackgroundTaskIdentifier = .invalid
    taskId = app.beginBackgroundTask(withName: name) {
      if taskId != .invalid {
        app.endBackgroundTask(taskId)
        taskId = .invalid
      }
    }
    await work()
    if taskId != .invalid {
      app.endBackgroundTask(taskId)
      taskId = .invalid
    }
  }

  private func outboxRoot() -> URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return docs.appendingPathComponent("feedback-outbox", isDirectory: true)
  }

  private func buildNumber() -> String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
  }

  private func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}

/// The lightweight "Something wrong?" prompt (replaces the old
/// confirmationDialog). Compact, one-tap dismissable, and it educates the user
/// that shake/tap stops the recording. Copy lives in the package with sensible
/// defaults - `ShakeToShipConfig` is deliberately not extended per-app for v1.
private struct FeedbackPromptSheet: View {
  let onRecord: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      VStack(spacing: 6) {
        Text("Something wrong?")
          .font(.headline)
        Text(FeedbackRecordingCopy.promptExplanation)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      VStack(spacing: 10) {
        Button(action: onRecord) {
          Text("Record & report").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        Button("Not now", action: onDismiss)
          .buttonStyle(.bordered)
      }
      Text("Turn off any time in Settings.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(24)
    .presentationDragIndicator(.visible)
  }
}

/// Upload-result toast states.
private enum FeedbackHUDState {
  case uploaded  // reached R2
  case queued    // retained for next-launch retry (marker on disk)
  case unqueued  // upload failed AND the confirm marker could not be written:
                 // the launch sweep will not retry this session

  var symbol: String {
    switch self {
    case .uploaded: return "checkmark.circle.fill"
    case .queued: return "arrow.clockwise"
    case .unqueued: return "exclamationmark.triangle.fill"
    }
  }

  var text: String {
    switch self {
    case .uploaded: return "Feedback uploaded"
    case .queued: return "Upload queued - retries next launch"
    case .unqueued: return "Could not queue - keep app open"
    }
  }

  var tint: Color {
    switch self {
    case .uploaded: return .green
    case .queued: return .orange
    case .unqueued: return .red
    }
  }
}

/// Small auto-dismissing pill shown near the top after an upload attempt.
private struct FeedbackToast: View {
  let state: FeedbackHUDState

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: state.symbol)
        .foregroundStyle(state.tint)
      Text(state.text)
        .font(.footnote.weight(.medium))
        .foregroundStyle(.primary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.ultraThinMaterial, in: Capsule())
    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    .transition(.move(edge: .top).combined(with: .opacity))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(state.text)
  }
}

/// Invisible UIKit responder that reports device shakes into SwiftUI.
private struct ShakeDetector: UIViewControllerRepresentable {
  let onShake: () -> Void

  func makeUIViewController(context: Context) -> ShakeViewController {
    let vc = ShakeViewController()
    vc.onShake = onShake
    return vc
  }

  func updateUIViewController(_ vc: ShakeViewController, context: Context) {
    vc.onShake = onShake
  }
}

final class ShakeViewController: UIViewController {
  var onShake: (() -> Void)?

  override var canBecomeFirstResponder: Bool { true }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    becomeFirstResponder()
  }

  override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
    if motion == .motionShake { onShake?() }
    super.motionEnded(motion, with: event)
  }
}

#endif  // !simulator && !macCatalyst
#endif  // canImport(UIKit)
