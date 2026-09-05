import Foundation
import os

// ACP (Agent Client Protocol) v1 client over a stdio subprocess.
//
// Spawns the configured agent command (default "omp acp") and drives a
// minimal JSON-RPC session: initialize -> session/new -> session/prompt.
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

enum ACPClient {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "ACPClient")
    private static let backendName = "ACP Agent"
    private static let maxLoggedStandardErrorBytes = 4096

    /// Runs one ACP summary session and returns the agent's assembled text.
    /// The process machinery is synchronous (Pipe readabilityHandler callbacks
    /// fire on a private queue and must not drive async code), so the session
    /// runs on an unstructured Task that inherits cancellation: the wait loop
    /// checks Task.isCancelled, terminates the child, and rethrows
    /// CancellationError so retry wrappers never retry a cancelled turn.
    static func summarize(
        instructions: String,
        userPrompt: String,
        command: String,
        timeout: TimeInterval
    ) async throws -> String {
        let session = Task(priority: .userInitiated) {
            try runSession(instructions: instructions, userPrompt: userPrompt, command: command, timeout: timeout)
        }
        return try await session.value
    }

    private nonisolated static func runSession(
        instructions: String,
        userPrompt: String,
        command: String,
        timeout: TimeInterval
    ) throws -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw MeetingSummaryError.backendFailed(
                backend: backendName,
                statusCode: nil,
                message: "No ACP agent command configured. Enter one in Settings."
            )
        }
        let parts = trimmedCommand.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = parts.first, !first.isEmpty else {
            throw ACPError.missingCommand
        }

        let process = Process()
        if first.hasPrefix("/") {
            // Absolute path: exec directly so the app never depends on PATH.
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: first), fileManager.isExecutableFile(atPath: first) else {
                throw MeetingSummaryError.backendFailed(
                    backend: backendName,
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
        let stdoutLock = NSLock()
        var stdoutData = Data()
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
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
        let stderrLock = NSLock()
        var stderrData = Data()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
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

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        let terminationSemaphore = DispatchSemaphore(value: 0)
        var exitStatus: Int32 = -1
        process.terminationHandler = { terminated in
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

        let deadline = Date().addingTimeInterval(timeout)
        var pendingLine = Data() // bytes past the last newline (session-loop only)
        var assembledText = ""
        var sessionEnded = false

        func takeStdout() -> Data {
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

        func terminateProcess() {
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

        func shutdownProcess() {
            try? stdinPipe.fileHandleForWriting.close()
            if !sessionEnded {
                // Grace period for the agent to exit on stdin EOF.
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
        /// returns the first JSON-RPC response envelope encountered. Chunks
        /// from "session/update" notifications accumulate into assembledText.
        func parseIncoming(_ newBytes: Data?) throws -> [String: Any]? {
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
                       update["sessionUpdate"] as? String == "agent_message_chunk",
                       let content = update["content"] as? [String: Any],
                       let text = content["text"] as? String {
                        assembledText.append(text)
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

        func responseResult(_ envelope: [String: Any], requestID: Int) throws -> [String: Any] {
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
        func waitForResponse(requestID: Int) throws -> [String: Any] {
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

        func writeRequest(id: Int, method: String, params: [String: Any]) throws {
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

        do {
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
            guard let sessionID = sessionResult["sessionId"] as? String, !sessionID.isEmpty else {
                throw ACPError.invalidResponse("ACP agent did not return a session id.")
            }

            try writeRequest(id: 2, method: "session/prompt", params: [
                "sessionId": sessionID,
                "prompt": [
                    ["type": "text", "text": instructions + "\n\n" + userPrompt],
                ],
            ])
            let promptResult = try waitForResponse(requestID: 2)

            let stopReason = (promptResult["stopReason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard stopReason == "end_turn" else {
                let reason = stopReason.isEmpty ? "unknown" : stopReason
                throw ACPError.invalidResponse("ACP agent stopped without notes (stop reason: \(reason)).")
            }

            shutdownProcess()
            let text = assembledText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw MeetingSummaryError.emptyResponse(backend: backendName)
            }
            return text
        } catch {
            shutdownProcess()
            logger.error("acp session failed: \(error.localizedDescription, privacy: .public)\(stderrSuffix(), privacy: .public)")
            throw error
        }
    }
}
