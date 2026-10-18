# ADR 0002: Reconnection delay is the server's retry time plus capped, jittered backoff

- Status: accepted
- Date: 2026-10-18

## Context

The standard (HTML Living Standard 9.2.3, "reestablish the connection") says to wait the stream's
reconnection time, which the server sets with `retry:`, and allows waiting longer, for example
with exponential backoff after failures. Mobile clients reconnect after network changes and
server deployments, often thousands at once, so a fixed delay creates synchronized reconnection
waves, and a server that keeps failing should not be retried at a constant rate.

## Options considered

1. **Fixed delay** (what browsers do): the reconnection time, every time. Spec-exact, but no
   backoff and no spread.
2. **Exponential backoff with "full jitter"** (`random(0, min(cap, base × 2ⁿ))`, from Marc
   Brooker's "Exponential Backoff And Jitter", AWS Architecture Blog, 2015): the best spread, but
   it can wait less than the server's `retry:` value, which the standard does not allow.
3. **Server time as a floor, capped exponential growth from the client's base, additive jitter.**

## Decision

Option 3. For the *n*-th consecutive failed connection:

- *n* = 1: the floor, which is the server's latest `retry:` value or the policy's
  `reconnectionTime` (3 s by default, "a few seconds" as the standard suggests);
- *n* ≥ 2: `max(floor, min(maximumDelay, reconnectionTime × multiplier^(n−1)))`;
- then `delay × (1 + jitter × u)` with *u* uniform in [0, 1).

Growth starts from the policy's own `reconnectionTime`, not from the server's value, so a server
that sends `retry: 0` and then fails is still backed off.

What resets *n* is a separate choice. Three rules were considered:

- **An event was dispatched** (the first version). A quiet but healthy stream that only sends
  keep-alive comments, as section 9.2.7 recommends against proxies, and that a proxy closes every
  few minutes, then backs off to `maximumDelay` and eventually exhausts `maximumAttempts`
  although nothing failed.
- **The connection stayed open for some time.** Needs a clock in the iterator and a threshold
  that is wrong for some deployments.
- **The connection delivered at least one byte of body.** Chosen: any event, field or comment
  shows that the server answered with a working stream. A failed attempt, or a 200
  `text/event-stream` response that closes without sending anything, counts as a failure.

## Consequences

- The server's reconnection time is always honored as a lower bound, including when it exceeds
  `maximumDelay`.
- The cap applies before jitter, so the longest wait is `maximumDelay × (1 + jitter)`.
- The delay computation is a pure function (`ReconnectionPolicy.delay(beforeAttempt:...)`) with
  the random value passed in, so it is unit-tested exactly, and the client tests inject the
  sleeper and the random source: no test waits for real time.
- `maximumAttempts` bounds consecutive failures; the default is no limit, as in browsers.
- A server that answers every request with a few bytes and then closes is retried at the floor
  delay forever, as browsers do. Errors that no retry can fix (an unsupported URL, an untrusted
  certificate) are not retried at all; `ReconnectionPolicy` lists them.
