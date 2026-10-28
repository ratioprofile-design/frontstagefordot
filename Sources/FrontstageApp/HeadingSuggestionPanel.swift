#if os(macOS)
import AppKit
import FrontstageCore

private final class HeadingSuggestionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SuggestionRowView: NSView {
    let index: Int
    let text: String
    private let titleLabel = NSTextField(labelWithString: "")
    private let onHover: (Int) -> Void
    private let onClick: (Int) -> Void
    private var trackingAreaRef: NSTrackingArea?

    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    init(index: Int, text: String, onHover: @escaping (Int) -> Void, onClick: @escaping (Int) -> Void) {
        self.index = index
        self.text = text
        self.onHover = onHover
        self.onClick = onClick
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.stringValue = text
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26)
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel("Screenplay suggestion: \(text)")
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover(index)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onClick(index)
    }

    func updateAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            titleLabel.textColor = .white
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = .labelColor
            titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        }
    }
}

/// Autocomplete popup panel with high-contrast keyboard selection and hover support
@MainActor
final class HeadingSuggestionPanel: NSObject {
    private var panel: NSPanel?
    private var choices = [String]()
    private var selected = 0
    private weak var text: NSTextView?
    private var replacement = NSRange(), caret = NSRange()
    private var expected = ""
    private var rowViews = [SuggestionRowView]()
    private var kind = ScreenplayElement.action
    private(set) var isCycling = false
    private var hasPlaced = false
    var isShown: Bool { panel?.isVisible == true }

    func close() {
        if let panel {
            panel.orderOut(nil)
            panel.parent?.removeChildWindow(panel)
        }
        choices = []
        rowViews = []
        hasPlaced = false
    }

    func show(in text: NSTextView, headings: [SceneHeading], names: [String] = [], choices supplied: [ScreenplayElement: [String]] = [:]) {
        close()
        let source = text.string as NSString, caret = text.selectedRange()
        guard let window = text.window, text.isEditable, !text.hasMarkedText(), caret.length == 0, caret.location <= source.length else { return }
        let paragraph = source.paragraphRange(for: caret)
        let line = source.substring(with: paragraph).trimmingCharacters(in: .newlines) as NSString
        let offset = caret.location - paragraph.location
        let explicitElement = source.length > 0 ? (text.attributedString().attribute(.screenplayElement, at: paragraph.location, effectiveRange: nil) as? String).flatMap(ScreenplayElement.init(rawValue:)) : nil
        kind = explicitElement ?? (text.typingAttributes[.screenplayElement] as? String).flatMap(ScreenplayElement.init(rawValue:)) ?? ScreenplayTextCodec.element(in: text.attributedString(), at: min(caret.location, max(0, source.length - 1)))
        guard offset <= line.length else { return }
        let completion: ScreenplayCompletion
        switch kind {
        case .sceneHeading: completion = ScreenplayCompletionRules.heading(line as String, caret: offset, headings: headings)
        case .character: completion = ScreenplayCompletionRules.character(line as String, caret: offset, names: names)
        case .parenthetical: completion = ScreenplayCompletionRules.parenthetical(line as String)
        default:
            let typed = CharacterCue.normalized(line.substring(to: offset))
            completion = ScreenplayCompletion(start: 0, end: line.length, values: (supplied[kind] ?? []).filter { !typed.isEmpty && CharacterCue.normalized($0).hasPrefix(typed) && CharacterCue.normalized($0) != typed })
        }
        choices = Array(completion.values.prefix(12))
        guard !choices.isEmpty else { return }
        self.text = text; self.caret = caret; replacement = NSRange(location: paragraph.location + completion.start, length: completion.end - completion.start)
        expected = source.substring(with: replacement); selected = 0; hasPlaced = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        rowViews.removeAll()
        for (index, choice) in choices.enumerated() {
            let row = SuggestionRowView(index: index, text: choice, onHover: { [weak self] idx in
                self?.selected = idx
                self?.highlight()
            }, onClick: { [weak self] idx in
                self?.selected = idx
                self?.acceptChoice(advance: true)
            })
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 260).isActive = true
            stack.addArrangedSubview(row)
            rowViews.append(row)
        }

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 8
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        visualEffect.layer?.borderWidth = 1

        visualEffect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
        ])

        let size = NSSize(width: 272, height: CGFloat(choices.count) * 28 + 14)
        let popup = panel ?? HeadingSuggestionWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel = popup
        popup.isReleasedWhenClosed = false
        popup.contentView = visualEffect
        popup.hasShadow = true
        popup.level = .popUpMenu
        popup.backgroundColor = .clear
        popup.isOpaque = false

        let anchor = text.firstRect(forCharacterRange: caret, actualRange: nil), screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let x = max(screen.minX, min(anchor.minX, screen.maxX - size.width))
        let y = anchor.minY - size.height - 4 >= screen.minY ? anchor.minY - size.height - 4 : min(screen.maxY - size.height, anchor.maxY + 4)
        popup.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        highlight()
        window.addChildWindow(popup, ordered: .above)
        popup.orderFront(nil)
    }

    private func highlight() {
        for (index, row) in rowViews.enumerated() {
            row.isSelected = (index == selected)
        }
    }

    private func cycleChoice(forward: Bool) {
        guard !choices.isEmpty else { return }
        if !hasPlaced {
            hasPlaced = true
            if !forward {
                selected = (selected + choices.count - 1) % choices.count
            }
        } else {
            if forward {
                selected = (selected + 1) % choices.count
            } else {
                selected = (selected + choices.count - 1) % choices.count
            }
        }
        highlight()
        placeCurrentChoice()
    }

    private func placeCurrentChoice() {
        guard let text, text.isEditable, choices.indices.contains(selected) else { return }
        var value = choices[selected]
        isCycling = true
        defer { isCycling = false }

        // If inserting a parenthesized voice extension on a character line without a preceding space, add one.
        if kind == .character && value.hasPrefix("(") && replacement.location > 0 {
            let prevChar = (text.string as NSString).substring(with: NSRange(location: replacement.location - 1, length: 1))
            if prevChar != " " && prevChar != "\n" {
                value = " " + value
            }
        }

        text.window?.makeFirstResponder(text)
        text.insertText(value, replacementRange: replacement)

        replacement = NSRange(location: replacement.location, length: value.utf16.count)
        expected = value
        caret = NSRange(location: NSMaxRange(replacement), length: 0)
        text.setSelectedRange(caret)
    }

    private func acceptChoice(advance: Bool) {
        if !hasPlaced {
            placeCurrentChoice()
        }
        let isCharacter = kind == .character
        let textView = text
        close()
        if advance, isCharacter, let textView {
            (textView as? ScreenplayTextView)?.screenplayController?.handleCommand(#selector(NSResponder.insertNewline(_:)), in: textView)
        }
    }

    func handle(_ selector: Selector) -> Bool {
        guard isShown, !choices.isEmpty else { return false }
        if selector == #selector(NSResponder.insertTab(_:)) {
            cycleChoice(forward: true)
            return true
        }
        if selector == #selector(NSResponder.insertBacktab(_:)) {
            cycleChoice(forward: false)
            return true
        }
        if selector == #selector(NSResponder.moveDown(_:)) {
            selected = (selected + 1) % choices.count
            highlight()
            if hasPlaced { placeCurrentChoice() }
            return true
        }
        if selector == #selector(NSResponder.moveUp(_:)) {
            selected = (selected + choices.count - 1) % choices.count
            highlight()
            if hasPlaced { placeCurrentChoice() }
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            acceptChoice(advance: true)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        close()
        return false
    }
}
#endif
