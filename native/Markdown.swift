import AppKit

func inlineText(_ source: String, size: CGFloat = 12.5, color: NSColor = Theme.text) -> NSMutableAttributedString {
    let result = NSMutableAttributedString(string: "")
    guard let value = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return NSMutableAttributedString(attributedString: attributed(source, size: size, color: color)) }
    for run in value.runs {
        var text = String(value[run.range].characters)
        let intent = run.inlinePresentationIntent ?? []
        let code = intent.contains(.code)
        var font = code ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular) : NSFont.systemFont(ofSize: size)
        if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if code { attributes[.backgroundColor] = NSColor.white.withAlphaComponent(0.06) }
        if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link, ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
            if text.hasPrefix("http:") || text.hasPrefix("https:") { text = shortLink(link.absoluteString) }
            attributes[.link] = link; attributes[.foregroundColor] = Theme.accent; attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        let part = NSMutableAttributedString(string: text, attributes: attributes)
        if !code && run.link == nil {
            let ranges = expression(#"https?://[^\s<>\"']+"#)?.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? []
            for match in ranges.reversed() {
                let raw = (text as NSString).substring(with: match.range)
                let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)"))
                if let url = URL(string: clean) {
                    let range = NSRange(location: match.range.location, length: (clean as NSString).length)
                    var linkAttributes = attributes
                    linkAttributes[.link] = url; linkAttributes[.foregroundColor] = Theme.accent; linkAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    part.replaceCharacters(in: range, with: NSAttributedString(string: shortLink(clean), attributes: linkAttributes))
                }
            }
        }
        result.append(part)
    }
    return result
}
func shortLink(_ url: String) -> String {
    let text = replace(#"^https?://"#, url)
    guard let slash = text.firstIndex(of: "/"), text.distance(from: slash, to: text.endIndex) > 11 else { return text }
    return String(text[...slash]) + "…" + text.suffix(10)
}
struct MarkdownPart {
    var text: NSAttributedString
    var code = false
    var spacing: CGFloat = 10
}
func codeText(_ source: String) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 17.25; paragraph.maximumLineHeight = 17.25
    return NSAttributedString(string: source, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: Theme.text, .paragraphStyle: paragraph])
}
func markdownParts(_ source: String) -> [MarkdownPart] {
    let lines = source.components(separatedBy: "\n")
    var parts: [MarkdownPart] = [], paragraph: [String] = [], fence: [String]?, index = 0, listIndex = 0
    func text(_ source: String, size: CGFloat = 12.5, weight: NSFont.Weight = .regular, indent: CGFloat = 0, color: NSColor = Theme.text, spacing: CGFloat = 10) {
        let value = inlineText(source, size: size, color: color)
        let style = NSMutableParagraphStyle(); style.minimumLineHeight = size * 1.6; style.maximumLineHeight = size * 1.6
        style.paragraphSpacing = 0; style.headIndent = indent; style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        if weight != .regular { value.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: weight), range: NSRange(location: 0, length: value.length)) }
        value.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: value.length))
        parts.append(MarkdownPart(text: value, spacing: spacing))
    }
    func flush() { if !paragraph.isEmpty { text(paragraph.joined(separator: "\n")); paragraph = [] } }
    while index < lines.count {
        let line = lines[index]; index += 1
        if fence == nil, matches(#"^\s*(?:[-*+]|\d+[.)])\s+"#, line).isEmpty, let last = parts.indices.last, parts[last].spacing == 2 { parts[last].spacing = 10 }
        if trimmed(line).hasPrefix("```") {
            if let code = fence { parts.append(MarkdownPart(text: codeText(code.joined(separator: "\n")), code: true)); fence = nil }
            else { flush(); fence = [] }; continue
        }
        if fence != nil { fence!.append(line); continue }
        if trimmed(line).isEmpty { flush(); listIndex = 0; continue }
        if let heading = matches(#"^(#{1,6})\s+(.*)$"#, line).first {
            flush(); if let last = parts.indices.last { parts[last].spacing = 14 }; text(heading[2], size: heading[1].count == 1 ? 15 : heading[1].count == 2 ? 14 : 13, weight: .semibold, spacing: 6); continue
        }
        if !matches(#"^\s*([-*_])\s*\1\s*\1[-*_\s]*$"#, line).isEmpty {
            flush(); let block = NSTextBlock(); block.setWidth(1, type: .absolute, for: .border, edge: .minY); block.setBorderColor(Theme.border)
            let style = NSMutableParagraphStyle(); style.textBlocks = [block]; style.paragraphSpacingBefore = 12; style.paragraphSpacing = 12
            parts.append(MarkdownPart(text: NSAttributedString(string: "\u{200b}", attributes: [.paragraphStyle: style, .font: NSFont.systemFont(ofSize: 1)]))); continue
        }
        if trimmed(line).hasPrefix("|"), index < lines.count, !matches(#"^\s*\|?[\s:|-]*-[\s:|-]*$"#, lines[index]).isEmpty {
            flush(); var rows = [tableCells(line)]; index += 1
            while index < lines.count && trimmed(lines[index]).hasPrefix("|") { rows.append(tableCells(lines[index])); index += 1 }
            parts.append(MarkdownPart(text: tableText(rows))); continue
        }
        if let quote = matches(#"^\s*>\s?(.*)$"#, line).first { flush(); text("│  " + quote[1], color: Theme.muted); continue }
        if let bullet = matches(#"^\s*[-*+]\s+(.*)$"#, line).first { flush(); text("•\t" + bullet[1], indent: 20, spacing: 2); continue }
        if let numbered = matches(#"^\s*\d+[.)]\s+(.*)$"#, line).first { flush(); listIndex += 1; text("\(listIndex).\t" + numbered[1], indent: 20, spacing: 2); continue }
        listIndex = 0; paragraph.append(line)
    }
    if let fence { parts.append(MarkdownPart(text: codeText(fence.joined(separator: "\n")), code: true)) }
    flush(); return parts
}
func tableCells(_ line: String) -> [String] {
    var text = trimmed(line)
    if text.hasPrefix("|") { text.removeFirst() }; if text.hasSuffix("|") { text.removeLast() }
    return text.components(separatedBy: "|").map(trimmed)
}
func tableText(_ rows: [[String]]) -> NSAttributedString {
    let result = NSMutableAttributedString(string: ""), table = NSTextTable()
    table.numberOfColumns = rows.map(\.count).max() ?? 1; table.collapsesBorders = true
    table.setContentWidth(100, type: .percentage)
    for (row, cells) in rows.enumerated() {
        for (column, cell) in cells.enumerated() {
            let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            block.setWidth(1, type: .absolute, for: .border); block.setBorderColor(Theme.border)
            block.setWidth(5, type: .absolute, for: .padding)
            block.setWidth(8, type: .absolute, for: .padding, edge: .minX); block.setWidth(8, type: .absolute, for: .padding, edge: .maxX)
            if row == 0 { block.backgroundColor = NSColor.white.withAlphaComponent(0.04) }
            let style = NSMutableParagraphStyle(); style.textBlocks = [block]; style.minimumLineHeight = 19.2; style.maximumLineHeight = 19.2
            let value = inlineText(cell + "\n", size: 12)
            value.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: value.length))
            if row == 0 { value.addAttribute(.font, value: NSFont.systemFont(ofSize: 12, weight: .semibold), range: NSRange(location: 0, length: value.length)) }
            result.append(value)
        }
    }
    return result
}

final class TranscriptText: NSTextView, NSTextViewDelegate {
    var original = NSAttributedString(string: "")
    private let storage = NSTextStorage()
    var reveal: (() -> Void)?
    init(_ text: NSAttributedString) {
        let manager = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        original = text; isEditable = false; isSelectable = true; drawsBackground = false
        textContainerInset = .zero; textContainer?.lineFragmentPadding = 0
        isVerticallyResizable = true; isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
        textStorage?.setAttributedString(text); delegate = self
        linkTextAttributes = [.foregroundColor: Theme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        insertionPointColor = Theme.text
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func measuredHeight(_ width: CGFloat) -> CGFloat {
        setFrameSize(NSSize(width: max(1, width), height: frame.height))
        textContainer?.containerSize = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        guard let layoutManager, let textContainer else { return 0 }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }
    func find(_ term: String) -> [NSRange] {
        let source = original.string as NSString
        guard !term.isEmpty else { return [] }
        var range = NSRange(location: 0, length: source.length), result: [NSRange] = []
        while range.length > 0 {
            let found = source.range(of: term, options: .caseInsensitive, range: range)
            if found.location == NSNotFound { break }; result.append(found)
            range = NSRange(location: NSMaxRange(found), length: source.length - NSMaxRange(found))
        }
        return result
    }
    func highlight(_ ranges: [NSRange], current: NSRange? = nil) {
        textStorage?.setAttributedString(original)
        for range in ranges { textStorage?.addAttributes([.backgroundColor: Theme.accent.withAlphaComponent(0.28), .foregroundColor: Theme.text], range: range) }
        if let current { textStorage?.addAttributes([.backgroundColor: rgb(0xf2c14e), .foregroundColor: rgb(0x1a1a1a)], range: current) }
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
        if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        return true
    }
}
final class MarkdownView: FlippedView {
    var texts: [TranscriptText] = []
    private var codes: [NSScrollView?] = []
    private var spacing: [CGFloat] = []
    init(_ source: String, plain: Bool = false) {
        super.init(frame: .zero)
        let parts = plain ? [MarkdownPart(text: attributed(source, size: 11.5, color: Theme.muted))] : markdownParts(source)
        for part in parts {
            let text = TranscriptText(part.text); texts.append(text); spacing.append(part.spacing)
            if part.code {
                text.isHorizontallyResizable = true; text.textContainer?.widthTracksTextView = false
                let scroll = NSScrollView(); scroll.documentView = text; scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
                scroll.scrollerStyle = .overlay; scroll.drawsBackground = true; scroll.backgroundColor = Theme.background
                scroll.wantsLayer = true; scroll.layer?.cornerRadius = 6; scroll.layer?.borderWidth = 1; scroll.layer?.borderColor = Theme.border.cgColor
                scroll.contentInsets = NSEdgeInsets(top: 9, left: 11, bottom: 9, right: 11)
                codes.append(scroll); addSubview(scroll)
            } else { codes.append(nil); addSubview(text) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func measure(_ width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        for index in texts.indices {
            let text = texts[index]
            if let code = codes[index] {
                let lines = text.original.string.components(separatedBy: "\n")
                let longest = lines.map { ($0 as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)]).width }.max() ?? 0
                let innerWidth = max(width - 22, longest + 2), height = text.measuredHeight(innerWidth)
                text.frame = NSRect(x: 0, y: 0, width: innerWidth, height: height)
                code.frame = NSRect(x: 0, y: y, width: width, height: height + 18); y += height + 28
            } else {
                let height = text.measuredHeight(width); text.frame = NSRect(x: 0, y: y, width: width, height: height); y += height + spacing[index]
            }
        }
        return max(0, y - (spacing.last ?? 0))
    }
}
