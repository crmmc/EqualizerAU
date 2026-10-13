import Foundation

enum M1FilterBypassReason: Equatable, Sendable {
    case frequencyAtOrAboveNyquist
    case coefficientsRejected
}

/// Biquad design for the classic EqualizerAPO filter types.
///
/// The closed-form design formulas mirror the local EqualizerAPO reference
/// implementation and are a compatibility contract, not a re-derived algorithm:
/// RBJ cookbook per type (reference `filters/BiQuad.cpp`), shelf corner-to-center
/// frequency conversion (reference `filters/BiQuadFilter.cpp`, including the
/// DCX2496 compatibility factor), and stage validity mirroring `isStableBiquad`
/// in `EAUM1Runtime.cpp`. Apple Accelerate provides no IIR filter-design API, so
/// design stays here on the control thread; runtime sample processing remains the
/// existing `EAUM1PreparedStageBiquad` path.
enum M1BiquadFilterDesign {
    static func design(
        specification: M1FilterSpecification,
        sampleRate: Double
    ) -> M1BiquadFilterDesignOutcome {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return .bypass(.coefficientsRejected)
        }

        var frequencyHz = specification.frequencyHz
        var shelfSlopeS = 0.0
        if specification.type.isShelf {
            let amplitude = pow(10.0, specification.gainDB / 40.0)
            switch specification.width {
            case .slopeDBPerOctave(let slopeDBPerOctave):
                shelfSlopeS = slopeDBPerOctave / 12.0
            case .q(let q):
                shelfSlopeS = 1.0
                    / ((1.0 / (q * q) - 2.0) / (amplitude + 1.0 / amplitude) + 1.0)
            case .bandwidthOctaves:
                return .bypass(.coefficientsRejected)
            }
            guard shelfSlopeS.isFinite, shelfSlopeS > 0 else {
                return .bypass(.coefficientsRejected)
            }
            if specification.cornerFrequency {
                // A degenerate Q-to-slope conversion (|S| → ∞) shifts nothing.
                let factor = pow(10.0, abs(specification.gainDB) / 80.0 / shelfSlopeS)
                frequencyHz = specification.type == .lowShelf
                    ? specification.frequencyHz * factor
                    : specification.frequencyHz / factor
            }
        }
        guard frequencyHz.isFinite, frequencyHz > 0 else {
            return .bypass(.coefficientsRejected)
        }
        if frequencyHz >= sampleRate / 2 {
            return .bypass(.frequencyAtOrAboveNyquist)
        }

        let gainDB = specification.type.supportsGain ? specification.gainDB : 0
        let amplitude: Double
        switch specification.type {
        case .peaking, .lowShelf, .highShelf:
            amplitude = pow(10.0, gainDB / 40.0)
        case .lowPass, .highPass, .bandPass, .notch, .allPass:
            amplitude = pow(10.0, gainDB / 20.0)
        }

        let omega = 2.0 * Double.pi * frequencyHz / sampleRate
        let sn = sin(omega)
        let cs = cos(omega)
        let alpha: Double
        switch specification.width {
        case .q(let q):
            alpha = sn / (2.0 * q)
        case .slopeDBPerOctave:
            guard specification.type.isShelf else {
                return .bypass(.coefficientsRejected)
            }
            alpha = sn / 2.0
                * sqrt((amplitude + 1.0 / amplitude) * (1.0 / shelfSlopeS - 1.0) + 2.0)
        case .bandwidthOctaves(let octaves):
            alpha = sn * sinh(M_LN2 / 2.0 * octaves * omega / sn)
        }
        let beta = 2.0 * sqrt(amplitude) * alpha

        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double
        switch specification.type {
        case .lowPass:
            b0 = (1 - cs) / 2
            b1 = 1 - cs
            b2 = (1 - cs) / 2
            a0 = 1 + alpha
            a1 = -2 * cs
            a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cs) / 2
            b1 = -(1 + cs)
            b2 = (1 + cs) / 2
            a0 = 1 + alpha
            a1 = -2 * cs
            a2 = 1 - alpha
        case .bandPass:
            b0 = alpha
            b1 = 0
            b2 = -alpha
            a0 = 1 + alpha
            a1 = -2 * cs
            a2 = 1 - alpha
        case .notch:
            b0 = 1
            b1 = -2 * cs
            b2 = 1
            a0 = 1 + alpha
            a1 = -2 * cs
            a2 = 1 - alpha
        case .allPass:
            b0 = 1 - alpha
            b1 = -2 * cs
            b2 = 1 + alpha
            a0 = 1 + alpha
            a1 = -2 * cs
            a2 = 1 - alpha
        case .peaking:
            b0 = 1 + alpha * amplitude
            b1 = -2 * cs
            b2 = 1 - alpha * amplitude
            a0 = 1 + alpha / amplitude
            a1 = -2 * cs
            a2 = 1 - alpha / amplitude
        case .lowShelf:
            b0 = amplitude * ((amplitude + 1) - (amplitude - 1) * cs + beta)
            b1 = 2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cs)
            b2 = amplitude * ((amplitude + 1) - (amplitude - 1) * cs - beta)
            a0 = (amplitude + 1) + (amplitude - 1) * cs + beta
            a1 = -2 * ((amplitude - 1) + (amplitude + 1) * cs)
            a2 = (amplitude + 1) + (amplitude - 1) * cs - beta
        case .highShelf:
            b0 = amplitude * ((amplitude + 1) + (amplitude - 1) * cs + beta)
            b1 = -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cs)
            b2 = amplitude * ((amplitude + 1) + (amplitude - 1) * cs - beta)
            a0 = (amplitude + 1) - (amplitude - 1) * cs + beta
            a1 = 2 * ((amplitude - 1) - (amplitude + 1) * cs)
            a2 = (amplitude + 1) - (amplitude - 1) * cs - beta
        }
        guard a0.isFinite, a0 != 0 else {
            return .bypass(.coefficientsRejected)
        }
        let coefficients = M1BiquadCoefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
        guard isValidBiquadStage(coefficients) else {
            return .bypass(.coefficientsRejected)
        }
        return .coefficients(coefficients)
    }

    /// Mirrors `isStableBiquad` in `EAUM1Runtime.cpp` so rejected designs never
    /// reach the runtime's final validation as a surprise.
    static func isValidBiquadStage(_ coefficients: M1BiquadCoefficients) -> Bool {
        func zeroOrNormal(_ value: Double) -> Bool {
            value == 0.0 || (value.isFinite && value.isNormal)
        }
        return zeroOrNormal(coefficients.b0)
            && zeroOrNormal(coefficients.b1)
            && zeroOrNormal(coefficients.b2)
            && zeroOrNormal(coefficients.a1)
            && zeroOrNormal(coefficients.a2)
            && abs(coefficients.a2) < 1.0
            && 1.0 + coefficients.a1 + coefficients.a2 > 0.0
            && 1.0 - coefficients.a1 + coefficients.a2 > 0.0
    }
}

enum M1BiquadFilterDesignOutcome: Equatable {
    case coefficients(M1BiquadCoefficients)
    case bypass(M1FilterBypassReason)
}
