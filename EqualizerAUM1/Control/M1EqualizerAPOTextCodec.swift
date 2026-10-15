import Foundation

struct M1APOTextPasteReport: Equatable, Sendable {
    var graphicEQLineCount = 0
    var filterLineCount = 0
    /// Lines dropped because they were invalid or out of domain; never silent.
    var ignoredLineCount = 0
    /// Parameters ignored per the reference semantics (e.g. `Gain` on a
    /// low-pass line, `BW Oct` on a shelf); the line itself is kept.
    var ignoredParameterCount = 0

    var hasIgnoredContent: Bool {
        ignoredLineCount > 0 || ignoredParameterCount > 0
    }
}

struct M1APOTextPaste: Equatable, Sendable {
    /// Nodes in source line order; each entry is one node to insert.
    let nodes: [M1ProcessingNode]
    let report: M1APOTextPasteReport
}

enum M1EqualizerAPOTextCodecError: Error, Equatable {
    case filterLineLimitExceeded(count: Int, maximum: Int)
}

/// Parses EqualizerAPO configuration text for clipboard paste, recognizing both
/// `GraphicEQ:` and `Filter:` command lines in source order.
///
/// Filter parsing mirrors the reference `BiQuadFilterFactory` parameter
/// semantics (type aliases, defaults, shelf slope/corner handling) with the
/// documented project deviations: invalid or out-of-domain lines are dropped
/// but counted in the visible report, and the reference's thousands-separator
/// reinterpretation (`1.000` → 1000) is not copied.
enum M1EqualizerAPOTextCodec {
    /// Same structural bound as the GraphicEQ per-line point limit.
    static let maximumFilterLines = M1GraphicEQContract.maximumPointCount

    private static let filterCommandExpression = try! NSRegularExpression(
        pattern: #"(?i)^\s*Filter\s*\d*\s*$"#
    )
    private static let filterTypeExpression = try! NSRegularExpression(
        pattern: #"(?i)^\s*ON\s+([A-Za-z]+)"#
    )
    private static let slopeExpression = try! NSRegularExpression(
        pattern: #"^\s*([-+0-9.eE]+)\s*dB"#
    )
    private static let frequencyExpression = try! NSRegularExpression(
        pattern: #"(?i)\s+Fc\s*([-+0-9.eE]+)\s*H\s*z"#
    )
    private static let gainExpression = try! NSRegularExpression(
        pattern: #"(?i)\s+Gain\s*([-+0-9.eE]+)\s*dB"#
    )
    private static let qExpression = try! NSRegularExpression(
        pattern: #"(?i)\s+Q\s*([-+0-9.eE]+)"#
    )
    private static let bandwidthExpression = try! NSRegularExpression(
        pattern: #"(?i)\s+BW\s+Oct\s*([-+0-9.eE]+)"#
    )

    static func parse(_ text: String) throws -> M1APOTextPaste {
        var nodes: [M1ProcessingNode] = []
        var report = M1APOTextPasteReport()
        for line in text.components(separatedBy: .newlines) {
            if let points = try M1GraphicEQTextCodec.parseGraphicEQLine(line) {
                if !points.isEmpty {
                    nodes.append(.graphicEQ(points: points))
                    report.graphicEQLineCount += 1
                }
                continue
            }
            if isFilterLine(line) {
                switch try parseFilterLine(line) {
                case .node(let specification, let ignoredParameterCount):
                    nodes.append(.filter(specification: specification))
                    report.filterLineCount += 1
                    report.ignoredParameterCount += ignoredParameterCount
                case .ignored:
                    report.ignoredLineCount += 1
                }
                if report.filterLineCount > maximumFilterLines {
                    throw M1EqualizerAPOTextCodecError.filterLineLimitExceeded(
                        count: report.filterLineCount,
                        maximum: maximumFilterLines
                    )
                }
            }
        }
        return M1APOTextPaste(nodes: nodes, report: report)
    }

    static func parseFilterLines(_ text: String) throws -> [M1FilterSpecification] {
        try parse(text).nodes.compactMap { node in
            node.kind == .filter ? node.filterSpecification : nil
        }
    }

    private static func isFilterLine(_ line: String) -> Bool {
        guard let separator = line.firstIndex(of: ":") else { return false }
        let command = String(line[..<separator])
        let range = NSRange(command.startIndex..., in: command)
        return filterCommandExpression
            .firstMatch(in: command, range: range) != nil
    }

    enum FilterLineParseOutcome {
        case node(M1FilterSpecification, ignoredParameterCount: Int)
        case ignored
    }

    /// Parses one `Filter: ON <type> …` line. Internal for reuse by the
    /// M14 config importer (single parsing source of truth).
    static func parseFilterLine(_ line: String) throws -> FilterLineParseOutcome {
        guard let separator = line.firstIndex(of: ":") else { return .ignored }
        var parameters = String(line[line.index(after: separator)...])
        if !parameters.contains(".") {
            parameters = parameters.replacingOccurrences(of: ",", with: ".")
        }

        guard let typeMatch = firstMatch(filterTypeExpression, in: parameters) else {
            return .ignored
        }
        guard let resolvedType = filterType(named: typeMatch.value) else {
            return .ignored
        }
        let filterType = resolvedType.type
        let cornerFrequency = resolvedType.cornerFrequency
        var ignoredParameters = 0
        parameters = typeMatch.suffix

        var slopeDBPerOctave: Double?
        if let slopeMatch = firstMatch(slopeExpression, in: parameters),
           let value = Double(slopeMatch.value), value.isFinite {
            if filterType.isShelf {
                slopeDBPerOctave = value
            } else {
                ignoredParameters += 1
            }
            parameters = slopeMatch.suffix
        }

        guard let frequencyMatch = firstMatch(frequencyExpression, in: parameters),
              let frequencyHz = Double(frequencyMatch.value), frequencyHz.isFinite
        else {
            return .ignored
        }
        guard frequencyHz >= M1FilterContract.minimumFrequencyHz,
              frequencyHz <= M1FilterContract.maximumFrequencyHz
        else {
            return .ignored
        }

        var gainDB = 0.0
        if let gainMatch = firstMatch(gainExpression, in: parameters),
           let value = Double(gainMatch.value), value.isFinite {
            if filterType.supportsGain {
                gainDB = min(
                    max(value, M1FilterContract.minimumGainDB),
                    M1FilterContract.maximumGainDB
                )
            } else {
                ignoredParameters += 1
            }
        }

        let qMatch = firstMatch(qExpression, in: parameters).flatMap {
            Double($0.value)
        }
        let bandwidthMatch = firstMatch(bandwidthExpression, in: parameters)
        if filterType.isShelf, bandwidthMatch != nil {
            // Reference ignores bandwidth for shelves; the slope position wins.
            ignoredParameters += 1
        }
        let bandwidthOctaves = bandwidthMatch.flatMap { Double($0.value) }

        func validQ(_ value: Double) -> Bool {
            value.isFinite
                && value >= M1FilterContract.minimumQ
                && value <= M1FilterContract.maximumQ
        }
        func validBandwidth(_ value: Double) -> Bool {
            value.isFinite
                && value >= M1FilterContract.minimumBandwidthOctaves
                && value <= M1FilterContract.maximumBandwidthOctaves
        }

        let width: M1FilterWidth
        if filterType.isShelf {
            if let slopeDBPerOctave, slopeDBPerOctave.isFinite,
               slopeDBPerOctave > 0,
               slopeDBPerOctave <= M1FilterContract.maximumSlopeDBPerOctave {
                width = .slopeDBPerOctave(slopeDBPerOctave)
            } else if let q = qMatch, validQ(q) {
                width = .q(q)
            } else {
                width = .slopeDBPerOctave(M1FilterContract.defaultShelfSlopeDBPerOctave)
            }
        } else if let bandwidthOctaves, validBandwidth(bandwidthOctaves) {
            width = .bandwidthOctaves(bandwidthOctaves)
        } else if let q = qMatch, validQ(q) {
            width = .q(q)
        } else {
            switch filterType {
            case .lowPass, .highPass, .bandPass:
                width = .q(M1FilterContract.defaultQ)
            case .notch:
                width = .q(M1FilterContract.defaultNotchQ)
            case .lowShelf, .highShelf:
                // Handled by the shelf branch above.
                width = .slopeDBPerOctave(M1FilterContract.defaultShelfSlopeDBPerOctave)
            case .peaking, .allPass:
                // Reference fails the line when Q/bandwidth is missing.
                return .ignored
            }
        }

        let specification = M1FilterSpecification(
            type: filterType,
            frequencyHz: frequencyHz,
            gainDB: gainDB,
            width: width,
            cornerFrequency: cornerFrequency
        )
        return .node(specification, ignoredParameterCount: ignoredParameters)
    }

    /// Paste-layer alias normalization; matching is case-insensitive, unlike
    /// the reference's case-sensitive map (documented positive deviation).
    private static func filterType(
        named rawName: String
    ) -> (type: M1FilterType, cornerFrequency: Bool)? {
        switch rawName.lowercased() {
        case "pk", "peq", "modal":
            return (.peaking, false)
        case "lp", "lpq":
            return (.lowPass, false)
        case "hp", "hpq":
            return (.highPass, false)
        case "bp":
            return (.bandPass, false)
        case "ls":
            return (.lowShelf, true)
        case "hs":
            return (.highShelf, true)
        case "lsc":
            return (.lowShelf, false)
        case "hsc":
            return (.highShelf, false)
        case "no":
            return (.notch, false)
        case "ap":
            return (.allPass, false)
        default:
            return nil
        }
    }

    private struct ExpressionMatch {
        var value: String
        var suffix: String
    }

    private static func firstMatch(
        _ expression: NSRegularExpression,
        in text: String
    ) -> ExpressionMatch? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let wholeRange = Range(match.range(at: 0), in: text),
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return ExpressionMatch(
            value: String(text[valueRange]),
            suffix: String(text[wholeRange.upperBound...])
        )
    }
}
