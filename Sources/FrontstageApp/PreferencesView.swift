#if os(macOS)
import SwiftUI
import AppKit
import FrontstageCore

struct PreferencesView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0
    @State private var selectedElement: ScreenplayElement = .action
    @State private var fontSearch = ""

    private var allSystemFonts: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    private var filteredFonts: [String] {
        let trimmed = fontSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return allSystemFonts
        } else {
            return allSystemFonts.filter { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    private var layout: ScriptLayoutSettings {
        workspace.project.scriptLayout
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Preferences")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") {
                    workspace.showPreferences = false
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Segmented tab bar
            Picker("", selection: $selectedTab) {
                Text("Script Typography").tag(0)
                Text("General Settings").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            Divider()

            if selectedTab == 0 {
                typographyTab
            } else {
                generalTab
            }
        }
        .frame(width: 820, height: 670)
        .background(Color(boardHex: WorkspaceDesign.panelColor))
    }

    // MARK: - Typography Tab
    private var typographyTab: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                globalTypographySection
                elementTypographySection
                previewSection
            }
            .padding(20)
        }
    }

    // MARK: - Global Typography Section
    private var globalTypographySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("GLOBAL SCRIPT TYPOGRAPHY")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Industry Standard") {
                        workspace.updateScriptLayout {
                            $0.fontName = "Courier"
                            $0.fontSize = 12.0
                            $0.lineHeight = 14.0
                            $0.paragraphSpacing = 10.0
                            $0.elements.removeAll()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base Font (\(allSystemFonts.count) installed)").font(.caption.weight(.medium))
                        Picker("", selection: Binding(
                            get: { layout.fontName },
                            set: { name in workspace.updateScriptLayout { $0.fontName = name } }
                        )) {
                            ForEach(filteredFonts, id: \.self) { font in
                                Text(font).tag(font)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)

                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.secondary)
                            TextField("Filter fonts...", text: $fontSearch)
                                .textFieldStyle(.plain)
                                .font(.caption2)
                        }
                        .padding(4)
                        .background(Color(white: 0.16))
                        .cornerRadius(4)
                        .frame(width: 220)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base Size: \(Int(layout.fontSize)) pt").font(.caption.weight(.medium))
                        HStack(spacing: 6) {
                            Stepper("", value: Binding(
                                get: { layout.fontSize },
                                set: { size in workspace.updateScriptLayout {
                                    $0.fontSize = size
                                    $0.lineHeight = max(size, $0.lineHeight)
                                }}
                            ), in: 9...28, step: 1)
                            .labelsHidden()

                            TextField("Size", value: Binding(
                                get: { layout.fontSize },
                                set: { size in workspace.updateScriptLayout {
                                    $0.fontSize = size
                                    $0.lineHeight = max(size, $0.lineHeight)
                                }}
                            ), format: .number)
                            .frame(width: 48)
                            .textFieldStyle(.roundedBorder)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Line Height: \(Int(layout.lineHeight)) pt").font(.caption.weight(.medium))
                        HStack(spacing: 6) {
                            Stepper("", value: Binding(
                                get: { layout.lineHeight },
                                set: { h in workspace.updateScriptLayout { $0.lineHeight = h } }
                            ), in: 10...40, step: 1)
                            .labelsHidden()

                            TextField("Height", value: Binding(
                                get: { layout.lineHeight },
                                set: { h in workspace.updateScriptLayout { $0.lineHeight = h } }
                            ), format: .number)
                            .frame(width: 48)
                            .textFieldStyle(.roundedBorder)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paragraph: \(Int(layout.paragraphSpacing)) pt").font(.caption.weight(.medium))
                        HStack(spacing: 6) {
                            Stepper("", value: Binding(
                                get: { layout.paragraphSpacing },
                                set: { s in workspace.updateScriptLayout { $0.paragraphSpacing = s } }
                            ), in: 0...30, step: 1)
                            .labelsHidden()

                            TextField("Spacing", value: Binding(
                                get: { layout.paragraphSpacing },
                                set: { s in workspace.updateScriptLayout { $0.paragraphSpacing = s } }
                            ), format: .number)
                            .frame(width: 48)
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            .padding(12)
        } label: {
            Label("Default Script Formatting", systemImage: "textformat")
        }
    }

    // MARK: - Per-Element Typography Section
    private var elementTypographySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("PER-ELEMENT STYLES & OVERRIDES")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if layout.elements[selectedElement.rawValue] != nil {
                        Button("Clear Overrides for \(selectedElement.label)") {
                            workspace.updateScriptLayout {
                                $0.elements.removeValue(forKey: selectedElement.rawValue)
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                }

                // Element selection chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ScreenplayElement.editable, id: \.self) { elem in
                            let isOverridden = layout.elements[elem.rawValue] != nil
                            let isTamil = layout.isTamil(for: elem)
                            Button {
                                selectedElement = elem
                            } label: {
                                HStack(spacing: 5) {
                                    Text(elem.label)
                                    if isTamil {
                                        Text("த")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.orange.opacity(0.85))
                                            .foregroundStyle(.black)
                                            .cornerRadius(3)
                                    } else if isOverridden {
                                        Circle()
                                            .fill(Color.accentColor)
                                            .frame(width: 6, height: 6)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(selectedElement == elem ? Color.accentColor : Color(white: 0.22))
                                .foregroundStyle(selectedElement == elem ? .white : .primary)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Divider()

                // Overrides editor for the selected element
                let elemTypography = layout.elements[selectedElement.rawValue]

                HStack(alignment: .top, spacing: 20) {
                    // Font family override
                    VStack(alignment: .leading, spacing: 6) {
                        let hasCustomFont = elemTypography?.fontName != nil
                        Toggle("Custom Font", isOn: Binding(
                            get: { hasCustomFont },
                            set: { enable in
                                workspace.updateScriptLayout {
                                    var current = $0.elements[selectedElement.rawValue] ?? ElementTypography()
                                    current.fontName = enable ? $0.fontName : nil
                                    $0.elements[selectedElement.rawValue] = current
                                }
                            }
                        ))
                        .font(.caption.weight(.medium))

                        if hasCustomFont {
                            Picker("", selection: Binding(
                                get: { elemTypography?.fontName ?? layout.fontName },
                                set: { name in
                                    workspace.updateScriptLayout {
                                        var current = $0.elements[selectedElement.rawValue] ?? ElementTypography()
                                        current.fontName = name
                                        $0.elements[selectedElement.rawValue] = current
                                    }
                                }
                            )) {
                                ForEach(filteredFonts, id: \.self) { font in
                                    Text(font).tag(font)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                        } else {
                            Text("Inheriting base: \(layout.fontName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Font size override
                    VStack(alignment: .leading, spacing: 6) {
                        let hasCustomSize = elemTypography?.fontSize != nil
                        Toggle("Custom Size", isOn: Binding(
                            get: { hasCustomSize },
                            set: { enable in
                                workspace.updateScriptLayout {
                                    var current = $0.elements[selectedElement.rawValue] ?? ElementTypography()
                                    current.fontSize = enable ? $0.fontSize : nil
                                    $0.elements[selectedElement.rawValue] = current
                                }
                            }
                        ))
                        .font(.caption.weight(.medium))

                        if hasCustomSize {
                            let sizeVal = elemTypography?.fontSize ?? layout.fontSize
                            HStack(spacing: 6) {
                                Stepper("", value: Binding(
                                    get: { sizeVal },
                                    set: { newSize in
                                        workspace.updateScriptLayout {
                                            var current = $0.elements[selectedElement.rawValue] ?? ElementTypography()
                                            current.fontSize = newSize
                                            $0.elements[selectedElement.rawValue] = current
                                        }
                                    }
                                ), in: 8...36, step: 1)
                                .labelsHidden()

                                TextField("Size", value: Binding(
                                    get: { sizeVal },
                                    set: { newSize in
                                        workspace.updateScriptLayout {
                                            var current = $0.elements[selectedElement.rawValue] ?? ElementTypography()
                                            current.fontSize = newSize
                                            $0.elements[selectedElement.rawValue] = current
                                        }
                                    }
                                ), format: .number)
                                .frame(width: 48)
                                .textFieldStyle(.roundedBorder)
                                Text("pt").font(.caption)
                            }
                        } else {
                            Text("Inheriting base: \(Int(layout.fontSize)) pt")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Style toggles (Bold, Italic, Underline, Uppercase, Tamil)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Style Traits & Language").font(.caption.weight(.medium))

                        HStack(spacing: 10) {
                            Toggle(isOn: Binding(
                                get: { layout.isBold(for: selectedElement) },
                                set: { b in
                                    workspace.updateScriptLayout {
                                        var current = $0.elements[selectedElement.rawValue] ?? ElementTypography()
                                        current.isBold = b
                                        $0.elements[selectedElement.rawValue] = current
                                    }
                                }
                            )) {
                                Text("Bold").fontWeight(.bold)
                            }

                            Toggle(isOn: Binding(
                                get: { layout.isItalic(for: selectedElement) },
                                set: { i in
                                    workspace.updateScriptLayout {
                                        var current = $0.elements[selectedElement.rawValue] ?? ElementTypography()
                                        current.isItalic = i
                                        $0.elements[selectedElement.rawValue] = current
                                    }
                                }
                            )) {
                                Text("Italic").italic()
                            }

                            Toggle(isOn: Binding(
                                get: { layout.isUnderline(for: selectedElement) },
                                set: { u in
                                    workspace.updateScriptLayout {
                                        var current = $0.elements[selectedElement.rawValue] ?? ElementTypography()
                                        current.isUnderline = u
                                        $0.elements[selectedElement.rawValue] = current
                                    }
                                }
                            )) {
                                Text("Underline").underline()
                            }

                            Toggle(isOn: Binding(
                                get: { layout.isUppercase(for: selectedElement) },
                                set: { cap in
                                    workspace.updateScriptLayout {
                                        var current = $0.elements[selectedElement.rawValue] ?? ElementTypography()
                                        current.isUppercase = cap
                                        $0.elements[selectedElement.rawValue] = current
                                    }
                                }
                            )) {
                                Text("CAPS")
                            }

                            // Tamil button
                            Toggle(isOn: Binding(
                                get: { layout.isTamil(for: selectedElement) },
                                set: { t in
                                    workspace.updateScriptLayout {
                                        var current = $0.elements[selectedElement.rawValue] ?? ElementTypography()
                                        current.isTamil = t
                                        if t && (current.fontName == nil || current.fontName?.isEmpty == true) {
                                            current.fontName = "Tamil Sangam MN"
                                        }
                                        $0.elements[selectedElement.rawValue] = current
                                    }
                                }
                            )) {
                                HStack(spacing: 3) {
                                    Text("த").fontWeight(.bold)
                                    Text("Tamil")
                                }
                            }
                            .help("When editing \(selectedElement.label), automatically switches macOS keyboard to Tamil input and renders native Tamil font.")
                        }
                        .font(.caption)

                        if layout.isTamil(for: selectedElement) {
                            Text("✓ Mac Tamil input will activate automatically when typing this element.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.top, 2)
                        }
                    }
                }
            }
            .padding(12)
        } label: {
            Label("Element-Specific Formatting", systemImage: "character.cursor.ibeam")
        }
    }

    // MARK: - Live Preview Section
    private var previewSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("LIVE SCREENPLAY PREVIEW")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Paper view with current fonts and sizes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // White screenplay paper mockup
                VStack(alignment: .leading, spacing: CGFloat(layout.paragraphSpacing)) {
                    // Slugline
                    previewLine(
                        element: .sceneHeading,
                        english: "INT. COFFEE SHOP - DAY",
                        tamil: "INT. காபி ஷாப் - DAY"
                    )

                    // Action
                    previewLine(
                        element: .action,
                        english: "A car was going for 150 km/hr. Inside the car a young girl was wounded heavily.",
                        tamil: "கார் 150 கி.மீ வேகத்தில் சென்றது. உள்ளே ஒரு பெண் பலத்த காயமடைந்திருந்தாள்."
                    )

                    // Character
                    previewLine(
                        element: .character,
                        english: "CODEX",
                        tamil: "கோடெக்ஸ்",
                        indent: 140
                    )

                    // Dialogue
                    previewLine(
                        element: .dialogue,
                        english: "Drive faster, we don't have much time.",
                        tamil: "வேகமாக ஓட்டு, நமக்கு அதிக நேரம் இல்லை.",
                        indent: 80
                    )

                    // Character
                    previewLine(
                        element: .character,
                        english: "CLAUDE",
                        tamil: "கிளாட்",
                        indent: 140
                    )

                    // Parenthetical
                    previewLine(
                        element: .parenthetical,
                        english: "(whispering)",
                        tamil: "(மெல்லிய குரலில்)",
                        indent: 110
                    )

                    // Dialogue
                    previewLine(
                        element: .dialogue,
                        english: "Don't panic. Keep her awake, we are almost there.",
                        tamil: "பயப்படாதே. அவளை விழித்திருக்க வை, நாம் அடைந்துவிட்டோம்.",
                        indent: 80
                    )

                    // Transition
                    HStack {
                        Spacer()
                        previewLine(
                            element: .transition,
                            english: "CUT TO:",
                            tamil: "காட்சி மாற்றம்:"
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white)
                .cornerRadius(6)
                .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
            }
            .padding(12)
        } label: {
            Label("Real-time Screenplay Preview", systemImage: "eye")
        }
    }

    @ViewBuilder
    private func previewLine(element: ScreenplayElement, english: String, tamil: String, indent: CGFloat = 0) -> some View {
        let isTamil = layout.isTamil(for: element)
        let fontName = layout.effectiveFontName(for: element)
        let resolvedFont = isTamil && (layout.elements[element.rawValue]?.fontName == nil || fontName == layout.fontName) ? "Tamil Sangam MN" : fontName
        let fontSize = layout.effectiveFontSize(for: element)
        let isBold = layout.isBold(for: element)
        let isItalic = layout.isItalic(for: element)
        let isUnderline = layout.isUnderline(for: element)
        let isUpper = layout.isUppercase(for: element)

        let text = isTamil ? tamil : english
        let displayText = isUpper ? text.uppercased() : text

        Text(displayText)
            .font(.custom(resolvedFont, size: fontSize))
            .fontWeight(isBold ? .bold : .regular)
            .italic(isItalic)
            .underline(isUnderline)
            .foregroundStyle(Color.black)
            .padding(.leading, indent)
    }

    // MARK: - General Tab
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Startup & Recent Projects") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Restore last project automatically on launch", isOn: $workspace.restoreLastProjectAutomatically)
                    Text("When enabled, DOT automatically reopens the project you were last working on when the application launches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }

            GroupBox("Page & Export") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Default Paper Size")
                        Spacer()
                        Picker("", selection: $workspace.paper) {
                            ForEach(ScreenplayPaper.allCases, id: \.self) { paper in
                                Text(paper.label).tag(paper)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
                .padding(12)
            }

            GroupBox("Project File Format") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Projects are saved natively with the .frontstage file extension and display the DOT app icon in Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }

            GroupBox("Beat Popup Editor") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The script text inside the Edit Beat popup automatically scales to a comfortable, readable size (15pt+) while retaining your project typography ratios and styling.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }

            Spacer()
        }
        .padding(20)
    }
}
#endif
