#include "EAUM1Runtime.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <limits>
#include <numeric>
#include <vector>

namespace {
constexpr uint32_t kFrames = 256;
constexpr uint32_t kDefaultTapCount = 16384;
constexpr uint32_t kDefaultMeasuredBlocks = 2000;
constexpr double kDeadlineNanoseconds = 256.0 / 48000.0 * 1.0e9;

void require(EAUM1Status status, const char *operation);

uint64_t threadCPUTimeNanoseconds() {
    timespec value{};
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) != 0) {
        std::perror("clock_gettime");
        std::exit(1);
    }
    return static_cast<uint64_t>(value.tv_sec) * 1'000'000'000u
        + static_cast<uint64_t>(value.tv_nsec);
}

uint64_t percentile(std::vector<uint64_t> values, double quantile) {
    std::sort(values.begin(), values.end());
    const size_t index = static_cast<size_t>(
        std::ceil(quantile * static_cast<double>(values.size()))
    ) - 1;
    return values[index];
}

size_t deadlineMisses(const std::vector<uint64_t> &values) {
    return static_cast<size_t>(std::count_if(
        values.begin(),
        values.end(),
        [](uint64_t value) { return value > kDeadlineNanoseconds; }
    ));
}

double maximumMicroseconds(const std::vector<uint64_t> &values) {
    return static_cast<double>(*std::max_element(values.begin(), values.end())) / 1000.0;
}

double p99Microseconds(const std::vector<uint64_t> &values) {
    return static_cast<double>(percentile(values, 0.99)) / 1000.0;
}

std::vector<float> makeDenseTaps(uint32_t tapCount) {
    std::vector<float> taps(tapCount);
    uint32_t state = 0x6D2B79F5u;
    const double decayScale = std::max(1.0, static_cast<double>(tapCount) / 6.0);
    for (uint32_t index = 0; index < tapCount; ++index) {
        state = state * 1664525u + 1013904223u;
        const double unit = static_cast<double>(state >> 8) / 16777215.0 - 0.5;
        float value = static_cast<float>(
            unit * 0.02 * std::exp(-index / decayScale)
        );
        if (value != 0.0f && !std::isnormal(value)) {
            value = 0.0f;
        }
        taps[index] = value;
    }
    taps[0] += 0.5f;
    if (taps.back() == 0.0f) {
        taps.back() = std::numeric_limits<float>::min();
    }
    return taps;
}

struct BlockMeasurements {
    std::vector<uint64_t> wall;
    std::vector<uint64_t> cpu;
};

BlockMeasurements measureBlocks(
    EAUM1Runtime *runtime,
    EAUM1AudioBuffer *buffer,
    const std::vector<float> &source,
    uint32_t blockCount,
    const char *operation
) {
    BlockMeasurements result;
    result.wall.reserve(blockCount);
    result.cpu.reserve(blockCount);
    for (uint32_t block = 0; block < blockCount; ++block) {
        std::copy(source.begin(), source.end(), buffer->samples);
        const uint64_t cpuStart = threadCPUTimeNanoseconds();
        const auto wallStart = std::chrono::steady_clock::now();
        require(EAUM1RuntimeProcess(runtime, buffer, 1, kFrames), operation);
        const auto wallEnd = std::chrono::steady_clock::now();
        const uint64_t cpuEnd = threadCPUTimeNanoseconds();
        result.wall.push_back(static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                wallEnd - wallStart
            ).count()
        ));
        result.cpu.push_back(cpuEnd - cpuStart);
    }
    return result;
}

void require(EAUM1Status status, const char *operation) {
    if (status != EAUM1StatusOK) {
        std::fprintf(stderr, "%s failed: %d\n", operation, status);
        std::exit(1);
    }
}

uint32_t parsePositiveUInt32(const char *value, const char *name) {
    errno = 0;
    char *end = nullptr;
    const unsigned long parsed = std::strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed == 0
        || parsed > std::numeric_limits<uint32_t>::max()) {
        std::fprintf(stderr, "%s must be a positive uint32\n", name);
        std::exit(1);
    }
    return static_cast<uint32_t>(parsed);
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

int main(int argc, char **argv) {
    const uint32_t tapCount = argc > 1
        ? parsePositiveUInt32(argv[1], "tapCount")
        : kDefaultTapCount;
    const uint32_t measuredBlocks = argc > 2
        ? parsePositiveUInt32(argv[2], "measuredBlocks")
        : kDefaultMeasuredBlocks;
    const char *metricPrefix = std::getenv("EAUM1_METRIC_PREFIX");
    if (metricPrefix == nullptr) {
        metricPrefix = "M6_RUNTIME_METRIC";
    }
    std::vector<float> taps = makeDenseTaps(tapCount);

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
        const auto createStart = std::chrono::steady_clock::now();
        require(EAUM1RuntimeCreate(&description, &prepared, &runtime), "create");
        const auto createEnd = std::chrono::steady_clock::now();

        std::vector<float> sourceSamples(static_cast<size_t>(kFrames) * channels);
        for (size_t index = 0; index < sourceSamples.size(); ++index) {
            sourceSamples[index] = static_cast<float>(
                (static_cast<int>(index % 31) - 15) * 0.001
            );
        }
        std::vector<float> samples(sourceSamples);
        EAUM1AudioBuffer buffer = {
            .samples = samples.data(),
            .channelCount = channels,
        };
        const char *runIndexText = std::getenv("EAUM1_PROBE_RUN_INDEX");
        const uint32_t runIndex = runIndexText == nullptr
            ? 0
            : parsePositiveUInt32(runIndexText, "EAUM1_PROBE_RUN_INDEX");
        const uint32_t phaseOffset = (runIndex * 13) % 64;
        const uint32_t warmupBlocks = (tapCount + kFrames - 1) / kFrames
            + 64
            + phaseOffset;
        for (uint32_t block = 0; block < warmupBlocks; ++block) {
            std::copy(sourceSamples.begin(), sourceSamples.end(), samples.begin());
            require(EAUM1RuntimeProcess(runtime, &buffer, 1, kFrames), "warmup");
        }

        const BlockMeasurements stable = measureBlocks(
            runtime,
            &buffer,
            sourceSamples,
            measuredBlocks,
            "stable process"
        );

        std::vector<float> candidateTaps = taps;
        candidateTaps[0] = 0.5f;
        EAUM1PreparedState *candidate = makePrepared(channels, candidateTaps);
        EAUM1PublicationOutcome outcome = {};
        require(EAUM1RuntimePublishPrepared(runtime, &candidate, &outcome), "publish");
        const BlockMeasurements transition = measureBlocks(
            runtime,
            &buffer,
            sourceSamples,
            2,
            "transition process"
        );
        if ((outcome.flags & EAUM1PublicationMaintenanceRequired) != 0) {
            EAUM1PublicationOutcome maintenance = {};
            require(
                EAUM1RuntimePerformMaintenance(
                    runtime,
                    outcome.retirementTicket,
                    &maintenance
                ),
                "transition maintenance"
            );
        }
        for (uint32_t block = 2; block < warmupBlocks; ++block) {
            std::copy(sourceSamples.begin(), sourceSamples.end(), samples.begin());
            require(EAUM1RuntimeProcess(runtime, &buffer, 1, kFrames), "fade warmup");
        }

        require(EAUM1RuntimeSetEffectsEnabled(runtime, 0), "disable effects");
        const BlockMeasurements fadeOut = measureBlocks(
            runtime,
            &buffer,
            sourceSamples,
            2,
            "fade-out process"
        );
        EAUM1EffectsState effectsState = 0;
        require(EAUM1RuntimeCopyEffectsState(runtime, &effectsState), "effects state");
        if (effectsState != EAUM1EffectsStateBypassed) {
            std::fprintf(stderr, "effects did not reach bypassed state\n");
            std::exit(1);
        }
        const BlockMeasurements bypassed = measureBlocks(
            runtime,
            &buffer,
            sourceSamples,
            measuredBlocks,
            "bypassed process"
        );

        const double prepareMs = std::chrono::duration<double, std::milli>(
            prepareEnd - prepareStart
        ).count();
        const double createMs = std::chrono::duration<double, std::milli>(
            createEnd - createStart
        ).count();
        const uint64_t stableWallNs = std::accumulate(
            stable.wall.begin(), stable.wall.end(), uint64_t{0}
        );
        const uint64_t transitionWallNs = std::accumulate(
            transition.wall.begin(), transition.wall.end(), uint64_t{0}
        );
        const uint64_t fadeOutWallNs = std::accumulate(
            fadeOut.wall.begin(), fadeOut.wall.end(), uint64_t{0}
        );
        const uint64_t bypassedWallNs = std::accumulate(
            bypassed.wall.begin(), bypassed.wall.end(), uint64_t{0}
        );
        const double stableAudioNs = static_cast<double>(measuredBlocks)
            * kDeadlineNanoseconds;
        const double transitionAudioNs = 2.0 * kDeadlineNanoseconds;
        const size_t wallMisses = deadlineMisses(stable.wall);
        const size_t cpuMisses = deadlineMisses(stable.cpu);
        EAUM1RuntimeDiagnostics diagnostics = {};
        require(EAUM1RuntimeCopyDiagnostics(runtime, &diagnostics), "copy diagnostics");
        if (diagnostics.saturatedOutputSampleCount != 0
            || diagnostics.nonFiniteInputSampleCount != 0
            || diagnostics.invalidProcessCallCount != 0) {
            std::fprintf(stderr, "probe diagnostics are nonzero\n");
            std::exit(1);
        }
        std::printf(
            "%s taps=%u channels=%u dense=1 phase_offset=%u warmup_blocks=%u "
            "prepare_ms=%.3f create_ms=%.3f stable_ratio=%.5f "
            "stable_us_per_block=%.3f stable_wall_p99_us=%.3f "
            "stable_cpu_p99_us=%.3f stable_wall_max_us=%.3f "
            "stable_cpu_max_us=%.3f wall_misses=%zu cpu_misses=%zu "
            "transition_ratio=%.5f transition_wall_p99_us=%.3f "
            "transition_cpu_p99_us=%.3f transition_wall_max_us=%.3f "
            "transition_cpu_max_us=%.3f transition_wall_misses=%zu "
            "transition_cpu_misses=%zu fade_out_ratio=%.5f "
            "fade_wall_p99_us=%.3f fade_cpu_p99_us=%.3f "
            "fade_wall_max_us=%.3f fade_cpu_max_us=%.3f "
            "fade_wall_misses=%zu fade_cpu_misses=%zu bypassed_ratio=%.5f "
            "bypass_wall_p99_us=%.3f bypass_cpu_p99_us=%.3f "
            "bypass_wall_max_us=%.3f bypass_cpu_max_us=%.3f "
            "bypass_wall_misses=%zu bypass_cpu_misses=%zu\n",
            metricPrefix,
            tapCount,
            channels,
            phaseOffset,
            warmupBlocks,
            prepareMs,
            createMs,
            static_cast<double>(stableWallNs) / stableAudioNs,
            static_cast<double>(stableWallNs) / measuredBlocks / 1000.0,
            p99Microseconds(stable.wall),
            p99Microseconds(stable.cpu),
            maximumMicroseconds(stable.wall),
            maximumMicroseconds(stable.cpu),
            wallMisses,
            cpuMisses,
            static_cast<double>(transitionWallNs) / transitionAudioNs,
            p99Microseconds(transition.wall),
            p99Microseconds(transition.cpu),
            maximumMicroseconds(transition.wall),
            maximumMicroseconds(transition.cpu),
            deadlineMisses(transition.wall),
            deadlineMisses(transition.cpu),
            static_cast<double>(fadeOutWallNs) / transitionAudioNs,
            p99Microseconds(fadeOut.wall),
            p99Microseconds(fadeOut.cpu),
            maximumMicroseconds(fadeOut.wall),
            maximumMicroseconds(fadeOut.cpu),
            deadlineMisses(fadeOut.wall),
            deadlineMisses(fadeOut.cpu),
            static_cast<double>(bypassedWallNs) / stableAudioNs,
            p99Microseconds(bypassed.wall),
            p99Microseconds(bypassed.cpu),
            maximumMicroseconds(bypassed.wall),
            maximumMicroseconds(bypassed.cpu),
            deadlineMisses(bypassed.wall),
            deadlineMisses(bypassed.cpu)
        );
        EAUM1RuntimeDestroy(runtime);
    }
}
