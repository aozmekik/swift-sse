/// A single event dispatched from a `text/event-stream`.
///
/// The fields mirror the `MessageEvent` that a browser's `EventSource` dispatches, as defined in
/// the WHATWG HTML Living Standard, section 9.2.6 "Interpreting an event stream":
///
/// - ``type`` is the value of the last `event:` field of the block, or `"message"` when the block
///   had no (or an empty) `event:` field.
/// - ``data`` is every `data:` field of the block joined with `"\n"`.
/// - ``lastEventID`` is the stream's *last event ID string* at the time the event was dispatched.
///   It persists across events (and reconnections) until the server sends a new `id:` field, so an
///   event without its own `id:` field carries the ID of an earlier event.
public struct ServerSentEvent: Sendable, Hashable {
    /// The event type used when a block does not set one with an `event:` field.
    public static let defaultType = "message"

    /// The event type: the value of the block's `event:` field, or ``defaultType``.
    public var type: String

    /// The event payload: the values of the block's `data:` fields joined with `"\n"`.
    public var data: String

    /// The last event ID string of the stream when this event was dispatched.
    ///
    /// An empty string means that no ID has been set, or that the server reset it with an empty
    /// `id:` field.
    public var lastEventID: String

    /// Creates an event.
    ///
    /// - Parameters:
    ///   - type: The event type. Defaults to ``defaultType``.
    ///   - data: The event payload.
    ///   - lastEventID: The last event ID string. Defaults to the empty string.
    public init(
        type: String = ServerSentEvent.defaultType,
        data: String,
        lastEventID: String = ""
    ) {
        self.type = type
        self.data = data
        self.lastEventID = lastEventID
    }
}

extension ServerSentEvent: CustomStringConvertible {
    /// A compact, human-readable representation of the event, for logging and debugging.
    public var description: String {
        var parts = ["type: \(type)"]
        if !lastEventID.isEmpty {
            parts.append("lastEventID: \(lastEventID)")
        }
        parts.append("data: \(data.debugDescription)")
        return "ServerSentEvent(\(parts.joined(separator: ", ")))"
    }
}
