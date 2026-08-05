//
//  CustomRules.swift
//  SwiftFormat
//
//  Created by Lorenz Schmoliner on 24/07/2026.
//  Copyright 2026 Nick Lockwood and the SwiftFormat project authors
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/nicklockwood/SwiftFormat
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation

enum RuleSeverity: String {
    case warning
    case error
}

struct CustomRules {
    private(set) var rules: [CustomRule]

    init(_ rules: [CustomRule] = []) {
        self.rules = rules.sorted { $0.identifier < $1.identifier }
    }

    var cacheKey: String {
        let data = try? JSONSerialization.data(withJSONObject: rules.map(\.cacheKey))
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func lint(
        _ tokens: [Token],
        options: FormatOptions,
        range: Range<Int>?
    ) -> [Formatter.Change] {
        guard !rules.isEmpty else { return [] }

        let context = CustomRuleContext(tokens: tokens, tabWidth: options.tabWidth)
        var options = options
        options.enabledRules.formUnion(rules.map(\.identifier))
        let formatter = Formatter(tokens, options: options, trackChanges: true, range: range)
        let filePath = options.fileInfo.filePath

        for rule in rules where rule.shouldLint(filePath: filePath) {
            formatter.currentRule = rule.formatRule
            rule.reportViolations(in: context, to: formatter)
        }
        formatter.currentRule = nil

        var previous: Formatter.Change?
        return formatter.changes.sorted(by: Formatter.Change.sourceOrder).filter { change in
            defer { previous = change }
            return change != previous
        }
    }
}

struct CustomRule {
    let identifier: String
    let name: String
    let message: String
    let severity: RuleSeverity
    let captureGroup: Int

    fileprivate let formatRule: FormatRule
    private let regex: NSRegularExpression
    private let included: [NSRegularExpression]
    private let excluded: [NSRegularExpression]
    private let matchKinds: Set<CustomSyntaxKind>?
    private let excludedMatchKinds: Set<CustomSyntaxKind>

    var cacheKey: String {
        let values: [Any] = [
            identifier,
            name,
            message,
            severity.rawValue,
            captureGroup,
            regex.pattern,
            included.map(\.pattern),
            excluded.map(\.pattern),
            matchKinds?.map(\.rawValue).sorted() ?? [NSNull()],
            excludedMatchKinds.map(\.rawValue).sorted(),
        ]
        let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? identifier
    }

    init(identifier: String, configuration: [String: CustomRuleValue]) throws {
        guard identifier.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil,
              identifier.lowercased() != "all"
        else {
            throw FormatError.options("Invalid custom rule identifier '\(identifier)'")
        }
        guard !FormatRules.byName.keys.contains(where: { $0.caseInsensitiveCompare(identifier) == .orderedSame }) else {
            throw FormatError.options("Custom rule identifier '\(identifier)' conflicts with a SwiftFormat rule")
        }
        guard let pattern = configuration["regex"]?.string else {
            throw FormatError.options("Custom rule '\(identifier)' is missing a regex")
        }

        let supportedKeys: Set = [
            "name", "regex", "message", "severity", "capture_group", "included", "excluded",
            "match_kinds", "excluded_match_kinds",
        ]
        if let unknown = Set(configuration.keys).subtracting(supportedKeys).sorted().first {
            throw FormatError.options("Unknown option '\(unknown)' in custom rule '\(identifier)'")
        }

        self.identifier = identifier
        name = configuration["name"]?.string ?? identifier
        message = configuration["message"]?.string ?? "Regex matched"

        if let value = configuration["severity"]?.string {
            guard let severity = RuleSeverity(rawValue: value.lowercased()) else {
                throw FormatError.options("Unsupported severity '\(value)' in custom rule '\(identifier)'")
            }
            self.severity = severity
        } else {
            severity = .warning
        }

        let compiledRegex: NSRegularExpression
        do {
            compiledRegex = try NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators, .anchorsMatchLines]
            )
        } catch {
            throw FormatError.options("Invalid regex in custom rule '\(identifier)': \(error.localizedDescription)")
        }
        regex = compiledRegex

        captureGroup = try configuration["capture_group"].map { value in
            guard let captureGroup = value.integer,
                  (0 ... compiledRegex.numberOfCaptureGroups).contains(captureGroup)
            else {
                throw FormatError.options("Invalid capture_group in custom rule '\(identifier)'")
            }
            return captureGroup
        } ?? 0

        func expressions(for key: String) throws -> [NSRegularExpression] {
            try configuration[key]?.strings.map { pattern in
                do {
                    return try NSRegularExpression(pattern: pattern)
                } catch {
                    throw FormatError.options(
                        "Invalid \(key) regex in custom rule '\(identifier)': \(error.localizedDescription)"
                    )
                }
            } ?? []
        }
        included = try expressions(for: "included")
        excluded = try expressions(for: "excluded")

        let configuredMatchKinds = configuration["match_kinds"]?.strings
        let configuredExcludedKinds = configuration["excluded_match_kinds"]?.strings
        if configuredMatchKinds != nil, configuredExcludedKinds != nil {
            throw FormatError.options(
                "Custom rule '\(identifier)' cannot specify both match_kinds and excluded_match_kinds"
            )
        }

        func syntaxKinds(_ values: [String]?) throws -> Set<CustomSyntaxKind>? {
            guard let values else { return nil }
            return try Set(values.map { value in
                guard let kind = CustomSyntaxKind(rawValue: value.lowercased()) else {
                    throw FormatError.options(
                        "Unsupported match kind '\(value)' in custom rule '\(identifier)'"
                    )
                }
                return kind
            })
        }
        matchKinds = try syntaxKinds(configuredMatchKinds)
        excludedMatchKinds = try syntaxKinds(configuredExcludedKinds) ?? []
        formatRule = FormatRule(customName: identifier, help: message, severity: severity) { _ in }
    }

    fileprivate func shouldLint(filePath: String?) -> Bool {
        guard let filePath else { return included.isEmpty }
        let range = NSRange(filePath.startIndex ..< filePath.endIndex, in: filePath)
        guard included.isEmpty || included.contains(where: {
            $0.firstMatch(in: filePath, range: range) != nil
        }) else {
            return false
        }
        return excluded.allSatisfy { $0.firstMatch(in: filePath, range: range) == nil }
    }

    fileprivate func reportViolations(in context: CustomRuleContext, to formatter: Formatter) {
        for match in regex.matches(in: context.source, range: context.sourceRange) {
            let violationRange = match.range(at: captureGroup)
            guard violationRange.location != NSNotFound,
                  context.matchesSyntaxKinds(
                      in: match.range,
                      included: matchKinds,
                      excluded: excludedMatchKinds
                  ),
                  let location = context.location(at: violationRange.location)
            else {
                continue
            }
            formatter.reportViolation(at: location.tokenIndex, column: location.column)
        }
    }
}

private enum CustomSyntaxKind: String {
    case comment
    case doccomment
    case identifier
    case keyword
    case number
    case string
}

private struct CustomRuleContext {
    struct TokenSpan {
        let index: Int
        let range: NSRange
        let syntaxKind: CustomSyntaxKind?
    }

    let tokens: [Token]
    let tabWidth: Int
    let source: String
    let sourceRange: NSRange
    let tokenSpans: [TokenSpan]

    init(tokens: [Token], tabWidth: Int) {
        self.tokens = tokens
        self.tabWidth = tabWidth
        source = sourceCode(for: tokens)
        sourceRange = NSRange(source.startIndex ..< source.endIndex, in: source)

        var spans = [TokenSpan]()
        var location = 0
        var commentScopes = [(kind: CustomSyntaxKind, isLineComment: Bool)]()
        for (index, token) in tokens.enumerated() {
            let kind: CustomSyntaxKind?
            switch token {
            case let .startOfScope(scope) where scope == "//" || scope == "/*":
                let body = tokens.indices.contains(index + 1) ? tokens[index + 1] : nil
                let isDocComment: Bool
                if case let .commentBody(value) = body {
                    isDocComment = value.hasPrefix(scope == "//" ? "/" : "*")
                } else {
                    isDocComment = false
                }
                let commentKind: CustomSyntaxKind = isDocComment ? .doccomment : .comment
                kind = commentKind
                commentScopes.append((commentKind, scope == "//"))
            case .endOfScope("*/"):
                kind = commentScopes.last?.kind ?? .comment
                _ = commentScopes.popLast()
            case .commentBody:
                kind = commentScopes.last?.kind ?? .comment
            case .linebreak:
                kind = nil
                if commentScopes.last?.isLineComment == true {
                    _ = commentScopes.popLast()
                }
            case .startOfScope where token.isStringDelimiter:
                kind = .string
            case .endOfScope where token.isStringDelimiter:
                kind = .string
            case .stringBody:
                kind = .string
            case .identifier:
                kind = .identifier
            case .keyword:
                kind = .keyword
            case .number:
                kind = .number
            case .startOfScope, .endOfScope, .delimiter, .operator, .space, .error:
                kind = nil
            }

            let length = token.string.utf16.count
            spans.append(TokenSpan(
                index: index,
                range: NSRange(location: location, length: length),
                syntaxKind: kind
            ))
            location += length
        }
        tokenSpans = spans
    }

    func matchesSyntaxKinds(
        in range: NSRange,
        included: Set<CustomSyntaxKind>?,
        excluded: Set<CustomSyntaxKind>
    ) -> Bool {
        for span in tokenSpans where NSIntersectionRange(range, span.range).length > 0 {
            guard let kind = span.syntaxKind else { continue }
            if let included, !included.contains(kind) {
                return false
            }
            if excluded.contains(kind) {
                return false
            }
        }
        return true
    }

    func location(at utf16Offset: Int) -> (tokenIndex: Int, column: Int)? {
        guard let span = tokenSpan(at: utf16Offset) else { return nil }
        let tokenOffset = min(max(utf16Offset - span.range.location, 0), span.range.length)
        let prefix = (tokens[span.index].string as NSString).substring(to: tokenOffset)
        let width = prefix.reduce(0) { width, character in
            width + (character == "\t" ? max(tabWidth, 1) : 1)
        }
        let offset = offsetForToken(at: span.index, in: tokens, tabWidth: tabWidth)
        return (span.index, offset.column + width)
    }

    private func tokenSpan(at utf16Offset: Int) -> TokenSpan? {
        guard !tokenSpans.isEmpty else { return nil }
        var lowerBound = 0
        var upperBound = tokenSpans.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            let span = tokenSpans[middle]
            if span.range.location + span.range.length <= utf16Offset {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        if lowerBound < tokenSpans.count {
            return tokenSpans[lowerBound]
        }
        return tokenSpans.last
    }
}

enum CustomRuleValue {
    case string(String)
    case strings([String])

    var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var strings: [String] {
        switch self {
        case let .string(value): return [value]
        case let .strings(values): return values
        }
    }

    var integer: Int? {
        string.flatMap(Int.init)
    }
}

private let customRulesCache = CustomRulesCache()

func loadCustomRules(at url: URL) throws -> CustomRules {
    try customRulesCache.rules(at: url)
}

private final class CustomRulesCache {
    private let lock = NSLock()
    private var values = [URL: CustomRules]()

    func rules(at url: URL) throws -> CustomRules {
        let url = url.standardizedFileURL
        lock.lock()
        defer { lock.unlock() }
        if let rules = values[url] {
            return rules
        }

        let rules = try parseCustomRules(Data(contentsOf: url))
        values[url] = rules
        return rules
    }
}

func parseCustomRules(_ data: Data) throws -> CustomRules {
    if let object = try? JSONSerialization.jsonObject(with: data),
       let root = object as? [String: Any]
    {
        return try parseCustomRules(json: root)
    }

    guard let source = String(data: data, encoding: .utf8) else {
        throw FormatError.reading("Unable to read custom rules configuration")
    }
    return try parseCustomRules(yaml: source)
}

private func parseCustomRules(json root: [String: Any]) throws -> CustomRules {
    guard let customRules = root["custom_rules"] as? [String: Any] else {
        throw FormatError.options("Custom rules configuration does not contain a custom_rules mapping")
    }
    return try CustomRules(customRules.map { identifier, value -> CustomRule in
        guard let dictionary = value as? [String: Any] else {
            throw FormatError.options("Invalid configuration for custom rule '\(identifier)'")
        }
        var values = [String: CustomRuleValue]()
        for (key, value) in dictionary {
            if let string = value as? String {
                values[key] = .string(string)
            } else if let integer = value as? Int {
                values[key] = .string(String(integer))
            } else if let strings = value as? [String] {
                values[key] = .strings(strings)
            } else {
                throw FormatError.options("Invalid value for '\(key)' in custom rule '\(identifier)'")
            }
        }
        return try CustomRule(identifier: identifier, configuration: values)
    })
}

private func parseCustomRules(yaml source: String) throws -> CustomRules {
    struct Line {
        let number: Int
        let indent: Int
        let content: String
    }

    let lines: [Line] = try source.components(separatedBy: .newlines).enumerated().compactMap { offset, rawLine in
        if rawLine.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") {
            throw FormatError.options("Tabs are not supported in custom rules configuration at line \(offset + 1)")
        }
        let content = yamlContentBeforeComment(in: rawLine).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty, content != "---", content != "..." else { return nil }
        return Line(number: offset + 1, indent: rawLine.prefix(while: { $0 == " " }).count, content: content)
    }

    guard let rootIndex = lines.firstIndex(where: { $0.content == "custom_rules:" }) else {
        throw FormatError.options("Custom rules configuration does not contain a custom_rules mapping")
    }
    let rootIndent = lines[rootIndex].indent
    var configurations = [String: [String: CustomRuleValue]]()
    var index = rootIndex + 1

    while index < lines.count, lines[index].indent > rootIndent {
        let ruleLine = lines[index]
        guard ruleLine.content.hasSuffix(":"),
              !ruleLine.content.contains(": ")
        else {
            throw FormatError.options("Expected custom rule identifier at line \(ruleLine.number)")
        }

        let identifier = String(ruleLine.content.dropLast()).trimmingCharacters(in: .whitespaces)
        if configurations[identifier] != nil {
            throw FormatError.options("Duplicate custom rule '\(identifier)' at line \(ruleLine.number)")
        }
        let ruleIndent = ruleLine.indent
        index += 1
        var configuration = [String: CustomRuleValue]()

        while index < lines.count, lines[index].indent > ruleIndent {
            let optionLine = lines[index]
            guard let colon = yamlKeyValueSeparator(in: optionLine.content) else {
                throw FormatError.options("Expected custom rule option at line \(optionLine.number)")
            }
            let key = String(optionLine.content[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(optionLine.content[optionLine.content.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            index += 1

            if rawValue.isEmpty {
                var values = [String]()
                while index < lines.count,
                      lines[index].indent > optionLine.indent,
                      lines[index].content.hasPrefix("-")
                {
                    try values.append(parseYAMLScalar(
                        String(lines[index].content.dropFirst()).trimmingCharacters(in: .whitespaces),
                        line: lines[index].number
                    ))
                    index += 1
                }
                configuration[key] = .strings(values)
            } else if rawValue.range(of: #"^[|>][+-]?[0-9]*$"#, options: .regularExpression) != nil {
                throw FormatError.options("Block scalar values are not supported at line \(optionLine.number)")
            } else if rawValue.hasPrefix("["), rawValue.hasSuffix("]") {
                configuration[key] = try .strings(parseYAMLArray(rawValue, line: optionLine.number))
            } else {
                configuration[key] = try .string(parseYAMLScalar(rawValue, line: optionLine.number))
            }
        }
        configurations[identifier] = configuration
    }

    return try CustomRules(configurations.map { try CustomRule(identifier: $0.key, configuration: $0.value) })
}

private func yamlContentBeforeComment(in line: String) -> String {
    var quote: Character?
    var escaped = false
    for index in line.indices {
        let character = line[index]
        if escaped {
            escaped = false
            continue
        }
        if character == "\\", quote == "\"" {
            escaped = true
        } else if character == "\"" || character == "'" {
            if quote == character {
                quote = nil
            } else if quote == nil {
                quote = character
            }
        } else if character == "#", quote == nil,
                  index == line.startIndex || line[line.index(before: index)].isWhitespace
        {
            return String(line[..<index])
        }
    }
    return line
}

private func yamlKeyValueSeparator(in line: String) -> String.Index? {
    var quote: Character?
    var escaped = false
    for index in line.indices {
        let character = line[index]
        if escaped {
            escaped = false
        } else if character == "\\", quote == "\"" {
            escaped = true
        } else if character == "\"" || character == "'" {
            quote = quote == character ? nil : (quote ?? character)
        } else if character == ":", quote == nil {
            return index
        }
    }
    return nil
}

private func parseYAMLArray(_ rawValue: String, line: Int) throws -> [String] {
    let body = rawValue.dropFirst().dropLast()
    var values = [String]()
    var start = body.startIndex
    var quote: Character?
    var escaped = false
    for index in body.indices {
        let character = body[index]
        if escaped {
            escaped = false
        } else if character == "\\", quote == "\"" {
            escaped = true
        } else if character == "\"" || character == "'" {
            quote = quote == character ? nil : (quote ?? character)
        } else if character == ",", quote == nil {
            try values.append(parseYAMLScalar(
                String(body[start ..< index]).trimmingCharacters(in: .whitespaces),
                line: line
            ))
            start = body.index(after: index)
        }
    }
    if quote != nil {
        throw FormatError.options("Unterminated quoted value at line \(line)")
    }
    let last = String(body[start...]).trimmingCharacters(in: .whitespaces)
    if !last.isEmpty {
        try values.append(parseYAMLScalar(last, line: line))
    }
    return values
}

private func parseYAMLScalar(_ rawValue: String, line: Int) throws -> String {
    guard !rawValue.isEmpty else { return "" }
    if rawValue.hasPrefix("'"), rawValue.hasSuffix("'") {
        return String(rawValue.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
    if rawValue.hasPrefix("\""), rawValue.hasSuffix("\"") {
        guard let data = "[\(rawValue)]".data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String],
              let value = values.first
        else {
            throw FormatError.options("Invalid quoted value at line \(line)")
        }
        return value
    }
    if rawValue.hasPrefix("'") || rawValue.hasPrefix("\"") {
        throw FormatError.options("Unterminated quoted value at line \(line)")
    }
    return rawValue
}
