#import <XCTest/XCTest.h>

#include "EAUM1Runtime.h"

#include <cmath>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstring>
#include <limits>
#include <type_traits>
#include <thread>
#include <vector>

static_assert(std::is_standard_layout_v<EAUM1RuntimeCapabilities>);
static_assert(std::is_trivially_copyable_v<EAUM1RuntimeCapabilities>);
static_assert(sizeof(EAUM1RuntimeCapabilities) == 4);
static_assert(sizeof(EAUM1RuntimeDescription) == 32);
static_assert(offsetof(EAUM1RuntimeDescription, channelCounts) == 16);
static_assert(sizeof(EAUM1AudioBuffer) == 16);
static_assert(sizeof(EAUM1RuntimeDiagnostics) == 24);
static_assert(sizeof(EAUM1PublicationOutcome) == 16);
static_assert(sizeof(EAUM1ConcurrencyDiagnostics) == 8);
static_assert(std::is_standard_layout_v<EAUM1PreparedStage>);
static_assert(std::is_trivially_copyable_v<EAUM1PreparedStage>);
static_assert(sizeof(EAUM1PreparedStage) == 48);
static_assert(offsetof(EAUM1PreparedStage, b0) == 8);
static_assert(sizeof(EAUM1PreparedDescription) == 16);
static_assert(std::is_standard_layout_v<EAUM1PreparedConvolution>);
static_assert(std::is_trivially_copyable_v<EAUM1PreparedConvolution>);
static_assert(sizeof(EAUM1PreparedConvolution) == 16);
static_assert(offsetof(EAUM1PreparedConvolution, taps) == 8);
static_assert(std::is_standard_layout_v<EAUM1PreparedDescriptionV3>);
static_assert(std::is_trivially_copyable_v<EAUM1PreparedDescriptionV3>);
static_assert(sizeof(EAUM1PreparedDescriptionV3) == 32);
static_assert(offsetof(EAUM1PreparedDescriptionV3, stages) == 8);
static_assert(offsetof(EAUM1PreparedDescriptionV3, convolutions) == 24);

namespace EAUM1TestHooks {
bool acquireCallback(EAUM1Runtime *runtime);
void completeCallback(EAUM1Runtime *runtime);
void setCallbackState(EAUM1Runtime *runtime, uint64_t state);
uint64_t callbackState(const EAUM1Runtime *runtime);
uintptr_t activePrepared(const EAUM1Runtime *runtime);
uintptr_t retiredPrepared(const EAUM1Runtime *runtime);
uintptr_t pendingPrepared(const EAUM1Runtime *runtime);
uint64_t storedRetirementTicket(const EAUM1Runtime *runtime);
uint64_t livePreparedCount();
}

static EAUM1PreparedState *createPrepared(float gain) {
    EAUM1PreparedState *prepared = nullptr;
    XCTAssertEqual(EAUM1PreparedStateCreate(&gain, 1, &prepared), EAUM1StatusOK);
    XCTAssertNotEqual(prepared, nullptr);
    return prepared;
}

static EAUM1Runtime *createRuntime(float gain, double sampleRate = 1000.0) {
    EAUM1PreparedState *prepared = createPrepared(gain);
    const uint32_t channelCount = 1;
    const EAUM1RuntimeDescription description = {
        .sampleRate = sampleRate,
        .maximumFrameCount = 32,
        .bufferCount = 1,
        .channelCounts = &channelCount,
        .effectsEnabled = 1,
    };
    EAUM1Runtime *runtime = nullptr;
    XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, &runtime), EAUM1StatusOK);
    XCTAssertEqual(prepared, nullptr);
    XCTAssertNotEqual(runtime, nullptr);
    return runtime;
}

static EAUM1PreparedState *createPreparedV2(
    uint32_t channelCount,
    const EAUM1PreparedStage *stages,
    uint32_t stageCount
) {
    EAUM1PreparedDescription description = {
        .channelCount = channelCount,
        .stageCount = stageCount,
        .stages = stages,
    };
    EAUM1PreparedState *prepared = nullptr;
    XCTAssertEqual(EAUM1PreparedStateCreateV2(&description, &prepared), EAUM1StatusOK);
    XCTAssertNotEqual(prepared, nullptr);
    return prepared;
}

static EAUM1PreparedState *createPreparedV3(
    uint32_t channelCount,
    const EAUM1PreparedStage *stages,
    uint32_t stageCount,
    const EAUM1PreparedConvolution *convolutions,
    uint32_t convolutionCount
) {
    const EAUM1PreparedDescriptionV3 description = {
        .channelCount = channelCount,
        .stageCount = stageCount,
        .stages = stages,
        .convolutionCount = convolutionCount,
        .convolutions = convolutions,
    };
    EAUM1PreparedState *prepared = nullptr;
    XCTAssertEqual(EAUM1PreparedStateCreateV3(&description, &prepared), EAUM1StatusOK);
    XCTAssertNotEqual(prepared, nullptr);
    return prepared;
}

static EAUM1Runtime *createRuntimeWithPrepared(
    EAUM1PreparedState **prepared,
    uint32_t channelCount,
    uint32_t maximumFrameCount = 512,
    double sampleRate = 48000.0
) {
    const EAUM1RuntimeDescription description = {
        .sampleRate = sampleRate,
        .maximumFrameCount = maximumFrameCount,
        .bufferCount = 1,
        .channelCounts = &channelCount,
        .effectsEnabled = 1,
    };
    EAUM1Runtime *runtime = nullptr;
    XCTAssertEqual(EAUM1RuntimeCreate(&description, prepared, &runtime), EAUM1StatusOK);
    XCTAssertEqual(*prepared, nullptr);
    XCTAssertNotEqual(runtime, nullptr);
    return runtime;
}

@interface EAUM1RuntimeSmokeTests : XCTestCase
@end

@implementation EAUM1RuntimeSmokeTests

- (void)testFormalABIAndRequiredAtomicsAreLockFree {
    XCTAssertEqual(EAUM1RuntimeABIVersion(), EAUM1_RUNTIME_ABI_VERSION);

    EAUM1RuntimeCapabilities capabilities = {};
    XCTAssertEqual(EAUM1RuntimeGetCapabilities(&capabilities), EAUM1StatusOK);
    XCTAssertEqual(capabilities.activePreparedPointerLockFree, 1);
    XCTAssertEqual(capabilities.callbackStateLockFree, 1);
    XCTAssertEqual(capabilities.effectsEnabledLockFree, 1);
    XCTAssertEqual(capabilities.diagnosticCountersLockFree, 1);
    XCTAssertEqual(EAUM1RuntimeGetCapabilities(nullptr), EAUM1StatusInvalidArgument);
}

- (void)testPreparedStateValidatesAndCopiesFiniteNormalTargets {
    EAUM1PreparedState *prepared = reinterpret_cast<EAUM1PreparedState *>(0x1);
    XCTAssertEqual(EAUM1PreparedStateCreate(nullptr, 1, &prepared), EAUM1StatusInvalidArgument);
    XCTAssertEqual(prepared, nullptr);

    const float invalidTargets[] = {
        -1.0f,
        std::numeric_limits<float>::quiet_NaN(),
        std::numeric_limits<float>::infinity(),
        std::numeric_limits<float>::denorm_min(),
    };
    for (float target : invalidTargets) {
        prepared = reinterpret_cast<EAUM1PreparedState *>(0x1);
        XCTAssertEqual(EAUM1PreparedStateCreate(&target, 1, &prepared), EAUM1StatusInvalidArgument);
        XCTAssertEqual(prepared, nullptr);
    }

    const float validTargets[] = {0.0f, std::numeric_limits<float>::min(), 1.0f};
    XCTAssertEqual(EAUM1PreparedStateCreate(validTargets, 3, &prepared), EAUM1StatusOK);
    XCTAssertNotEqual(prepared, nullptr);
    EAUM1PreparedStateDestroy(prepared);
}

- (void)testPreparedV2RejectsMalformedUnstableAndOverCapacityStages {
    EAUM1PreparedState *prepared = reinterpret_cast<EAUM1PreparedState *>(0x1);
    XCTAssertEqual(EAUM1PreparedStateCreateV2(nullptr, &prepared), EAUM1StatusInvalidArgument);
    XCTAssertEqual(prepared, nullptr);

    EAUM1PreparedDescription transparent = {
        .channelCount = 2,
        .stageCount = 0,
        .stages = nullptr,
    };
    XCTAssertEqual(EAUM1PreparedStateCreateV2(&transparent, &prepared), EAUM1StatusOK);
    EAUM1PreparedStateDestroy(prepared);

    EAUM1PreparedStage invalidGain = {
        .kind = EAUM1PreparedStageGain,
        .channelIndex = 0,
        .b0 = 1.0,
        .b1 = 1.0,
    };
    EAUM1PreparedDescription description = {
        .channelCount = 2,
        .stageCount = 1,
        .stages = &invalidGain,
    };
    XCTAssertEqual(EAUM1PreparedStateCreateV2(&description, &prepared), EAUM1StatusInvalidArgument);

    invalidGain.b0 = std::numeric_limits<double>::denorm_min();
    invalidGain.b1 = 0.0;
    XCTAssertEqual(EAUM1PreparedStateCreateV2(&description, &prepared), EAUM1StatusInvalidArgument);

    EAUM1PreparedStage unstable = {
        .kind = EAUM1PreparedStageBiquad,
        .channelIndex = 0,
        .b0 = 1.0,
        .a2 = 1.0,
    };
    description.stages = &unstable;
    XCTAssertEqual(EAUM1PreparedStateCreateV2(&description, &prepared), EAUM1StatusInvalidArgument);

    const EAUM1PreparedStage unsorted[] = {
        {.kind = EAUM1PreparedStageGain, .channelIndex = 1, .b0 = 1.0},
        {.kind = EAUM1PreparedStageGain, .channelIndex = 0, .b0 = 1.0},
    };
    description.stageCount = 2;
    description.stages = unsorted;
    XCTAssertEqual(EAUM1PreparedStateCreateV2(&description, &prepared), EAUM1StatusInvalidArgument);

    std::vector<EAUM1PreparedStage> excessive(EAUM1_MAX_STAGES_PER_CHANNEL + 1);
    for (EAUM1PreparedStage &stage : excessive) {
        stage.kind = EAUM1PreparedStageGain;
        stage.channelIndex = 0;
        stage.b0 = 1.0;
    }
    description.stageCount = static_cast<uint32_t>(excessive.size());
    description.stages = excessive.data();
    XCTAssertEqual(EAUM1PreparedStateCreateV2(&description, &prepared), EAUM1StatusCapacityExceeded);
}

- (void)testPreparedV3RejectsMalformedConvolutionAndCapacityViolations {
    float tap = 1.0f;
    EAUM1PreparedConvolution convolution = {.tapCount = 1, .taps = &tap};
    EAUM1PreparedStage stage = {
        .kind = EAUM1PreparedStageConvolution,
        .channelIndex = 0,
        .b0 = 0.0,
    };
    EAUM1PreparedDescriptionV3 description = {
        .channelCount = 1,
        .stageCount = 1,
        .stages = &stage,
        .convolutionCount = 1,
        .convolutions = &convolution,
    };
    EAUM1PreparedState *prepared = reinterpret_cast<EAUM1PreparedState *>(0x1);
    XCTAssertEqual(EAUM1PreparedStateCreateV3(nullptr, &prepared), EAUM1StatusInvalidArgument);
    XCTAssertEqual(prepared, nullptr);

    EAUM1PreparedDescription v2 = {
        .channelCount = 1,
        .stageCount = 1,
        .stages = &stage,
    };
    XCTAssertEqual(EAUM1PreparedStateCreateV2(&v2, &prepared), EAUM1StatusInvalidArgument);

    stage.b0 = 1.0;
    XCTAssertEqual(EAUM1PreparedStateCreateV3(&description, &prepared), EAUM1StatusInvalidArgument);
    stage.b0 = 0.5;
    XCTAssertEqual(EAUM1PreparedStateCreateV3(&description, &prepared), EAUM1StatusInvalidArgument);
    stage.b0 = 0.0;
    stage.b1 = 1.0;
    XCTAssertEqual(EAUM1PreparedStateCreateV3(&description, &prepared), EAUM1StatusInvalidArgument);
    stage.b1 = 0.0;

    convolution.tapCount = 0;
    XCTAssertEqual(EAUM1PreparedStateCreateV3(&description, &prepared), EAUM1StatusInvalidArgument);
    convolution.tapCount = 1;
    tap = std::numeric_limits<float>::quiet_NaN();
    XCTAssertEqual(EAUM1PreparedStateCreateV3(&description, &prepared), EAUM1StatusInvalidArgument);
    tap = std::numeric_limits<float>::denorm_min();
    XCTAssertEqual(EAUM1PreparedStateCreateV3(&description, &prepared), EAUM1StatusInvalidArgument);
    tap = 1.0f;

    std::vector<float> excessive(EAUM1_MAX_TOTAL_CONVOLUTION_TAPS / 2 + 1, 0.0f);
    convolution = {
        .tapCount = static_cast<uint32_t>(excessive.size()),
        .taps = excessive.data(),
    };
    const EAUM1PreparedStage twoStages[] = {stage, stage};
    description.stageCount = 2;
    description.stages = twoStages;
    XCTAssertEqual(EAUM1PreparedStateCreateV3(&description, &prepared), EAUM1StatusCapacityExceeded);

    std::vector<float> tooLarge(EAUM1_MAX_CONVOLUTION_TAPS + 1, 0.0f);
    convolution = {
        .tapCount = static_cast<uint32_t>(tooLarge.size()),
        .taps = tooLarge.data(),
    };
    description.stageCount = 1;
    description.stages = &stage;
    XCTAssertEqual(EAUM1PreparedStateCreateV3(&description, &prepared), EAUM1StatusCapacityExceeded);

    convolution = {.tapCount = 1, .taps = &tap};
    std::vector<EAUM1PreparedStage> tooMany(EAUM1_MAX_CONVOLUTION_STAGES + 1, stage);
    description.stageCount = static_cast<uint32_t>(tooMany.size());
    description.stages = tooMany.data();
    XCTAssertEqual(EAUM1PreparedStateCreateV3(&description, &prepared), EAUM1StatusCapacityExceeded);

    description.stageCount = 0;
    description.stages = nullptr;
    description.convolutionCount = 1;
    description.convolutions = &convolution;
    XCTAssertEqual(EAUM1PreparedStateCreateV3(&description, &prepared), EAUM1StatusInvalidArgument);

    std::vector<EAUM1PreparedConvolution> tooManyDescriptors(
        EAUM1_MAX_CONVOLUTION_STAGES + 1,
        convolution
    );
    description.convolutionCount = static_cast<uint32_t>(tooManyDescriptors.size());
    description.convolutions = tooManyDescriptors.data();
    XCTAssertEqual(EAUM1PreparedStateCreateV3(&description, &prepared), EAUM1StatusCapacityExceeded);
}

- (void)testConvolutionDeltaIsImmediateAndCopiesTaps {
    float tap = 1.0f;
    const EAUM1PreparedConvolution convolution = {.tapCount = 1, .taps = &tap};
    const EAUM1PreparedStage stage = {
        .kind = EAUM1PreparedStageConvolution,
        .channelIndex = 0,
        .b0 = 0.0,
    };
    EAUM1PreparedState *prepared = createPreparedV3(1, &stage, 1, &convolution, 1);
    tap = 0.0f;
    EAUM1Runtime *runtime = createRuntimeWithPrepared(&prepared, 1);

    std::vector<float> samples(16, 0.0f);
    samples[0] = 1.0f;
    EAUM1AudioBuffer buffer = {.samples = samples.data(), .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 16), EAUM1StatusOK);
    for (size_t index = 0; index < samples.size(); ++index) {
        XCTAssertEqualWithAccuracy(samples[index], index == 0 ? 1.0f : 0.0f, 1e-12f);
    }
    EAUM1RuntimeDestroy(runtime);
}

- (void)testShortConvolutionMatchesDirectReferenceAcrossVariableBlocks {
    const float taps[] = {0.5f, -0.25f, 0.125f, 0.0f, 0.0625f};
    const EAUM1PreparedConvolution convolution = {.tapCount = 5, .taps = taps};
    const EAUM1PreparedStage stage = {
        .kind = EAUM1PreparedStageConvolution,
        .channelIndex = 0,
        .b0 = 0.0,
    };
    EAUM1PreparedState *prepared = createPreparedV3(1, &stage, 1, &convolution, 1);
    EAUM1Runtime *runtime = createRuntimeWithPrepared(&prepared, 1, 97);
    std::vector<float> input(900);
    for (size_t index = 0; index < input.size(); ++index) {
        input[index] = static_cast<float>((static_cast<int>(index % 17) - 8) * 0.03125);
    }
    std::vector<float> actual = input;
    const uint32_t blockSizes[] = {1, 7, 63, 2, 97, 31, 5, 89};
    size_t offset = 0;
    size_t blockIndex = 0;
    while (offset < actual.size()) {
        const uint32_t frameCount = static_cast<uint32_t>(std::min(
            actual.size() - offset,
            static_cast<size_t>(blockSizes[blockIndex++ % std::size(blockSizes)])));
        EAUM1AudioBuffer buffer = {.samples = actual.data() + offset, .channelCount = 1};
        XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, frameCount), EAUM1StatusOK);
        offset += frameCount;
    }

    for (size_t frame = 0; frame < actual.size(); ++frame) {
        double expected = 0.0;
        for (size_t tapIndex = 0; tapIndex < std::size(taps); ++tapIndex) {
            if (frame >= tapIndex) {
                expected += static_cast<double>(taps[tapIndex])
                    * input[frame - tapIndex];
            }
        }
        XCTAssertEqualWithAccuracy(actual[frame], static_cast<float>(expected), 2e-6f);
    }
    EAUM1RuntimeDestroy(runtime);
}

- (void)testPartitionedTailMatchesDirectReferenceAcrossVariableBlocks {
    std::vector<float> taps(520, 0.0f);
    taps[0] = 0.5f;
    taps[1] = -0.25f;
    taps[255] = 0.125f;
    taps[256] = 0.0625f;
    taps[300] = -0.03125f;
    taps[519] = 0.015625f;
    const EAUM1PreparedConvolution convolution = {
        .tapCount = static_cast<uint32_t>(taps.size()),
        .taps = taps.data(),
    };
    const EAUM1PreparedStage stage = {
        .kind = EAUM1PreparedStageConvolution,
        .channelIndex = 0,
        .b0 = 0.0,
    };
    EAUM1PreparedState *prepared = createPreparedV3(1, &stage, 1, &convolution, 1);
    EAUM1Runtime *runtime = createRuntimeWithPrepared(&prepared, 1, 113);
    std::vector<float> input(1100);
    for (size_t index = 0; index < input.size(); ++index) {
        input[index] = static_cast<float>((static_cast<int>(index % 23) - 11) * 0.015625);
    }
    std::vector<float> actual = input;
    const uint32_t blockSizes[] = {3, 113, 1, 64, 17, 92, 5, 37};
    size_t offset = 0;
    size_t blockIndex = 0;
    while (offset < actual.size()) {
        const uint32_t frameCount = static_cast<uint32_t>(std::min(
            actual.size() - offset,
            static_cast<size_t>(blockSizes[blockIndex++ % std::size(blockSizes)])));
        EAUM1AudioBuffer buffer = {.samples = actual.data() + offset, .channelCount = 1};
        XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, frameCount), EAUM1StatusOK);
        offset += frameCount;
    }

    for (size_t frame = 0; frame < actual.size(); ++frame) {
        double expected = 0.0;
        for (size_t tapIndex = 0; tapIndex < taps.size() && tapIndex <= frame; ++tapIndex) {
            expected += static_cast<double>(taps[tapIndex]) * input[frame - tapIndex];
        }
        XCTAssertEqualWithAccuracy(actual[frame], static_cast<float>(expected), 3e-6f);
    }
    EAUM1RuntimeDestroy(runtime);
}

- (void)testConvolutionChannelsAreIndependentAndStageOrderIsPreserved {
    const float tap = 1.0f;
    const EAUM1PreparedConvolution convolution = {.tapCount = 1, .taps = &tap};
    const EAUM1PreparedStage stages[] = {
        {.kind = EAUM1PreparedStageGain, .channelIndex = 0, .b0 = 2.0},
        {.kind = EAUM1PreparedStageConvolution, .channelIndex = 0, .b0 = 0.0},
        {.kind = EAUM1PreparedStageGain, .channelIndex = 0, .b0 = 3.0},
        {.kind = EAUM1PreparedStageConvolution, .channelIndex = 1, .b0 = 0.0},
    };
    EAUM1PreparedState *prepared = createPreparedV3(2, stages, 4, &convolution, 1);
    EAUM1Runtime *runtime = createRuntimeWithPrepared(&prepared, 2);
    std::vector<float> samples(600, 0.0f);
    samples[0] = 1.0f;
    EAUM1AudioBuffer buffer = {.samples = samples.data(), .channelCount = 2};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 300), EAUM1StatusOK);
    XCTAssertEqualWithAccuracy(samples[0], 6.0f, 1e-6f);
    for (size_t frame = 0; frame < 300; ++frame) {
        XCTAssertEqualWithAccuracy(samples[frame * 2 + 1], 0.0f, 1e-12f);
    }
    EAUM1RuntimeDestroy(runtime);
}

- (void)testCascadedConvolutionsAddNoAlgorithmicLatency {
    const float tap = 1.0f;
    const EAUM1PreparedConvolution convolution = {.tapCount = 1, .taps = &tap};
    const EAUM1PreparedStage stages[] = {
        {.kind = EAUM1PreparedStageConvolution, .channelIndex = 0, .b0 = 0.0},
        {.kind = EAUM1PreparedStageConvolution, .channelIndex = 0, .b0 = 0.0},
    };
    EAUM1PreparedState *prepared = createPreparedV3(1, stages, 2, &convolution, 1);
    EAUM1Runtime *runtime = createRuntimeWithPrepared(&prepared, 1);
    std::vector<float> samples(16, 0.0f);
    samples[0] = 1.0f;
    EAUM1AudioBuffer buffer = {.samples = samples.data(), .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 16), EAUM1StatusOK);
    for (size_t index = 0; index < samples.size(); ++index) {
        XCTAssertEqualWithAccuracy(samples[index], index == 0 ? 1.0f : 0.0f, 1e-12f);
    }
    EAUM1RuntimeDestroy(runtime);
}

- (void)testEquivalentConvolutionPublicationPreservesStateAndDifferentIRRetires {
    std::vector<float> taps(101, 0.0f);
    taps[100] = 1.0f;
    EAUM1PreparedConvolution convolution = {
        .tapCount = static_cast<uint32_t>(taps.size()),
        .taps = taps.data(),
    };
    const EAUM1PreparedStage stage = {
        .kind = EAUM1PreparedStageConvolution,
        .channelIndex = 0,
        .b0 = 0.0,
    };
    EAUM1PreparedState *prepared = createPreparedV3(1, &stage, 1, &convolution, 1);
    EAUM1Runtime *runtime = createRuntimeWithPrepared(&prepared, 1, 128, 1000.0);
    std::vector<float> first(50, 0.0f);
    first[0] = 1.0f;
    EAUM1AudioBuffer buffer = {.samples = first.data(), .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 50), EAUM1StatusOK);

    EAUM1PreparedState *equivalent = createPreparedV3(1, &stage, 1, &convolution, 1);
    EAUM1PublicationOutcome outcome = {};
    XCTAssertEqual(EAUM1RuntimePublishPrepared(runtime, &equivalent, &outcome), EAUM1StatusOK);
    XCTAssertEqual(outcome.flags, EAUM1PublicationCandidatePublished);
    std::vector<float> remainder(51, 0.0f);
    buffer.samples = remainder.data();
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 51), EAUM1StatusOK);
    XCTAssertEqualWithAccuracy(remainder[50], 1.0f, 1e-6f);

    taps[100] = 0.5f;
    EAUM1PreparedState *different = createPreparedV3(1, &stage, 1, &convolution, 1);
    XCTAssertEqual(EAUM1RuntimePublishPrepared(runtime, &different, &outcome), EAUM1StatusOK);
    XCTAssertEqual(
        outcome.flags,
        EAUM1PublicationCandidatePublished | EAUM1PublicationMaintenanceRequired
    );
    XCTAssertNotEqual(outcome.retirementTicket, 0u);
    float transition[10] = {};
    buffer.samples = transition;
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 10), EAUM1StatusOK);
    EAUM1PublicationOutcome reclaimed = {};
    XCTAssertEqual(
        EAUM1RuntimePerformMaintenance(runtime, outcome.retirementTicket, &reclaimed),
        EAUM1StatusOK
    );
    XCTAssertEqual(reclaimed.flags, EAUM1PublicationRetiredReclaimed);
    EAUM1RuntimeDestroy(runtime);
}

- (void)testBiquadStateCrossesBlocksWithoutLeakingBetweenChannels {
    const EAUM1PreparedStage stage = {
        .kind = EAUM1PreparedStageBiquad,
        .channelIndex = 0,
        .b0 = 0.5,
        .b1 = 0.0,
        .b2 = 0.0,
        .a1 = -0.5,
        .a2 = 0.0,
    };
    EAUM1PreparedState *prepared = createPreparedV2(2, &stage, 1);
    const uint32_t channelCount = 2;
    const EAUM1RuntimeDescription description = {
        .sampleRate = 1000.0,
        .maximumFrameCount = 2,
        .bufferCount = 1,
        .channelCounts = &channelCount,
        .effectsEnabled = 1,
    };
    EAUM1Runtime *runtime = nullptr;
    XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, &runtime), EAUM1StatusOK);

    float first[] = {1.0f, 7.0f, 0.0f, 8.0f};
    EAUM1AudioBuffer buffer = {.samples = first, .channelCount = 2};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 2), EAUM1StatusOK);
    XCTAssertEqualWithAccuracy(first[0], 0.5f, 1e-7f);
    XCTAssertEqual(first[1], 7.0f);
    XCTAssertEqualWithAccuracy(first[2], 0.25f, 1e-7f);
    XCTAssertEqual(first[3], 8.0f);

    float second[] = {0.0f, 9.0f, 0.0f, 10.0f};
    buffer.samples = second;
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 2), EAUM1StatusOK);
    XCTAssertEqualWithAccuracy(second[0], 0.125f, 1e-7f);
    XCTAssertEqual(second[1], 9.0f);
    XCTAssertEqualWithAccuracy(second[2], 0.0625f, 1e-7f);
    XCTAssertEqual(second[3], 10.0f);
    EAUM1RuntimeDestroy(runtime);
}

- (void)testGraphicEQBiquadImpulseResponseMatchesCenterGain {
    constexpr double sampleRate = 48000.0;
    constexpr double frequency = 1000.0;
    constexpr double gainDB = 6.0;
    const double bandwidthRatio = std::pow(2.0, 2.0 / 3.0);
    const double q = std::sqrt(bandwidthRatio) / (bandwidthRatio - 1.0);
    const double amplitude = std::pow(10.0, gainDB / 40.0);
    const double omega = 2.0 * M_PI * frequency / sampleRate;
    const double alpha = std::sin(omega) / (2.0 * q);
    const double cosine = std::cos(omega);
    const double a0 = 1.0 + alpha / amplitude;
    const EAUM1PreparedStage stage = {
        .kind = EAUM1PreparedStageBiquad,
        .channelIndex = 0,
        .b0 = (1.0 + alpha * amplitude) / a0,
        .b1 = (-2.0 * cosine) / a0,
        .b2 = (1.0 - alpha * amplitude) / a0,
        .a1 = (-2.0 * cosine) / a0,
        .a2 = (1.0 - alpha / amplitude) / a0,
    };
    EAUM1PreparedState *prepared = createPreparedV2(1, &stage, 1);
    const uint32_t channelCount = 1;
    const EAUM1RuntimeDescription description = {
        .sampleRate = sampleRate,
        .maximumFrameCount = 64,
        .bufferCount = 1,
        .channelCounts = &channelCount,
        .effectsEnabled = 1,
    };
    EAUM1Runtime *runtime = nullptr;
    XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, &runtime), EAUM1StatusOK);

    constexpr size_t responseLength = 8192;
    std::vector<float> response(responseLength);
    response[0] = 1.0f;
    EAUM1AudioBuffer buffer = {.samples = nullptr, .channelCount = 1};
    for (size_t offset = 0; offset < response.size(); offset += 64) {
        buffer.samples = response.data() + offset;
        XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 64), EAUM1StatusOK);
    }

    double real = 0.0;
    double imaginary = 0.0;
    for (size_t index = 0; index < response.size(); ++index) {
        const double phase = -omega * static_cast<double>(index);
        real += static_cast<double>(response[index]) * std::cos(phase);
        imaginary += static_cast<double>(response[index]) * std::sin(phase);
    }
    const double measuredDB = 20.0 * std::log10(std::hypot(real, imaginary));
    XCTAssertEqualWithAccuracy(measuredDB, gainDB, 0.01);
    EAUM1RuntimeDestroy(runtime);
}

- (void)testRuntimeCreationTransfersOwnershipOnlyOnSuccess {
    const float targets[] = {2.0f, 0.5f, 1.0f};
    EAUM1PreparedState *prepared = nullptr;
    XCTAssertEqual(EAUM1PreparedStateCreate(targets, 3, &prepared), EAUM1StatusOK);

    const uint32_t wrongChannelCounts[] = {2, 2};
    EAUM1RuntimeDescription description = {
        .sampleRate = 48000.0,
        .maximumFrameCount = 64,
        .bufferCount = 2,
        .channelCounts = wrongChannelCounts,
        .effectsEnabled = 1,
    };
    EAUM1Runtime *runtime = reinterpret_cast<EAUM1Runtime *>(0x1);
    XCTAssertEqual(
        EAUM1RuntimeCreate(&description, &prepared, &runtime),
        EAUM1StatusTopologyMismatch
    );
    XCTAssertNotEqual(prepared, nullptr);
    XCTAssertEqual(runtime, nullptr);

    description.sampleRate = std::numeric_limits<double>::infinity();
    XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, &runtime), EAUM1StatusInvalidArgument);
    XCTAssertNotEqual(prepared, nullptr);
    XCTAssertEqual(runtime, nullptr);
    description.sampleRate = 48000.0;

    XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, nullptr), EAUM1StatusInvalidArgument);
    XCTAssertNotEqual(prepared, nullptr);

    const uint32_t channelCounts[] = {2, 1};
    description.channelCounts = channelCounts;
    XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, &runtime), EAUM1StatusOK);
    XCTAssertEqual(prepared, nullptr);
    XCTAssertNotEqual(runtime, nullptr);
    EAUM1RuntimeDestroy(runtime);
}

- (void)testInitialTargetsApplyDirectlyAcrossMixedBufferTopology {
    float targets[] = {2.0f, 0.5f, 1.0f};
    EAUM1PreparedState *prepared = nullptr;
    XCTAssertEqual(EAUM1PreparedStateCreate(targets, 3, &prepared), EAUM1StatusOK);
    targets[0] = 3.0f;
    targets[1] = 3.0f;

    const uint32_t channelCounts[] = {2, 1};
    const EAUM1RuntimeDescription description = {
        .sampleRate = 48000.0,
        .maximumFrameCount = 2,
        .bufferCount = 2,
        .channelCounts = channelCounts,
        .effectsEnabled = 1,
    };
    EAUM1Runtime *runtime = nullptr;
    XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, &runtime), EAUM1StatusOK);

    float interleavedStereo[] = {1.0f, 1.0f, 2.0f, 2.0f};
    float mono[] = {3.0f, 4.0f};
    EAUM1AudioBuffer buffers[] = {
        {.samples = interleavedStereo, .channelCount = 2},
        {.samples = mono, .channelCount = 1},
    };
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, buffers, 2, 2), EAUM1StatusOK);
    XCTAssertEqual(interleavedStereo[0], 2.0f);
    XCTAssertEqual(interleavedStereo[1], 0.5f);
    XCTAssertEqual(interleavedStereo[2], 4.0f);
    XCTAssertEqual(interleavedStereo[3], 1.0f);
    XCTAssertEqual(mono[0], 3.0f);
    XCTAssertEqual(mono[1], 4.0f);
    EAUM1RuntimeDestroy(runtime);
}

- (void)testInitialEffectsOffAndZeroDBAreBitwiseTransparent {
    const float input[] = {
        0.0f,
        -0.0f,
        std::numeric_limits<float>::denorm_min(),
        -3.25f,
        std::numeric_limits<float>::max(),
    };
    const uint32_t channelCount = 1;

    for (uint32_t scenario = 0; scenario < 2; ++scenario) {
        const float target = scenario == 0 ? 2.0f : 1.0f;
        EAUM1PreparedState *prepared = nullptr;
        XCTAssertEqual(EAUM1PreparedStateCreate(&target, 1, &prepared), EAUM1StatusOK);
        const EAUM1RuntimeDescription description = {
            .sampleRate = 48000.0,
            .maximumFrameCount = 5,
            .bufferCount = 1,
            .channelCounts = &channelCount,
            .effectsEnabled = scenario == 0 ? static_cast<uint8_t>(0) : static_cast<uint8_t>(1),
        };
        EAUM1Runtime *runtime = nullptr;
        XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, &runtime), EAUM1StatusOK);

        float samples[5];
        std::memcpy(samples, input, sizeof(input));
        EAUM1AudioBuffer buffer = {.samples = samples, .channelCount = 1};
        XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 5), EAUM1StatusOK);
        XCTAssertEqual(std::memcmp(samples, input, sizeof(input)), 0);
        EAUM1RuntimeDestroy(runtime);
    }
}

- (void)testInitialZeroTargetIsExactAndNeverSubnormal {
    const float target = 0.0f;
    EAUM1PreparedState *prepared = nullptr;
    XCTAssertEqual(EAUM1PreparedStateCreate(&target, 1, &prepared), EAUM1StatusOK);

    const uint32_t channelCount = 1;
    const EAUM1RuntimeDescription description = {
        .sampleRate = 48000.0,
        .maximumFrameCount = 4,
        .bufferCount = 1,
        .channelCounts = &channelCount,
        .effectsEnabled = 1,
    };
    EAUM1Runtime *runtime = nullptr;
    XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, &runtime), EAUM1StatusOK);

    float samples[] = {
        std::numeric_limits<float>::max(),
        std::numeric_limits<float>::min(),
        std::numeric_limits<float>::denorm_min(),
        -1.0f,
    };
    EAUM1AudioBuffer buffer = {.samples = samples, .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 4), EAUM1StatusOK);
    for (float sample : samples) {
        XCTAssertEqual(sample, 0.0f);
        XCTAssertNotEqual(std::fpclassify(sample), FP_SUBNORMAL);
    }
    EAUM1RuntimeDestroy(runtime);
}

- (void)testEffectsSwitchUsesExactTenMillisecondRampAndContinuousRestart {
    const float target = 2.0f;
    EAUM1PreparedState *prepared = nullptr;
    XCTAssertEqual(EAUM1PreparedStateCreate(&target, 1, &prepared), EAUM1StatusOK);

    const uint32_t channelCount = 1;
    const EAUM1RuntimeDescription description = {
        .sampleRate = 1050.0,
        .maximumFrameCount = 11,
        .bufferCount = 1,
        .channelCounts = &channelCount,
        .effectsEnabled = 1,
    };
    EAUM1Runtime *runtime = nullptr;
    XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, &runtime), EAUM1StatusOK);

    XCTAssertEqual(EAUM1RuntimeSetEffectsEnabled(runtime, 0), EAUM1StatusOK);
    float fadeOut[11];
    for (float &sample : fadeOut) {
        sample = 1.0f;
    }
    EAUM1AudioBuffer buffer = {.samples = fadeOut, .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 11), EAUM1StatusOK);
    for (uint32_t frame = 0; frame < 11; ++frame) {
        const float expected = static_cast<float>(
            2.0 - static_cast<double>(frame + 1) / 11.0
        );
        XCTAssertEqualWithAccuracy(fadeOut[frame], expected, 1e-6f);
    }
    XCTAssertEqual(fadeOut[10], 1.0f);

    XCTAssertEqual(EAUM1RuntimeSetEffectsEnabled(runtime, 1), EAUM1StatusOK);
    float fadeIn[] = {1.0f, 1.0f, 1.0f};
    buffer.samples = fadeIn;
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 3), EAUM1StatusOK);
    XCTAssertEqualWithAccuracy(fadeIn[0], static_cast<float>(1.0 + 1.0 / 11.0), 1e-6f);
    XCTAssertEqualWithAccuracy(fadeIn[1], static_cast<float>(1.0 + 2.0 / 11.0), 1e-6f);
    XCTAssertEqualWithAccuracy(fadeIn[2], static_cast<float>(1.0 + 3.0 / 11.0), 1e-6f);

    XCTAssertEqual(EAUM1RuntimeSetEffectsEnabled(runtime, 0), EAUM1StatusOK);
    float restarted = 1.0f;
    buffer.samples = &restarted;
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 1), EAUM1StatusOK);
    const float expectedRestart = static_cast<float>(
        static_cast<double>(fadeIn[2])
            + (1.0 - static_cast<double>(fadeIn[2])) / 11.0
    );
    XCTAssertEqualWithAccuracy(restarted, expectedRestart, 1e-6f);
    EAUM1RuntimeDestroy(runtime);
}

- (void)testBypassKeepsBiquadStateHotForSmoothRestore {
    const EAUM1PreparedStage stage = {
        .kind = EAUM1PreparedStageBiquad,
        .channelIndex = 0,
        .b0 = 0.5,
        .b1 = 0.0,
        .b2 = 0.0,
        .a1 = -0.5,
        .a2 = 0.0,
    };
    EAUM1PreparedState *prepared = createPreparedV2(1, &stage, 1);
    const uint32_t channelCount = 1;
    const EAUM1RuntimeDescription description = {
        .sampleRate = 1000.0,
        .maximumFrameCount = 1,
        .bufferCount = 1,
        .channelCounts = &channelCount,
        .effectsEnabled = 0,
    };
    EAUM1Runtime *runtime = nullptr;
    XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, &runtime), EAUM1StatusOK);

    float impulse = 1.0f;
    EAUM1AudioBuffer buffer = {.samples = &impulse, .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 1), EAUM1StatusOK);
    XCTAssertEqual(impulse, 1.0f);

    XCTAssertEqual(EAUM1RuntimeSetEffectsEnabled(runtime, 1), EAUM1StatusOK);
    float restored = 0.0f;
    buffer.samples = &restored;
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 1), EAUM1StatusOK);
    XCTAssertEqualWithAccuracy(restored, 0.025f, 1e-7f);
    EAUM1RuntimeDestroy(runtime);
}

- (void)testFiniteOverflowSaturatesAndNonFiniteInputBecomesZero {
    const float target = std::numeric_limits<float>::max();
    EAUM1PreparedState *prepared = nullptr;
    XCTAssertEqual(EAUM1PreparedStateCreate(&target, 1, &prepared), EAUM1StatusOK);

    const uint32_t channelCount = 1;
    const EAUM1RuntimeDescription description = {
        .sampleRate = 48000.0,
        .maximumFrameCount = 5,
        .bufferCount = 1,
        .channelCounts = &channelCount,
        .effectsEnabled = 1,
    };
    EAUM1Runtime *runtime = nullptr;
    XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, &runtime), EAUM1StatusOK);

    float samples[] = {
        2.0f,
        -2.0f,
        std::numeric_limits<float>::quiet_NaN(),
        std::numeric_limits<float>::infinity(),
        -std::numeric_limits<float>::infinity(),
    };
    EAUM1AudioBuffer buffer = {.samples = samples, .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 5), EAUM1StatusOK);
    XCTAssertEqual(samples[0], std::numeric_limits<float>::max());
    XCTAssertEqual(samples[1], -std::numeric_limits<float>::max());
    XCTAssertEqual(samples[2], 0.0f);
    XCTAssertEqual(samples[3], 0.0f);
    XCTAssertEqual(samples[4], 0.0f);

    EAUM1RuntimeDiagnostics diagnostics = {};
    XCTAssertEqual(EAUM1RuntimeCopyDiagnostics(runtime, &diagnostics), EAUM1StatusOK);
    XCTAssertEqual(diagnostics.saturatedOutputSampleCount, 2u);
    XCTAssertEqual(diagnostics.nonFiniteInputSampleCount, 3u);
    XCTAssertEqual(diagnostics.invalidProcessCallCount, 0u);
    EAUM1RuntimeDestroy(runtime);
}

- (void)testInvalidProcessCallsDoNotMutateSamplesAndAreCounted {
    const float target = 1.0f;
    EAUM1PreparedState *prepared = nullptr;
    XCTAssertEqual(EAUM1PreparedStateCreate(&target, 1, &prepared), EAUM1StatusOK);

    const uint32_t channelCount = 1;
    const EAUM1RuntimeDescription description = {
        .sampleRate = 48000.0,
        .maximumFrameCount = 1,
        .bufferCount = 1,
        .channelCounts = &channelCount,
        .effectsEnabled = 1,
    };
    EAUM1Runtime *runtime = nullptr;
    XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, &runtime), EAUM1StatusOK);

    float sample = 0.25f;
    EAUM1AudioBuffer validBuffer = {.samples = &sample, .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &validBuffer, 1, 2), EAUM1StatusCapacityExceeded);
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &validBuffer, 0, 1), EAUM1StatusTopologyMismatch);
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, nullptr, 1, 1), EAUM1StatusInvalidArgument);

    EAUM1AudioBuffer wrongChannels = {.samples = &sample, .channelCount = 2};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &wrongChannels, 1, 1), EAUM1StatusTopologyMismatch);
    EAUM1AudioBuffer nullSamples = {.samples = nullptr, .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &nullSamples, 1, 1), EAUM1StatusTopologyMismatch);
    XCTAssertEqual(sample, 0.25f);

    EAUM1RuntimeDiagnostics diagnostics = {};
    XCTAssertEqual(EAUM1RuntimeCopyDiagnostics(runtime, &diagnostics), EAUM1StatusOK);
    XCTAssertEqual(diagnostics.invalidProcessCallCount, 5u);
    EAUM1RuntimeDestroy(runtime);
}

- (void)testImmediatePublicationTransfersOwnershipAndSmoothsToNewTarget {
    const uint64_t liveBefore = EAUM1TestHooks::livePreparedCount();
    EAUM1Runtime *runtime = createRuntime(1.0f);
    EAUM1PreparedState *candidate = createPrepared(2.0f);
    const uintptr_t candidateAddress = reinterpret_cast<uintptr_t>(candidate);

    EAUM1PublicationOutcome outcome = {};
    XCTAssertEqual(
        EAUM1RuntimePublishPrepared(runtime, &candidate, &outcome),
        EAUM1StatusOK
    );
    XCTAssertEqual(candidate, nullptr);
    XCTAssertEqual(
        outcome.flags,
        EAUM1PublicationCandidatePublished | EAUM1PublicationMaintenanceRequired
    );
    XCTAssertEqual(outcome.retirementTicket, 1u);
    XCTAssertEqual(EAUM1TestHooks::activePrepared(runtime), candidateAddress);
    XCTAssertNotEqual(EAUM1TestHooks::retiredPrepared(runtime), 0u);

    float samples[10];
    for (float &sample : samples) {
        sample = 1.0f;
    }
    EAUM1AudioBuffer buffer = {.samples = samples, .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 10), EAUM1StatusOK);
    for (uint32_t frame = 0; frame < 10; ++frame) {
        const float expected = 1.0f + static_cast<float>(frame + 1) / 10.0f;
        XCTAssertEqualWithAccuracy(samples[frame], expected, 1e-6f);
    }
    EAUM1PublicationOutcome reclaimed = {};
    XCTAssertEqual(
        EAUM1RuntimePerformMaintenance(runtime, outcome.retirementTicket, &reclaimed),
        EAUM1StatusOK
    );
    XCTAssertEqual(reclaimed.flags, EAUM1PublicationRetiredReclaimed);

    EAUM1RuntimeDestroy(runtime);
    XCTAssertEqual(EAUM1TestHooks::livePreparedCount(), liveBefore);
}

- (void)testEquivalentPublicationPreservesBiquadStateWithoutMaintenance {
    const uint64_t liveBefore = EAUM1TestHooks::livePreparedCount();
    const EAUM1PreparedStage stage = {
        .kind = EAUM1PreparedStageBiquad,
        .channelIndex = 0,
        .b0 = 0.5,
        .b1 = 0.0,
        .b2 = 0.0,
        .a1 = -0.5,
        .a2 = 0.0,
    };
    EAUM1PreparedState *prepared = createPreparedV2(1, &stage, 1);
    const uint32_t channelCount = 1;
    const EAUM1RuntimeDescription description = {
        .sampleRate = 1000.0,
        .maximumFrameCount = 1,
        .bufferCount = 1,
        .channelCounts = &channelCount,
        .effectsEnabled = 1,
    };
    EAUM1Runtime *runtime = nullptr;
    XCTAssertEqual(EAUM1RuntimeCreate(&description, &prepared, &runtime), EAUM1StatusOK);

    float sample = 1.0f;
    EAUM1AudioBuffer buffer = {.samples = &sample, .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 1), EAUM1StatusOK);
    XCTAssertEqual(sample, 0.5f);

    EAUM1PreparedState *equivalent = createPreparedV2(1, &stage, 1);
    const uintptr_t equivalentAddress = reinterpret_cast<uintptr_t>(equivalent);
    EAUM1PublicationOutcome outcome = {};
    XCTAssertEqual(
        EAUM1RuntimePublishPrepared(runtime, &equivalent, &outcome),
        EAUM1StatusOK
    );
    XCTAssertEqual(equivalent, nullptr);
    XCTAssertEqual(outcome.flags, EAUM1PublicationCandidatePublished);
    XCTAssertEqual(outcome.retirementTicket, 0u);
    XCTAssertEqual(EAUM1TestHooks::activePrepared(runtime), equivalentAddress);
    XCTAssertEqual(EAUM1TestHooks::retiredPrepared(runtime), 0u);

    sample = 0.0f;
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 1), EAUM1StatusOK);
    XCTAssertEqual(sample, 0.25f);

    EAUM1RuntimeDestroy(runtime);
    XCTAssertEqual(EAUM1TestHooks::livePreparedCount(), liveBefore);
}

- (void)testRetirementWaitsForExactOwnerCompletionAndRejectsStaleTicket {
    const uint64_t liveBefore = EAUM1TestHooks::livePreparedCount();
    EAUM1Runtime *runtime = createRuntime(1.0f);
    const uintptr_t oldAddress = EAUM1TestHooks::activePrepared(runtime);
    XCTAssertTrue(EAUM1TestHooks::acquireCallback(runtime));
    XCTAssertEqual(EAUM1TestHooks::callbackState(runtime), 1u);

    EAUM1PreparedState *candidate = createPrepared(2.0f);
    const uintptr_t candidateAddress = reinterpret_cast<uintptr_t>(candidate);
    EAUM1PublicationOutcome outcome = {};
    XCTAssertEqual(EAUM1RuntimePublishPrepared(runtime, &candidate, &outcome), EAUM1StatusOK);
    XCTAssertEqual(candidate, nullptr);
    XCTAssertEqual(
        outcome.flags,
        EAUM1PublicationCandidatePublished | EAUM1PublicationMaintenanceRequired
    );
    XCTAssertEqual(outcome.retirementTicket, 1u);
    XCTAssertEqual(EAUM1TestHooks::activePrepared(runtime), candidateAddress);
    XCTAssertEqual(EAUM1TestHooks::retiredPrepared(runtime), oldAddress);

    EAUM1PublicationOutcome waiting = {};
    XCTAssertEqual(EAUM1RuntimePerformMaintenance(runtime, 1, &waiting), EAUM1StatusOK);
    XCTAssertEqual(waiting.flags, EAUM1PublicationMaintenanceRequired);
    XCTAssertEqual(EAUM1TestHooks::retiredPrepared(runtime), oldAddress);

    EAUM1TestHooks::completeCallback(runtime);
    XCTAssertEqual(EAUM1TestHooks::callbackState(runtime), 2u);
    float transition[10];
    std::fill(std::begin(transition), std::end(transition), 1.0f);
    EAUM1AudioBuffer transitionBuffer = {.samples = transition, .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &transitionBuffer, 1, 10), EAUM1StatusOK);
    EAUM1PublicationOutcome reclaimed = {};
    XCTAssertEqual(EAUM1RuntimePerformMaintenance(runtime, 1, &reclaimed), EAUM1StatusOK);
    XCTAssertEqual(reclaimed.flags, EAUM1PublicationRetiredReclaimed);
    XCTAssertEqual(EAUM1TestHooks::retiredPrepared(runtime), 0u);
    XCTAssertEqual(
        EAUM1RuntimePerformMaintenance(runtime, 1, &reclaimed),
        EAUM1StatusStaleRetirementTicket
    );

    EAUM1RuntimeDestroy(runtime);
    XCTAssertEqual(EAUM1TestHooks::livePreparedCount(), liveBefore);
}

- (void)testPendingCandidatesCoalesceAndOnlyLatestPublishesAfterRetirement {
    const uint64_t liveBefore = EAUM1TestHooks::livePreparedCount();
    EAUM1Runtime *runtime = createRuntime(1.0f);
    XCTAssertTrue(EAUM1TestHooks::acquireCallback(runtime));

    EAUM1PreparedState *gain2 = createPrepared(2.0f);
    EAUM1PublicationOutcome first = {};
    XCTAssertEqual(EAUM1RuntimePublishPrepared(runtime, &gain2, &first), EAUM1StatusOK);
    const uint64_t ticket = first.retirementTicket;

    EAUM1PreparedState *gain3 = createPrepared(3.0f);
    EAUM1PublicationOutcome coalesced = {};
    XCTAssertEqual(EAUM1RuntimePublishPrepared(runtime, &gain3, &coalesced), EAUM1StatusOK);
    XCTAssertEqual(gain3, nullptr);
    XCTAssertEqual(
        coalesced.flags,
        EAUM1PublicationCandidateCoalesced | EAUM1PublicationMaintenanceRequired
    );
    const uintptr_t oldPendingAddress = EAUM1TestHooks::pendingPrepared(runtime);

    EAUM1PreparedState *gain4 = createPrepared(4.0f);
    const uintptr_t latestAddress = reinterpret_cast<uintptr_t>(gain4);
    XCTAssertEqual(EAUM1RuntimePublishPrepared(runtime, &gain4, &coalesced), EAUM1StatusOK);
    XCTAssertEqual(gain4, nullptr);
    XCTAssertNotEqual(EAUM1TestHooks::pendingPrepared(runtime), oldPendingAddress);
    XCTAssertEqual(EAUM1TestHooks::pendingPrepared(runtime), latestAddress);
    XCTAssertEqual(EAUM1TestHooks::livePreparedCount(), liveBefore + 3);

    EAUM1TestHooks::completeCallback(runtime);
    float firstTransition[10];
    std::fill(std::begin(firstTransition), std::end(firstTransition), 1.0f);
    EAUM1AudioBuffer transitionBuffer = {.samples = firstTransition, .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &transitionBuffer, 1, 10), EAUM1StatusOK);
    EAUM1PublicationOutcome advanced = {};
    XCTAssertEqual(EAUM1RuntimePerformMaintenance(runtime, ticket, &advanced), EAUM1StatusOK);
    XCTAssertEqual(
        advanced.flags,
        EAUM1PublicationRetiredReclaimed
            | EAUM1PublicationCandidatePublished
            | EAUM1PublicationMaintenanceRequired
    );
    XCTAssertEqual(EAUM1TestHooks::activePrepared(runtime), latestAddress);
    XCTAssertNotEqual(EAUM1TestHooks::retiredPrepared(runtime), 0u);
    XCTAssertEqual(EAUM1TestHooks::pendingPrepared(runtime), 0u);
    XCTAssertEqual(EAUM1TestHooks::livePreparedCount(), liveBefore + 2);

    float secondTransition[10];
    std::fill(std::begin(secondTransition), std::end(secondTransition), 1.0f);
    transitionBuffer.samples = secondTransition;
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &transitionBuffer, 1, 10), EAUM1StatusOK);
    EAUM1PublicationOutcome completed = {};
    XCTAssertEqual(
        EAUM1RuntimePerformMaintenance(runtime, advanced.retirementTicket, &completed),
        EAUM1StatusOK
    );
    XCTAssertEqual(completed.flags, EAUM1PublicationRetiredReclaimed);

    EAUM1RuntimeDestroy(runtime);
    XCTAssertEqual(EAUM1TestHooks::livePreparedCount(), liveBefore);
}

- (void)testStopDiscardRemovesOnlyPendingCandidate {
    const uint64_t liveBefore = EAUM1TestHooks::livePreparedCount();
    EAUM1Runtime *runtime = createRuntime(1.0f);
    XCTAssertTrue(EAUM1TestHooks::acquireCallback(runtime));

    EAUM1PreparedState *gain2 = createPrepared(2.0f);
    EAUM1PublicationOutcome first = {};
    XCTAssertEqual(EAUM1RuntimePublishPrepared(runtime, &gain2, &first), EAUM1StatusOK);
    const uintptr_t activeAddress = EAUM1TestHooks::activePrepared(runtime);
    EAUM1PreparedState *gain3 = createPrepared(3.0f);
    EAUM1PublicationOutcome pending = {};
    XCTAssertEqual(EAUM1RuntimePublishPrepared(runtime, &gain3, &pending), EAUM1StatusOK);

    XCTAssertEqual(EAUM1RuntimeDiscardPendingPrepared(runtime), EAUM1StatusOK);
    XCTAssertEqual(EAUM1TestHooks::pendingPrepared(runtime), 0u);
    EAUM1TestHooks::completeCallback(runtime);
    float transition[10];
    std::fill(std::begin(transition), std::end(transition), 1.0f);
    EAUM1AudioBuffer transitionBuffer = {.samples = transition, .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &transitionBuffer, 1, 10), EAUM1StatusOK);
    EAUM1PublicationOutcome reclaimed = {};
    XCTAssertEqual(
        EAUM1RuntimePerformMaintenance(runtime, first.retirementTicket, &reclaimed),
        EAUM1StatusOK
    );
    XCTAssertEqual(EAUM1TestHooks::activePrepared(runtime), activeAddress);

    EAUM1RuntimeDestroy(runtime);
    XCTAssertEqual(EAUM1TestHooks::livePreparedCount(), liveBefore);
}

- (void)testOverlapSilencesValidBlockWithoutCompletingOwner {
    EAUM1Runtime *runtime = createRuntime(2.0f);
    XCTAssertTrue(EAUM1TestHooks::acquireCallback(runtime));
    float samples[] = {1.0f, -2.0f};
    EAUM1AudioBuffer buffer = {.samples = samples, .channelCount = 1};
    XCTAssertEqual(
        EAUM1RuntimeProcess(runtime, &buffer, 1, 2),
        EAUM1StatusCallbackOverlap
    );
    XCTAssertEqual(samples[0], 0.0f);
    XCTAssertEqual(samples[1], 0.0f);
    XCTAssertEqual(EAUM1TestHooks::callbackState(runtime), 1u);

    XCTAssertEqual(
        EAUM1RuntimeProcess(runtime, nullptr, 1, 1),
        EAUM1StatusCallbackOverlap
    );
    XCTAssertEqual(EAUM1TestHooks::callbackState(runtime), 1u);
    EAUM1ConcurrencyDiagnostics concurrency = {};
    XCTAssertEqual(
        EAUM1RuntimeCopyConcurrencyDiagnostics(runtime, &concurrency),
        EAUM1StatusOK
    );
    XCTAssertEqual(concurrency.overlappingCallbackCount, 2u);
    EAUM1RuntimeDiagnostics diagnostics = {};
    XCTAssertEqual(EAUM1RuntimeCopyDiagnostics(runtime, &diagnostics), EAUM1StatusOK);
    XCTAssertEqual(diagnostics.invalidProcessCallCount, 1u);

    EAUM1TestHooks::completeCallback(runtime);
    XCTAssertEqual(EAUM1TestHooks::callbackState(runtime), 2u);
    EAUM1RuntimeDestroy(runtime);
}

- (void)testTransitionTicketIsIndependentFromCallbackEpochWrap {
    EAUM1Runtime *runtime = createRuntime(1.0f);
    EAUM1TestHooks::setCallbackState(runtime, UINT64_MAX);
    EAUM1PreparedState *candidate = createPrepared(2.0f);
    EAUM1PublicationOutcome published = {};
    XCTAssertEqual(EAUM1RuntimePublishPrepared(runtime, &candidate, &published), EAUM1StatusOK);
    XCTAssertEqual(published.retirementTicket, 1u);
    XCTAssertEqual(EAUM1TestHooks::storedRetirementTicket(runtime), 1u);

    EAUM1TestHooks::completeCallback(runtime);
    XCTAssertEqual(EAUM1TestHooks::callbackState(runtime), 0u);
    float transition[10];
    std::fill(std::begin(transition), std::end(transition), 1.0f);
    EAUM1AudioBuffer transitionBuffer = {.samples = transition, .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &transitionBuffer, 1, 10), EAUM1StatusOK);
    EAUM1PublicationOutcome reclaimed = {};
    XCTAssertEqual(
        EAUM1RuntimePerformMaintenance(runtime, 1, &reclaimed),
        EAUM1StatusOK
    );
    XCTAssertEqual(reclaimed.flags, EAUM1PublicationRetiredReclaimed);
    EAUM1RuntimeDestroy(runtime);
}

- (void)testNearZeroPublishedTargetNormalizesTransitionWithoutSubnormals {
    EAUM1Runtime *runtime = createRuntime(std::numeric_limits<float>::min());
    EAUM1PreparedState *zero = createPrepared(0.0f);
    EAUM1PublicationOutcome published = {};
    XCTAssertEqual(EAUM1RuntimePublishPrepared(runtime, &zero, &published), EAUM1StatusOK);

    float samples[10];
    for (float &sample : samples) {
        sample = 1.0f;
    }
    EAUM1AudioBuffer buffer = {.samples = samples, .channelCount = 1};
    XCTAssertEqual(EAUM1RuntimeProcess(runtime, &buffer, 1, 10), EAUM1StatusOK);
    for (float sample : samples) {
        XCTAssertTrue(sample == 0.0f || std::isnormal(sample));
    }
    XCTAssertEqual(samples[9], 0.0f);
    EAUM1RuntimeDestroy(runtime);
}

- (void)testTenThousandPublishedCandidatesAndSyntheticOverlapsRemainBounded {
    const uint64_t liveBefore = EAUM1TestHooks::livePreparedCount();
    EAUM1Runtime *runtime = createRuntime(1.0f);
    float sample = 1.0f;
    EAUM1AudioBuffer buffer = {.samples = &sample, .channelCount = 1};

    for (uint32_t iteration = 0; iteration < 10000; ++iteration) {
        XCTAssertTrue(EAUM1TestHooks::acquireCallback(runtime));
        const float gain = (iteration & 1u) == 0 ? 2.0f : 1.0f;
        EAUM1PreparedState *candidate = createPrepared(gain);
        EAUM1PublicationOutcome published = {};
        XCTAssertEqual(EAUM1RuntimePublishPrepared(runtime, &candidate, &published), EAUM1StatusOK);
        XCTAssertNotEqual(
            published.flags & EAUM1PublicationMaintenanceRequired,
            0u
        );

        sample = 1.0f;
        XCTAssertEqual(
            EAUM1RuntimeProcess(runtime, &buffer, 1, 1),
            EAUM1StatusCallbackOverlap
        );
        XCTAssertEqual(sample, 0.0f);
        EAUM1TestHooks::completeCallback(runtime);

        float transition[10];
        std::fill(std::begin(transition), std::end(transition), 1.0f);
        EAUM1AudioBuffer transitionBuffer = {.samples = transition, .channelCount = 1};
        XCTAssertEqual(EAUM1RuntimeProcess(runtime, &transitionBuffer, 1, 10), EAUM1StatusOK);

        EAUM1PublicationOutcome maintained = {};
        XCTAssertEqual(
            EAUM1RuntimePerformMaintenance(
                runtime,
                published.retirementTicket,
                &maintained
            ),
            EAUM1StatusOK
        );
        XCTAssertEqual(
            maintained.flags & EAUM1PublicationMaintenanceRequired,
            0u
        );
        XCTAssertEqual(EAUM1TestHooks::livePreparedCount(), liveBefore + 1);
    }

    EAUM1ConcurrencyDiagnostics diagnostics = {};
    XCTAssertEqual(
        EAUM1RuntimeCopyConcurrencyDiagnostics(runtime, &diagnostics),
        EAUM1StatusOK
    );
    XCTAssertEqual(diagnostics.overlappingCallbackCount, 10000u);
    EAUM1RuntimeDestroy(runtime);
    XCTAssertEqual(EAUM1TestHooks::livePreparedCount(), liveBefore);
}

- (void)testTenThousandPublicationsRaceARealCallbackThreadWithoutLeaks {
    const uint64_t liveBefore = EAUM1TestHooks::livePreparedCount();
    const float initialTargets[] = {1.0f, 2.0f};
    EAUM1PreparedState *initial = nullptr;
    XCTAssertEqual(EAUM1PreparedStateCreate(initialTargets, 2, &initial), EAUM1StatusOK);
    const uint32_t channelCounts[] = {1, 1};
    const EAUM1RuntimeDescription description = {
        .sampleRate = 48000.0,
        .maximumFrameCount = 8,
        .bufferCount = 2,
        .channelCounts = channelCounts,
        .effectsEnabled = 1,
    };
    EAUM1Runtime *runtime = nullptr;
    XCTAssertEqual(EAUM1RuntimeCreate(&description, &initial, &runtime), EAUM1StatusOK);
    XCTAssertEqual(initial, nullptr);
    std::atomic<bool> stop{false};
    std::atomic<bool> callbackStarted{false};
    std::atomic<bool> callbackFailed{false};
    std::atomic<uint64_t> processedBlocks{0};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);

    std::thread callback([&] {
        float left[8];
        float right[8];
        EAUM1AudioBuffer buffers[] = {
            {.samples = left, .channelCount = 1},
            {.samples = right, .channelCount = 1},
        };
        while (!stop.load(std::memory_order_acquire)) {
            std::fill(std::begin(left), std::end(left), 1.0f);
            std::fill(std::begin(right), std::end(right), 1.0f);
            if (EAUM1RuntimeProcess(runtime, buffers, 2, 8) != EAUM1StatusOK) {
                callbackFailed.store(true, std::memory_order_release);
                break;
            }
            for (size_t index = 0; index < 8; ++index) {
                if (!std::isfinite(left[index]) || !std::isfinite(right[index])
                    || left[index] < 1.0f || left[index] > 2.0f
                    || std::abs(right[index] - (2.0f * left[index])) > 0.00001f) {
                    callbackFailed.store(true, std::memory_order_release);
                    break;
                }
            }
            processedBlocks.fetch_add(1, std::memory_order_relaxed);
            callbackStarted.store(true, std::memory_order_release);
        }
    });

    while (!callbackStarted.load(std::memory_order_acquire)
        && !callbackFailed.load(std::memory_order_acquire)
        && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::yield();
    }
    bool timedOut = !callbackStarted.load(std::memory_order_acquire);
    for (uint32_t iteration = 0; iteration < 10000 && !timedOut; ++iteration) {
        const float base = (iteration & 1u) == 0 ? 2.0f : 1.0f;
        const float targets[] = {base, 2.0f * base};
        EAUM1PreparedState *candidate = nullptr;
        XCTAssertEqual(EAUM1PreparedStateCreate(targets, 2, &candidate), EAUM1StatusOK);
        EAUM1PublicationOutcome outcome = {};
        XCTAssertEqual(EAUM1RuntimePublishPrepared(runtime, &candidate, &outcome), EAUM1StatusOK);
        XCTAssertEqual(candidate, nullptr);
        while ((outcome.flags & EAUM1PublicationMaintenanceRequired) != 0u
            && std::chrono::steady_clock::now() < deadline) {
            std::this_thread::yield();
            EAUM1PublicationOutcome maintained = {};
            XCTAssertEqual(
                EAUM1RuntimePerformMaintenance(runtime, outcome.retirementTicket, &maintained),
                EAUM1StatusOK
            );
            outcome = maintained;
        }
        if ((outcome.flags & EAUM1PublicationMaintenanceRequired) != 0u) {
            timedOut = true;
            break;
        }
        XCTAssertEqual(EAUM1TestHooks::livePreparedCount(), liveBefore + 1);
        if ((iteration + 1) % 100 == 0) {
            const uint64_t observed = processedBlocks.load(std::memory_order_acquire);
            while (processedBlocks.load(std::memory_order_acquire) == observed
                && !callbackFailed.load(std::memory_order_acquire)
                && std::chrono::steady_clock::now() < deadline) {
                std::this_thread::yield();
            }
            if (processedBlocks.load(std::memory_order_acquire) == observed) {
                timedOut = true;
                break;
            }
            if (callbackFailed.load(std::memory_order_acquire)) {
                break;
            }
        }
    }

    stop.store(true, std::memory_order_release);
    callback.join();
    XCTAssertFalse(timedOut);
    XCTAssertTrue(callbackStarted.load(std::memory_order_acquire));
    XCTAssertFalse(callbackFailed.load(std::memory_order_acquire));
    XCTAssertGreaterThanOrEqual(processedBlocks.load(std::memory_order_relaxed), 101u);
    XCTAssertEqual(EAUM1TestHooks::pendingPrepared(runtime), 0u);
    XCTAssertEqual(EAUM1TestHooks::retiredPrepared(runtime), 0u);
    EAUM1RuntimeDestroy(runtime);
    XCTAssertEqual(EAUM1TestHooks::livePreparedCount(), liveBefore);
}

@end
