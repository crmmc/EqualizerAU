import Foundation

/// Why a single source line appears in the import issue list.
enum M1APOImportIssueCategory: Equatable, Sendable {
    /// Command has no equivalent node (Copy, IIR coefficients, VSTPlugin,
    /// LoudnessCorrection); the line is skipped.
    case unsupportedCommand
    /// An `If` block was skipped as a whole; the payload carries the block's
    /// line count.
    case conditionalBlock(lineCount: Int)
    /// `Eval` line or inline backtick expression on a mapped command.
    case expression
    /// `Device`/`Stage` gate line; section gating is not applied (PRD M14 R2).
    case deviceGate
    /// Recognized command whose parameters failed to parse or left the
    /// supported domain.
    case invalidLine
    /// Convolution source is a Windows absolute path or cannot be resolved.
    case convolutionPath
    /// Convolution source extension is outside the supported WAV set.
    case convolutionFormat
    /// Include target unreadable or beyond the depth budget.
    case includeFailure
    /// Include target was already loaded once (cycle or diamond include);
    /// the flat chain model loads every file at most once (ADR-0024).
    case includeDuplicate
}

struct M1APOImportIssue: Equatable, Sendable {
    let fileIndex: Int
    let lineNumber: Int
    let command: String
    let category: M1APOImportIssueCategory
}

struct M1APOConfigImportPlan: Equatable, Sendable {
    /// Nodes in source order; fresh identities are assigned when the plan is
    /// applied (same new-identity semantics as paste).
    let nodes: [M1ProcessingNode]
    let issues: [M1APOImportIssue]
    /// Display file names, index-aligned with issue `fileIndex`.
    let fileNames: [String]
    let nodeCountByKind: [M1ProcessingNodeKind: Int]
    let disabledFilterCount: Int
    /// The config contains more than one `Device:` section; all sections were
    /// imported without device gating.
    let hasMultipleDeviceSections: Bool
}

enum M1EqualizerAPOConfigImporterError: Error, Equatable, Sendable {
    case fileUnreadable(path: String)
    case noRecognizedCommands
    case totalSizeLimitExceeded(bytes: Int, maximum: Int)
    case graphicEQPointLimitExceeded(count: Int, maximum: Int)
    case filterLineLimitExceeded(count: Int, maximum: Int)
    case nodeLimitExceeded(count: Int, maximum: Int)
}

/// Parses a full EqualizerAPO configuration file (plus its `Include:` chain)
/// into a dry-run import plan. No draft mutation happens here; the plan feeds
/// the preview dialog and the session import operations (PRD M14 R1–R3).
///
/// Degradation contract (M14 decision D1): `Preamp`, `Filter`, `GraphicEQ`,
/// `Delay`, `Channel` and `Convolution` map to existing node kinds; `Copy`,
/// IIR coefficient filters, `Device`, `Stage`, `If` blocks, `Eval`/inline
/// expressions, `VSTPlugin` and `LoudnessCorrection` are skipped and listed
/// per item. Non-command lines (REW export headers) are ignored silently,
/// matching the reference parser.
/// File access for the importer, injectable for tests; the disk reader
/// pre-checks the file size so an oversized file never loads into memory.
protocol M1ConfigFileReading: Sendable {
    func readText(at url: URL) throws -> String
}

struct M1DiskConfigFileReader: M1ConfigFileReading {
    func readText(at url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let fileSize = attributes[.size] as? Int,
           fileSize > M1EqualizerAPOConfigImporter.maximumTotalBytes {
            throw M1EqualizerAPOConfigImporterError.totalSizeLimitExceeded(
                bytes: fileSize,
                maximum: M1EqualizerAPOConfigImporter.maximumTotalBytes
            )
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Windows configs are frequently ANSI/CP1252; the reference falls
            // back from UTF-8 to the system code page. Latin-1 maps every
            // byte, so only I/O errors can escape here.
            return try String(contentsOf: url, encoding: .isoLatin1)
        }
    }
}

enum M1EqualizerAPOConfigImporter {
    static let maximumTotalBytes = 4 * 1024 * 1024
    /// Main file plus at most three levels of `Include:` (user decision,
    /// 2026-10-15): the flat single-level chain model does not adapt deep
    /// include graphs.
    static let maximumIncludeDepth = 3
    static let maximumPreampDB = 100.0
    /// Whole-plan node budget (user decision, 2026-10-15): pathological
    /// include graphs abort instead of adapting.
    static let maximumNodeCount = 64

    /// Commands that would map to nodes but are skipped when they carry
    /// inline backtick expressions.
    private static let mappedCommands: Set<String> = [
        "PREAMP", "FILTER", "GRAPHICEQ", "DELAY", "CHANNEL", "CONVOLUTION", "INCLUDE",
    ]

    static func makePlan(
        mainFile: URL,
        read: @Sendable (URL) throws -> String
    ) throws -> M1APOConfigImportPlan {
        var context = ImportContext()
        try loadFile(url: mainFile, depth: 0, required: true, read: read, context: &context)
        guard context.recognizedCommandCount > 0 else {
            throw M1EqualizerAPOConfigImporterError.noRecognizedCommands
        }
        guard context.nodes.count <= maximumNodeCount else {
            throw M1EqualizerAPOConfigImporterError.nodeLimitExceeded(
                count: context.nodes.count,
                maximum: maximumNodeCount
            )
        }
        var nodeCountByKind: [M1ProcessingNodeKind: Int] = [:]
        for node in context.nodes {
            nodeCountByKind[node.kind, default: 0] += 1
        }
        return M1APOConfigImportPlan(
            nodes: context.nodes,
            issues: context.issues,
            fileNames: context.fileNames,
            nodeCountByKind: nodeCountByKind,
            disabledFilterCount: context.nodes.filter {
                $0.kind == .filter && !$0.isEnabled
            }.count,
            hasMultipleDeviceSections: context.deviceLineCount > 1
        )
    }

    // MARK: - File loading

    private struct ImportContext {
        var nodes: [M1ProcessingNode] = []
        var issues: [M1APOImportIssue] = []
        var fileNames: [String] = []
        var visitedPaths: Set<String> = []
        var totalBytes = 0
        var recognizedCommandCount = 0
        var deviceLineCount = 0
        var filterLineCount = 0
        /// Channel selection at the current parse position; saved and restored
        /// around `Include:` boundaries like the reference FilterEngine.
        var currentSelection = M1ChannelSelection.all
    }

    private static func loadFile(
        url: URL,
        depth: Int,
        required: Bool,
        origin: (fileIndex: Int, lineNumber: Int)? = nil,
        read: (URL) throws -> String,
        context: inout ImportContext
    ) throws {
        let content: String
        do {
            content = try read(url)
        } catch let error as M1EqualizerAPOConfigImporterError {
            throw error
        } catch {
            if required {
                throw M1EqualizerAPOConfigImporterError.fileUnreadable(path: url.path)
            }
            // Attribute the failure to the includer's location so the report
            // can point at a real file and line. The main file (required)
            // never reaches this branch, so `origin` is always present.
            guard let origin else { return }
            context.issues.append(
                M1APOImportIssue(
                    fileIndex: origin.fileIndex,
                    lineNumber: origin.lineNumber,
                    command: "Include",
                    category: .includeFailure
                )
            )
            return
        }
        let byteCount = content.utf8.count
        if context.totalBytes + byteCount > maximumTotalBytes {
            throw M1EqualizerAPOConfigImporterError.totalSizeLimitExceeded(
                bytes: context.totalBytes + byteCount,
                maximum: maximumTotalBytes
            )
        }
        context.totalBytes += byteCount
        context.visitedPaths.insert(url.path)
        let fileIndex = context.fileNames.count
        context.fileNames.append(url.lastPathComponent)
        try parseLines(
            content.components(separatedBy: .newlines),
            fileURL: url,
            fileIndex: fileIndex,
            depth: depth,
            read: read,
            context: &context
        )
    }

    // MARK: - Line parsing

    private static func parseLines(
        _ lines: [String],
        fileURL: URL,
        fileIndex: Int,
        depth: Int,
        read: (URL) throws -> String,
        context: inout ImportContext
    ) throws {
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let lineNumber = index + 1
            index += 1

            guard let (command, parameters) = splitCommand(line) else {
                continue
            }
            if parameters.contains("`"), mappedCommands.contains(command) {
                context.recognizedCommandCount += 1
                context.issues.append(issue(fileIndex, lineNumber, command, .expression))
                continue
            }

            switch command {
            case "PREAMP":
                context.recognizedCommandCount += 1
                parsePreamp(parameters, fileIndex, lineNumber, context: &context)
            case "FILTER":
                context.recognizedCommandCount += 1
                try parseFilter(parameters, fileIndex, lineNumber, context: &context)
            case "GRAPHICEQ":
                context.recognizedCommandCount += 1
                try parseGraphicEQ(line, fileIndex, lineNumber, context: &context)
            case "DELAY":
                context.recognizedCommandCount += 1
                parseDelay(parameters, fileIndex, lineNumber, context: &context)
            case "CHANNEL":
                context.recognizedCommandCount += 1
                parseChannel(parameters, fileIndex, lineNumber, context: &context)
            case "CONVOLUTION":
                context.recognizedCommandCount += 1
                parseConvolution(
                    parameters,
                    baseDirectory: fileURL.deletingLastPathComponent(),
                    fileIndex,
                    lineNumber,
                    context: &context
                )
            case "INCLUDE":
                context.recognizedCommandCount += 1
                if depth + 1 > maximumIncludeDepth {
                    context.issues.append(issue(fileIndex, lineNumber, command, .includeFailure))
                } else {
                    // Reference semantics: restore the outer file's channel
                    // selection once the included file returns, so later
                    // commands keep the scope the includer had.
                    let outerSelection = context.currentSelection
                    try loadInclude(
                        parameters,
                        baseDirectory: fileURL.deletingLastPathComponent(),
                        depth: depth,
                        fileIndex: fileIndex,
                        lineNumber: lineNumber,
                        read: read,
                        context: &context
                    )
                    if context.currentSelection != outerSelection {
                        context.nodes.append(.channels(id: UUID(), selection: outerSelection))
                        context.currentSelection = outerSelection
                    }
                }
            case "DEVICE":
                context.recognizedCommandCount += 1
                context.deviceLineCount += 1
                context.issues.append(issue(fileIndex, lineNumber, command, .deviceGate))
            case "STAGE":
                context.recognizedCommandCount += 1
                context.issues.append(issue(fileIndex, lineNumber, command, .deviceGate))
            case "IF":
                context.recognizedCommandCount += 1
                let endLine = endOfConditionalBlock(lines, from: index)
                context.issues.append(
                    issue(
                        fileIndex,
                        lineNumber,
                        command,
                        .conditionalBlock(lineCount: endLine - lineNumber + 1)
                    )
                )
                index = endLine
            case "EVAL":
                context.recognizedCommandCount += 1
                context.issues.append(issue(fileIndex, lineNumber, command, .expression))
            case "COPY", "VSTPLUGIN", "LOUDNESSCORRECTION":
                context.recognizedCommandCount += 1
                context.issues.append(issue(fileIndex, lineNumber, command, .unsupportedCommand))
            case "ELSE", "ELSEIF", "ENDIF":
                // Known command keywords outside any If block.
                context.recognizedCommandCount += 1
                context.issues.append(issue(fileIndex, lineNumber, command, .invalidLine))
            default:
                // Unknown command names are ignored silently, like the
                // reference parser and REW export headers.
                continue
            }
        }
    }

    /// Splits `Command: Parameters`; returns the upper-cased single command
    /// word (filter slot numbers stripped) or nil for non-command lines.
    private static func splitCommand(_ line: String) -> (String, String)? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let rawCommand = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        // `Filter 3:` carries a slot number the reference ignores; every APO
        // command word itself is a single word.
        let commandWord = rawCommand.split(separator: " ").first.map(String.init) ?? ""
        guard !commandWord.isEmpty else { return nil }
        return (commandWord.uppercased(), String(line[line.index(after: separator)...]))
    }

    private static func parsePreamp(
        _ parameters: String,
        _ fileIndex: Int,
        _ lineNumber: Int,
        context: inout ImportContext
    ) {
        let normalized = parameters.replacingOccurrences(of: ",", with: ".")
        let tokens = normalized.split(separator: " ")
        guard tokens.count == 2,
              let value = Double(tokens[0]),
              value.isFinite,
              tokens[1].lowercased() == "db"
        else {
            context.issues.append(issue(fileIndex, lineNumber, "Preamp", .invalidLine))
            return
        }
        let clamped = min(max(value, -maximumPreampDB), maximumPreampDB)
        context.nodes.append(
            M1ProcessingNode(
                id: UUID(),
                isEnabled: true,
                gainDB: clamped,
                channels: .all
            )
        )
    }

    private static func parseFilter(
        _ parameters: String,
        _ fileIndex: Int,
        _ lineNumber: Int,
        context: inout ImportContext
    ) throws {
        let tokens = parameters.split(separator: " ").map(String.init)
        guard let stateToken = tokens.first?.lowercased() else {
            // `Filter 3:` with empty parameters is REW slot noise.
            return
        }
        guard stateToken == "on" || stateToken == "off" else {
            context.issues.append(issue(fileIndex, lineNumber, "Filter", .invalidLine))
            return
        }
        let typeToken = tokens.count > 1 ? tokens[1].lowercased() : ""
        if typeToken.isEmpty || typeToken == "none" {
            // `Filter 3: OFF None` empty slots are REW export noise.
            return
        }
        if typeToken == "iir" {
            context.issues.append(issue(fileIndex, lineNumber, "Filter", .unsupportedCommand))
            return
        }
        // Reuse the paste codec by substituting the `ON` state token it
        // expects; disabled filters import as disabled nodes.
        var synthesizedTokens = tokens
        synthesizedTokens[0] = "ON"
        let synthesized = "Filter: " + synthesizedTokens.joined(separator: " ")
        let outcome: M1EqualizerAPOTextCodec.FilterLineParseOutcome
        do {
            outcome = try M1EqualizerAPOTextCodec.parseFilterLine(synthesized)
        } catch {
            context.issues.append(issue(fileIndex, lineNumber, "Filter", .invalidLine))
            return
        }
        switch outcome {
        case .node(let specification, _):
            context.nodes.append(
                .filter(
                    id: UUID(),
                    isEnabled: stateToken == "on",
                    specification: specification
                )
            )
            // Same whole-import abort contract as the paste path.
            context.filterLineCount += 1
            if context.filterLineCount > M1EqualizerAPOTextCodec.maximumFilterLines {
                throw M1EqualizerAPOConfigImporterError.filterLineLimitExceeded(
                    count: context.filterLineCount,
                    maximum: M1EqualizerAPOTextCodec.maximumFilterLines
                )
            }
        case .ignored:
            context.issues.append(issue(fileIndex, lineNumber, "Filter", .invalidLine))
        }
    }

    private static func parseGraphicEQ(
        _ line: String,
        _ fileIndex: Int,
        _ lineNumber: Int,
        context: inout ImportContext
    ) throws {
        do {
            guard let points = try M1GraphicEQTextCodec.parseGraphicEQLine(line), !points.isEmpty else {
                context.issues.append(issue(fileIndex, lineNumber, "GraphicEQ", .invalidLine))
                return
            }
            context.nodes.append(.graphicEQ(id: UUID(), points: points))
        } catch M1GraphicEQTextCodecError.pointLimitExceeded(let count, let maximum) {
            // Single lines beyond the point budget abort the whole import,
            // matching the established paste contract.
            throw M1EqualizerAPOConfigImporterError.graphicEQPointLimitExceeded(
                count: count,
                maximum: maximum
            )
        }
    }

    private static func parseDelay(
        _ parameters: String,
        _ fileIndex: Int,
        _ lineNumber: Int,
        context: inout ImportContext
    ) {
        let normalized = parameters.replacingOccurrences(of: ",", with: ".")
        let tokens = normalized.split(separator: " ")
        guard tokens.count == 2,
              let value = Double(tokens[0]),
              value.isFinite,
              value > 0
        else {
            context.issues.append(issue(fileIndex, lineNumber, "Delay", .invalidLine))
            return
        }
        let unit: M1DelayUnit
        switch tokens[1].lowercased() {
        case "ms": unit = .milliseconds
        case "samples": unit = .samples
        default:
            context.issues.append(issue(fileIndex, lineNumber, "Delay", .invalidLine))
            return
        }
        // Out-of-budget values stay as-is; the existing per-node bypass
        // diagnostics own that degradation (PRD M14 R2).
        context.nodes.append(
            .delay(id: UUID(), specification: M1DelaySpecification(value: value, unit: unit))
        )
    }

    private static func parseChannel(
        _ parameters: String,
        _ fileIndex: Int,
        _ lineNumber: Int,
        context: inout ImportContext
    ) {
        let tokens = parameters.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else {
            context.issues.append(issue(fileIndex, lineNumber, "Channel", .invalidLine))
            return
        }
        if tokens.count == 1, tokens[0].lowercased() == "all" {
            context.currentSelection = .all
            context.nodes.append(.channels(id: UUID(), selection: .all))
            return
        }
        var identifiers: [M1ChannelIdentifier] = []
        for token in tokens {
            guard let identifier = M1ChannelIdentifier(token) else {
                context.issues.append(issue(fileIndex, lineNumber, "Channel", .invalidLine))
                return
            }
            identifiers.append(identifier)
        }
        context.currentSelection = .identifiers(identifiers)
        context.nodes.append(.channels(id: UUID(), selection: .identifiers(identifiers)))
    }

    private static func parseConvolution(
        _ parameters: String,
        baseDirectory: URL,
        _ fileIndex: Int,
        _ lineNumber: Int,
        context: inout ImportContext
    ) {
        let path = unquote(parameters.trimmingCharacters(in: .whitespaces))
        guard !path.isEmpty else {
            context.issues.append(issue(fileIndex, lineNumber, "Convolution", .invalidLine))
            return
        }
        let isWindowsAbsolute = isWindowsAbsolutePath(path)
        // Windows absolute paths are kept verbatim: they can never resolve on
        // this system, and `URL(fileURLWithPath:)` would prefix them with the
        // working directory. The node keeps the string so the user can repoint
        // it; the existing missing-source bypass covers the interim.
        let sourcePath: String
        if isWindowsAbsolute {
            sourcePath = path
            context.issues.append(issue(fileIndex, lineNumber, "Convolution", .convolutionPath))
        } else if path.hasPrefix("/") {
            sourcePath = path
        } else {
            sourcePath = baseDirectory.appendingPathComponent(path).standardizedFileURL.path
        }
        let fileExtension = (sourcePath as NSString).pathExtension.lowercased()
        if !fileExtension.isEmpty, fileExtension != "wav", fileExtension != "wave" {
            context.issues.append(issue(fileIndex, lineNumber, "Convolution", .convolutionFormat))
        }
        context.nodes.append(
            .convolution(id: UUID(), ir: M1ConvolutionIRReference(sourcePath: sourcePath))
        )
    }

    private static func loadInclude(
        _ parameters: String,
        baseDirectory: URL,
        depth: Int,
        fileIndex: Int,
        lineNumber: Int,
        read: (URL) throws -> String,
        context: inout ImportContext
    ) throws {
        let path = unquote(parameters.trimmingCharacters(in: .whitespaces))
        guard !path.isEmpty else {
            context.issues.append(issue(fileIndex, lineNumber, "Include", .invalidLine))
            return
        }
        if isWindowsAbsolutePath(path) {
            context.issues.append(issue(fileIndex, lineNumber, "Include", .includeFailure))
            return
        }
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : baseDirectory.appendingPathComponent(path).standardizedFileURL
        if context.visitedPaths.contains(url.path) {
            // Cycle or diamond include: every file loads at most once in the
            // flat chain model; reported as a duplicate, not a failure.
            context.issues.append(issue(fileIndex, lineNumber, "Include", .includeDuplicate))
            return
        }
        try loadFile(
            url: url,
            depth: depth + 1,
            required: false,
            origin: (fileIndex, lineNumber),
            read: read,
            context: &context
        )
    }

    /// Returns the 1-based line number of the `EndIf:` closing the `If` block
    /// that starts at `from` (0-based index of the line after `If:`); nested
    /// blocks are consumed. An unterminated block ends at the last line.
    private static func endOfConditionalBlock(_ lines: [String], from start: Int) -> Int {
        var depth = 1
        var index = start
        while index < lines.count {
            guard let (command, _) = splitCommand(lines[index]) else {
                index += 1
                continue
            }
            if command == "IF" {
                depth += 1
            } else if command == "ENDIF" {
                depth -= 1
                if depth == 0 {
                    return index + 1
                }
            }
            index += 1
        }
        return lines.count
    }

    private static let windowsDrivePrefixExpression = try! NSRegularExpression(
        pattern: "^[A-Za-z]:[\\\\/]"
    )

    /// Drive-letter (`C:\\…`, `C:/…`) or UNC (`\\\\…`) paths can never resolve
    /// on this system; a bare colon elsewhere is a legal macOS file name.
    private static func isWindowsAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("\\\\") { return true }
        let range = NSRange(path.startIndex..., in: path)
        return windowsDrivePrefixExpression.firstMatch(in: path, range: range) != nil
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static let canonicalCommandNames: [String: String] = [
        "PREAMP": "Preamp",
        "FILTER": "Filter",
        "GRAPHICEQ": "GraphicEQ",
        "DELAY": "Delay",
        "CHANNEL": "Channel",
        "CONVOLUTION": "Convolution",
        "INCLUDE": "Include",
        "DEVICE": "Device",
        "STAGE": "Stage",
        "IF": "If",
        "EVAL": "Eval",
        "COPY": "Copy",
        "VSTPLUGIN": "VSTPlugin",
        "LOUDNESSCORRECTION": "LoudnessCorrection",
        "ELSE": "Else",
        "ELSEIF": "ElseIf",
        "ENDIF": "EndIf",
    ]

    private static func issue(
        _ fileIndex: Int,
        _ lineNumber: Int,
        _ command: String,
        _ category: M1APOImportIssueCategory
    ) -> M1APOImportIssue {
        M1APOImportIssue(
            fileIndex: fileIndex,
            lineNumber: lineNumber,
            command: canonicalCommandNames[command.uppercased()] ?? command,
            category: category
        )
    }
}
