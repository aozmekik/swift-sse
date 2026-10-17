#!/usr/bin/env bash
# Runs the examples against the fixtures, offline and over HTTP, and checks their output.
#
#   scripts/check-examples.sh
#
# Needs python3 for examples/serve-fixture.py. Used by CI on macOS and Linux.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
pids=()
cleanup() {
    for pid in "${pids[@]:-}"; do
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -rf "$work"
}
trap cleanup EXIT

swift build -c release
bin="$(swift build -c release --show-bin-path)"

expect() {
    if [[ "$1" != *"$2"* ]]; then
        printf 'FAIL: expected %q in output:\n%s\n' "$2" "$1" >&2
        exit 1
    fi
}

# Starts the fixture server in the background and waits until it listens.
serve() {
    local log="$1"
    shift
    python3 examples/serve-fixture.py "$@" 2>"$log" &
    pids+=("$!")
    for _ in $(seq 1 100); do
        grep -q listening "$log" 2>/dev/null && return 0
        sleep 0.1
    done
    echo "FAIL: fixture server did not start" >&2
    cat "$log" >&2
    exit 1
}

openai_text="Server-Sent Events deliver a model's answer one token at a time."
anthropic_text="Each event carries a small text delta; the client joins them."

echo "== assemble-text, from files"
out="$("$bin/assemble-text" --provider openai --file examples/fixtures/openai-chat.sse 2>&1)"
expect "$out" "$openai_text"
expect "$out" "[finish_reason: stop, 27 tokens]"
out="$("$bin/assemble-text" --provider anthropic --file examples/fixtures/anthropic-messages.sse 2>&1)"
expect "$out" "$anthropic_text"
expect "$out" "[stop_reason: end_turn, 14 output tokens]"

echo "== assemble-text, over HTTP"
echo '{"stream": true}' >"$work/request.json"
serve "$work/openai.log" examples/fixtures/openai-chat.sse --port 18765 --requests 1
out="$("$bin/assemble-text" --provider openai --url http://127.0.0.1:18765/v1/chat/completions \
    --header "Authorization: Bearer test" --body "$work/request.json" 2>&1)"
expect "$out" "$openai_text"
expect "$(cat "$work/openai.log")" "POST /v1/chat/completions"

serve "$work/anthropic.log" examples/fixtures/anthropic-messages.sse --port 18766 --requests 1
out="$("$bin/assemble-text" --provider anthropic --url http://127.0.0.1:18766/v1/messages \
    --body "$work/request.json" 2>&1)"
expect "$out" "$anthropic_text"

echo "== sse-tail, reconnecting with Last-Event-ID"
serve "$work/ticks.log" examples/fixtures/ticks.sse --port 18767 --max-blocks 2 --requests 2
out="$("$bin/sse-tail" http://127.0.0.1:18767/ --max-events 3 2>&1)"
expect "$out" "tick 1"
expect "$out" "tick 3"
expect "$(cat "$work/ticks.log")" "Last-Event-ID='1'"

echo "All example checks passed."
