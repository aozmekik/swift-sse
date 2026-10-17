import Testing

@testable import SSE

@Suite("Reconnection policy")
struct ReconnectionPolicyTests {
    private let policy = ReconnectionPolicy.exponentialBackoff(
        reconnectionTime: .seconds(3),
        maximumDelay: .seconds(60),
        multiplier: 2,
        jitter: 0.5
    )

    @Test(
        "Without jitter the delay doubles from the reconnection time up to the cap",
        arguments: [(1, 3.0), (2, 6.0), (3, 12.0), (4, 24.0), (5, 48.0), (6, 60.0), (40, 60.0)]
    )
    func exponentialGrowth(attempt: Int, expectedSeconds: Double) {
        let delay = policy.delay(
            beforeAttempt: attempt, serverReconnectionTime: nil, randomValue: 0)
        #expect(delay == .seconds(expectedSeconds))
    }

    @Test("The server's reconnection time is the delay of the first attempt")
    func serverTimeIsTheFirstDelay() {
        let delay = policy.delay(
            beforeAttempt: 1, serverReconnectionTime: .milliseconds(250), randomValue: 0)
        #expect(delay == .milliseconds(250))
    }

    @Test("A short server reconnection time does not shrink the backoff after failures")
    func shortServerTimeStillBacksOff() {
        let delay = policy.delay(beforeAttempt: 3, serverReconnectionTime: .zero, randomValue: 0)
        #expect(delay == .seconds(12))
    }

    @Test("A server reconnection time above the cap is still honored")
    func serverTimeAboveCap() {
        let delay = policy.delay(
            beforeAttempt: 9, serverReconnectionTime: .seconds(600), randomValue: 0)
        #expect(delay == .seconds(600))
    }

    @Test("Jitter adds up to the jitter fraction and never subtracts")
    func jitterBounds() {
        let low = policy.delay(beforeAttempt: 2, serverReconnectionTime: nil, randomValue: 0)
        let middle = policy.delay(beforeAttempt: 2, serverReconnectionTime: nil, randomValue: 0.5)
        let high = policy.delay(
            beforeAttempt: 2, serverReconnectionTime: nil, randomValue: 0.999_999)
        #expect(low == .seconds(6))
        #expect(middle == .seconds(7.5))
        #expect(high < .seconds(9))
        #expect(high > .seconds(8.99))
    }

    @Test("Random values outside [0, 1) are clamped")
    func clampsRandomValues() {
        #expect(
            policy.delay(beforeAttempt: 1, serverReconnectionTime: nil, randomValue: -3)
                == .seconds(3))
        #expect(
            policy.delay(beforeAttempt: 1, serverReconnectionTime: nil, randomValue: 7)
                == .seconds(4.5))
    }

    @Test("A multiplier of 1 gives a constant delay")
    func constantDelay() {
        let constant = ReconnectionPolicy.exponentialBackoff(
            reconnectionTime: .seconds(1), multiplier: 1, jitter: 0)
        for attempt in 1...10 {
            let delay = constant.delay(
                beforeAttempt: attempt, serverReconnectionTime: nil, randomValue: 0.7)
            #expect(delay == .seconds(1))
        }
    }

    @Test("A zero reconnection time does not produce NaN or a huge delay")
    func zeroReconnectionTime() {
        let immediate = ReconnectionPolicy.exponentialBackoff(reconnectionTime: .zero, jitter: 0)
        #expect(
            immediate.delay(beforeAttempt: 50, serverReconnectionTime: nil, randomValue: 0) == .zero
        )
    }

    @Test("A saturated server reconnection time stays finite")
    func saturatedServerTime() {
        let delay = policy.delay(
            beforeAttempt: 1, serverReconnectionTime: .milliseconds(Int64.max), randomValue: 0.9)
        #expect(delay > .seconds(9_000_000_000_000_000))
    }

    @Test("The presets")
    func presets() {
        #expect(ReconnectionPolicy.disabled.isEnabled == false)
        #expect(ReconnectionPolicy.default.isEnabled)
        #expect(ReconnectionPolicy.default.reconnectionTime == .seconds(3))
        #expect(ReconnectionPolicy.default.maximumDelay == .seconds(60))
        #expect(ReconnectionPolicy.default.maximumAttempts == nil)
        #expect(ReconnectionPolicy.default == .exponentialBackoff())
    }
}
