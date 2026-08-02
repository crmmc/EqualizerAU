#ifndef EAUM1_CONVOLUTION_HPP
#define EAUM1_CONVOLUTION_HPP

#include "EAUM1Runtime.h"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <new>
#include <vector>

namespace eaum1 {

constexpr std::size_t kConvolutionQuantum = EAUM1_CONVOLUTION_PARTITION_SIZE;
constexpr std::size_t kDirectTapCount = 256;
constexpr std::size_t kSecondLength = 512;
constexpr std::size_t kThirdLength = 2048;
constexpr std::size_t kTailLength = 16384;
constexpr std::size_t kFirstOffset = 256;
constexpr std::size_t kSecondOffset = 512;
constexpr std::size_t kThirdOffset = 2560;
constexpr std::size_t kTailOffset = 18944;

static_assert(kConvolutionQuantum == kDirectTapCount);

inline vDSP_Length fftLog2(std::size_t size) noexcept {
    vDSP_Length result = 0;
    while ((std::size_t{1} << result) < size) {
        ++result;
    }
    return result;
}

inline std::size_t nextPowerOfTwo(std::size_t value) noexcept {
    std::size_t result = 1;
    while (result < value) {
        result <<= 1;
    }
    return result;
}

inline std::size_t segmentPartitionCount(
    std::size_t tapCount,
    std::size_t offset,
    std::size_t length,
    std::size_t maximum
) noexcept {
    if (tapCount <= offset) {
        return 0;
    }
    const std::size_t count = (tapCount - offset + length - 1) / length;
    return std::min(count, maximum);
}

struct FFTSetupDeleter {
    void operator()(OpaqueFFTSetupD *setup) const noexcept {
        if (setup != nullptr) {
            vDSP_destroy_fftsetupD(setup);
        }
    }
};

using OwnedFFTSetup = std::unique_ptr<OpaqueFFTSetupD, FFTSetupDeleter>;

struct ConvolutionSegment {
    std::size_t length;
    std::size_t partitions;
    std::size_t offset;
    std::size_t fftSize;
    vDSP_Length log2Size;
    std::size_t macGroups;
    OwnedFFTSetup setup;
    std::vector<double> kernelReal;
    std::vector<double> kernelImaginary;

    ConvolutionSegment(
        std::size_t segmentLength,
        std::size_t partitionCount,
        std::size_t segmentOffset,
        std::size_t distributedGroups,
        const float *taps,
        std::size_t tapCount
    );
};

inline ConvolutionSegment::ConvolutionSegment(
    std::size_t segmentLength,
    std::size_t partitionCount,
    std::size_t segmentOffset,
    std::size_t distributedGroups,
    const float *taps,
    std::size_t tapCount
) : length(segmentLength),
    partitions(partitionCount),
    offset(segmentOffset),
    fftSize(2 * segmentLength),
    log2Size(fftLog2(fftSize)),
    macGroups(distributedGroups),
    setup(vDSP_create_fftsetupD(log2Size, kFFTRadix2)),
    kernelReal(partitionCount * segmentLength),
    kernelImaginary(partitionCount * segmentLength) {
    if (setup == nullptr) {
        throw std::bad_alloc();
    }
    std::vector<double> time(fftSize, 0.0);
    for (std::size_t partition = 0; partition < partitions; ++partition) {
        std::fill(time.begin(), time.end(), 0.0);
        const std::size_t source = offset + partition * length;
        if (source < tapCount) {
            std::copy_n(taps + source, std::min(length, tapCount - source), time.data());
        }
        const std::size_t spectrumOffset = partition * length;
        DSPDoubleSplitComplex spectrum{
            kernelReal.data() + spectrumOffset,
            kernelImaginary.data() + spectrumOffset,
        };
        vDSP_ctozD(
            reinterpret_cast<const DSPDoubleComplex *>(time.data()),
            2,
            &spectrum,
            1,
            length
        );
        vDSP_fft_zripD(setup.get(), &spectrum, 1, log2Size, FFT_FORWARD);
    }
}

struct PreparedConvolutionKernel {
    std::vector<float> taps;
    std::vector<ConvolutionSegment> segments;
    std::size_t timelineSize = kConvolutionQuantum;

    PreparedConvolutionKernel(const float *source, std::size_t tapCount)
        : taps(source, source + tapCount) {
        const std::size_t firstCount = segmentPartitionCount(
            tapCount, kFirstOffset, kConvolutionQuantum, 1
        );
        const std::size_t secondCount = segmentPartitionCount(
            tapCount, kSecondOffset, kSecondLength, 4
        );
        const std::size_t thirdCount = segmentPartitionCount(
            tapCount, kThirdOffset, kThirdLength, 8
        );
        const std::size_t tailCount = segmentPartitionCount(
            tapCount,
            kTailOffset,
            kTailLength,
            std::numeric_limits<std::size_t>::max()
        );
        segments.reserve(4);
        appendSegment(kConvolutionQuantum, firstCount, kFirstOffset, 0);
        appendSegment(kSecondLength, secondCount, kSecondOffset, 0);
        appendSegment(kThirdLength, thirdCount, kThirdOffset, 2);
        appendSegment(kTailLength, tailCount, kTailOffset, 10);
        if (!segments.empty()) {
            timelineSize = nextPowerOfTwo(
                std::max(kConvolutionQuantum, segments.back().offset + kConvolutionQuantum)
            );
        }
    }

private:
    void appendSegment(
        std::size_t length,
        std::size_t partitions,
        std::size_t offset,
        std::size_t macGroups
    ) {
        if (partitions != 0) {
            segments.emplace_back(length, partitions, offset, macGroups, taps.data(), taps.size());
        }
    }
};

struct RuntimeSegmentState {
    std::vector<double> inputTime;
    std::vector<double> outputTime;
    std::vector<double> historyReal;
    std::vector<double> historyImaginary;
    std::vector<double> accumulatorReal;
    std::vector<double> accumulatorImaginary;
    std::size_t inputFill = 0;
    std::size_t historyHead = 0;
    std::size_t chunkIndex = 0;
    std::size_t jobPhase = 0;
    std::size_t jobHistoryHead = 0;
    std::size_t macCursor = 0;
    std::size_t absoluteTarget = 0;

    explicit RuntimeSegmentState(const ConvolutionSegment &segment)
        : inputTime(segment.fftSize, 0.0),
          outputTime(segment.fftSize, 0.0),
          historyReal(segment.partitions * segment.length, 0.0),
          historyImaginary(segment.partitions * segment.length, 0.0),
          accumulatorReal(segment.length, 0.0),
          accumulatorImaginary(segment.length, 0.0) {}
};

class RuntimeConvolution {
public:
    explicit RuntimeConvolution(
        std::shared_ptr<const PreparedConvolutionKernel> preparedKernel
    ) : kernel_(std::move(preparedKernel)),
        timeline_(kernel_->timelineSize, 0.0),
        timelineMask_(kernel_->timelineSize - 1) {
        states_.reserve(kernel_->segments.size());
        for (const ConvolutionSegment &segment : kernel_->segments) {
            states_.emplace_back(segment);
        }
    }

    double process(double input) noexcept;

    const std::shared_ptr<const PreparedConvolutionKernel> &kernelOwner() const noexcept {
        return kernel_;
    }

    std::size_t jobPhaseForTesting(std::size_t segmentOffset) const noexcept {
        for (std::size_t index = 0; index < kernel_->segments.size(); ++index) {
            if (kernel_->segments[index].offset == segmentOffset) {
                return states_[index].jobPhase;
            }
        }
        return std::numeric_limits<std::size_t>::max();
    }

private:
    static void startProduct(
        const DSPDoubleSplitComplex &input,
        const DSPDoubleSplitComplex &kernel,
        DSPDoubleSplitComplex &accumulator,
        std::size_t bins
    ) noexcept;
    static void addProduct(
        const DSPDoubleSplitComplex &input,
        const DSPDoubleSplitComplex &kernel,
        DSPDoubleSplitComplex &accumulator,
        std::size_t bins
    ) noexcept;
    static void prepareJob(
        const ConvolutionSegment &segment,
        RuntimeSegmentState &state
    ) noexcept;
    static void runMacUntil(
        const ConvolutionSegment &segment,
        RuntimeSegmentState &state,
        std::size_t end
    ) noexcept;
    static void runMacGroup(
        const ConvolutionSegment &segment,
        RuntimeSegmentState &state,
        std::size_t group
    ) noexcept;
    static void retireInput(
        const ConvolutionSegment &segment,
        RuntimeSegmentState &state
    ) noexcept;
    void publishJob(
        const ConvolutionSegment &segment,
        RuntimeSegmentState &state
    ) noexcept;
    void executeImmediate(
        const ConvolutionSegment &segment,
        RuntimeSegmentState &state
    ) noexcept;
    void beginDistributed(
        const ConvolutionSegment &segment,
        RuntimeSegmentState &state
    ) noexcept;
    void advanceDistributed(
        const ConvolutionSegment &segment,
        RuntimeSegmentState &state
    ) noexcept;
    void addToTimeline(
        std::size_t target,
        const double *values,
        std::size_t count
    ) noexcept;
    double takeTimeline() noexcept;

    std::shared_ptr<const PreparedConvolutionKernel> kernel_;
    std::vector<RuntimeSegmentState> states_;
    std::vector<double> timeline_;
    std::array<double, kDirectTapCount> directInput_{};
    std::size_t timelineMask_;
    std::size_t sampleCursor_ = 0;
};

inline void RuntimeConvolution::startProduct(
    const DSPDoubleSplitComplex &input,
    const DSPDoubleSplitComplex &kernel,
    DSPDoubleSplitComplex &accumulator,
    std::size_t bins
) noexcept {
    accumulator.realp[0] = input.realp[0] * kernel.realp[0];
    accumulator.imagp[0] = input.imagp[0] * kernel.imagp[0];
    if (bins == 1) {
        return;
    }
    DSPDoubleSplitComplex inputTail{input.realp + 1, input.imagp + 1};
    DSPDoubleSplitComplex kernelTail{kernel.realp + 1, kernel.imagp + 1};
    DSPDoubleSplitComplex accumulatorTail{
        accumulator.realp + 1,
        accumulator.imagp + 1,
    };
    vDSP_zvmulD(
        &inputTail, 1, &kernelTail, 1, &accumulatorTail, 1, bins - 1, 1
    );
}

inline void RuntimeConvolution::addProduct(
    const DSPDoubleSplitComplex &input,
    const DSPDoubleSplitComplex &kernel,
    DSPDoubleSplitComplex &accumulator,
    std::size_t bins
) noexcept {
    accumulator.realp[0] += input.realp[0] * kernel.realp[0];
    accumulator.imagp[0] += input.imagp[0] * kernel.imagp[0];
    if (bins == 1) {
        return;
    }
    DSPDoubleSplitComplex inputTail{input.realp + 1, input.imagp + 1};
    DSPDoubleSplitComplex kernelTail{kernel.realp + 1, kernel.imagp + 1};
    DSPDoubleSplitComplex accumulatorTail{
        accumulator.realp + 1,
        accumulator.imagp + 1,
    };
    vDSP_zvmaD(
        &inputTail,
        1,
        &kernelTail,
        1,
        &accumulatorTail,
        1,
        &accumulatorTail,
        1,
        bins - 1
    );
}

inline void RuntimeConvolution::prepareJob(
    const ConvolutionSegment &segment,
    RuntimeSegmentState &state
) noexcept {
    state.jobHistoryHead = state.historyHead;
    const std::size_t spectrumOffset = state.jobHistoryHead * segment.length;
    DSPDoubleSplitComplex spectrum{
        state.historyReal.data() + spectrumOffset,
        state.historyImaginary.data() + spectrumOffset,
    };
    vDSP_ctozD(
        reinterpret_cast<const DSPDoubleComplex *>(state.inputTime.data()),
        2,
        &spectrum,
        1,
        segment.length
    );
    vDSP_fft_zripD(
        segment.setup.get(), &spectrum, 1, segment.log2Size, FFT_FORWARD
    );
    state.macCursor = 0;
    state.absoluteTarget = state.chunkIndex * segment.length + segment.offset;
}

inline void RuntimeConvolution::runMacUntil(
    const ConvolutionSegment &segment,
    RuntimeSegmentState &state,
    std::size_t end
) noexcept {
    DSPDoubleSplitComplex accumulator{
        state.accumulatorReal.data(),
        state.accumulatorImaginary.data(),
    };
    while (state.macCursor < end) {
        const std::size_t partition = state.macCursor;
        const std::size_t historyIndex = (
            state.jobHistoryHead + segment.partitions - partition
        ) % segment.partitions;
        const std::size_t historyOffset = historyIndex * segment.length;
        const std::size_t kernelOffset = partition * segment.length;
        DSPDoubleSplitComplex history{
            state.historyReal.data() + historyOffset,
            state.historyImaginary.data() + historyOffset,
        };
        DSPDoubleSplitComplex kernel{
            const_cast<double *>(segment.kernelReal.data() + kernelOffset),
            const_cast<double *>(segment.kernelImaginary.data() + kernelOffset),
        };
        if (partition == 0) {
            startProduct(history, kernel, accumulator, segment.length);
        } else {
            addProduct(history, kernel, accumulator, segment.length);
        }
        ++state.macCursor;
    }
}

inline void RuntimeConvolution::runMacGroup(
    const ConvolutionSegment &segment,
    RuntimeSegmentState &state,
    std::size_t group
) noexcept {
    const std::size_t end = segment.partitions * (group + 1) / segment.macGroups;
    runMacUntil(segment, state, end);
}

inline void RuntimeConvolution::retireInput(
    const ConvolutionSegment &segment,
    RuntimeSegmentState &state
) noexcept {
    std::copy_n(
        state.inputTime.data() + segment.length,
        segment.length,
        state.inputTime.data()
    );
    state.historyHead = (state.historyHead + 1) % segment.partitions;
    ++state.chunkIndex;
}

inline void RuntimeConvolution::publishJob(
    const ConvolutionSegment &segment,
    RuntimeSegmentState &state
) noexcept {
    DSPDoubleSplitComplex accumulator{
        state.accumulatorReal.data(),
        state.accumulatorImaginary.data(),
    };
    vDSP_fft_zripD(
        segment.setup.get(), &accumulator, 1, segment.log2Size, FFT_INVERSE
    );
    vDSP_ztocD(
        &accumulator,
        1,
        reinterpret_cast<DSPDoubleComplex *>(state.outputTime.data()),
        2,
        segment.length
    );
    const double scale = 1.0 / static_cast<double>(4 * segment.fftSize);
    vDSP_vsmulD(
        state.outputTime.data() + segment.length,
        1,
        &scale,
        state.outputTime.data() + segment.length,
        1,
        segment.length
    );
    addToTimeline(
        state.absoluteTarget,
        state.outputTime.data() + segment.length,
        segment.length
    );
}

inline void RuntimeConvolution::executeImmediate(
    const ConvolutionSegment &segment,
    RuntimeSegmentState &state
) noexcept {
    prepareJob(segment, state);
    runMacUntil(segment, state, segment.partitions);
    publishJob(segment, state);
    retireInput(segment, state);
}

inline void RuntimeConvolution::beginDistributed(
    const ConvolutionSegment &segment,
    RuntimeSegmentState &state
) noexcept {
    prepareJob(segment, state);
    runMacGroup(segment, state, 0);
    state.jobPhase = 1;
    retireInput(segment, state);
}

inline void RuntimeConvolution::advanceDistributed(
    const ConvolutionSegment &segment,
    RuntimeSegmentState &state
) noexcept {
    if (state.jobPhase == 0) {
        return;
    }
    if (state.jobPhase < segment.macGroups) {
        runMacGroup(segment, state, state.jobPhase);
        ++state.jobPhase;
        return;
    }
    publishJob(segment, state);
    state.jobPhase = 0;
}

inline void RuntimeConvolution::addToTimeline(
    std::size_t target,
    const double *values,
    std::size_t count
) noexcept {
    const std::size_t position = target & timelineMask_;
    const std::size_t first = std::min(count, timeline_.size() - position);
    vDSP_vaddD(
        timeline_.data() + position,
        1,
        values,
        1,
        timeline_.data() + position,
        1,
        first
    );
    if (first < count) {
        vDSP_vaddD(
            timeline_.data(),
            1,
            values + first,
            1,
            timeline_.data(),
            1,
            count - first
        );
    }
}

inline double RuntimeConvolution::takeTimeline() noexcept {
    const std::size_t position = sampleCursor_ & timelineMask_;
    const double value = timeline_[position];
    timeline_[position] = 0.0;
    return value;
}

inline double RuntimeConvolution::process(double input) noexcept {
    if ((sampleCursor_ & (kConvolutionQuantum - 1)) == 0) {
        for (std::size_t index = 0; index < kernel_->segments.size(); ++index) {
            const ConvolutionSegment &segment = kernel_->segments[index];
            if (segment.macGroups != 0) {
                advanceDistributed(segment, states_[index]);
            }
        }
    }

    const std::size_t directPosition = sampleCursor_ & (kDirectTapCount - 1);
    directInput_[directPosition] = input;
    double result = takeTimeline();
    const std::size_t headCount = std::min(kernel_->taps.size(), kDirectTapCount);
    for (std::size_t tap = 0; tap < headCount; ++tap) {
        const std::size_t inputIndex = (
            directPosition + kDirectTapCount - tap
        ) & (kDirectTapCount - 1);
        result += static_cast<double>(kernel_->taps[tap]) * directInput_[inputIndex];
    }

    for (std::size_t index = 0; index < kernel_->segments.size(); ++index) {
        const ConvolutionSegment &segment = kernel_->segments[index];
        RuntimeSegmentState &state = states_[index];
        state.inputTime[segment.length + state.inputFill] = input;
        ++state.inputFill;
        if (state.inputFill != segment.length) {
            continue;
        }
        if (segment.macGroups == 0) {
            executeImmediate(segment, state);
        } else {
            beginDistributed(segment, state);
        }
        state.inputFill = 0;
    }
    ++sampleCursor_;
    return result;
}

inline bool kernelTapsEqual(
    const PreparedConvolutionKernel &kernel,
    const float *taps,
    std::size_t tapCount
) noexcept {
    return kernel.taps.size() == tapCount
        && std::equal(kernel.taps.begin(), kernel.taps.end(), taps);
}

}  // namespace eaum1

#endif
