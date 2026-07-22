import Foundation
import Testing

@testable import AppFeedback

@Suite struct FeedbackSessionTests {
  @Test func encodesOrderedRecordingSegments() throws {
    let session = FeedbackSession(
      session_id: "s1",
      app: "dotself",
      build: "42",
      started_at: "2026-07-15T00:00:00Z",
      events: [],
      segments: [
        FeedbackRecordingSegment(file: "recording.mov"),
        FeedbackRecordingSegment(file: "recording-002.mov"),
      ])

    let data = try JSONEncoder().encode(session)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let segments = try #require(json["segments"] as? [[String: Any]])

    #expect(segments.map { $0["file"] as? String } == ["recording.mov", "recording-002.mov"])
  }

  @Test func encodesSidecarShapeWithSnakeCaseKeys() throws {
    let session = FeedbackSession(
      session_id: "s1",
      app: "dotself",
      build: "42",
      started_at: "2026-07-15T00:00:00Z",
      events: [
        FeedbackEvent(t: 0, screen: "Home"),
        FeedbackEvent(t: 1.5, screen: "Detail"),
      ]
    )

    let data = try JSONEncoder().encode(session)
    let json = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(json["session_id"] as? String == "s1")
    #expect(json["app"] as? String == "dotself")
    #expect(json["build"] as? String == "42")
    #expect(json["started_at"] as? String == "2026-07-15T00:00:00Z")

    let events = try #require(json["events"] as? [[String: Any]])
    #expect(events.count == 2)
    #expect(events[0]["t"] as? Double == 0)
    #expect(events[0]["screen"] as? String == "Home")
    #expect(events[1]["t"] as? Double == 1.5)
    #expect(events[1]["screen"] as? String == "Detail")
  }

  /// A screen entry must stay EXACTLY `{t, screen}`: no `tap` key, no nulls.
  @Test func screenEventEncodesWithoutTapKey() throws {
    let data = try JSONEncoder().encode([FeedbackEvent(t: 1, screen: "home")])
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    #expect(Set(json[0].keys) == ["t", "screen"])
  }

  @Test func tapEventEncodesNestedTapObject() throws {
    let event = FeedbackEvent.tap(t: 12.25, tap: FeedbackTap(x: 0.51, y: 0.83, element: "PRACTICE"))
    let data = try JSONEncoder().encode([event])
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])

    #expect(Set(json[0].keys) == ["t", "tap"])
    #expect(json[0]["t"] as? Double == 12.25)
    let tap = try #require(json[0]["tap"] as? [String: Any])
    #expect(tap["x"] as? Double == 0.51)
    #expect(tap["y"] as? Double == 0.83)
    #expect(tap["element"] as? String == "PRACTICE")
  }

  /// A tap with no resolved element omits the key entirely (JSON stays minimal;
  /// consumers read a missing element as null).
  @Test func tapEventWithoutElementOmitsElementKey() throws {
    let event = FeedbackEvent.tap(t: 3, tap: FeedbackTap(x: 0.1, y: 0.2, element: nil))
    let data = try JSONEncoder().encode([event])
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let tap = try #require(json[0]["tap"] as? [String: Any])
    #expect(Set(tap.keys) == ["x", "y"])
  }

  @Test func roundTripsThroughCodable() throws {
    let session = FeedbackSession(
      session_id: "s2",
      app: "lockin",
      build: "7",
      started_at: "2026-07-15T12:00:00Z",
      events: [
        FeedbackEvent(t: 2.25, screen: "Quiz"),
        .tap(t: 3.5, tap: FeedbackTap(x: 0.5, y: 0.5, element: "Check")),
        .tap(t: 4, tap: FeedbackTap(x: 0, y: 1, element: nil)),
      ]
    )
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(FeedbackSession.self, from: data)
    #expect(decoded == session)
  }

  /// Sessions written before taps existed (screen-only entries) must decode.
  @Test func decodesLegacyScreenOnlySession() throws {
    let legacy = """
      {"session_id":"old","app":"dotself","build":"3","started_at":"T",
       "events":[{"t":0,"screen":"Home"},{"t":9.5,"screen":"Detail"}]}
      """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(FeedbackSession.self, from: legacy)

    #expect(decoded.events == [
      FeedbackEvent(t: 0, screen: "Home"),
      FeedbackEvent(t: 9.5, screen: "Detail"),
    ])
    #expect(decoded.events[0].screen == "Home")
    #expect(decoded.events[0].t == 0)
  }

  @Test func decodesTapEventFromJSON() throws {
    let raw = """
      [{"t":12.3,"tap":{"x":0.5,"y":0.75,"element":"PRACTICE"}}]
      """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode([FeedbackEvent].self, from: raw)
    #expect(decoded == [.tap(t: 12.3, tap: FeedbackTap(x: 0.5, y: 0.75, element: "PRACTICE"))])
    // A tap is not a screen: the compat accessor stays nil.
    #expect(decoded[0].screen == nil)
    #expect(decoded[0].t == 12.3)
  }

  @Test func decodingEntryWithNeitherScreenNorTapThrows() {
    let raw = """
      [{"t":1}]
      """.data(using: .utf8)!
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode([FeedbackEvent].self, from: raw)
    }
  }
}
