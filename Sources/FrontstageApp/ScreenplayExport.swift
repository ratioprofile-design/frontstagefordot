#if os(macOS)
import AppKit
import FrontstageCore
import UniformTypeIdentifiers

@MainActor
enum ScreenplayFDX {
    static func render(_ project: Project) throws -> Data {
        var paragraphs = ""
        for segment in try project.orderedScript() {
            let scene = segment.scene
            let headingText = scene.heading.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let sceneNum = segment.number.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Scene Heading paragraph
            paragraphs += "    <Paragraph Type=\"Scene Heading\">\n"
            if !sceneNum.isEmpty {
                paragraphs += "      <SceneProperties Number=\"\(OfficeArchive.xml(sceneNum))\" Title=\"\(OfficeArchive.xml(headingText))\"/>\n"
            } else {
                paragraphs += "      <SceneProperties Title=\"\(OfficeArchive.xml(headingText))\"/>\n"
            }
            paragraphs += "      <Text>\(OfficeArchive.xml(headingText))</Text>\n"
            paragraphs += "    </Paragraph>\n"

            // Scene body paragraphs
            let text = DialoguePresentation.materialized(try ScreenplayTextCodec.decode(scene.html))
            let source = text.string as NSString
            var offset = 0
            while offset < text.length {
                let range = source.paragraphRange(for: NSRange(location: offset, length: 0))
                let element = ScreenplayTextCodec.element(in: text, at: offset)
                let dual = text.attribute(.screenplayDualDialogue, at: offset, effectiveRange: nil) as? String
                let dualAttr = dual != nil ? " DualDialogue=\"True\"" : ""
                let pType: String
                switch element {
                case .sceneHeading: pType = "Scene Heading"
                case .action: pType = "Action"
                case .character: pType = "Character"
                case .parenthetical: pType = "Parenthetical"
                case .dialogue: pType = "Dialogue"
                case .transition: pType = "Transition"
                case .shot: pType = "Shot"
                case .lyrics: pType = "General"
                }

                var runs = ""
                text.enumerateAttributes(in: range) { attributes, attrRange, _ in
                    let value = source.substring(with: attrRange).trimmingCharacters(in: .newlines)
                    if value.isEmpty { return }
                    let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
                    var adornment = 0
                    if traits.contains(.boldFontMask) { adornment += 1 }
                    if traits.contains(.italicFontMask) { adornment += 2 }
                    if (attributes[.underlineStyle] as? Int ?? 0) > 0 { adornment += 4 }

                    if adornment > 0 {
                        runs += "      <Text AdornmentStyle=\"\(adornment)\">\(OfficeArchive.xml(value))</Text>\n"
                    } else {
                        runs += "      <Text>\(OfficeArchive.xml(value))</Text>\n"
                    }
                }

                if !runs.isEmpty {
                    paragraphs += "    <Paragraph Type=\"\(pType)\"\(dualAttr)>\n\(runs)    </Paragraph>\n"
                }
                offset = NSMaxRange(range)
            }
        }

        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
        <FinalDraft DocumentType="Script" Template="No" Version="4">
          <Content>
        \(paragraphs)  </Content>
          <HeaderAndFooter AlignValue="Right" FirstPageHeader="No" TopMargin="0.50">
            <Header>
              <Paragraph Alignment="Right">
                <Text></Text>
              </Paragraph>
            </Header>
            <Footer>
              <Paragraph Alignment="Right">
                <Text></Text>
              </Paragraph>
            </Footer>
          </HeaderAndFooter>
        </FinalDraft>
        """

        guard let data = xml.data(using: .utf8) else {
            throw ProjectError.invalidProject("Unable to encode Final Draft XML")
        }
        return data
    }
}

@MainActor
enum ScreenplayFountain {
    static func render(_ project: Project) throws -> String {
        var lines: [String] = []

        // Title Page Header
        lines.append("Title: \(project.name)")
        lines.append("Draft date: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none))")
        lines.append("")
        lines.append("===")
        lines.append("")

        let standardPrefixes = ["INT.", "EXT.", "INT./EXT.", "EXT./INT.", "I/E.", "INT ", "EXT "]

        for segment in try project.orderedScript() {
            let scene = segment.scene
            let headingText = scene.heading.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let sceneNum = segment.number.trimmingCharacters(in: .whitespacesAndNewlines)

            // Format Scene Heading
            var headingLine = headingText.uppercased()
            let startsStandard = standardPrefixes.contains { headingLine.hasPrefix($0) }
            if !startsStandard && !headingLine.isEmpty {
                headingLine = "." + headingLine
            }
            if !sceneNum.isEmpty {
                headingLine += " #\(sceneNum)#"
            }
            lines.append(headingLine)
            lines.append("")

            // Format body paragraphs
            let text = DialoguePresentation.materialized(try ScreenplayTextCodec.decode(scene.html))
            let source = text.string as NSString
            var offset = 0
            while offset < text.length {
                let range = source.paragraphRange(for: NSRange(location: offset, length: 0))
                let rawLine = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawLine.isEmpty {
                    let element = ScreenplayTextCodec.element(in: text, at: offset)
                    switch element {
                    case .sceneHeading:
                        let h = rawLine.uppercased()
                        lines.append(standardPrefixes.contains { h.hasPrefix($0) } ? h : "." + h)
                        lines.append("")
                    case .action:
                        lines.append(rawLine)
                        lines.append("")
                    case .character:
                        let dual = text.attribute(.screenplayDualDialogue, at: offset, effectiveRange: nil) as? String
                        let suffix = (dual == "right") ? " ^" : ""
                        lines.append(rawLine.uppercased() + suffix)
                    case .parenthetical:
                        var p = rawLine
                        if !p.hasPrefix("(") { p = "(" + p }
                        if !p.hasSuffix(")") { p = p + ")" }
                        lines.append(p)
                    case .dialogue:
                        lines.append(rawLine)
                        lines.append("")
                    case .transition:
                        let t = rawLine.uppercased()
                        if t.hasSuffix("TO:") {
                            lines.append(t)
                        } else {
                            lines.append("> " + t)
                        }
                        lines.append("")
                    case .shot:
                        lines.append(rawLine.uppercased())
                        lines.append("")
                    case .lyrics:
                        lines.append("~" + rawLine)
                        lines.append("")
                    }
                }
                offset = NSMaxRange(range)
            }
        }

        return lines.joined(separator: "\n")
    }
}

extension Workspace {
    func exportFDX() {
        do {
            let data = try ScreenplayFDX.render(project)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "fdx") ?? .xml, .xml]
            panel.nameFieldStringValue = project.name.replacingOccurrences(of: "/", with: "-") + ".fdx"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportFountain() {
        do {
            let text = try ScreenplayFountain.render(project)
            guard let data = text.data(using: .utf8) else {
                throw ProjectError.invalidProject("Unable to encode Fountain text")
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "fountain") ?? .plainText, .plainText]
            panel.nameFieldStringValue = project.name.replacingOccurrences(of: "/", with: "-") + ".fountain"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
