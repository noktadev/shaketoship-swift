@preconcurrency import AVFoundation
import Foundation

#if canImport(Speech)
  @preconcurrency import Speech
#endif

/// One spoken phrase in recording time (seconds from the start of the review source).
struct FeedbackTranscriptSegment: Equatable, Sendable, Identifiable {
  let id: Int
  let text: String
  let start: Double
  let end: Double
}

/// Pure transcript rules: trim filtering, phrase grouping, and the note block.
enum FeedbackTranscript {
  static let openMarker = "--- On-device transcript ---"
  static let closeMarker = "--- End of transcript ---"

  /// Keep complete phrases inside the trim window; boundary phrases may contain removed speech.
  static func visible(_ segments: [FeedbackTranscriptSegment], in range: FeedbackTrimRange)
    -> [FeedbackTranscriptSegment]
  {
    segments.filter {
      $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start
        && $0.start >= range.start && $0.end <= range.end
    }
  }

  static func text(_ segments: [FeedbackTranscriptSegment]) -> String {
    segments.map(\.text).joined(separator: " ")
  }

  /// The segment under the playhead, if any.
  static func current(_ segments: [FeedbackTranscriptSegment], at time: Double)
    -> FeedbackTranscriptSegment?
  {
    segments.first { time >= $0.start && time < $0.end }
  }

  /// The ingest contract has no transcript field, so the transcript rides in the
  /// note inside a marked block. The server wire format is unchanged.
  static func note(_ note: String, transcript: String?) -> String {
    let spoken = (transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !spoken.isEmpty else { return note }
    let written = note.trimmingCharacters(in: .whitespacesAndNewlines)
    let block = openMarker + "\n" + spoken + "\n" + closeMarker
    return written.isEmpty ? block : written + "\n\n" + block
  }

  /// Groups timed words into phrases: a pause, sentence punctuation, or twelve words ends one.
  static func phrases(_ words: [(text: String, start: Double, end: Double)])
    -> [FeedbackTranscriptSegment]
  {
    var result: [FeedbackTranscriptSegment] = []
    var current: [(text: String, start: Double, end: Double)] = []
    func flush() {
      guard let first = current.first, let last = current.last else { return }
      result.append(
        .init(
          id: result.count, text: current.map(\.text).joined(separator: " "),
          start: first.start, end: last.end))
      current = []
    }
    for word in words where !word.text.trimmingCharacters(in: .whitespaces).isEmpty {
      if let last = current.last, word.start - last.end > 0.7 { flush() }
      current.append(word)
      if current.count >= 12 || word.text.hasSuffix(".") || word.text.hasSuffix("?")
        || word.text.hasSuffix("!")
      {
        flush()
      }
    }
    flush()
    return result
  }
}

/// Transcribes narration ON DEVICE. Returns nil when on-device recognition is not
/// available for the locale; there is no server fallback.
protocol FeedbackTranscribing: Sendable {
  func transcribe(audio url: URL, locale: Locale) async throws -> [FeedbackTranscriptSegment]?
}

enum FeedbackTranscription {
  /// The Harness replaces this with a fixture; production uses the on-device transcriber.
  @MainActor static var transcriber: any FeedbackTranscribing = FeedbackOnDeviceTranscriber()

  static func transcribe(
    source: URL, audio: URL, locale: Locale,
    using transcriber: any FeedbackTranscribing,
    extract: @Sendable (URL, URL) async throws -> Bool = {
      try await extractAudio(from: $0, to: $1)
    }
  ) async throws -> [FeedbackTranscriptSegment]? {
    try Task.checkCancellation()
    guard try await extract(source, audio) else { return nil }
    try Task.checkCancellation()
    let segments = try await transcriber.transcribe(audio: audio, locale: locale)
    try Task.checkCancellation()
    return segments
  }

  /// Cancellation never requests a second recognizer or a permission prompt.
  static func preferAnalyzer(
    analyze: @Sendable () async throws -> [FeedbackTranscriptSegment]?,
    recognize: @Sendable () async throws -> [FeedbackTranscriptSegment]?
  ) async throws -> [FeedbackTranscriptSegment]? {
    try Task.checkCancellation()
    do {
      if let segments = try await analyze() {
        try Task.checkCancellation()
        return segments
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
    }
    try Task.checkCancellation()
    let segments = try await recognize()
    try Task.checkCancellation()
    return segments
  }

  /// The worker finishes the analyzer on success. Errors and cancellation finish
  /// it through one cleanup task, then wait for the canceled collector to finish.
  static func collect<Value: Sendable>(
    collector: Task<Value, Error>,
    analyze: @Sendable () async throws -> Void,
    cancelAnalyzer: @escaping @Sendable () async -> Void
  ) async throws -> Value {
    let cleanup = FeedbackSpeechCleanup {
      collector.cancel()
      await cancelAnalyzer()
    }
    return try await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        try await analyze()
        try Task.checkCancellation()
        let value = try await collector.value
        try Task.checkCancellation()
        return value
      } catch {
        await cleanup.run().value
        _ = await collector.result
        throw error
      }
    } onCancel: {
      _ = cleanup.run()
    }
  }

  /// Bridges callback APIs with an owned cancellation action and one result.
  static func callback<Value: Sendable>(
    start:
      @escaping @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> (
        @Sendable () -> Void
      )
  ) async throws -> Value {
    let waiter = FeedbackSpeechWaiter<Value>()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        guard waiter.install(continuation) else { return }
        let cancel = start { waiter.finish($0) }
        waiter.setCancellation(cancel)
      }
    } onCancel: {
      waiter.cancel()
    }
  }

  /// Writes the source's audio to an M4A file. Cancellation stops the exporter.
  static func extractAudio(from source: URL, to destination: URL) async throws -> Bool {
    try Task.checkCancellation()
    let asset = AVURLAsset(url: source)
    guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { return false }
    try Task.checkCancellation()
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
    else { return false }
    try? FileManager.default.removeItem(at: destination)
    exporter.outputURL = destination
    exporter.outputFileType = .m4a
    try await FeedbackMediaExport.run(exporter)
    return true
  }
}

/// Both transcription audio and selected video exports use the same cancellation bridge.
enum FeedbackMediaExport {
  static func run(_ exporter: AVAssetExportSession) async throws {
    let _: Void = try await FeedbackTranscription.callback { completion in
      exporter.exportAsynchronously {
        if exporter.status == .completed {
          completion(.success(()))
        } else {
          completion(.failure(exporter.error ?? FeedbackVideoRecoveryError.invalidMedia))
        }
      }
      return { exporter.cancelExport() }
    }
    try Task.checkCancellation()
  }
}

/// A cancellation may arrive before a callback supplies its task handle.
/// Locking protects that race; API cancellation and continuations run outside the lock.
private final class FeedbackSpeechWaiter<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var result: Result<Value, Error>?
  private var cancellation: (@Sendable () -> Void)?
  private var canceled = false

  func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
    lock.lock()
    if let result {
      lock.unlock()
      continuation.resume(with: result)
      return false
    }
    self.continuation = continuation
    lock.unlock()
    return true
  }

  func setCancellation(_ action: @escaping @Sendable () -> Void) {
    lock.lock()
    let cancelNow = canceled
    if result == nil { cancellation = action }
    lock.unlock()
    if cancelNow { action() }
  }

  func finish(_ result: Result<Value, Error>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    let continuation = continuation
    self.continuation = nil
    cancellation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }

  func cancel() {
    lock.lock()
    guard result == nil else {
      lock.unlock()
      return
    }
    canceled = true
    let failure: Result<Value, Error> = .failure(CancellationError())
    result = failure
    let continuation = continuation
    self.continuation = nil
    let cancellation = cancellation
    self.cancellation = nil
    lock.unlock()
    cancellation?()
    continuation?.resume(with: failure)
  }
}

private final class FeedbackSpeechCleanup: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?
  private let action: @Sendable () async -> Void
  init(_ action: @escaping @Sendable () async -> Void) { self.action = action }
  func run() -> Task<Void, Never> {
    lock.lock()
    defer { lock.unlock() }
    if let task { return task }
    let task = Task { await action() }
    self.task = task
    return task
  }
}

#if canImport(Speech) && os(iOS)
  struct FeedbackOnDeviceTranscriber: FeedbackTranscribing {
    func transcribe(audio url: URL, locale: Locale) async throws -> [FeedbackTranscriptSegment]? {
      try await FeedbackTranscription.preferAnalyzer {
        if #available(iOS 26.0, *) { return try await analyze(url, locale: locale) }
        return nil
      } recognize: {
        try await recognize(url, locale: locale)
      }
    }

    @available(iOS 26.0, *)
    private func analyze(_ url: URL, locale: Locale) async throws -> [FeedbackTranscriptSegment]? {
      try Task.checkCancellation()
      guard SpeechTranscriber.isAvailable,
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
      else { return nil }
      try Task.checkCancellation()
      let transcriber = SpeechTranscriber(
        locale: supported, transcriptionOptions: [],
        reportingOptions: [], attributeOptions: [.audioTimeRange])
      switch await AssetInventory.status(forModules: [transcriber]) {
      case .installed: break
      case .unsupported: return nil
      default:
        // Downloads the on-device model only. No audio leaves the device.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]
        ) {
          try Task.checkCancellation()
          try await request.downloadAndInstall()
        }
      }
      try Task.checkCancellation()
      let analyzer = SpeechAnalyzer(modules: [transcriber])
      let collector = Task {
        var phrases: [FeedbackTranscriptSegment] = []
        for try await result in transcriber.results where result.isFinal {
          try Task.checkCancellation()
          let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty else { continue }
          phrases.append(
            .init(
              id: phrases.count, text: text,
              start: result.range.start.seconds, end: result.range.end.seconds))
        }
        return phrases
      }
      return try await FeedbackTranscription.collect(collector: collector) {
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
          try Task.checkCancellation()
          try await analyzer.finalizeAndFinish(through: last)
        } else {
          await analyzer.cancelAndFinishNow()
        }
      } cancelAnalyzer: {
        await analyzer.cancelAndFinishNow()
      }
    }

    private func recognize(_ url: URL, locale: Locale) async throws -> [FeedbackTranscriptSegment]?
    {
      try Task.checkCancellation()
      // Requesting authorization without the usage string terminates the app.
      guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
      else { return nil }
      let status: SFSpeechRecognizerAuthorizationStatus = try await FeedbackTranscription.callback {
        completion in
        SFSpeechRecognizer.requestAuthorization { completion(.success($0)) }
        // iOS owns the system permission prompt. Cancellation prevents recognition.
        return {}
      }
      try Task.checkCancellation()
      guard status == .authorized, let recognizer = SFSpeechRecognizer(locale: locale),
        recognizer.supportsOnDeviceRecognition
      else { return nil }
      let request = SFSpeechURLRecognitionRequest(url: url)
      request.requiresOnDeviceRecognition = true
      request.shouldReportPartialResults = false
      request.addsPunctuation = true
      let words: [(text: String, start: Double, end: Double)] =
        try await FeedbackTranscription.callback { completion in
          let task = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
              let words = result.bestTranscription.segments.map {
                (text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
              }
              completion(.success(words))
            } else if let error {
              completion(.failure(error))
            }
          }
          return { task.cancel() }
        }
      try Task.checkCancellation()
      return FeedbackTranscript.phrases(words)
    }
  }
#else
  struct FeedbackOnDeviceTranscriber: FeedbackTranscribing {
    func transcribe(audio url: URL, locale: Locale) async throws -> [FeedbackTranscriptSegment]? {
      nil
    }
  }
#endif
