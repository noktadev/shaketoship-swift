import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import AppFeedbackCapture

@Suite struct CaptureWriterSinkTests {
  /// Wires a real AVAssetWriter with a video input plus whichever audio tracks
  /// this case declares, runs real buffers through the sink, finalizes, and
  /// returns the file for inspection.
  private func record(
    tracks: Set<CaptureAudioTrack>,
    maxDuration: TimeInterval = 300,
    frames: Int = 12
  ) async throws -> URL {
    let url = CaptureSampleFactory.outputURL()
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let video = CaptureSampleFactory.videoInput()
    #expect(writer.canAdd(video))
    writer.add(video)

    var audioInputs: [CaptureAudioTrack: AVAssetWriterInput] = [:]
    for track in CaptureAudioTrack.allCases where tracks.contains(track) {
      let input = CaptureSampleFactory.audioInput()
      #expect(writer.canAdd(input))
      writer.add(input)
      audioInputs[track] = input
    }

    let sink = CaptureWriterSink(
      writer: writer, videoInput: video, audioInputs: audioInputs, maxDuration: maxDuration)

    for index in 0..<frames {
      let videoSample = try #require(
        CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: index)))
      sink.appendVideo(videoSample)
      for track in audioInputs.keys {
        let audioSample = try #require(
          CaptureSampleFactory.audioSample(at: CaptureSampleFactory.audioPTS(bufferIndex: index)))
        sink.appendAudio(audioSample, track: track)
      }
    }

    #expect(sink.quiesce())
    sink.markFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
    return url
  }

  private func trackCounts(_ url: URL) async throws -> (video: Int, audio: Int, seconds: Double) {
    let asset = AVURLAsset(url: url)
    let video = try await asset.loadTracks(withMediaType: .video)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    let duration = try await asset.load(.duration)
    return (video.count, audio.count, CMTimeGetSeconds(duration))
  }

  @Test func writesAVideoOnlyFileWhenNoAudioTrackIsConfigured() async throws {
    let url = try await record(tracks: [])
    defer { try? FileManager.default.removeItem(at: url) }

    let counts = try await trackCounts(url)
    #expect(counts.video == 1)
    #expect(counts.audio == 0)
    #expect(counts.seconds > 0)
  }

  @Test func writesVideoPlusNarration() async throws {
    let url = try await record(tracks: [.narration])
    defer { try? FileManager.default.removeItem(at: url) }

    let counts = try await trackCounts(url)
    #expect(counts.video == 1)
    #expect(counts.audio == 1)
  }

  @Test func writesVideoPlusAppAudio() async throws {
    let url = try await record(tracks: [.appAudio])
    defer { try? FileManager.default.removeItem(at: url) }

    let counts = try await trackCounts(url)
    #expect(counts.video == 1)
    #expect(counts.audio == 1)
  }

  @Test func writesTwoDistinctAudioTracksWithoutMixing() async throws {
    let url = try await record(tracks: [.narration, .appAudio])
    defer { try? FileManager.default.removeItem(at: url) }

    let counts = try await trackCounts(url)
    #expect(counts.video == 1)
    // Two separate AAC tracks in one file - never summed into one. Mixing would
    // mean resampling PCM inside a 50 MB extension process.
    #expect(counts.audio == 2)
  }

  @Test func eachTracksBuffersLandInThatTracksInputNotItsPeer() async throws {
    // A routing bug that ignores the `track:` argument (e.g. always resolving
    // `audioInputs.values.first` instead of `audioInputs[track]`) would still
    // satisfy every count-only assertion elsewhere in this file: it still
    // produces "some" audio. What it cannot fake is which physical input
    // received which call's buffers, so this test gives each track a
    // distinct, known buffer count and checks the two resulting tracks'
    // durations against those counts.
    //
    // A format-description-based check was tried first and rejected: probing
    // this toolchain directly (feed a mono/44100-shaped PCM buffer into an
    // AVAssetWriterInput configured for stereo/22050 AAC output) showed the
    // append succeeds and the finished track reports channels=2, rate=22050
    // - the INPUT's configured outputSettings, not the shape of the data fed
    // to it. Format descriptions can't tell correctly-routed content from a
    // swap, so duration - driven by which physical input actually received
    // how many buffers - is the discriminator used here.
    let url = CaptureSampleFactory.outputURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let video = CaptureSampleFactory.videoInput()
    let narration = CaptureSampleFactory.audioInput()
    let appAudio = CaptureSampleFactory.audioInput()
    writer.add(video)
    writer.add(narration)
    writer.add(appAudio)

    let sink = CaptureWriterSink(
      writer: writer, videoInput: video,
      audioInputs: [.narration: narration, .appAudio: appAudio], maxDuration: 300)

    let narrationBufferCount = 4
    let appAudioBufferCount = 9

    sink.appendVideo(
      try #require(CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: 0))))
    for index in 0..<narrationBufferCount {
      sink.appendAudio(
        try #require(
          CaptureSampleFactory.audioSample(at: CaptureSampleFactory.audioPTS(bufferIndex: index))),
        track: .narration)
    }
    for index in 0..<appAudioBufferCount {
      sink.appendAudio(
        try #require(
          CaptureSampleFactory.audioSample(at: CaptureSampleFactory.audioPTS(bufferIndex: index))),
        track: .appAudio)
    }

    #expect(sink.quiesce())
    sink.markFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)

    let asset = AVURLAsset(url: url)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    // If both track calls funneled into a single physical input, the peer
    // input never receives a buffer and is omitted from the file entirely
    // (see the "never produces a buffer" test below) - collapsing this to 1.
    #expect(audioTracks.count == 2)

    let expectedNarrationSeconds =
      Double(narrationBufferCount * CaptureSampleFactory.audioFramesPerBuffer)
      / CaptureSampleFactory.audioSampleRate
    let expectedAppAudioSeconds =
      Double(appAudioBufferCount * CaptureSampleFactory.audioFramesPerBuffer)
      / CaptureSampleFactory.audioSampleRate

    var observedSeconds: [Double] = []
    for track in audioTracks {
      let range = try await track.load(.timeRange)
      observedSeconds.append(CMTimeGetSeconds(range.duration))
    }
    observedSeconds.sort()
    let expectedSeconds = [expectedNarrationSeconds, expectedAppAudioSeconds].sorted()
    // Guarded rather than indexed directly: the count assertion above already
    // failed the test if routing collapsed the two tracks into one, and
    // indexing a short array here would crash instead of reporting cleanly.
    if observedSeconds.count == expectedSeconds.count {
      for (observed, expected) in zip(observedSeconds, expectedSeconds) {
        #expect(abs(observed - expected) < 0.05)
      }
    }
  }

  @Test func swappedTrackKeysAreCaughtByTheSurvivingTracksConfiguredSampleRate() async throws {
    // `eachTracksBuffersLandInThatTracksInputNotItsPeer` above uses differing
    // buffer COUNTS per track, so it catches a sink that ignores `track:`
    // entirely. It cannot catch a *consistent* key reversal - `.narration`
    // always resolving to the `.appAudio` input and vice versa - because
    // that still produces two distinct, correctly durationed tracks; it just
    // mislabels which physical input is which.
    //
    // The format-description probe documented above (mono/44100-shaped PCM
    // fed into a stereo/22050-configured input still reports 2ch/22050 in
    // the finished track) established that AVAssetWriter's output format
    // description reflects the DESTINATION INPUT's configured
    // `outputSettings`, not the shape of the content fed to it. That is
    // exactly the marker a key reversal cannot fake: configure `.narration`'s
    // input and `.appAudio`'s input at different sample rates, feed buffers
    // to ONLY `.narration`, and whichever input actually received them is
    // named by the surviving track's sample rate.
    //
    // Verified directly against this toolchain outside this test (two mono
    // AAC inputs differing only in AVSampleRateKey - 44100 vs 22050 - one fed
    // with matching PCM and the other left untouched): the fed input's
    // configured rate survives into the file unconditionally, and the unfed
    // peer is omitted from the container entirely, exactly as this test
    // requires.
    let url = CaptureSampleFactory.outputURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let video = CaptureSampleFactory.videoInput()
    let narrationSampleRate = CaptureSampleFactory.audioSampleRate
    let appAudioSampleRate: Double = 22_050
    let narration = CaptureSampleFactory.audioInput(sampleRate: narrationSampleRate)
    let appAudio = CaptureSampleFactory.audioInput(sampleRate: appAudioSampleRate)
    writer.add(video)
    writer.add(narration)
    writer.add(appAudio)

    let sink = CaptureWriterSink(
      writer: writer, videoInput: video,
      audioInputs: [.narration: narration, .appAudio: appAudio], maxDuration: 300)

    sink.appendVideo(
      try #require(CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: 0))))
    // Only `.narration` is ever fed, with PCM shaped to match narration's own
    // configured rate (the factory default). `.appAudio`'s input is
    // configured but deliberately never touched.
    for index in 0..<4 {
      sink.appendAudio(
        try #require(
          CaptureSampleFactory.audioSample(at: CaptureSampleFactory.audioPTS(bufferIndex: index))),
        track: .narration)
    }

    #expect(sink.quiesce())
    sink.markFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)

    let asset = AVURLAsset(url: url)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    // Under correct routing `.appAudio`'s input never receives a buffer and
    // is omitted (see `aTrackThatNeverProducesABufferDoesNotStallTheOthers`
    // for that established toolchain fact), leaving exactly one track. Under
    // a reversed key, `.narration`'s calls land in `.appAudio`'s input
    // instead, and that one survives - the count assertion alone cannot tell
    // the two apart, so it's guarded rather than treated as sufficient here.
    #expect(audioTracks.count == 1)
    guard let track = audioTracks.first else { return }
    let descriptions = try await track.load(.formatDescriptions)
    guard let description = descriptions.first else {
      Issue.record("surviving audio track has no format description to inspect")
      return
    }
    let observedRate = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
      .mSampleRate
    // Under a key reversal this observes appAudioSampleRate (22_050)
    // instead, and the assertion fails.
    #expect(observedRate == narrationSampleRate)
  }

  @Test func aTrackThatNeverProducesABufferDoesNotStallTheOthers() async throws {
    // Mic disabled mid-session, app silent: the narration input is configured
    // but zero buffers ever arrive. The file must still finalize.
    let url = CaptureSampleFactory.outputURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let video = CaptureSampleFactory.videoInput()
    let narration = CaptureSampleFactory.audioInput()
    let appAudio = CaptureSampleFactory.audioInput()
    writer.add(video)
    writer.add(narration)
    writer.add(appAudio)

    let sink = CaptureWriterSink(
      writer: writer, videoInput: video,
      audioInputs: [.narration: narration, .appAudio: appAudio], maxDuration: 300)

    for index in 0..<12 {
      let videoSample = try #require(
        CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: index)))
      sink.appendVideo(videoSample)
      let audioSample = try #require(
        CaptureSampleFactory.audioSample(at: CaptureSampleFactory.audioPTS(bufferIndex: index)))
      sink.appendAudio(audioSample, track: .appAudio)
    }

    #expect(sink.quiesce())
    sink.markFinished()
    await writer.finishWriting()

    #expect(writer.status == .completed)
    let asset = AVURLAsset(url: url)
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    // Verified against a minimal AVAssetWriter repro outside this sink: an
    // AVAssetWriterInput that never receives a sample is omitted from the .mov
    // container entirely, even after markAsFinished() - it does not surface as
    // an empty track. What this test actually guards is that the silent
    // narration input does not stall finalization of the file or the track
    // that DID receive buffers.
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    #expect(audioTracks.count == 1)
  }

  @Test func audioForATrackWithNoConfiguredInputIsDroppedNotBuffered() async throws {
    let url = CaptureSampleFactory.outputURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let video = CaptureSampleFactory.videoInput()
    writer.add(video)
    let sink = CaptureWriterSink(
      writer: writer, videoInput: video, audioInputs: [:], maxDuration: 300)

    sink.appendVideo(
      try #require(CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: 0))))
    sink.appendAudio(
      try #require(CaptureSampleFactory.audioSample(at: .zero)), track: .narration)

    #expect(sink.droppedSampleCount() == 1)

    #expect(sink.quiesce())
    sink.markFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
  }

  @Test func anUnconfiguredTracksFirstBufferDoesNotStartTheWritingSession() async throws {
    // Reproduces the extension failure mode directly: app audio is disabled
    // (only `.narration` is configured), ReplayKit delivers an `.appAudio`
    // buffer anyway, and it happens to be the very first buffer the sink
    // ever sees - before any video or mic buffer arrives. If `admit()` runs
    // before the `audioInputs[track]` lookup, that unmapped buffer still
    // starts the writer's session and latches `started`, so `quiesce()`
    // would wrongly report "something was written" and the caller would
    // finalize a file that has zero real samples in it.
    let url = CaptureSampleFactory.outputURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let video = CaptureSampleFactory.videoInput()
    let narration = CaptureSampleFactory.audioInput()
    writer.add(video)
    writer.add(narration)

    let sink = CaptureWriterSink(
      writer: writer, videoInput: video, audioInputs: [.narration: narration], maxDuration: 300)

    sink.appendAudio(
      try #require(CaptureSampleFactory.audioSample(at: .zero)), track: .appAudio)

    #expect(sink.droppedSampleCount() == 1)
    // The real assertion: nothing was ever actually written, so the caller
    // must cancel + delete rather than finalize.
    #expect(sink.quiesce() == false)
    writer.cancelWriting()
  }

  @Test func aNotReadyInputDropsItsBufferInsteadOfQueueingIt() async throws {
    let url = CaptureSampleFactory.outputURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let video = CaptureSampleFactory.videoInput()
    let narration = CaptureSampleFactory.audioInput()
    writer.add(video)
    writer.add(narration)

    let sink = CaptureWriterSink(
      writer: writer, videoInput: video, audioInputs: [.narration: narration], maxDuration: 300)

    for index in 0..<6 {
      sink.appendVideo(
        try #require(
          CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: index))))
      sink.appendAudio(
        try #require(
          CaptureSampleFactory.audioSample(at: CaptureSampleFactory.audioPTS(bufferIndex: index))),
        track: .narration)
    }
    let droppedBefore = sink.droppedSampleCount()

    // markAsFinished flips a REAL AVAssetWriterInput to not-ready. This is the
    // genuine article, not a stub: appending to it would raise, and queueing it
    // would grow memory the 50 MB extension budget cannot pay for.
    sink.markFinished()
    #expect(narration.isReadyForMoreMediaData == false)

    sink.appendAudio(
      try #require(
        CaptureSampleFactory.audioSample(at: CaptureSampleFactory.audioPTS(bufferIndex: 99))),
      track: .narration)

    #expect(sink.droppedSampleCount() == droppedBefore + 1)

    await writer.finishWriting()
    #expect(writer.status == .completed)
    let asset = AVURLAsset(url: url)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
  }

  @Test func stopsFeedingSamplesOnceTheDurationCapIsReached() async throws {
    let url = CaptureSampleFactory.outputURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let video = CaptureSampleFactory.videoInput()
    writer.add(video)
    let sink = CaptureWriterSink(
      writer: writer, videoInput: video, audioInputs: [:], maxDuration: 1)

    for index in 0..<15 {
      // Wait for the real H.264 encoder's readiness before each append. Firing
      // all 15 frames with zero elapsed wall-clock time (as this synthetic PTS
      // sequence does) saturates VideoToolbox's encode queue well before it
      // would in a real ~33 ms-per-frame capture cadence, producing spurious
      // backpressure drops unrelated to the duration cap this test targets.
      //
      // Skip the wait on the very first frame: the sink calls startWriting()
      // lazily inside admit(), so isReadyForMoreMediaData is false until that
      // first append happens - waiting on it here would just spin the full
      // 1_000-iteration bound for nothing.
      if index > 0 {
        var spins = 0
        while !video.isReadyForMoreMediaData && spins < 1_000 {
          try await Task.sleep(nanoseconds: 1_000_000)
          spins += 1
        }
        // If this bound is ever hit, the wait gave up silently and any
        // subsequent drop/cap assertion would be measuring a stalled encoder,
        // not the duration cap this test exists to verify.
        #expect(spins < 1_000, "readiness wait exhausted its bound before frame \(index)")
      }
      sink.appendVideo(
        try #require(
          CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: index))))
    }
    // 30 fps against a 1 s cap: frame 30 would be the first past it, so feed a
    // frame well beyond the cap to trip it deterministically.
    sink.appendVideo(
      try #require(CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: 90))))

    #expect(sink.hasReachedCap())
    // Capping is not a drop: it is a normal end-of-recording, and the caller
    // maps it to manifest state `.capped`.
    #expect(sink.droppedSampleCount() == 0)

    #expect(sink.quiesce())
    sink.markFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)

    let asset = AVURLAsset(url: url)
    let seconds = CMTimeGetSeconds(try await asset.load(.duration))
    #expect(seconds < 3)
  }

  @Test func quiesceReportsNoWriteWhenNoBufferEverArrived() async throws {
    let url = CaptureSampleFactory.outputURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let video = CaptureSampleFactory.videoInput()
    writer.add(video)
    let sink = CaptureWriterSink(
      writer: writer, videoInput: video, audioInputs: [:], maxDuration: 300)

    // FeedbackRecorder.stop() relies on this to distinguish "empty recording"
    // (cancel + delete) from "finalize the file".
    #expect(sink.quiesce() == false)
    writer.cancelWriting()
  }

  @Test func appendsAfterQuiesceAreIgnored() async throws {
    let url = CaptureSampleFactory.outputURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let video = CaptureSampleFactory.videoInput()
    writer.add(video)
    let sink = CaptureWriterSink(
      writer: writer, videoInput: video, audioInputs: [:], maxDuration: 300)

    sink.appendVideo(
      try #require(CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: 0))))
    #expect(sink.quiesce())
    // A late buffer from ReplayKit's queue must not touch a writer that stop()
    // is already finalizing.
    sink.appendVideo(
      try #require(CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: 1))))

    sink.markFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
    // writer.status alone can't tell "1 frame written" from "2 frames
    // written" - both complete successfully. Measured on this toolchain: a
    // single 30 fps frame yields a track duration of 0.03333333s, two frames
    // 0.06666667s. Asserting under 0.05s is the discriminator that actually
    // proves the post-quiesce append was dropped rather than admitted.
    let asset = AVURLAsset(url: url)
    let seconds = CMTimeGetSeconds(try await asset.load(.duration))
    #expect(seconds < 0.05)
  }
}
