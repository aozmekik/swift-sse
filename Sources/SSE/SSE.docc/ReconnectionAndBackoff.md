# Reconnection and Backoff

How an event source decides whether and when to reconnect.

## Overview

The standard's processing model distinguishes three ways a connection can end:

| What happened | Standard | ``EventSource`` |
|---|---|---|
| The server closed the stream, or a network error occurred | Reestablish the connection | Ask the ``ReconnectionPolicy`` |
| The response was not 200, or not `text/event-stream` | Fail the connection | Throw an ``EventSourceError`` |
| The response was `204 No Content` | Fail the connection (the server's way to say "stop") | End the sequence normally |

### The delay

When the policy reconnects, it waits at least the stream's reconnection time: the value of the
server's latest `retry:` field, or ``ReconnectionPolicy/reconnectionTime`` until the server sends
one. After consecutive attempts that did not receive an event, the delay grows exponentially from
the policy's own reconnection time, up to ``ReconnectionPolicy/maximumDelay``, and a random
fraction (``ReconnectionPolicy/jitter``) is added so that many clients that lost their connection
at the same moment do not reconnect in lockstep. With the default policy:

| Attempt since the last event | Delay before jitter | With jitter (default 0.5) |
|---|---|---|
| 1 | 3 s (or the server's `retry:`) | 3 s to 4.5 s |
| 2 | 6 s | 6 s to 9 s |
| 3 | 12 s | 12 s to 18 s |
| 6 and later | 60 s | 60 s to 90 s |

Receiving an event resets the count, so a healthy stream that drops reconnects after the floor
delay. The server's reconnection time is never undercut, even when it is larger than the maximum
delay.

### Last-Event-ID

Every reconnection carries a `Last-Event-ID` header with the stream's last event ID string, if it
is not empty. The ID persists across reconnections until the server sends a new `id:` field (an
empty `id:` resets it), and an `id:` field inside a block that never completed does not count.
Pass `lastEventID:` when you create the event source to resume a stream across app launches.

### Choosing a policy

- ``ReconnectionPolicy/default``: the backoff above, retrying forever, as browsers do. This is the
  default for `GET` requests.
- ``ReconnectionPolicy/disabled``: iteration ends when the server closes the stream and fails with
  ``EventSourceError/connectionFailed(underlying:)`` when the connection fails. This is the default
  for every other method, such as the `POST` requests of LLM APIs.
- ``ReconnectionPolicy/exponentialBackoff(reconnectionTime:maximumDelay:multiplier:jitter:maximumAttempts:)``:
  your own parameters, including a limit after which iteration fails with
  ``EventSourceError/reconnectionLimitReached(attempts:lastError:)``.

Reconnection is pull-based: the event source reconnects only when you ask for the next event. If
you stop iterating after a terminal event, as the `SSELLM` sequences do, no reconnection happens.
