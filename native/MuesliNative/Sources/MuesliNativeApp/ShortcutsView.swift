import SwiftUI
import AppKit
import MuesliCore

struct ShortcutsView: View {
    let appState: AppState
    let controller: MuesliController

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
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Meeting Recording")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Toggle meeting recording on/off")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
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
                .tint(MuesliTheme.accent)
                .labelsHidden()
            }

            Divider()
                .background(MuesliTheme.surfaceBorder)

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
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func hotkeyBadge(_ hotkey: HotkeyConfig) -> some View {
        Text(hotkey.displayLabel)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, MuesliTheme.spacing4)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .help(hotkey.label)
    }

    private func shortcutControls(
        target: ShortcutTarget,
        threshold: Int,
        isEnabled: Bool = true,
        onThresholdChange: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            hotkeyBadge(hotkey(for: target))
            changeButton(for: target)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.55)
            Spacer(minLength: MuesliTheme.spacing16)
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
        HStack(spacing: MuesliTheme.spacing8) {
            Text("Hold")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)

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
            .foregroundStyle(MuesliTheme.textPrimary)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, MuesliTheme.spacing4)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )

            Text("ms")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .help("Hold threshold: \(HotkeyTriggerTiming.minThresholdMilliseconds)-\(HotkeyTriggerTiming.maxThresholdMilliseconds) ms")
    }

    private func shortcutMessage(_ message: String) -> some View {
        Text(message)
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.transcribing)
    }

    private func changeButton(for target: ShortcutTarget) -> some View {
        Button {
            if recordingTarget == target {
                stopRecording()
            } else {
                startRecording(target)
            }
        } label: {
            Text(recordingTarget == target ? recordingPrompt(for: target) : "Change Shortcut")
                .font(MuesliTheme.body())
                .foregroundStyle(recordingTarget == target ? MuesliTheme.accent : MuesliTheme.textPrimary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, MuesliTheme.spacing8)
        .background(recordingTarget == target ? MuesliTheme.accentSubtle : MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(recordingTarget == target ? MuesliTheme.accent.opacity(0.3) : MuesliTheme.surfaceBorder, lineWidth: 1)
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
