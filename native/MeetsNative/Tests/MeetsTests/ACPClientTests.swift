import Foundation
import Testing
@testable import MeetsApp

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

    @Test("model override is sent as set_config_option before the prompt")
    func modelOverrideSendsConfigOption() async throws {
        // Requests one of the two models the fake advertises, and one that is
        // not its current value: ACPClient only sends values the agent
        // currently offers and only when they differ from `currentValue`.
        let scriptURL = try makeFakeAgent(mode: "config", expectedConfig: [
            ["model", "anthropic/claude-fable-5"],
        ])
        let text = try await ACPClient.summarize(
            instructions: "You are a notes assistant.",
            userPrompt: "Summarize this.",
            command: scriptURL.path,
            model: "anthropic/claude-fable-5",
            timeout: 20
        )
        #expect(text == "Hello world")
    }

    @Test("model and thinking overrides apply in order")
    func modelAndThinkingOverridesApplyInOrder() async throws {
        // The model must differ from the fake's `currentValue`
        // ("anthropic/claude-sonnet-5"); a value equal to currentValue is
        // deliberately not sent, so requesting it would prove nothing here.
        let scriptURL = try makeFakeAgent(mode: "config", expectedConfig: [
            ["model", "anthropic/claude-fable-5"],
            ["thinking", "xhigh"],
        ])
        let text = try await ACPClient.summarize(
            instructions: "You are a notes assistant.",
            userPrompt: "Summarize this.",
            command: scriptURL.path,
            model: "anthropic/claude-fable-5",
            thinking: "xhigh",
            timeout: 20
        )
        #expect(text == "Hello world")
    }

    @Test("value the agent does not advertise skips set_config_option silently")
    func unadvertisedModelValueKeepsAgentDefault() async throws {
        // The fake advertises exactly two models; an unadvertised value must
        // not produce a set_config_option (the fake's ordering check exits
        // non-zero if one arrives) and the session still completes.
        let scriptURL = try makeFakeAgent(mode: "config")
        let text = try await ACPClient.summarize(
            instructions: "You are a notes assistant.",
            userPrompt: "Summarize this.",
            command: scriptURL.path,
            model: "anthropic/claude-opus-5",
            timeout: 20
        )
        #expect(text == "Hello world")
    }

    @Test("agent without config options ignores requested overrides")
    func missingConfigOptionsAreIgnored() async throws {
        // session/new response without configOptions: overrides fall back to
        // the agent default and the session proceeds untouched.
        let scriptURL = try makeFakeAgent(mode: "roundtrip")
        let text = try await ACPClient.summarize(
            instructions: "You are a notes assistant.",
            userPrompt: "Summarize this.",
            command: scriptURL.path,
            model: "command-code/deepseek/deepseek-v4-flash",
            thinking: "xhigh",
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
    /// (initialize -> session/new -> session/prompt, with optional
    /// session/set_config_option calls interleaved when `mode` is "config")
    /// and exits non-zero on any deviation, so a passing test also proves
    /// wire ordering. When `expectedConfig` is non-empty the agent requires
    /// exactly those set_config_option calls, in order, before session/prompt.
    private func makeFakeAgent(mode: String, expectedConfig: [[String]] = []) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-acp-agent.py")
        let expectedConfigJSON = String(
            data: try JSONSerialization.data(withJSONObject: expectedConfig),
            encoding: .utf8
        )!
        let body = """
        #!/usr/bin/env python3
        import json
        import sys

        sys.stdout.reconfigure(line_buffering=True)
        MODE = "\(mode)"
        EXPECTED_CONFIG = json.loads('\(expectedConfigJSON)')


        def send(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()


        def config_options():
            return [
                {
                    "id": "model",
                    "name": "Model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "anthropic/claude-sonnet-5",
                    "options": [
                        {"value": "anthropic/claude-sonnet-5", "name": "Claude Sonnet 5"},
                        {"value": "anthropic/claude-fable-5", "name": "Claude Fable 5"},
                    ],
                },
                {
                    "id": "thinking",
                    "name": "Thinking",
                    "category": "thinking",
                    "type": "select",
                    "currentValue": "auto",
                    "options": [
                        {"value": "off", "name": "Off"},
                        {"value": "auto", "name": "Auto"},
                        {"value": "xhigh", "name": "X-High"},
                    ],
                },
            ]

        expected = ["initialize", "session/new"]
        step = 0
        config_calls = 0
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            method = msg.get("method")
            if step < len(expected) and method != expected[step]:
                sys.stderr.write("unexpected method %s at step %d\\n" % (method, step))
                sys.exit(9)
            if method == "initialize":
                step += 1
                send({"jsonrpc": "2.0", "id": msg.get("id"), "result": {"protocolVersion": 1, "agentInfo": {"name": "fake", "version": "1.0"}}})
            elif method == "session/new":
                step += 1
                result = {"sessionId": "fake-session-1"}
                if MODE == "config":
                    result["configOptions"] = config_options()
                send({"jsonrpc": "2.0", "id": msg.get("id"), "result": result})
            elif method == "session/set_config_option":
                if MODE != "config":
                    sys.stderr.write("unexpected set_config_option in mode %s\\n" % MODE)
                    sys.exit(9)
                if config_calls >= len(EXPECTED_CONFIG):
                    sys.stderr.write("too many set_config_option calls\\n")
                    sys.exit(9)
                want_id, want_value = EXPECTED_CONFIG[config_calls]
                got_id = msg.get("params", {}).get("configId")
                got_value = msg.get("params", {}).get("value")
                if got_id != want_id or got_value != want_value:
                    sys.stderr.write("expected config %s=%s, got %s=%s\\n" % (want_id, want_value, got_id, got_value))
                    sys.exit(9)
                config_calls += 1
                # The response returns the full updated configOptions and a
                # trailing config_option_update notification may also arrive.
                options = config_options()
                for option in options:
                    if option["id"] == got_id:
                        option["currentValue"] = got_value
                send({"jsonrpc": "2.0", "id": msg.get("id"), "result": {"configOptions": options}})
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "fake-session-1", "update": {"sessionUpdate": "config_option_update", "configOptions": options}}})
            elif method == "session/prompt":
                if step < len(expected) or config_calls != len(EXPECTED_CONFIG):
                    sys.stderr.write("session/prompt before all expected steps/config calls\\n")
                    sys.exit(9)
                if MODE == "empty":
                    pass
                elif MODE == "refusal":
                    send({"jsonrpc": "2.0", "id": msg.get("id"), "result": {"stopReason": "refusal"}})
                    continue
                else:
                    # roundtrip and config modes both produce a summary
                    for text in ["Hello ", "world"]:
                        send({"jsonrpc": "2.0", "method": "session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}, "messageId": "m1"}}})
                    send({"jsonrpc": "2.0", "method": "session/update", "params": {"update": {"sessionUpdate": "session_info_update", "updatedAt": "2026-09-05T00:00:00Z"}}})
                send({"jsonrpc": "2.0", "id": msg.get("id"), "result": {"stopReason": "end_turn"}})
        """
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
