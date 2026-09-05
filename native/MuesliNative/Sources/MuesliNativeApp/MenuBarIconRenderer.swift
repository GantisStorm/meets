import AppKit

enum MenuBarIconRenderer {

    private static let displaySize = NSSize(width: 18, height: 18)

    static let options: [(id: String, label: String)] = [
        ("muesli", "M"),
        ("mic.fill", "Microphone"),
        ("waveform", "Waveform"),
        ("bubble.left.fill", "Bubble"),
        ("text.bubble", "Speech Bubble"),
        ("pencil.line", "Pencil"),
        ("brain.head.profile", "Brain"),
        ("sparkles", "Sparkles"),
        ("headphones", "Headphones"),
        ("person.wave.2", "Meeting"),
        ("character.bubble", "Character"),
        ("doc.text", "Document"),
    ]

    /// Returns the configured menu bar/floating indicator icon. The brand
    /// choice is a plain letter "M" drawn as a resolution-independent
    /// template so it adapts to light/dark menu bars.
    static func make(choice: String = "muesli") -> NSImage? {
        if choice == "muesli" {
            return makeMuesliMark()
        }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: choice, accessibilityDescription: "Meets")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    static func hotkeyCueLabel(for hotkey: HotkeyConfig) -> String {
        if hotkey.isCombination {
            return hotkey.label
        }
        switch hotkey.keyCode {
        case 55: return "L⌘"
        case 54: return "R⌘"
        case 63: return "fn"
        case 59: return "L⌃"
        case 62: return "R⌃"
        case 58: return "L⌥"
        case 61: return "R⌥"
        case 56: return "L⇧"
        case 60: return "R⇧"
        default: return hotkey.displayLabel
        }
    }

    static func statusTitle(
        hotkey: HotkeyConfig,
        showsHotkey: Bool = true,
        detail: String? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if showsHotkey {
            result.append(NSAttributedString(
                string: "\u{2009}\(hotkeyCueLabel(for: hotkey))",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                    .baselineOffset: 1,
                ]
            ))
        }
        if let detail, !detail.isEmpty {
            if result.length > 0 {
                result.append(NSAttributedString(string: "  "))
            }
            result.append(NSAttributedString(
                string: detail,
                attributes: [.font: NSFont.menuBarFont(ofSize: 0)]
            ))
        }
        return result
    }

    private static func makeMuesliMark() -> NSImage {
        let image = NSImage(size: displaySize, flipped: false) { rect in
            let fontSize = displaySize.height * 0.8
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph,
            ]
            let glyph = NSAttributedString(string: "M", attributes: attributes)
            let bounds = glyph.boundingRect(
                with: NSSize(width: rect.width, height: rect.height),
                options: [.usesLineFragmentOrigin]
            )
            glyph.draw(
                in: NSRect(
                    x: rect.midX - bounds.width / 2,
                    y: rect.midY - bounds.height / 2,
                    width: bounds.width,
                    height: bounds.height
                )
            )
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func makeBundledMarkFallback() -> NSImage {
        let image = NSImage(
            systemSymbolName: "m.square",
            accessibilityDescription: "Meets"
        ) ?? NSImage(size: displaySize)
        image.size = displaySize
        image.isTemplate = true
        return image
    }

}
