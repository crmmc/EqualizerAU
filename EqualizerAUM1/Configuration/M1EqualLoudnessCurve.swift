import Foundation

/// ISO 226:2003 equal-loudness contour math (Suzuki–Takeshima 2004 analytic fit).
///
/// Compensation model (ADR-0023): when the output volume sits `ΔV` dB below the
/// node's reference volume, a frequency `f` needs
///
///     g(f) = [Lp(f, P_ref + ΔV) − Lp(f, P_ref)] − [Lp(1 kHz, ·) difference]
///
/// so the perceived spectral balance matches the reference listening level while
/// the overall level change itself is left to the user. The standard defines
/// contours only on its 20 Hz…12.5 kHz third-octave support; gains outside that
/// support hold the nearest endpoint value (documented deviation). Phon inputs
/// below `minimumFittedPhon` are clamped to the floor contour so extreme volume
/// drops keep a frozen curve instead of dropping the node.
enum M1EqualLoudnessCurve {
    /// Documented calibration assumption: the reference volume corresponds to an
    /// assumed 85 phon listening level; `strength` absorbs individual error.
    static let assumedReferencePhon = 85.0

    /// The analytic fit is only meaningful for positive loudness levels, and a
    /// volume far below the reference would drive `currentPhon` through zero.
    /// Compensation inputs are clamped to this floor so an extreme volume drop
    /// freezes the curve at the floor contour instead of dropping the node
    /// (ADR-0023); the clamp is continuous at the boundary.
    static let minimumFittedPhon = 10.0

    private struct Row {
        let frequencyHz: Double
        let alpha: Double
        let levelUnitLU: Double
        let thresholdDB: Double
    }

    private static let rows: [Row] = [
        Row(frequencyHz: 20, alpha: 0.532, levelUnitLU: -31.6, thresholdDB: 78.5),
        Row(frequencyHz: 25, alpha: 0.506, levelUnitLU: -27.2, thresholdDB: 68.7),
        Row(frequencyHz: 31.5, alpha: 0.480, levelUnitLU: -23.0, thresholdDB: 59.5),
        Row(frequencyHz: 40, alpha: 0.455, levelUnitLU: -19.1, thresholdDB: 51.1),
        Row(frequencyHz: 50, alpha: 0.432, levelUnitLU: -15.9, thresholdDB: 44.0),
        Row(frequencyHz: 63, alpha: 0.409, levelUnitLU: -13.0, thresholdDB: 37.5),
        Row(frequencyHz: 80, alpha: 0.387, levelUnitLU: -10.3, thresholdDB: 31.5),
        Row(frequencyHz: 100, alpha: 0.367, levelUnitLU: -8.1, thresholdDB: 26.5),
        Row(frequencyHz: 125, alpha: 0.349, levelUnitLU: -6.2, thresholdDB: 22.1),
        Row(frequencyHz: 160, alpha: 0.330, levelUnitLU: -4.5, thresholdDB: 17.9),
        Row(frequencyHz: 200, alpha: 0.315, levelUnitLU: -3.1, thresholdDB: 14.4),
        Row(frequencyHz: 250, alpha: 0.301, levelUnitLU: -2.0, thresholdDB: 11.4),
        Row(frequencyHz: 315, alpha: 0.288, levelUnitLU: -1.1, thresholdDB: 8.6),
        Row(frequencyHz: 400, alpha: 0.276, levelUnitLU: -0.4, thresholdDB: 6.2),
        Row(frequencyHz: 500, alpha: 0.267, levelUnitLU: 0.0, thresholdDB: 4.4),
        Row(frequencyHz: 630, alpha: 0.259, levelUnitLU: 0.3, thresholdDB: 3.0),
        Row(frequencyHz: 800, alpha: 0.253, levelUnitLU: 0.5, thresholdDB: 2.2),
        Row(frequencyHz: 1_000, alpha: 0.250, levelUnitLU: 0.0, thresholdDB: 2.4),
        Row(frequencyHz: 1_250, alpha: 0.246, levelUnitLU: -2.7, thresholdDB: 3.5),
        Row(frequencyHz: 1_600, alpha: 0.244, levelUnitLU: -4.1, thresholdDB: 1.7),
        Row(frequencyHz: 2_000, alpha: 0.243, levelUnitLU: -1.0, thresholdDB: -1.3),
        Row(frequencyHz: 2_500, alpha: 0.243, levelUnitLU: 1.7, thresholdDB: -4.2),
        Row(frequencyHz: 3_150, alpha: 0.243, levelUnitLU: 2.5, thresholdDB: -6.0),
        Row(frequencyHz: 4_000, alpha: 0.242, levelUnitLU: 1.2, thresholdDB: -5.4),
        Row(frequencyHz: 5_000, alpha: 0.242, levelUnitLU: -2.1, thresholdDB: -1.5),
        Row(frequencyHz: 6_300, alpha: 0.245, levelUnitLU: -7.1, thresholdDB: 6.0),
        Row(frequencyHz: 8_000, alpha: 0.254, levelUnitLU: -11.2, thresholdDB: 12.6),
        Row(frequencyHz: 10_000, alpha: 0.271, levelUnitLU: -10.7, thresholdDB: 13.9),
        Row(frequencyHz: 12_500, alpha: 0.301, levelUnitLU: -3.1, thresholdDB: 12.3),
    ]

    /// Sound pressure level the standard requires for loudness level `phon` at
    /// `frequencyHz`, linearly interpolated in log-frequency between rows and
    /// clamped to the table support. Returns nil outside the fit's domain.
    static func soundPressureLevelDB(frequencyHz: Double, phon: Double) -> Double? {
        guard frequencyHz.isFinite, frequencyHz > 0, phon.isFinite else { return nil }
        guard phon > 0, let level = level(frequencyHz: frequencyHz, phon: phon) else {
            return nil
        }
        return level
    }

    /// dB gain for frequency `f` so its perceived balance at `currentPhon`
    /// matches `referencePhon`, normalized to 0 dB at 1 kHz. Both phon inputs
    /// are clamped to `minimumFittedPhon` (see there).
    static func compensationGainDB(
        frequencyHz: Double,
        referencePhon: Double,
        currentPhon: Double
    ) -> Double? {
        let reference = max(referencePhon, minimumFittedPhon)
        let current = max(currentPhon, minimumFittedPhon)
        guard let atReference = soundPressureLevelDB(
            frequencyHz: frequencyHz,
            phon: reference
        ), let atCurrent = soundPressureLevelDB(
            frequencyHz: frequencyHz,
            phon: current
        ), let referenceAtKilohertz = soundPressureLevelDB(
            frequencyHz: 1_000,
            phon: reference
        ), let currentAtKilohertz = soundPressureLevelDB(
            frequencyHz: 1_000,
            phon: current
        ) else { return nil }
        return (atCurrent - atReference) - (currentAtKilohertz - referenceAtKilohertz)
    }

    /// Ready-to-compile target curve for the FIR pipeline: gains clamped to
    /// ±24 dB (GraphicEQ domain), scaled by `strength`, then shifted down by
    /// the curve's maximum positive gain so the compiled chain never amplifies
    /// peaks (ADR-0023 anti-clipping guard, equivalent to the reference
    /// implementation's protective preamp). Returns nil for a flat curve.
    static func compensationTargetGainDB(
        referencePhon: Double,
        currentPhon: Double,
        strength: Double
    ) -> ((Double) -> Double)? {
        let reference = max(referencePhon, minimumFittedPhon)
        let current = max(currentPhon, minimumFittedPhon)
        guard strength > 0, reference != current else { return nil }
        var rowGains: [Double] = []
        rowGains.reserveCapacity(rows.count)
        for row in rows {
            guard let gain = compensationGainDB(
                frequencyHz: row.frequencyHz,
                referencePhon: reference,
                currentPhon: current
            ) else { return nil }
            rowGains.append(max(-24, min(24, gain * strength)))
        }
        let maximumGain = rowGains.max() ?? 0
        let shifted = rowGains.map { $0 - max(0, maximumGain) }
        return { frequencyHz in
            interpolatedShiftedGain(shifted, frequencyHz: frequencyHz)
        }
    }

    /// Picks the log-frequency bracket for `frequencyHz`: the lower row index
    /// and the blend fraction toward the next row, clamped to the table ends
    /// (fraction 0 means the lower row stands alone).
    private static func logFrequencyBracket(frequencyHz: Double) -> (lower: Int, fraction: Double) {
        let logarithmic = log2(frequencyHz)
        if logarithmic <= log2(rows[0].frequencyHz) {
            return (0, 0)
        }
        if logarithmic >= log2(rows[rows.count - 1].frequencyHz) {
            return (rows.count - 1, 0)
        }
        var lower = 0
        while log2(rows[lower + 1].frequencyHz) < logarithmic {
            lower += 1
        }
        let fraction = (logarithmic - log2(rows[lower].frequencyHz))
            / (log2(rows[lower + 1].frequencyHz) - log2(rows[lower].frequencyHz))
        return (lower, fraction)
    }

    private static func level(frequencyHz: Double, phon: Double) -> Double? {
        let bracket = logFrequencyBracket(frequencyHz: frequencyHz)
        guard let lowerLevel = rowLevel(rows[bracket.lower], phon: phon) else { return nil }
        guard bracket.fraction > 0 else { return lowerLevel }
        guard let upperLevel = rowLevel(rows[bracket.lower + 1], phon: phon) else { return nil }
        return lowerLevel + bracket.fraction * (upperLevel - lowerLevel)
    }

    private static func rowLevel(_ row: Row, phon: Double) -> Double? {
        let excitation = 4.47e-3 * (pow(10, 0.025 * phon) - 1.15)
            + pow(0.4 * pow(10, (row.thresholdDB + row.levelUnitLU) / 10 - 9), row.alpha)
        guard excitation.isFinite, excitation > 0 else { return nil }
        let level = 10 / row.alpha * log10(excitation) - row.levelUnitLU + 94
        guard level.isFinite else { return nil }
        return level
    }

    private static func interpolatedShiftedGain(_ shiftedGains: [Double], frequencyHz: Double) -> Double {
        let bracket = logFrequencyBracket(frequencyHz: frequencyHz)
        guard bracket.fraction > 0 else { return shiftedGains[bracket.lower] }
        return shiftedGains[bracket.lower]
            + bracket.fraction * (shiftedGains[bracket.lower + 1] - shiftedGains[bracket.lower])
    }
}
