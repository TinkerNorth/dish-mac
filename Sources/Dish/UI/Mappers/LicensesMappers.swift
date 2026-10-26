// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import SwiftUI

/// One block of the third-party notice as the page draws it.
enum LicenseBlock: Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    /// A licence's verbatim text, kept as written.
    case code(String)
    case row(cells: [AttributedString], header: Bool)
    case rule
}

struct LicenseBlockItem: Equatable, Identifiable {
    let id: Int
    let block: LicenseBlock
}

enum LicensesPageState: Equatable {
    /// The build carries no notice to show.
    case missing(title: String, body: String)
    case notice(blocks: [LicenseBlockItem], footer: String)
}

func licensesPageState(notice: String?, appVersion: String, words: L10n = .app) -> LicensesPageState {
    guard let notice, !notice.isEmpty else {
        return .missing(title: words.noLicenseManifest, body: words.licenseManifestUnreadable)
    }
    let items = licenseBlocks(notice).enumerated().map { LicenseBlockItem(id: $0.offset, block: $0.element) }
    return .notice(blocks: items, footer: words.aboutLine(appVersion))
}

/// The notice's Markdown as blocks: headings, paragraphs, fenced licence
/// texts, table rows and rules. Inline links and emphasis stay live.
func licenseBlocks(_ markdown: String) -> [LicenseBlock] {
    var parser = LicenseParser()
    for line in markdown.components(separatedBy: "\n") {
        parser.read(line)
    }
    return parser.finish()
}

private struct LicenseParser {
    private var blocks: [LicenseBlock] = []
    private var paragraph: [String] = []
    private var code: [String]?

    mutating func read(_ line: String) {
        if code != nil {
            readFenced(line)
            return
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        switch licenseLineKind(trimmed) {
        case .fence: openFence()
        case .blank: flushParagraph()
        case .rule: emit(.rule)
        case let .heading(level, text): emit(.heading(level: level, text: inlineMarkdown(text)))
        case .tableSeparator: markLastRowAsHeader()
        case let .tableRow(cells): emit(.row(cells: cells.map(inlineMarkdown), header: false))
        case .text: paragraph.append(trimmed)
        }
    }

    mutating func finish() -> [LicenseBlock] {
        flushParagraph()
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    private mutating func readFenced(_ line: String) {
        guard line.trimmingCharacters(in: .whitespaces).hasPrefix("```") else {
            code?.append(line)
            return
        }
        blocks.append(.code(code?.joined(separator: "\n") ?? ""))
        code = nil
    }

    private mutating func openFence() {
        flushParagraph()
        code = []
    }

    private mutating func emit(_ block: LicenseBlock) {
        flushParagraph()
        blocks.append(block)
    }

    private mutating func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(inlineMarkdown(paragraph.joined(separator: " "))))
        paragraph = []
    }

    private mutating func markLastRowAsHeader() {
        guard case let .row(cells, _) = blocks.last else { return }
        blocks[blocks.count - 1] = .row(cells: cells, header: true)
    }
}

enum LicenseLineKind: Equatable {
    case fence
    case blank
    case rule
    case heading(level: Int, text: String)
    case tableSeparator
    case tableRow([String])
    case text
}

/// What one trimmed line of the notice is.
func licenseLineKind(_ line: String) -> LicenseLineKind {
    if line.hasPrefix("```") { return .fence }
    if line.isEmpty { return .blank }
    if line == "---" { return .rule }
    if line.hasPrefix("#") { return headingKind(line) }
    if line.hasPrefix("|") { return tableKind(line) }
    return .text
}

private func headingKind(_ line: String) -> LicenseLineKind {
    let level = line.prefix { $0 == "#" }.count
    let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
    return .heading(level: level, text: text)
}

private let tableSeparatorCharacters: Set<Character> = ["|", "-", ":", " "]

private func tableKind(_ line: String) -> LicenseLineKind {
    let isSeparator = line.allSatisfy { tableSeparatorCharacters.contains($0) }
    if isSeparator { return .tableSeparator }
    let cells = line.split(separator: "|", omittingEmptySubsequences: false)
        .dropFirst()
        .dropLast()
        .map { $0.trimmingCharacters(in: .whitespaces) }
    return .tableRow(cells)
}

/// Links, code spans and emphasis, the text itself as written when the
/// line is not Markdown after all.
func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

// MARK: - Type

/// A top-level heading reads as a title, a deeper one as body text.
func licenseHeadingFont(_ level: Int) -> Font {
    level <= 1 ? DishFont.title : DishFont.body
}

/// A table's header row stands out from its cells.
func licenseCellFont(header: Bool) -> Font {
    header ? DishFont.control : DishFont.caption
}

func licenseCellColor(header: Bool) -> Color {
    header ? DishTheme.onSurface : DishTheme.muted
}
