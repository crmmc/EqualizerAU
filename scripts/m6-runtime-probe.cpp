#include "EAUM1Runtime.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {
constexpr uint32_t kFrames = 256;
constexpr uint32_t kTapCount = 16384;
constexpr uint32_t kMeasuredBlocks = 2000;

void require(EAUM1Status status, const char *operation) {
    if (status != EAUM1StatusOK) {
        std::fprintf(stderr, "%s failed: %d\n", operation, status);
        std::exit(1);
    }
}

EAUM1PreparedState *makePrepared(uint32_t channels, const std::vector<float> &taps) {
    EAUM1PreparedConvolution convolution = {
        .tapCount = static_cast<uint32_t>(taps.size()),
        .taps = taps.data(),
    };
    std::vector<EAUM1PreparedStage> stages;
    stages.reserve(channels);
    for (uint32_t channel = 0; channel < channels; ++channel) {
        stages.push_back({
            .kind = EAUM1PreparedStageConvolution,
            .channelIndex = channel,
            .b0 = static_cast<double>(channel),
            .b1 = 0.0,
            .b2 = 0.0,
            .a1 = 0.0,
            .a2 = 0.0,
        });
    }
    std::vector<EAUM1PreparedConvolution> convolutions(channels, convolution);
    EAUM1PreparedDescriptionV3 description = {
        .channelCount = channels,
        .stageCount = static_cast<uint32_t>(stages.size()),
        .stages = stages.data(),
        .convolutionCount = static_cast<uint32_t>(convolutions.size()),
        .convolutions = convolutions.data(),
    };
    EAUM1PreparedState *prepared = nullptr;
    require(EAUM1PreparedStateCreateV3(&description, &prepared), "prepare");
    return prepared;
}
}

int main() {
    std::vector<float> taps(kTapCount, 0.0f);
    taps[0] = 1.0f;

    for (uint32_t channels : {1u, 2u, 4u, 8u}) {
        const auto prepareStart = std::chrono::steady_clock::now();
        EAUM1PreparedState *prepared = makePrepared(channels, taps);
        const auto prepareEnd = std::chrono::steady_clock::now();

        const uint32_t channelCount = channels;
        const EAUM1RuntimeDescription description = {
            .sampleRate = 48000.0,
            .maximumFrameCount = kFrames,
            .bufferCount = 1,
            .channelCounts = &channelCount,
            .effectsEnabled = 1,
        };
        EAUM1Runtime *runtime = nullptr;
        require(EAUM1RuntimeCreate(&description, &prepared, &runtime), "create");

        std::vector<float> samples(static_cast<size_t>(kFrames) * channels, 0.0f);
        EAUM1AudioBuffer buffer = {
            .samples = samples.data(),
            .channelCount = channels,
        };
        for (uint32_t block = 0; block < 100; ++block) {
            require(EAUM1RuntimeProcess(runtime, &buffer, 1, kFrames), "warmup");
        }

        const auto stableStart = std::chrono::steady_clock::now();
        for (uint32_t block = 0; block < kMeasuredBlocks; ++block) {
            require(EAUM1RuntimeProcess(runtime, &buffer, 1, kFrames), "stable process");
        }
        const auto stableEnd = std::chrono::steady_clock::now();

        EAUM1PreparedState *candidate = makePrepared(channels, taps);
        EAUM1PublicationOutcome outcome = {};
        require(EAUM1RuntimePublishPrepared(runtime, &candidate, &outcome), "publish");
        const auto transitionStart = std::chrono::steady_clock::now();
        require(EAUM1RuntimeProcess(runtime, &buffer, 1, kFrames), "transition process 1");
        require(EAUM1RuntimeProcess(runtime, &buffer, 1, kFrames), "transition process 2");
        const auto transitionEnd = std::chrono::steady_clock::now();

        const double prepareMs = std::chrono::duration<double, std::milli>(
            prepareEnd - prepareStart
        ).count();
        const double stableMs = std::chrono::duration<double, std::milli>(
            stableEnd - stableStart
        ).count();
        const double transitionMs = std::chrono::duration<double, std::milli>(
            transitionEnd - transitionStart
        ).count();
        const double stableAudioMs = static_cast<double>(kMeasuredBlocks) * kFrames / 48.0;
        const double transitionAudioMs = 2.0 * kFrames / 48.0;
        std::printf(
            "M6_RUNTIME_METRIC channels=%u prepare_ms=%.3f stable_ratio=%.5f "
            "stable_us_per_block=%.3f transition_ratio=%.5f\n",
            channels,
            prepareMs,
            stableMs / stableAudioMs,
            stableMs * 1000.0 / kMeasuredBlocks,
            transitionMs / transitionAudioMs
        );
        EAUM1RuntimeDestroy(runtime);
    }
}
