import CoreMedia
import Foundation
import ReplayKit
import Testing

@testable import AppFeedbackBroadcast
@testable import AppFeedbackCapture

/// `capture-core` shipped a two-arm routing switch whose arms could be swapped
/// with every gate still green (follow-up #839). This chunk's switch has three
/// arms, so it is strictly easier to get wrong.
///
/// This suite pins the mapping as a table. It is the cheap half of the
/// guarantee: it fails immediately and legibly on any swap, but on its own it
/// only proves a function returns the right value.
/// `BroadcastCaptureSessionTests.eachReplayKitBufferTypeLandsInItsOwnTrackNotItsPeer`
/// is the other half - it proves this same mapping is the one actually wired to
/// the writer, by reading which physical track received which buffers out of a
/// finished file.
@Suite struct BroadcastSampleRouteTests {
  @Test func mapsVideoToTheVideoInput() {
    #expect(BroadcastSampleRoute(bufferType: .video) == .video)
  }

  @Test func mapsMicToNarrationBecauseTheMicIsThePersonTalking() {
    #expect(BroadcastSampleRoute(bufferType: .audioMic) == .audio(.narration))
  }

  @Test func mapsAppAudioToTheAppAudioTrackAndNeverMixesItIntoNarration() {
    // App audio is its own track in v1 - a settled owner decision. If this ever
    // maps to `.narration`, the two streams are being summed into one input and
    // the transcript stops being the reviewer's commentary.
    #expect(BroadcastSampleRoute(bufferType: .audioApp) == .audio(.appAudio))
  }

  @Test func everyBufferTypeGetsADistinctDestination() {
    // A swap between two arms keeps the destinations distinct, so this alone
    // cannot catch one - what it catches is the other failure mode: two arms
    // collapsed onto the same destination (e.g. both audio types routed to
    // `.narration`, which would silently mix them).
    let routes = [
      BroadcastSampleRoute(bufferType: .video),
      BroadcastSampleRoute(bufferType: .audioMic),
      BroadcastSampleRoute(bufferType: .audioApp),
    ]
    #expect(routes.allSatisfy { $0 != nil })
    for (index, route) in routes.enumerated() {
      for other in routes[(index + 1)...] {
        #expect(route != other)
      }
    }
  }

  @Test func anUnknownBufferTypeIsDroppedRatherThanGuessedAt() {
    // ReplayKit's enum is an NS_ENUM: a future OS can deliver a raw value this
    // build has never heard of. Dropping keeps the file valid; guessing a
    // destination would put unknown media into a named track.
    let future = RPSampleBufferType(rawValue: 99)
    #expect(future == nil || BroadcastSampleRoute(bufferType: future!) == nil)
  }
}
