import Foundation

/// How an ``EventSource`` reconnects after its connection ends or fails.
///
/// The WHATWG HTML Living Standard (section 9.2.3, "reestablish the connection") requires a
/// client to wait at least the stream's *reconnection time* before reconnecting, lets the server
/// change that time with a `retry:` field, and allows a client to wait longer, for example with an
/// exponential backoff after failed attempts. `ReconnectionPolicy` implements that as follows.
///
/// Let *n* be the number of consecutive failed connections (attempts that failed, and connections
/// that ended without delivering a single byte of body), *floor* the reconnection time (the
/// server's latest `retry:` value, or ``reconnectionTime`` when the server has not sent one) and
/// *u* a uniformly distributed random number in `[0, 1)`:
///
/// | Attempt | Delay before jitter                                                     |
/// |---------|-------------------------------------------------------------------------|
/// | n = 1   | floor                                                                   |
/// | n ≥ 2   | max(floor, min(``maximumDelay``, ``reconnectionTime`` × ``multiplier``ⁿ⁻¹)) |
///
/// The jittered delay is `delay × (1 + jitter × u)`, so the server's reconnection time is always
/// honored as a lower bound, consecutive failures back off exponentially from the policy's own
/// ``reconnectionTime`` (so a server that sends `retry: 0` and then fails cannot cause a tight
/// reconnection loop), and clients that lost their connections at the same moment spread out
/// instead of reconnecting in lockstep.
///
/// A connection that delivers any data, an event or only a comment, resets *n*. A long-lived
/// stream that drops once therefore reconnects after the floor delay, and so does a quiet stream
/// that the server keeps alive with comments (as section 9.2.7 recommends) when a proxy closes it.
/// Only failed attempts and connections that close without sending anything back off and count
/// toward ``maximumAttempts``.
///
/// Whatever the policy, errors that a reconnection cannot fix end iteration at once with
/// ``EventSourceError/connectionFailed(underlying:)``: an invalid or unsupported URL, a URL that
/// App Transport Security blocks, an untrusted or not yet or no longer valid server certificate,
/// a missing or rejected client certificate, cancelled or required authentication, file URL
/// errors, and loads that the URL loading system cancelled although the iterating task was not
/// cancelled. Without this rule, a typo in a URL scheme would retry forever without an error.
public struct ReconnectionPolicy: Sendable, Hashable {
    /// Whether the event source reconnects at all.
    public let isEnabled: Bool

    /// The reconnection time used until the server sends a `retry:` field, and the base of the
    /// exponential backoff.
    public let reconnectionTime: Duration

    /// The largest backoff delay, before jitter is added.
    ///
    /// A larger reconnection time requested by the server with `retry:` still takes precedence.
    public let maximumDelay: Duration

    /// The factor by which the delay grows after each consecutive failed attempt.
    public let multiplier: Double

    /// The fraction of the delay that is added at random, in `0...1`.
    public let jitter: Double

    /// The number of consecutive failed reconnection attempts (attempts that failed, or whose
    /// connection closed without delivering any data) after which iteration fails with
    /// ``EventSourceError/reconnectionLimitReached(attempts:lastError:)``, or `nil` to keep
    /// trying forever, as browsers do.
    public let maximumAttempts: Int?

    private init(
        isEnabled: Bool,
        reconnectionTime: Duration,
        maximumDelay: Duration,
        multiplier: Double,
        jitter: Double,
        maximumAttempts: Int?
    ) {
        self.isEnabled = isEnabled
        self.reconnectionTime = reconnectionTime
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
        self.jitter = jitter
        self.maximumAttempts = maximumAttempts
    }

    /// Never reconnect: iteration ends when the server closes the stream and fails when the
    /// connection fails.
    ///
    /// Use this for streams that must not be replayed, such as `POST` requests to LLM APIs, where
    /// reconnecting would start (and bill) a new generation.
    public static let disabled = ReconnectionPolicy(
        isEnabled: false,
        reconnectionTime: .zero,
        maximumDelay: .zero,
        multiplier: 1,
        jitter: 0,
        maximumAttempts: nil
    )

    /// Reconnect with the server's reconnection time as a floor and a capped, jittered
    /// exponential backoff after consecutive failures.
    ///
    /// - Parameters:
    ///   - reconnectionTime: The reconnection time used until the server sends `retry:`, and the
    ///     base of the backoff. The standard leaves the initial value to the implementation and
    ///     suggests a few seconds. Defaults to 3 seconds.
    ///   - maximumDelay: The largest backoff delay before jitter. Defaults to 60 seconds.
    ///   - multiplier: The growth factor per consecutive failure; at least 1. Defaults to 2.
    ///   - jitter: The fraction of the delay added at random, in `0...1`. Defaults to 0.5.
    ///   - maximumAttempts: The number of consecutive failed attempts before giving up, at least
    ///     1, or `nil` (the default) for no limit.
    /// - Returns: A policy that reconnects with the given parameters.
    public static func exponentialBackoff(
        reconnectionTime: Duration = .seconds(3),
        maximumDelay: Duration = .seconds(60),
        multiplier: Double = 2,
        jitter: Double = 0.5,
        maximumAttempts: Int? = nil
    ) -> ReconnectionPolicy {
        precondition(reconnectionTime >= .zero, "reconnectionTime must not be negative")
        precondition(maximumDelay >= .zero, "maximumDelay must not be negative")
        precondition(multiplier.isFinite && multiplier >= 1, "multiplier must be at least 1")
        precondition(jitter.isFinite && (0...1).contains(jitter), "jitter must be in 0...1")
        precondition(maximumAttempts.map { $0 >= 1 } ?? true, "maximumAttempts must be at least 1")
        return ReconnectionPolicy(
            isEnabled: true,
            reconnectionTime: reconnectionTime,
            maximumDelay: maximumDelay,
            multiplier: multiplier,
            jitter: jitter,
            maximumAttempts: maximumAttempts
        )
    }

    /// The default policy: ``exponentialBackoff(reconnectionTime:maximumDelay:multiplier:jitter:maximumAttempts:)``
    /// with its default arguments.
    public static let `default` = ReconnectionPolicy.exponentialBackoff()

    /// Returns the delay to wait before a reconnection attempt.
    ///
    /// - Parameters:
    ///   - attempt: The 1-based number of consecutive failed connections.
    ///   - serverReconnectionTime: The latest `retry:` value from the server, if any.
    ///   - randomValue: A uniformly distributed random number in `[0, 1)` used for jitter.
    /// - Returns: The delay before the attempt.
    func delay(
        beforeAttempt attempt: Int,
        serverReconnectionTime: Duration?,
        randomValue: Double
    ) -> Duration {
        let floor = (serverReconnectionTime ?? reconnectionTime).seconds
        var delay = floor
        if attempt >= 2, reconnectionTime > .zero {
            let growth = reconnectionTime.seconds * pow(multiplier, Double(attempt - 1))
            delay = max(floor, min(maximumDelay.seconds, growth))
        }
        let sample = min(max(randomValue, 0), 1)
        delay *= 1 + jitter * sample
        guard delay.isFinite else { return .seconds(Int64.max) }
        return .seconds(delay)
    }
}

extension Duration {
    /// The duration as a (possibly rounded) number of seconds.
    fileprivate var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
