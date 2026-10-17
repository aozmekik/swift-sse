// assemble-text: streams an LLM response and assembles its text as it arrives.
//
//   swift run assemble-text --provider openai --file examples/fixtures/openai-chat.sse
//   swift run assemble-text --provider anthropic --file examples/fixtures/anthropic-messages.sse
//   swift run assemble-text --provider openai --url http://127.0.0.1:8080/ \
//       [--header 'Name: value']... [--body request.json]
//
// With --file, the stream is read from disk and fed to EventStreamParser in small chunks, as a
// network would deliver it. With --url, EventSource sends the request (POST when --body is
// given) with reconnection disabled, as LLM streams must not be replayed.
//
// The text is written to standard output as it streams; a summary goes to standard error.

import Foundation
import SSE
import SSELLM

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum Provider: String {
    case openai
    case anthropic
}

enum Source {
    case file(String)
    case url(URL)
}

struct Options {
    var provider = Provider.openai
    var source: Source?
    var headers: [(name: String, value: String)] = []
    var bodyPath: String?
}

struct UsageError: Error, CustomStringConvertible {
    var description: String
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var remaining = arguments[...]
    func value(for flag: String) throws -> String {
        guard let value = remaining.popFirst() else {
            throw UsageError(description: "\(flag) needs a value")
        }
        return value
    }
    while let flag = remaining.popFirst() {
        switch flag {
        case "--provider":
            let name = try value(for: flag)
            guard let provider = Provider(rawValue: name) else {
                throw UsageError(description: "unknown provider '\(name)'")
            }
            options.provider = provider
        case "--file":
            options.source = .file(try value(for: flag))
        case "--url":
            let text = try value(for: flag)
            guard let url = URL(string: text) else {
                throw UsageError(description: "invalid URL '\(text)'")
            }
            options.source = .url(url)
        case "--header":
            let header = try value(for: flag)
            guard let colon = header.firstIndex(of: ":") else {
                throw UsageError(description: "headers look like 'Name: value'")
            }
            let name = header[..<colon].trimmingCharacters(in: .whitespaces)
            let value = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            options.headers.append((name, value))
        case "--body":
            options.bodyPath = try value(for: flag)
        default:
            throw UsageError(description: "unknown argument '\(flag)'")
        }
    }
    return options
}

/// Parses a stream file into events, feeding the parser 7 bytes at a time.
func eventsFromFile(_ path: String) throws -> AsyncStream<ServerSentEvent> {
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    var parser = EventStreamParser()
    var events: [ServerSentEvent] = []
    var start = 0
    while start < bytes.count {
        let end = min(start + 7, bytes.count)
        events += parser.parse(bytes[start..<end])
        start = end
    }
    parser.finish()
    return AsyncStream { continuation in
        for event in events {
            continuation.yield(event)
        }
        continuation.finish()
    }
}

func eventSource(for url: URL, options: Options) throws -> EventSource {
    var request = URLRequest(url: url)
    request.timeoutInterval = 120
    for header in options.headers {
        request.setValue(header.value, forHTTPHeaderField: header.name)
    }
    if let bodyPath = options.bodyPath {
        request.httpMethod = "POST"
        request.httpBody = try Data(contentsOf: URL(fileURLWithPath: bodyPath))
        if request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }
    return EventSource(request: request, reconnection: .disabled)
}

func write(_ text: String, to handle: FileHandle = .standardOutput) {
    handle.write(Data(text.utf8))
}

func assemble<Events: AsyncSequence>(
    _ events: Events,
    provider: Provider
) async throws where Events.Element == ServerSentEvent {
    switch provider {
    case .openai:
        var completion = OpenAIChatCompletionAccumulator()
        for try await chunk in events.openAIChatCompletionChunks() {
            write(chunk.textDelta ?? "")
            completion.add(chunk)
        }
        let reason = completion.choices.first?.finishReason?.rawValue ?? "none"
        let tokens = completion.usage.map { "\($0.totalTokens) tokens" } ?? "no usage reported"
        write("\n", to: .standardOutput)
        write("[finish_reason: \(reason), \(tokens)]\n", to: .standardError)
    case .anthropic:
        var message = AnthropicMessageAccumulator()
        for try await event in events.anthropicStreamEvents() {
            write(event.textDelta ?? "")
            try message.add(event)
        }
        let reason = message.stopReason?.rawValue ?? "none"
        let output = message.usage.outputTokens.map { "\($0) output tokens" } ?? "no usage"
        write("\n", to: .standardOutput)
        write("[stop_reason: \(reason), \(output)]\n", to: .standardError)
    }
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    switch options.source {
    case .file(let path):
        try await assemble(try eventsFromFile(path), provider: options.provider)
    case .url(let url):
        try await assemble(try eventSource(for: url, options: options), provider: options.provider)
    case nil:
        throw UsageError(description: "pass --file <path> or --url <url>")
    }
} catch let error as UsageError {
    write("assemble-text: \(error)\n", to: .standardError)
    write(
        "usage: assemble-text --provider openai|anthropic (--file <path> | --url <url>)"
            + " [--header 'Name: value']... [--body <file>]\n",
        to: .standardError)
    exit(64)
} catch {
    write("\nassemble-text: \(error)\n", to: .standardError)
    exit(1)
}
