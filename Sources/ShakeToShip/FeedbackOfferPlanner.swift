import Foundation

/// #472/#491: the pure decision layer for the interrupted-session resend offer.
///
/// The recording-lifecycle work (#472) left the "present vs re-arm vs drop"
/// orchestration inline in the SwiftUI `ShakeRecorderModifier`, explicitly
/// "NOT unit tested" - and three review rounds found race bugs there (#491:
/// dropped overlapping scans; present-vs-sweep delete race). Modeling the
/// decision as a pure function gives those fixes a regression net instead of
/// another review round-trip: future offer-logic edits (coalesced scans,
/// serialized sweep-vs-offer) should land AS planner changes with planner tests.
///
/// Foundation-only on purpose: it decides over `FeedbackPendingInterrupted`
/// (not the UIKit-gated `FeedbackReviewData`) so it compiles and tests on the
/// host, where UIKit - and therefore the modifier - is `#if`-compiled out.
public enum FeedbackOfferDecision: Equatable {
  /// Present the review sheet for this partial (newest of the pending set).
  case present(FeedbackPendingInterrupted)
  /// Nothing can be presented right now (a live capture/prompt/review, or a
  /// stop still finalizing) - keep the offer armed so a later lifecycle tick
  /// retries. Disk stays the durable source of truth; this just guarantees a
  /// retry even if a tick is missed.
  case rearm
  /// Nothing to offer, or the candidate is no longer pending on disk - clear
  /// any armed retry so scanning stops.
  case drop
}

/// Pure orchestrator for the interrupted-session resend offer. Reads the
/// filesystem for the candidate's modification date + on-disk pending state
/// (like `pendingInterruptedSessions`, these are `nonisolated`/`static` and
/// safe off the MainActor), but takes NO view state - the caller passes the
/// live `busy`/presentation/single-flight flags in.
public enum FeedbackOfferPlanner {
  /// Modification date of an interrupted partial's dir; `.distantPast` when the
  /// dir is gone (removed between scan and decision) so `max(by:)` never crashes
  /// on a candidate that vanished mid-flight.
  static func modifiedDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate ?? .distantPast
  }

  /// Is `dir` STILL an offerable interrupted partial right now - the
  /// `.interrupted` marker + `recording.mov` present and not yet `.confirmed`?
  /// Cheap `fileExists` checks used to revalidate immediately before presenting,
  /// so a session uploaded/discarded between the scan and the decision is not
  /// offered.
  static func isStillPendingInterrupted(
    dir: URL, fileManager: FileManager = .default
  ) -> Bool {
    fileManager.fileExists(atPath: dir.appendingPathComponent(feedbackInterruptedMarker).path)
      && fileManager.fileExists(atPath: dir.appendingPathComponent("recording.mov").path)
      && !fileManager.fileExists(atPath: dir.appendingPathComponent(feedbackConfirmedMarker).path)
  }

  /// Decide what to do with a completed off-main scan of the outbox. Mirrors the
  /// branches that were inline in `offerPendingInterrupted`, in the same order:
  /// single-flight → nothing-offerable → busy/no-presentation → disk-miss →
  /// present the newest.
  ///
  /// - Parameters:
  ///   - scanResult: pending interrupted partials from `pendingInterruptedSessions`.
  ///   - busy: a start or stop/finalize/upload is in flight.
  ///   - presentationPossible: no live capture, prompt sheet, or open review is
  ///     blocking a new presentation.
  ///   - scanInFlight: a scan is already running (single-flight); this
  ///     invocation must do nothing.
  ///   - now: reserved for the time-based retention #491 will add to the offer
  ///     decision; unused today (offer logic has no time input yet).
  public static func decide(
    scanResult: [FeedbackPendingInterrupted],
    busy: Bool,
    presentationPossible: Bool,
    scanInFlight: Bool,
    now: Date,
    fileManager: FileManager = .default
  ) -> FeedbackOfferDecision {
    // #472 NEW-2 single-flight: a scan is already running, so this concurrent
    // lifecycle tick must not race to present the same partial twice.
    if scanInFlight { return .drop }
    // Offer the most-recently-modified partial first when more than one waits.
    guard
      let newest = scanResult.max(by: { modifiedDate($0.dir) < modifiedDate($1.dir) })
    else { return .drop }  // nothing offerable
    // A capture/prompt/review began (or a stop is still finalizing) while the
    // scan ran: keep the offer armed and let a later tick retry.
    guard !busy, presentationPossible else { return .rearm }
    // #472 NEW-2: revalidate on-disk state immediately before presenting - the
    // partial may have just been uploaded/discarded, and the scan is a snapshot.
    guard isStillPendingInterrupted(dir: newest.dir, fileManager: fileManager) else {
      return .drop
    }
    return .present(newest)
  }
}
