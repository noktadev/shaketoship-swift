import Foundation
import Testing

@testable import ShakeToShip

private actor TranscriptionSignal {
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if released { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    released = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }
}

private final class TranscriptionCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  private var callback: (@Sendable (Result<Int, Error>) -> Void)?
  private var parentCancellation: (@Sendable () -> Void)?
  func record(_ name: String) { lock.withLock { values.append(name) } }
  func count(_ name: String) -> Int { lock.withLock { values.filter { $0 == name }.count } }
  func install(_ completion: @escaping @Sendable (Result<Int, Error>) -> Void) {
    lock.withLock { callback = completion }
  }
  func setParentCancellation(_ cancel: @escaping @Sendable () -> Void) {
    lock.withLock { parentCancellation = cancel }
  }
  func cancelParent() {
    let cancel = lock.withLock { parentCancellation }
    cancel?()
  }
  func finish(_ result: Result<Int, Error>) {
    let completion = lock.withLock { callback }
    completion?(result)
  }
}

private struct CountingTranscriber: FeedbackTranscribing {
  let calls: TranscriptionCalls
  func transcribe(audio url: URL, locale: Locale) async throws -> [FeedbackTranscriptSegment]? {
    calls.record("recognize")
    return []
  }
}

@Suite struct FeedbackTranscriptionCancellationTests {
  @Test(arguments: ["audio export", "speech authorization", "legacy recognition", "video export"])
  func cancellationStopsOwnedCallbackAndIgnoresLateCompletion(stage: String) async {
    let started = TranscriptionSignal()
    let calls = TranscriptionCalls()
    let operation = Task {
      try await FeedbackTranscription.callback { completion in
        calls.install(completion)
        Task { await started.release() }
        return { calls.record(stage) }
      } as Int
    }
    await started.wait()
    operation.cancel()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(calls.count(stage) == 1)
    // Both a canceled framework callback and a late final result must be harmless.
    calls.finish(.failure(CancellationError()))
    calls.finish(.success(7))
    #expect(calls.count(stage) == 1)
  }

  @Test func cancellationBeforeTaskHandleRegistrationCancelsTheLateHandle() async {
    let permit = TranscriptionSignal()
    let calls = TranscriptionCalls()
    let operation = Task {
      await permit.wait()
      return try await FeedbackTranscription.callback { completion in
        calls.install(completion)
        calls.cancelParent()
        return { calls.record("late handle canceled") }
      } as Int
    }
    calls.setParentCancellation { operation.cancel() }
    await permit.release()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(calls.count("late handle canceled") == 1)
    calls.finish(.success(7))
  }

  @Test func aCompletedCallbackIgnoresDuplicateResultsAndCancellation() async throws {
    let calls = TranscriptionCalls()
    let operation = Task {
      try await FeedbackTranscription.callback { completion in
        completion(.success(7))
        completion(.success(8))
        return { calls.record("cancel") }
      } as Int
    }
    #expect(try await operation.value == 7)
    operation.cancel()
    #expect(calls.count("cancel") == 0)
  }

  @Test func cancellationBetweenExportAndRecognitionDoesNotStartRecognition() async {
    let exported = TranscriptionSignal()
    let returnExport = TranscriptionSignal()
    let calls = TranscriptionCalls()
    let operation = Task {
      try await FeedbackTranscription.transcribe(
        source: URL(fileURLWithPath: "/source.mov"), audio: URL(fileURLWithPath: "/audio.m4a"),
        locale: Locale(identifier: "en"), using: CountingTranscriber(calls: calls)
      ) { _, _ in
        await exported.release()
        await returnExport.wait()
        return true
      }
    }
    await exported.wait()
    operation.cancel()
    await returnExport.release()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(calls.count("recognize") == 0)
  }

  @Test func analyzerCancellationNeverEntersLegacyFallback() async {
    let calls = TranscriptionCalls()
    await #expect(throws: CancellationError.self) {
      try await FeedbackTranscription.preferAnalyzer {
        throw CancellationError()
      } recognize: {
        calls.record("legacy")
        return []
      }
    }
    #expect(calls.count("legacy") == 0)
  }

  @Test func cancellationDuringAnalyzerErrorNeverEntersLegacyFallback() async {
    let started = TranscriptionSignal()
    let failed = TranscriptionSignal()
    let calls = TranscriptionCalls()
    let operation = Task {
      try await FeedbackTranscription.preferAnalyzer {
        await started.release()
        await failed.wait()
        throw CocoaError(.featureUnsupported)
      } recognize: {
        calls.record("legacy")
        return []
      }
    }
    await started.wait()
    operation.cancel()
    await failed.release()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(calls.count("legacy") == 0)
  }

  @Test func ordinaryAnalyzerFailureCanUseOnDeviceLegacyRecognition() async throws {
    let calls = TranscriptionCalls()
    let result = try await FeedbackTranscription.preferAnalyzer {
      throw CocoaError(.featureUnsupported)
    } recognize: {
      calls.record("legacy")
      return []
    }
    #expect(result == [])
    #expect(calls.count("legacy") == 1)
  }

  @Test func analyzerCancellationFinishesAnalyzerAndCollectorOnce() async {
    let started = TranscriptionSignal()
    let stopped = TranscriptionSignal()
    let calls = TranscriptionCalls()
    let collector = Task<Int, Error> {
      defer { calls.record("collector finished") }
      await stopped.wait()
      try Task.checkCancellation()
      return 7
    }
    let operation = Task {
      try await FeedbackTranscription.collect(collector: collector) {
        await started.release()
        await stopped.wait()
      } cancelAnalyzer: {
        calls.record("analyzer stopped")
        await stopped.release()
      }
    }
    await started.wait()
    operation.cancel()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(calls.count("analyzer stopped") == 1)
    #expect(calls.count("collector finished") == 1)
  }

  @Test func analyzerFailureFinishesAnalyzerAndCollectorBeforeItReturns() async {
    let stopped = TranscriptionSignal()
    let calls = TranscriptionCalls()
    let collector = Task<Int, Error> {
      defer { calls.record("collector finished") }
      await stopped.wait()
      try Task.checkCancellation()
      return 7
    }
    await #expect(throws: CocoaError.self) {
      try await FeedbackTranscription.collect(collector: collector) {
        throw CocoaError(.fileReadUnknown)
      } cancelAnalyzer: {
        calls.record("analyzer stopped")
        await stopped.release()
      }
    }
    #expect(calls.count("analyzer stopped") == 1)
    #expect(calls.count("collector finished") == 1)
  }

  @Test func analyzerSuccessWaitsForItsFinalCollector() async throws {
    let completed = TranscriptionSignal()
    let calls = TranscriptionCalls()
    let collector = Task<Int, Error> {
      await completed.wait()
      calls.record("collector finished")
      return 7
    }
    let result = try await FeedbackTranscription.collect(collector: collector) {
      calls.record("analyzer finalized")
      await completed.release()
    } cancelAnalyzer: {
      calls.record("analyzer stopped")
    }
    #expect(result == 7)
    #expect(calls.count("analyzer finalized") == 1)
    #expect(calls.count("collector finished") == 1)
    #expect(calls.count("analyzer stopped") == 0)
  }
}
