import Foundation
import SwiftUI

// Auto-discovery for installed ACP (Agent Client Protocol) agent commands.
//
// The Command dropdown in Meeting Summaries / Transcript Cleanup (and the
// onboarding wizard) lists agents whose launcher resolves on this Mac, so the
// user picks instead of typing. Each entry stores a plain command string in
// `AppConfig.acpAgentCommand` (same format as before: split on whitespace at
// spawn, bare names resolved via /usr/bin/env), so existing configs and the
// Custom… free-text fallback keep working unchanged.
//
// Sources for the candidate launchers:
// - `omp acp`: this harness's own CLI (the historical default).
// - `opencode acp`: native ACP server (opencode.ai/docs/acp).
// - `gemini --acp`: native ACP server (gemini-cli docs; --experimental-acp
//   is deprecated).
// - `claude-agent-acp` / `codex-acp`: ACP adapters, either installed globally
//   or fetched on demand via `npx -y`.
// Presence is checked by executable lookup only — nothing is spawned.

struct ACPAgentCommand: Equatable {
    /// Short unique dropdown label.
    let label: String
    /// Exact string stored in config (executable + args).
    let command: String
}

enum ACPAgentDiscovery {
    /// Extra lookup dirs beyond $PATH. GUI apps inherit a sparse PATH that
    /// usually lacks Homebrew / user bins where these CLIs actually live.
    private static var searchDirectories: [String] {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            let homeNSString = home as NSString
            // ~/.local/bin (claude/codex installers), ~/.bun/bin (bun shims
            // such as omp), ~/.npm-global/bin (npm -g with a user prefix).
            for subpath in [".local/bin", ".bun/bin", ".npm-global/bin"] {
                dirs.append(homeNSString.appendingPathComponent(subpath))
            }
        }
        var seen = Set<String>()
        return dirs.filter { dir in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir),
                  isDir.boolValue, seen.insert(dir).inserted else { return false }
            return true
        }
    }

    private static func resolveExecutable(_ name: String) -> Bool {
        if name.hasPrefix("/") || name.hasPrefix("~") {
            let path = (name as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path)
        }
        return searchDirectories.contains {
            FileManager.default.isExecutableFile(atPath: ($0 as NSString).appendingPathComponent(name))
        }
    }

    /// Agents installed on this Mac, most-preferred first. Pure and cheap
    /// (a handful of stat calls) — safe to evaluate during view rendering so
    /// the list is always fresh, no caching or refresh button needed.
    static func discoveredCommands() -> [ACPAgentCommand] {
        var found: [ACPAgentCommand] = []
        if resolveExecutable("omp") {
            found.append(ACPAgentCommand(label: "omp", command: "omp acp"))
        }
        if resolveExecutable("opencode") {
            found.append(ACPAgentCommand(label: "OpenCode", command: "opencode acp"))
        }
        if resolveExecutable("gemini") {
            found.append(ACPAgentCommand(label: "Gemini CLI", command: "gemini --acp"))
        }
        if resolveExecutable("claude-agent-acp") {
            found.append(ACPAgentCommand(label: "Claude Code", command: "claude-agent-acp"))
        } else if resolveExecutable("npx") {
            found.append(ACPAgentCommand(
                label: "Claude Code",
                command: "npx -y @agentclientprotocol/claude-agent-acp"
            ))
        }
        if resolveExecutable("codex-acp") {
            found.append(ACPAgentCommand(label: "Codex", command: "codex-acp"))
        } else if resolveExecutable("npx") {
            found.append(ACPAgentCommand(
                label: "Codex",
                command: "npx -y @agentclientprotocol/codex-acp"
            ))
        }
        return found
    }
}

/// Dropdown of discovered ACP agents + Custom… free-text fallback. Shared by
/// the Meeting Summaries and Transcript Cleanup Command rows and the
/// onboarding wizard so all three stay identical.
struct ACPCommandPicker: View {
    private static let customLabel = "Custom…"

    let appState: AppState
    let controller: MeetsController
    var popupHeight: CGFloat = 24
    var fieldHeight: CGFloat = 22

    var body: some View {
        let discovered = ACPAgentDiscovery.discoveredCommands()
        let current = appState.config.acpAgentCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = discovered.first(where: { $0.command == current })?.label
            ?? Self.customLabel
        VStack(alignment: .trailing, spacing: 6) {
            FixedWidthPopUp(
                selection: selection,
                options: discovered.map(\.label) + [Self.customLabel]
            ) { label in
                guard label != Self.customLabel,
                      let match = discovered.first(where: { $0.label == label })
                else { return }
                controller.updateConfig { $0.acpAgentCommand = match.command }
            }
            .frame(height: popupHeight)
            if selection == Self.customLabel {
                PastableTextField(
                    text: appState.config.acpAgentCommand,
                    placeholder: "omp acp",
                    onChange: { val in controller.updateConfig { $0.acpAgentCommand = val } }
                )
                .frame(height: fieldHeight)
            }
        }
    }
}
