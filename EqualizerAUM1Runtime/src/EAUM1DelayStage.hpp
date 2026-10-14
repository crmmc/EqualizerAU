#ifndef EAUM1_DELAY_STAGE_HPP
#define EAUM1_DELAY_STAGE_HPP

#include "EAUM1Runtime.h"

#include <cstddef>
#include <vector>

namespace eaum1 {

// Per-channel delay line with fractional (linear interpolation) readback.
// All memory is allocated at construction time on the control thread; the
// realtime path only touches preallocated storage.
class RuntimeDelayLine {
public:
    explicit RuntimeDelayLine(uint32_t integerDelay, float fraction)
        : history_(static_cast<std::size_t>(integerDelay) + 2, 0.0f),
          integerDelay_(integerDelay),
          fraction_(fraction) {}

    // Returns the sample delayed by integerDelay + fraction samples:
    // y[n] = (1 - f) * x[n - D] + f * x[n - D - 1].
    double process(double input) noexcept {
        const std::size_t length = history_.size();
        history_[writeIndex_] = static_cast<float>(input);
        const std::size_t nearIndex =
            (writeIndex_ + length - integerDelay_) % length;
        const std::size_t farIndex = (nearIndex + length - 1) % length;
        const double nearSample = static_cast<double>(history_[nearIndex]);
        const double farSample = static_cast<double>(history_[farIndex]);
        writeIndex_ = (writeIndex_ + 1) % length;
        const double weight = static_cast<double>(fraction_);
        return nearSample + weight * (farSample - nearSample);
    }

    uint32_t integerDelay() const noexcept { return integerDelay_; }
    float fraction() const noexcept { return fraction_; }

private:
    std::vector<float> history_;
    std::size_t writeIndex_ = 0;
    uint32_t integerDelay_;
    float fraction_;
};

}  // namespace eaum1

#endif
