//
//  CustomRulesTests.swift
//  SwiftFormatTests
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

import XCTest
@testable import SwiftFormat

final class CustomRulesTests: XCTestCase {
    func testParseConfiguration() throws {
        let rules = try parseCustomRules(Data(#"""
        custom_rules:
          no_ninja:
            name: "Pirates Beat Ninjas"
            regex: 'let\s+(ninja)'
            capture_group: 1
            included:
              - ".*\\.swift"
            excluded: ".*Tests\\.swift"
            match_kinds: [identifier]
            message: "Pirates are better than ninjas."
            severity: error
        """#.utf8))

        XCTAssertEqual(rules.rules.count, 1)
        XCTAssertEqual(rules.rules[0].identifier, "no_ninja")
        XCTAssertEqual(rules.rules[0].name, "Pirates Beat Ninjas")
        XCTAssertEqual(rules.rules[0].message, "Pirates are better than ninjas.")
        XCTAssertEqual(rules.rules[0].severity, .error)
        XCTAssertEqual(rules.rules[0].captureGroup, 1)
    }

    func testParseJSONConfiguration() throws {
        let rules = try parseCustomRules(Data(#"""
        {
          "custom_rules": {
            "no_ninja": {
              "regex": "ninja",
              "severity": "warning"
            }
          }
        }
        """#.utf8))

        XCTAssertEqual(rules.rules.map(\.identifier), ["no_ninja"])
    }

    func testIgnoresUnrelatedTopLevelSwiftLintConfiguration() throws {
        let rules = try rules("""
        disabled_rules:
          - line_length
        custom_rules:
          no_ninja:
            regex: ninja
        reporter: emoji
        """)

        XCTAssertEqual(rules.rules.map(\.identifier), ["no_ninja"])
    }

    func testBlockScalarIsRejected() {
        for marker in ["|", "|-", "|+2", ">", ">-", ">+2"] {
            XCTAssertThrowsError(try rules("""
            custom_rules:
              no_ninja:
                regex: \(marker)
                  ninja
            """)) { error in
                XCTAssertEqual("\(error)", "Block scalar values are not supported at line 3")
            }
        }
    }

    func testCaptureGroupReportsExactLocation() throws {
        let changes = try lint(
            """
            let pirate = 1
            let ninja = 2

            """,
            with: """
            custom_rules:
              no_ninja:
                regex: 'let\\s+(ninja)'
                capture_group: 1
                message: "Pirates are better than ninjas."
            """
        )

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].line, 2)
        XCTAssertEqual(changes[0].column, 5)
        XCTAssertEqual(changes[0].rule.name, "no_ninja")
        XCTAssertEqual(changes[0].help, "Pirates are better than ninjas.")
    }

    func testReportsMultipleMatchesOnSameLine() throws {
        let changes = try lint(
            """
            let values = (ninja, ninja)

            """,
            with: """
            custom_rules:
              no_ninja:
                regex: '\\bninja\\b'
            """
        )

        XCTAssertEqual(changes.map(\.line), [1, 1])
        XCTAssertEqual(changes.compactMap(\.column), [15, 22])
    }

    func testColumnUsesConfiguredTabWidth() throws {
        let source = "\tlet ninja = 1\n"
        let configuration = """
        custom_rules:
          no_ninja:
            regex: ninja
        """

        XCTAssertEqual(try lint(source, with: configuration, tabWidth: 0).first?.column, 6)
        XCTAssertEqual(try lint(source, with: configuration, tabWidth: 4).first?.column, 9)
    }

    func testSupportedSyntaxKinds() throws {
        let source = """
        let ninja = "ninja" // ninja
        /// ninja
        let count = 42

        """
        XCTAssertEqual(try lint(source, matching: "identifier", regex: "ninja").map(\.column), [5])
        XCTAssertEqual(try lint(source, matching: "string", regex: "ninja").map(\.column), [14])
        XCTAssertEqual(try lint(source, matching: "comment", regex: "ninja").map(\.line), [1])
        XCTAssertEqual(try lint(source, matching: "doccomment", regex: "ninja").map(\.line), [2])
        XCTAssertEqual(try lint(source, matching: "keyword", regex: "let").map(\.line), [1, 3])
        XCTAssertEqual(try lint(source, matching: "number", regex: "42").map(\.line), [3])
    }

    func testExcludedSyntaxKinds() throws {
        let changes = try lint(
            """
            let ninja = "ninja" // ninja

            """,
            with: """
            custom_rules:
              no_ninja:
                regex: 'ninja'
                excluded_match_kinds: [comment, string]
            """
        )

        XCTAssertEqual(changes.map(\.column), [5])
    }

    func testUnsupportedSyntaxKindThrows() {
        XCTAssertThrowsError(try rules("""
        custom_rules:
          no_parameters:
            regex: 'value'
            match_kinds: [parameter]
        """)) { error in
            XCTAssertEqual("\(error)", "Unsupported match kind 'parameter' in custom rule 'no_parameters'")
        }
    }

    func testCanBeDisabledWithSwiftFormatDirective() throws {
        let changes = try lint(
            """
            // swiftformat:disable:next no_ninja
            let ninja = 1

            """,
            with: """
            custom_rules:
              no_ninja:
                regex: '\\bninja\\b'
                match_kinds: identifier
            """
        )

        XCTAssertTrue(changes.isEmpty)
    }

    func testIncludedAndExcludedPaths() throws {
        let configuration = """
        custom_rules:
          no_ninja:
            regex: '\\bninja\\b'
            included: 'Sources/.*\\.swift$'
            excluded: 'Generated\\.swift$'
        """
        let source = """
        let ninja = 1

        """

        XCTAssertEqual(try lint(source, with: configuration, path: "/project/Sources/App.swift").count, 1)
        XCTAssertTrue(try lint(source, with: configuration, path: "/project/Tests/AppTests.swift").isEmpty)
        XCTAssertTrue(try lint(source, with: configuration, path: "/project/Sources/Generated.swift").isEmpty)
    }

    func testRulesRespectLineRange() throws {
        let configuration = """
        custom_rules:
          no_ninja:
            regex: '\\bninja\\b'
        """
        let source = """
        let ninja = 1
        let ninja = 2

        """
        let customRules = try rules(configuration)
        let tokens = tokenize(source)
        var options = FormatOptions.default
        options.fileInfo = FileInfo(filePath: "/project/Source.swift")
        let range = tokenRange(forLineRange: 2 ... 2, in: tokens)

        let changes = customRules.lint(tokens, options: options, range: range)

        XCTAssertEqual(changes.map(\.line), [2])
    }

    func testRulesOnlyRunInLintMode() throws {
        var options = Options(formatOptions: .default, rules: [])
        options.customRules = try rules("""
        custom_rules:
          no_ninja:
            regex: '\\bninja\\b'
        """)
        let source = """
        let ninja = 1

        """

        let result = try applyRules(
            source,
            options: options,
            lineRange: nil,
            verbose: false,
            lint: false,
            reporter: nil
        )

        XCTAssertTrue(result.changes.isEmpty)
    }

    func testMissingRegexThrows() {
        XCTAssertThrowsError(try rules("""
        custom_rules:
          no_ninja:
            message: "Missing regex"
        """)) { error in
            XCTAssertEqual("\(error)", "Custom rule 'no_ninja' is missing a regex")
        }
    }

    func testUnsupportedRuleOptionThrows() {
        XCTAssertThrowsError(try rules("""
        custom_rules:
          no_ninja:
            regex: ninja
            execution_mode: swiftsyntax
        """)) { error in
            XCTAssertEqual("\(error)", "Unknown option 'execution_mode' in custom rule 'no_ninja'")
        }
    }

    func testRuleIdentifierCannotConflictWithBuiltInRule() {
        XCTAssertThrowsError(try rules("""
        custom_rules:
          indent:
            regex: ninja
        """)) { error in
            XCTAssertEqual("\(error)", "Custom rule identifier 'indent' conflicts with a SwiftFormat rule")
        }
    }

    func testReporterOutputIncludesColumnAndSeverity() throws {
        let change = try XCTUnwrap(lint(
            """
            let ninja = 1

            """,
            with: """
            custom_rules:
              no_ninja:
                regex: ninja
                severity: error
            """,
            path: "/project/Source.swift"
        ).first)

        XCTAssertEqual(
            change.description(asError: false),
            "/project/Source.swift:1:5: error: (no_ninja) Regex matched"
        )

        let githubReporter = GithubActionsLogReporter(environment: ["GITHUB_WORKSPACE": "/project"])
        githubReporter.report([change])
        XCTAssertEqual(
            try output(from: githubReporter),
            "::error file=Source.swift,line=1,col=5::Regex matched (no_ninja)\n"
        )

        let jsonReporter = JSONReporter(environment: [:])
        jsonReporter.report([change])
        XCTAssertTrue(try output(from: jsonReporter).contains("\"column\" : 5"))

        let xmlReporter = XMLReporter(environment: [:])
        xmlReporter.report([change])
        XCTAssertTrue(try output(from: xmlReporter).contains("column=\"5\" severity=\"error\""))

        let sarifReporter = SARIFReporter(environment: [:])
        sarifReporter.report([change])
        XCTAssertTrue(try output(from: sarifReporter).contains("\"startColumn\" : 5"))
    }

    private func lint(
        _ source: String,
        matching syntaxKind: String,
        regex: String
    ) throws -> [SwiftFormat.Formatter.Change] {
        try lint(source, with: """
        custom_rules:
          test_rule:
            regex: '\(regex)'
            match_kinds: \(syntaxKind)
        """)
    }

    private func lint(
        _ source: String,
        with configuration: String,
        path: String = "/project/Source.swift",
        tabWidth: Int = FormatOptions.default.tabWidth
    ) throws -> [SwiftFormat.Formatter.Change] {
        let tokens = tokenize(source)
        var options = FormatOptions.default
        options.fileInfo = FileInfo(filePath: path)
        options.tabWidth = tabWidth
        return try rules(configuration).lint(tokens, options: options, range: nil)
    }

    private func rules(_ configuration: String) throws -> CustomRules {
        try parseCustomRules(Data(configuration.utf8))
    }

    private func output(from reporter: Reporter) throws -> String {
        let data = try XCTUnwrap(reporter.write())
        return String(decoding: data, as: UTF8.self)
    }
}
