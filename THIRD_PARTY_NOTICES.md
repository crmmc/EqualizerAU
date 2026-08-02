# Third-Party Notices

EqualizerAU is distributed under the GNU General Public License version 3 or later. See
[`LICENSE`](LICENSE) for the complete terms.

## EqualizerAPO

Parts of EqualizerAU's Graphic EQ behavior and implementation are based on EqualizerAPO:

> EqualizerAPO, a system-wide equalizer
> Copyright (C) 2015 Jonas Thedering
> GNU General Public License version 2 or later

The corresponding EqualizerAPO source files are:

- `filters/GraphicEQFilter.cpp`: minimum-phase Graphic EQ spectrum, 32,768-point design,
  16,384-tap truncation, magnitude floor, real-cepstrum transform and one-sided cosine taper;
- `helpers/GainIterator.cpp`: constant endpoint gains and linear dB interpolation on a logarithmic
  frequency axis;
- `Editor/guis/GraphicEQFilterGUI.cpp`: CSV number-pair parsing and tab-separated export behavior.

EqualizerAU reimplements these parts in Swift using Accelerate and adds strict model validation,
positive-frequency and gain contracts, cooperative cancellation, finite-value checks, subnormal
zeroing, an active 20 Hz to 20 kHz processing domain, deterministic schema migration and explicit
resolution diagnostics. The SwiftUI editor also uses EqualizerAPO as a workflow reference, but it
is not a translation of the Qt editor.

EqualizerAPO's GPL-2.0-or-later terms permit distribution of these modified parts under this
project's GPL-3.0-or-later license. EqualizerAPO's original notices and disclaimer remain applicable
to the portions derived from the files listed above.

## Algorithm references

The historical fixed-band Graphic EQ used peaking-biquad equations from Robert Bristow-Johnson's
Audio EQ Cookbook. M6 replaced that product model with the minimum-phase FIR described above, while
the Runtime retains a generic biquad execution stage for migrated and compatible processing data.

## Dependency boundary

EqualizerAU does not copy, link or distribute EqualizerAPO's bundled libHybridConv, FFTW or
libsndfile code. Its Runtime FFT/convolution engine and WAV decoder are independent implementations. The project also does not bundle source or binary code from the local
Resonance reference project or its Rust dependencies.

Apple Accelerate, Foundation, CryptoKit, CoreAudio and AudioToolbox are operating-system frameworks
and are not redistributed as third-party source by this project.
