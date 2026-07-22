import Foundation

/// A tap captured during a recording. `x`/`y` are normalized 0-1 against the
/// window bounds (2 decimals). `element` is the best accessibility description
/// of what was hit, or nil when the hierarchy exposes nothing usable - the
/// coordinates are still worth recording.
public struct FeedbackTap: Codable, Sendable, Equatable {
  public let x: Double
  public let y: Double
  public let element: String?

  public init(x: Double, y: Double, element: String?) {
    self.x = x
    self.y = y
    self.element = element
  }

  private enum CodingKeys: String, CodingKey { case x, y, element }

  /// Hand-written so a nil element OMITS the key instead of writing `null`.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(x, forKey: .x)
    try c.encode(y, forKey: .y)
    try c.encodeIfPresent(element, forKey: .element)
  }
}

/// A single event in a recording's trail: a screen navigation or a tap.
/// `t` is seconds (Double) relative to recording start.
///
/// A tagged union on the wire: screen entries stay EXACTLY `{t, screen}` (the
/// shape written before taps existed, so old sessions decode and old readers
/// keep working) and taps are `{t, tap: {x, y, element?}}`.
public enum FeedbackEvent: Codable, Sendable, Equatable {
  case screen(t: Double, name: String)
  case tap(t: Double, tap: FeedbackTap)

  /// Source-compatible with the pre-union struct: `FeedbackEvent(t:screen:)`.
  public init(t: Double, screen: String) {
    self = .screen(t: t, name: screen)
  }

  public var t: Double {
    switch self {
    case let .screen(t, _): return t
    case let .tap(t, _): return t
    }
  }

  /// The screen name for screen events; nil for taps.
  public var screen: String? {
    switch self {
    case let .screen(_, name): return name
    case .tap: return nil
    }
  }

  private enum CodingKeys: String, CodingKey { case t, screen, tap }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let t = try c.decode(Double.self, forKey: .t)
    if let tap = try c.decodeIfPresent(FeedbackTap.self, forKey: .tap) {
      self = .tap(t: t, tap: tap)
      return
    }
    if let name = try c.decodeIfPresent(String.self, forKey: .screen) {
      self = .screen(t: t, name: name)
      return
    }
    throw DecodingError.dataCorrupted(
      DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "Trail event has neither a screen nor a tap"))
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(t, forKey: .t)
    switch self {
    case let .screen(_, name): try c.encode(name, forKey: .screen)
    case let .tap(_, tap): try c.encode(tap, forKey: .tap)
    }
  }
}

/// The sidecar `events.json` describing a feedback recording session.
/// Keys are snake_case to match the repo's JSON conventions.
public struct FeedbackSession: Codable, Sendable, Equatable {
  public let session_id: String
  public let app: String
  public let build: String
  public let started_at: String
  /// Stable reporter identity (see `FeedbackUserRef`). The processor copies it
  /// onto the session record so resolved-issue inbox messages can address this
  /// reporter. Optional so pre-userRef payloads still decode.
  public let user_ref: String?
  public let events: [FeedbackEvent]

  public init(
    session_id: String,
    app: String,
    build: String,
    started_at: String,
    user_ref: String? = nil,
    events: [FeedbackEvent]
  ) {
    self.session_id = session_id
    self.app = app
    self.build = build
    self.started_at = started_at
    self.user_ref = user_ref
    self.events = events
  }
}
