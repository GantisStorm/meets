import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("ACPClient")
struct ACPClientTests {

    @Test("scripted chunks are concatenated in order")
    func fakeAgentRoundTrip() async throws {
        let scriptURL = try makeFakeAgent(mode: "roundtrip")
        let text = try await ACPClient.summarize(
            instructions: "You are a notes assistant.",
            userPrompt: "Summarize this.",
            command: scriptURL.path,
            timeout: 20
        )
        #expect(text == "Hello world")
    }

    @Test("refusal stop reason throws")
    func refusalStopReasonThrows() async throws {
        let scriptURL = try makeFakeAgent(mode: "refusal")
        do {
            _ = try await ACPClient.summarize(
                instructions: "You are a notes assistant.",
                userPrompt: "Summarize this.",
                command: scriptURL.path,
                timeout: 20
            )
            Issue.record("Expected refusal stop reason to throw")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("refusal"))
        }
    }

    @Test("end_turn without chunks throws empty response")
    func endTurnWithoutChunksThrowsEmptyResponse() async throws {
        let scriptURL = try makeFakeAgent(mode: "empty")
        do {
            _ = try await ACPClient.summarize(
                instructions: "You are a notes assistant.",
                userPrompt: "Summarize this.",
                command: scriptURL.path,
                timeout: 20
            )
            Issue.record("Expected empty response to throw")
        } catch let error as MeetingSummaryError {
            guard case .emptyResponse(let backend) = error else {
                Issue.record("Expected emptyResponse, got \(error)")
                return
            }
            #expect(backend == "ACP Agent")
        }
    }

    @Test("missing executable throws a readable MeetingSummaryError")
    func missingExecutableAgentThrows() async throws {
        do {
            _ = try await ACPClient.summarize(
                instructions: "You are a notes assistant.",
                userPrompt: "Summarize this.",
                command: "/nonexistent/definitely-not-an-acp-binary",
                timeout: 20
            )
            Issue.record("Expected missing executable to throw")
        } catch let error as MeetingSummaryError {
            #expect(error.localizedDescription.contains("not found or not executable"))
        }
    }

    // MARK: - Fake agent helpers

    /// Writes a fake ACP agent that validates request ordering
    /// (initialize -> session/new -> session/prompt) and exits non-zero on any
    /// deviation, so a passing test also proves wire ordering.
    private func makeFakeAgent(mode: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-acp-agent.py")
        let body = """
        #!/usr/bin/env python3
        import json
        import sys

        sys.stdout.reconfigure(line_buffering=True)
        MODE = "\(mode)"

        def send(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        expected = ["initialize", "session/new", "session/prompt"]
        step = 0
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            method = msg.get("method")
            if method != expected[step]:
                sys.stderr.write("unexpected method %s at step %d\\n" % (method, step))
                sys.exit(9)
            step += 1
            mid = msg.get("id")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentInfo": {"name": "fake", "version": "1.0"}}})
            elif method == "session/new":
                send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "fake-session-1"}})
            elif method == "session/prompt":
                if MODE == "roundtrip":
                    for text in ["Hello ", "world"]:
                        send({"jsonrpc": "2.0", "method": "session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}, "messageId": "m1"}}})
                    send({"jsonrpc": "2.0", "method": "session/update", "params": {"update": {"sessionUpdate": "session_info_update", "updatedAt": "2026-09-05T00:00:00Z"}}})
                elif MODE == "empty":
                    pass
                elif MODE == "refusal":
                    send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "refusal"}})
                    continue
                send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
        """
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
