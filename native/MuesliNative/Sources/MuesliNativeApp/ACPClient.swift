import Foundation
import os

// ACP (Agent Client Protocol) v1 client over a stdio subprocess.
//
// Spawns the configured agent command (default "omp acp") and drives a
// minimal JSON-RPC session: initialize -> session/new -> (optional
// session/set_config_option for model/reasoning overrides) -> session/prompt.
// Agent output arrives as id-less "session/update" notifications whose
// params.update.sessionUpdate == "agent_message_chunk" carry
// params.update.content.text; those chunks are concatenated in arrival order
// and returned once the prompt response reports stopReason "end_turn".
//
// The child's stdout is drained continuously for the whole session (not just
// while awaiting a response) so a chatty agent can never fill the 64KB pipe
// buffer and deadlock; a bounded stderr buffer is kept for diagnostics.

enum ACPError: LocalizedError {
    case missingCommand
    case invalidResponse(String)
    case agentExit(Int32)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "No ACP agent command was provided."
        case .invalidResponse(let message):
            return message
        case .agentExit(let status):
            return "ACP agent process exited with status \(status). Check that the command is installed and available on PATH."
        case .timedOut:
            return "ACP agent did not finish generating notes within the allowed time."
        }
    }
}

/// A single selectable value for an ACP session config option
/// (a member of `ACPConfigOption.options`).
struct ACPConfigValue: Codable, Equatable, Sendable {
    let value: String
    let name: String
    let description: String?
}

/// One ACP session config option (ids include "model" and "thinking")
/// advertised by the agent in `session/new` or `session/update`
/// (`config_option_update`) payloads.
struct ACPConfigOption: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let category: String
    let type: String
    let currentValue: String
    let options: [ACPConfigValue]
}

/// The result of `session/new`: a session id plus the agent's authoritative
/// config options. Agents that do not advertise options decode with an empty
/// list so callers fall back to the agent defaults.
struct ACPAgentSession: Codable, Sendable {
    let sessionId: String
    let configOptions: [ACPConfigOption]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        configOptions = try container.decodeIfPresent([ACPConfigOption].self, forKey: .configOptions) ?? []
    }
}

enum ACPClient {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "ACPClient")
    private static let backendName = "ACP Agent"

    /// Runs one ACP summary session and returns the agent's assembled text.
    /// The process machinery is synchronous (Pipe readabilityHandler callbacks
    /// fire on a private queue and must not drive async code), so the session
    /// runs on an unstructured Task that inherits cancellation: the wait loop
    /// checks Task.isCancelled, terminates the child, and rethrows
    /// CancellationError so retry wrappers never retry a cancelled turn.
    ///
    /// `model` and `thinking` are the `value` strings of the agent's "model"
    /// / "thinking" config options. nil (or an option the agent does not
    /// advertise, a value it no longer offers, or the option's current
    /// value) leaves the agent default in place. Overrides are applied right
    /// after session/new, before the prompt.
    static func summarize(
        instructions: String,
        userPrompt: String,
        command: String,
        model: String? = nil,
        thinking: String? = nil,
        timeout: TimeInterval
    ) async throws -> String {
        let session = Task(priority: .userInitiated) {
            try runSession(
                instructions: instructions,
                userPrompt: userPrompt,
                command: command,
                model: model,
                thinking: thinking,
                timeout: timeout
            )
        }
        return try await session.value
    }

    /// Spawns the agent once and returns the config options it advertises for
    /// a fresh session (used to populate the Settings model/reasoning menus).
    /// Covers only the lightweight initialize -> session/new -> terminate
    /// sequence; a session is never prompted. An agent that advertises no
    /// config options returns an empty array.
    static func availableOptions(
        command: String,
        timeout: TimeInterval
    ) async throws -> [ACPConfigOption] {
        let session = Task(priority: .userInitiated) {
            try runSessionProbe(command: command, timeout: timeout)
        }
        return try await session.value
    }

    private nonisolated static func runSession(
        instructions: String,
        userPrompt: String,
        command: String,
        model: String?,
        thinking: String?,
        timeout: TimeInterval
    ) throws -> String {
        let agent = try AgentProcess(command: command, timeout: timeout)
        do {
            let session = try agent.startSession()
            var nextRequestID = 2
            for (configID, requestedValue) in [("model", model), ("thinking", thinking)] {
                guard let requestedValue, !requestedValue.isEmpty else { continue }
                guard let option = agent.latestConfigOptions.first(where: { $0.id == configID }) else {
                    continue // agent does not advertise this option: keep its default
                }
                guard option.currentValue != requestedValue else { continue }
                // Only send values the agent currently offers; a stale
                // selection (agent's catalog changed) falls back silently.
                guard option.options.contains(where: { $0.value == requestedValue }) else { continue }
                try agent.setConfigOption(
                    sessionID: session.sessionId,
                    requestID: nextRequestID,
                    configID: configID,
                    value: requestedValue
                )
                nextRequestID += 1
            }
            try agent.prompt(
                sessionID: session.sessionId,
                requestID: nextRequestID,
                text: instructions + "\n\n" + userPrompt
            )
            agent.shutdown()
            let text = agent.assembledText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw MeetingSummaryError.emptyResponse(backend: backendName)
            }
            return text
        } catch {
            agent.shutdown()
            logger.error("acp session failed: \(error.localizedDescription, privacy: .public)\(agent.stderrSuffix(), privacy: .public)")
            throw error
        }
    }

    private nonisolated static func runSessionProbe(
        command: String,
        timeout: TimeInterval
    ) throws -> [ACPConfigOption] {
        let agent = try AgentProcess(command: command, timeout: timeout)
        do {
            let session = try agent.startSession()
            // A config_option_update notification may trail the session/new
            // response; prefer the freshest advertised list.
            agent.drainConfigOptionNotifications()
            agent.shutdown()
            return agent.latestConfigOptions.isEmpty
                ? session.configOptions
                : agent.latestConfigOptions
        } catch {
            agent.shutdown()
            logger.error("acp options probe failed: \(error.localizedDescription, privacy: .public)\(agent.stderrSuffix(), privacy: .public)")
            throw error
        }
    }
}

/// One live ACP agent subprocess plus the synchronous JSON-RPC plumbing that
/// drives it: initialize -> session/new -> optional set_config_option ->
/// session/prompt. stdout is drained continuously (never only while awaiting
/// a response) so a chatty agent can never fill the 64KB pipe buffer and
/// deadlock; a bounded stderr buffer is kept for diagnostics. Lives exactly
/// one summary/probe session and must be shut down (stdin close + optional
/// terminate) via `shutdown()` on every exit path.
private final class AgentProcess {
    private static let maxLoggedStandardErrorBytes = 4096

    private let process = Process()
    private let stdoutLock = NSLock()
    private var stdoutData = Data()
    private let stdoutPipe = Pipe()
    private let stderrLock = NSLock()
    private var stderrData = Data()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private let terminationSemaphore = DispatchSemaphore(value: 0)
    private var exitStatus: Int32 = -1
    private let deadline: Date
    private var pendingLine = Data() // bytes past the last newline
    private var sessionEnded = false
    private(set) var assembledText = ""
    /// The agent's latest full config option list: seeded from the
    /// session/new response and refreshed by set_config_option responses and
    /// config_option_update notifications (the response and/or a trailing
    /// notification are both authoritative replacements).
    private(set) var latestConfigOptions: [ACPConfigOption] = []

    init(command: String, timeout: TimeInterval) throws {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw MeetingSummaryError.backendFailed(
                backend: "ACP Agent",
                statusCode: nil,
                message: "No ACP agent command configured. Enter one in Settings."
            )
        }
        let parts = trimmedCommand.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = parts.first, !first.isEmpty else {
            throw ACPError.missingCommand
        }

        deadline = Date().addingTimeInterval(timeout)

        if first.hasPrefix("/") {
            // Absolute path: exec directly so the app never depends on PATH.
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: first), fileManager.isExecutableFile(atPath: first) else {
                throw MeetingSummaryError.backendFailed(
                    backend: "ACP Agent",
                    statusCode: nil,
                    message: "ACP agent command not found or not executable: \(first)"
                )
            }
            process.executableURL = URL(fileURLWithPath: first)
            process.arguments = Array(parts.dropFirst())
        } else {
            // Bare command: /usr/bin/env resolves it against the app's PATH
            // (launchd-spawned processes may inherit a minimal PATH).
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = parts
        }
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        // Continuous stdout drain: readabilityHandler appends raw bytes under
        // a lock; the session loop parses complete lines between polls.
        process.standardOutput = stdoutPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stdoutLock.lock()
            stdoutData.append(chunk)
            stdoutLock.unlock()
        }

        // Bounded stderr buffer for diagnostics (MeetingHookRunner precedent).
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stderrLock.lock()
            if stderrData.count + chunk.count > Self.maxLoggedStandardErrorBytes {
                stderrData.removeAll(keepingCapacity: true)
                stderrData.append(chunk.suffix(Self.maxLoggedStandardErrorBytes))
            } else {
                stderrData.append(chunk)
            }
            stderrLock.unlock()
        }

        process.standardInput = stdinPipe
        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            exitStatus = terminated.terminationStatus
            terminationSemaphore.signal()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error // NSError; callers map it to a retryable request failure
        }
    }

    /// Runs initialize + session/new and returns the session, seeding
    /// `latestConfigOptions` from the response (the authoritative list).
    func startSession() throws -> ACPAgentSession {
        try writeRequest(id: 0, method: "initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": [:],
            "clientInfo": [
                "name": AppIdentity.displayName,
                "version": AppIdentity.marketingVersion,
            ],
        ])
        _ = try waitForResponse(requestID: 0)

        try writeRequest(id: 1, method: "session/new", params: [
            "cwd": AppIdentity.supportDirectoryURL.path,
            "mcpServers": [],
        ])
        let sessionResult = try waitForResponse(requestID: 1)
        let session: ACPAgentSession
        do {
            let data = try JSONSerialization.data(withJSONObject: sessionResult)
            session = try JSONDecoder().decode(ACPAgentSession.self, from: data)
        } catch {
            throw ACPError.invalidResponse("ACP agent did not return a parseable session result.")
        }
        guard !session.sessionId.isEmpty else {
            throw ACPError.invalidResponse("ACP agent did not return a session id.")
        }
        latestConfigOptions = session.configOptions
        return session
    }

    /// Sends one session/set_config_option and keeps `latestConfigOptions`
    /// fresh: the response's configOptions (when present) replace it, then a
    /// short drain absorbs a trailing config_option_update notification.
    func setConfigOption(sessionID: String, requestID: Int, configID: String, value: String) throws {
        try writeRequest(id: requestID, method: "session/set_config_option", params: [
            "sessionId": sessionID,
            "configId": configID,
            "value": value,
        ])
        let result = try waitForResponse(requestID: requestID)
        applyConfigOptions(from: result["configOptions"])
        drainConfigOptionNotifications()
    }

    /// Sends session/prompt and validates the end_turn stop reason. Message
    /// chunks emitted before the response accumulate into `assembledText`.
    func prompt(sessionID: String, requestID: Int, text: String) throws {
        try writeRequest(id: requestID, method: "session/prompt", params: [
            "sessionId": sessionID,
            "prompt": [
                ["type": "text", "text": text],
            ],
        ])
        let promptResult = try waitForResponse(requestID: requestID)

        let stopReason = (promptResult["stopReason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard stopReason == "end_turn" else {
            let reason = stopReason.isEmpty ? "unknown" : stopReason
            throw ACPError.invalidResponse("ACP agent stopped without notes (stop reason: \(reason)).")
        }
    }

    /// Briefly keeps parsing after a response so a config_option_update
    /// notification that trails it is absorbed into `latestConfigOptions`.
    func drainConfigOptionNotifications() {
        let drainDeadline = Date().addingTimeInterval(0.25)
        while Date() < drainDeadline {
            _ = try? parseIncoming(takeStdout())
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func applyConfigOptions(from raw: Any?) {
        guard let raw,
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let options = try? JSONDecoder().decode([ACPConfigOption].self, from: data) else {
            return
        }
        latestConfigOptions = options
    }

    private func takeStdout() -> Data {
        stdoutLock.lock()
        let data = stdoutData
        stdoutData.removeAll(keepingCapacity: true)
        stdoutLock.unlock()
        return data
    }

    func stderrSuffix() -> String {
        stderrLock.lock()
        let data = stderrData
        stderrLock.unlock()
        guard let value = String(data: data, encoding: .utf8) else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let singleLine = trimmed
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return " stderr=\(singleLine)"
    }

    private func terminateProcess() {
        guard !sessionEnded else { return }
        if process.isRunning {
            process.terminate()
            if terminationSemaphore.wait(timeout: .now() + .seconds(1)) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = terminationSemaphore.wait(timeout: .now() + .seconds(1))
            }
        }
        sessionEnded = true
    }

    /// Closes stdin and gives the agent a short grace period to exit on EOF,
    /// terminating it if needed. Idempotent.
    func shutdown() {
        try? stdinPipe.fileHandleForWriting.close()
        if !sessionEnded {
            if terminationSemaphore.wait(timeout: .now() + .seconds(2)) == .timedOut {
                terminateProcess()
            } else {
                sessionEnded = true
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    /// Parses any buffered complete lines (plus newly arrived bytes) and
    /// returns the first JSON-RPC response envelope encountered. "session/
    /// update" notifications accumulate text chunks into assembledText and
    /// config_option_update payloads refresh latestConfigOptions.
    private func parseIncoming(_ newBytes: Data?) throws -> [String: Any]? {
        if let newBytes {
            pendingLine.append(newBytes)
        }
        var responseEnvelope: [String: Any]? = nil
        let newline = Data([0x0A])
        while let range = pendingLine.firstRange(of: newline) {
            let lineData = pendingLine.subdata(in: pendingLine.startIndex..<range.lowerBound)
            pendingLine.removeSubrange(pendingLine.startIndex...range.lowerBound)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
            else {
                continue // tolerate non-JSON agent chatter on stdout
            }
            if object["method"] as? String == "session/update" {
                if let params = object["params"] as? [String: Any],
                   let update = params["update"] as? [String: Any],
                   let sessionUpdate = update["sessionUpdate"] as? String {
                    if sessionUpdate == "agent_message_chunk",
                       let content = update["content"] as? [String: Any],
                       let text = content["text"] as? String {
                        assembledText.append(text)
                    } else if sessionUpdate == "config_option_update" {
                        applyConfigOptions(from: update["configOptions"])
                    }
                }
                continue
            }
            if object["id"] != nil {
                responseEnvelope = object // responses carry "id"; notifications do not
                break
            }
        }
        return responseEnvelope
    }

    private func responseResult(_ envelope: [String: Any], requestID: Int) throws -> [String: Any] {
        if let error = envelope["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? String(describing: error)
            throw ACPError.invalidResponse("ACP agent returned an error for request \(requestID): \(message)")
        }
        guard let result = envelope["result"] as? [String: Any] else {
            throw ACPError.invalidResponse("ACP agent returned a malformed response for request \(requestID).")
        }
        return result
    }

    /// Waits until the response for `requestID` arrives, draining and
    /// parsing stdout the whole time. Throws on cancellation, deadline
    /// expiry, or premature agent exit.
    private func waitForResponse(requestID: Int) throws -> [String: Any] {
        while true {
            if Task.isCancelled {
                terminateProcess()
                throw CancellationError()
            }
            if Date() > deadline {
                terminateProcess()
                throw ACPError.timedOut
            }
            if let envelope = try parseIncoming(takeStdout()) {
                return try responseResult(envelope, requestID: requestID)
            }
            if terminationSemaphore.wait(timeout: .now()) == .success {
                sessionEnded = true
                // Final drain: the agent may have written its last lines
                // just before exiting.
                if let envelope = try parseIncoming(takeStdout()) {
                    return try responseResult(envelope, requestID: requestID)
                }
                throw ACPError.agentExit(exitStatus)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func writeRequest(id: Int, method: String, params: [String: Any]) throws {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        envelope["params"] = params
        let payload = try JSONSerialization.data(withJSONObject: envelope)
        try stdinPipe.fileHandleForWriting.write(contentsOf: payload)
        try stdinPipe.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
    }
}
