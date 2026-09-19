import SwiftUI
import AppKit
import MeetsCore

struct ShortcutsView: View {
    let appState: AppState
    let controller: MeetsController

    /// The standalone page is gone (now a section in Meetings settings);
    /// body stays only for View conformance.
    var body: some View {
        meetingRecordingShortcutSection
    }
    @State private var recordingTarget: ShortcutTarget?
    @State private var eventMonitor: Any?
    @State private var pendingModifierKeyCode: UInt16?
    @State private var meetingRecordingShortcutMessage: String?

    private enum ShortcutTarget {
        case meetingRecording
    }

    /// Section content embedded at the top of the Meetings settings pane.
    /// Carries its own card styling; the pane adds the section header.
    var meetingRecordingShortcutSection: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                    Text("Meeting Recording")
                        .font(MeetsTheme.headline())
                        .foregroundStyle(MeetsTheme.textPrimary)
                    Text("Toggle meeting recording on/off")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textSecondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.config.enableMeetingRecordingHotkey },
                    set: { newValue in
                        let result = controller.updateMeetingRecordingHotkeyEnabled(newValue)
                        meetingRecordingShortcutMessage = result.message
                    }
                ))
                .toggleStyle(.switch)
                .tint(MeetsTheme.accent)
                .labelsHidden()
            }

            Divider()
                .background(MeetsTheme.surfaceBorder)

            shortcutControls(
                target: .meetingRecording,
                threshold: appState.config.meetingRecordingHotkeyTriggerThresholdMS,
                isEnabled: appState.config.enableMeetingRecordingHotkey
            ) { value in
                controller.updateConfig { $0.meetingRecordingHotkeyTriggerThresholdMS = value }
            }

            if let meetingRecordingShortcutMessage {
                shortcutMessage(meetingRecordingShortcutMessage)
            } else if appState.config.enableMeetingRecordingHotkey,
                      let warning = ShortcutHotkeyPolicy.commonGlobalShortcutWarning(for: appState.config.meetingRecordingHotkey) {
                shortcutMessage(warning)
            }
        }
        .onDisappear {
            stopRecording()
        }
        .padding(MeetsTheme.spacing16)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func hotkeyBadge(_ hotkey: HotkeyConfig) -> some View {
        Text(hotkey.displayLabel)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(MeetsTheme.textPrimary)
            .padding(.horizontal, MeetsTheme.spacing12)
            .padding(.vertical, MeetsTheme.spacing4)
            .background(MeetsTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                    .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
            )
            .help(hotkey.label)
    }

    private func shortcutControls(
        target: ShortcutTarget,
        threshold: Int,
        isEnabled: Bool = true,
        onThresholdChange: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: MeetsTheme.spacing12) {
            hotkeyBadge(hotkey(for: target))
            compactChangeButton(for: target)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.55)
            Spacer(minLength: MeetsTheme.spacing16)
            if isEnabled {
                thresholdInput(
                    value: threshold,
                    onChange: onThresholdChange
                )
            }
        }
    }

    private func hotkey(for target: ShortcutTarget) -> HotkeyConfig {
        switch target {
        case .meetingRecording:
            return appState.config.meetingRecordingHotkey
        }
    }

    private func thresholdInput(value: Int, onChange: @escaping (Int) -> Void) -> some View {
        HStack(spacing: MeetsTheme.spacing8) {
            Text("Hold")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)

            TextField(
                "",
                value: Binding(
                    get: { HotkeyTriggerTiming.clampedMilliseconds(value) },
                    set: { onChange(HotkeyTriggerTiming.clampedMilliseconds($0)) }
                ),
                format: .number
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(MeetsTheme.textPrimary)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .padding(.horizontal, MeetsTheme.spacing8)
            .padding(.vertical, MeetsTheme.spacing4)
            .background(MeetsTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                    .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
            )

            Text("ms")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)
        }
        .help("Hold threshold: \(HotkeyTriggerTiming.minThresholdMilliseconds)-\(HotkeyTriggerTiming.maxThresholdMilliseconds) ms")
    }

    private func shortcutMessage(_ message: String) -> some View {
        Text(message)
            .font(MeetsTheme.caption())
            .foregroundStyle(MeetsTheme.transcribing)
    }

    private func compactChangeButton(for target: ShortcutTarget) -> some View {
        Button {
            if recordingTarget == target {
                stopRecording()
            } else {
                startRecording(target)
            }
        } label: {
            Text(recordingTarget == target ? recordingPrompt(for: target) : "Change Shortcut")
                .font(MeetsTheme.body())
                .foregroundStyle(recordingTarget == target ? MeetsTheme.accent : MeetsTheme.textPrimary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MeetsTheme.spacing12)
        .padding(.vertical, MeetsTheme.spacing8)
        .background(recordingTarget == target ? MeetsTheme.accentSubtle : MeetsTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                .strokeBorder(recordingTarget == target ? MeetsTheme.accent.opacity(0.3) : MeetsTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func recordingPrompt(for target: ShortcutTarget) -> String {
        switch target {
        case .meetingRecording:
            return "Press a key or modifier..."
        }
    }

    private func startRecording(_ target: ShortcutTarget) {
        stopRecording()
        clearShortcutMessage(for: target)
        pendingModifierKeyCode = nil
        recordingTarget = target
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [self] event in
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    stopRecording()
                    return nil
                }
                let mods = HotkeyConfig.supportedCombinationModifiers(from: event.modifierFlags)
                let modifierCount = [NSEvent.ModifierFlags.command, .control, .option, .shift]
                    .filter { mods.contains($0) }.count
                guard target == .meetingRecording,
                      modifierCount > 0,
                      HotkeyConfig.letterLabel(for: event.keyCode) != nil else {
                    return event
                }
                pendingModifierKeyCode = nil
                let newConfig = HotkeyConfig.combination(modifiers: mods, keyCode: event.keyCode)
                commitShortcut(newConfig, for: target)
                return nil
            }

            let keyCode = event.keyCode
            guard HotkeyConfig.label(for: keyCode) != nil else { return event }
            let flags = event.modifierFlags
            let isDown: Bool
            switch keyCode {
            case 55, 54: isDown = flags.contains(.command)
            case 56, 60: isDown = flags.contains(.shift)
            case 58, 61: isDown = flags.contains(.option)
            case 59, 62: isDown = flags.contains(.control)
            case 63: isDown = flags.contains(.function)
            default: isDown = false
            }
            if isDown {
                pendingModifierKeyCode = keyCode
            } else if keyCode == pendingModifierKeyCode {
                let newConfig = HotkeyConfig(keyCode: keyCode, label: HotkeyConfig.label(for: keyCode)!)
                pendingModifierKeyCode = nil
                commitShortcut(newConfig, for: target)
            }
            return event
        }
    }

    private func commitShortcut(_ config: HotkeyConfig, for target: ShortcutTarget) {
        let result: ShortcutHotkeyUpdateResult
        switch target {
        case .meetingRecording:
            result = controller.updateMeetingRecordingHotkey(config)
        }
        setShortcutMessage(result.message, for: target)
        stopRecording()
    }

    private func clearShortcutMessage(for target: ShortcutTarget) {
        setShortcutMessage(nil, for: target)
    }

    private func setShortcutMessage(_ message: String?, for target: ShortcutTarget) {
        switch target {
        case .meetingRecording:
            meetingRecordingShortcutMessage = message
        }
    }

    private func stopRecording() {
        recordingTarget = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
