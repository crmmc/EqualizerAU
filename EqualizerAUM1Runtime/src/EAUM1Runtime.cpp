#include "EAUM1Runtime.h"

#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <new>
#include <utility>
#include <vector>

namespace {

std::atomic<uint64_t> preparedLiveCount{0};

struct RuntimeStage {
    EAUM1PreparedStage definition{};
    double state1 = 0.0;
    double state2 = 0.0;
};

struct ExecutionSlot {
    std::vector<RuntimeStage> stages;
    std::vector<uint32_t> channelOffsets;
    uint32_t stageCount = 0;

    explicit ExecutionSlot(uint32_t channelCount)
        : stages(EAUM1_MAX_PREPARED_STAGE_COUNT),
          channelOffsets(static_cast<size_t>(channelCount) + 1) {}
};

}  // namespace

struct EAUM1PreparedState {
    uint32_t channelCount;
    uint64_t publicationGeneration;
    std::vector<EAUM1PreparedStage> stages;
    std::vector<uint32_t> channelOffsets;

    EAUM1PreparedState(
        uint32_t channels,
        std::vector<EAUM1PreparedStage> preparedStages,
        std::vector<uint32_t> offsets
    )
        : channelCount(channels),
          publicationGeneration(0),
          stages(std::move(preparedStages)),
          channelOffsets(std::move(offsets)) {
        preparedLiveCount.fetch_add(1, std::memory_order_relaxed);
    }

    ~EAUM1PreparedState() {
        preparedLiveCount.fetch_sub(1, std::memory_order_relaxed);
    }
};

struct EAUM1Runtime {
    std::atomic<EAUM1PreparedState *> activePrepared;
    std::atomic<uint64_t> callbackState;
    EAUM1PreparedState *retiredPrepared;
    EAUM1PreparedState *pendingPrepared;
    uint64_t retirementTicket;
    uint64_t nextPublicationGeneration;
    std::atomic<uint64_t> requestedPublicationGeneration;
    std::atomic<uint64_t> completedPublicationGeneration;
    std::atomic<uint32_t> requestedSlotIndex;
    uint64_t callbackPublicationGeneration;
    double sampleRate;
    uint32_t maximumFrameCount;
    uint32_t rampFrameCount;
    std::vector<uint32_t> channelCounts;
    std::array<ExecutionSlot, 2> slots;
    std::atomic<uint32_t> activeSlotIndex;
    uint32_t transitionTargetSlotIndex;
    uint32_t transitionFrameIndex;
    double effectsTransitionStart;
    double effectsTransitionTarget;
    double currentEffectsMix;
    uint32_t effectsTransitionFrameIndex;
    std::atomic<bool> effectsEnabled;
    std::atomic<uint64_t> nonFiniteInputSampleCount;
    std::atomic<uint64_t> saturatedOutputSampleCount;
    std::atomic<uint64_t> invalidProcessCallCount;
    std::atomic<uint64_t> overlappingCallbackCount;

    EAUM1Runtime(
        const EAUM1RuntimeDescription &description,
        uint32_t totalChannelCount,
        uint32_t computedRampFrameCount,
        EAUM1PreparedState *prepared
    )
        : activePrepared(prepared),
          callbackState(0),
          retiredPrepared(nullptr),
          pendingPrepared(nullptr),
          retirementTicket(0),
          nextPublicationGeneration(0),
          requestedPublicationGeneration(0),
          completedPublicationGeneration(0),
          requestedSlotIndex(0),
          callbackPublicationGeneration(0),
          sampleRate(description.sampleRate),
          maximumFrameCount(description.maximumFrameCount),
          rampFrameCount(computedRampFrameCount),
          channelCounts(description.channelCounts, description.channelCounts + description.bufferCount),
          slots{ExecutionSlot(totalChannelCount), ExecutionSlot(totalChannelCount)},
          activeSlotIndex(0),
          transitionTargetSlotIndex(0),
          transitionFrameIndex(computedRampFrameCount),
          effectsTransitionStart(description.effectsEnabled != 0 ? 1.0 : 0.0),
          effectsTransitionTarget(description.effectsEnabled != 0 ? 1.0 : 0.0),
          currentEffectsMix(description.effectsEnabled != 0 ? 1.0 : 0.0),
          effectsTransitionFrameIndex(computedRampFrameCount),
          effectsEnabled(description.effectsEnabled != 0),
          nonFiniteInputSampleCount(0),
          saturatedOutputSampleCount(0),
          invalidProcessCallCount(0),
          overlappingCallbackCount(0) {}

    ~EAUM1Runtime() {
        delete activePrepared.load(std::memory_order_relaxed);
        delete retiredPrepared;
        delete pendingPrepared;
    }
};

namespace {

bool isValidTarget(float target) {
    return target == 0.0f || (target > 0.0f && std::isfinite(target) && std::isnormal(target));
}

bool isZeroOrNormal(double value) {
    return value == 0.0 || (std::isfinite(value) && std::isnormal(value));
}

bool isStableBiquad(const EAUM1PreparedStage &stage) {
    return isZeroOrNormal(stage.b0)
        && isZeroOrNormal(stage.b1)
        && isZeroOrNormal(stage.b2)
        && isZeroOrNormal(stage.a1)
        && isZeroOrNormal(stage.a2)
        && std::abs(stage.a2) < 1.0
        && 1.0 + stage.a1 + stage.a2 > 0.0
        && 1.0 - stage.a1 + stage.a2 > 0.0;
}

bool validateStage(const EAUM1PreparedStage &stage) {
    switch (stage.kind) {
    case EAUM1PreparedStageGain:
        return (stage.b0 == 0.0 || (stage.b0 > 0.0 && std::isnormal(stage.b0)))
            && stage.b1 == 0.0
            && stage.b2 == 0.0
            && stage.a1 == 0.0
            && stage.a2 == 0.0;
    case EAUM1PreparedStageBiquad:
        return isStableBiquad(stage);
    default:
        return false;
    }
}

std::vector<uint32_t> makeChannelOffsets(
    const std::vector<EAUM1PreparedStage> &stages,
    uint32_t channelCount
) {
    std::vector<uint32_t> offsets(static_cast<size_t>(channelCount) + 1);
    uint32_t stageIndex = 0;
    for (uint32_t channel = 0; channel < channelCount; ++channel) {
        offsets[channel] = stageIndex;
        while (stageIndex < stages.size() && stages[stageIndex].channelIndex == channel) {
            ++stageIndex;
        }
    }
    offsets[channelCount] = stageIndex;
    return offsets;
}

bool allRequiredAtomicsAreLockFree() {
    std::atomic<EAUM1PreparedState *> preparedPointer;
    std::atomic<uint64_t> callbackState;
    std::atomic<bool> effectsEnabled;
    std::atomic<uint64_t> diagnosticCounter;
    std::atomic<uint32_t> slotIndex;
    return preparedPointer.is_lock_free()
        && callbackState.is_lock_free()
        && effectsEnabled.is_lock_free()
        && diagnosticCounter.is_lock_free()
        && slotIndex.is_lock_free();
}

void copyPreparedToSlot(
    const EAUM1PreparedState *prepared,
    ExecutionSlot *slot
) {
    slot->stageCount = static_cast<uint32_t>(prepared->stages.size());
    for (uint32_t index = 0; index < slot->stageCount; ++index) {
        slot->stages[index].definition = prepared->stages[index];
        slot->stages[index].state1 = 0.0;
        slot->stages[index].state2 = 0.0;
    }
    for (uint32_t index = 0; index <= prepared->channelCount; ++index) {
        slot->channelOffsets[index] = prepared->channelOffsets[index];
    }
}

bool executionPlanMatches(
    const EAUM1PreparedState *prepared,
    const ExecutionSlot &slot
) {
    if (prepared->stages.size() != slot.stageCount) {
        return false;
    }
    for (uint32_t index = 0; index < slot.stageCount; ++index) {
        const EAUM1PreparedStage &left = prepared->stages[index];
        const EAUM1PreparedStage &right = slot.stages[index].definition;
        if (left.kind != right.kind
            || left.channelIndex != right.channelIndex
            || left.b0 != right.b0
            || left.b1 != right.b1
            || left.b2 != right.b2
            || left.a1 != right.a1
            || left.a2 != right.a2) {
            return false;
        }
    }
    return true;
}

void beginChainTransitionIfNeeded(EAUM1Runtime *runtime) {
    const uint64_t requested = runtime->requestedPublicationGeneration.load(
        std::memory_order_acquire
    );
    if (requested == runtime->callbackPublicationGeneration) {
        return;
    }

    runtime->transitionTargetSlotIndex = runtime->requestedSlotIndex.load(
        std::memory_order_relaxed
    );
    runtime->transitionFrameIndex = 0;
    runtime->callbackPublicationGeneration = requested;
}

void beginEffectsTransitionIfNeeded(EAUM1Runtime *runtime, bool enabled) {
    const double target = enabled ? 1.0 : 0.0;
    if (runtime->effectsTransitionTarget == target) {
        return;
    }
    runtime->effectsTransitionStart = runtime->currentEffectsMix;
    runtime->effectsTransitionTarget = target;
    runtime->effectsTransitionFrameIndex = 0;
}

void advanceEffectsTransition(EAUM1Runtime *runtime) {
    if (runtime->effectsTransitionFrameIndex >= runtime->rampFrameCount) {
        return;
    }
    const uint32_t frame = runtime->effectsTransitionFrameIndex + 1;
    if (frame == runtime->rampFrameCount) {
        runtime->currentEffectsMix = runtime->effectsTransitionTarget;
    } else {
        runtime->currentEffectsMix = runtime->effectsTransitionStart
            + (runtime->effectsTransitionTarget - runtime->effectsTransitionStart)
                * static_cast<double>(frame)
                / static_cast<double>(runtime->rampFrameCount);
    }
    runtime->effectsTransitionFrameIndex = frame;
}

float sanitizeInput(EAUM1Runtime *runtime, float input) {
    if (std::isfinite(input)) {
        return input;
    }
    runtime->nonFiniteInputSampleCount.fetch_add(1, std::memory_order_relaxed);
    return 0.0f;
}

double boundedDSPValue(EAUM1Runtime *runtime, double value) {
    const double maximum = static_cast<double>(std::numeric_limits<float>::max());
    if (std::isfinite(value) && value <= maximum && value >= -maximum) {
        return value;
    }
    runtime->saturatedOutputSampleCount.fetch_add(1, std::memory_order_relaxed);
    if (std::isnan(value)) {
        return 0.0;
    }
    return value < 0.0 ? -maximum : maximum;
}

float normalizedFloatSample(double value) {
    const float converted = static_cast<float>(value);
    if (converted != 0.0f && !std::isnormal(converted)) {
        return 0.0f;
    }
    return converted;
}

float processChainSample(
    EAUM1Runtime *runtime,
    ExecutionSlot *slot,
    uint32_t channelIndex,
    float input
) {
    double value = static_cast<double>(input);
    bool processed = false;
    const uint32_t start = slot->channelOffsets[channelIndex];
    const uint32_t end = slot->channelOffsets[channelIndex + 1];
    for (uint32_t index = start; index < end; ++index) {
        RuntimeStage &stage = slot->stages[index];
        const EAUM1PreparedStage &definition = stage.definition;
        if (definition.kind == EAUM1PreparedStageGain) {
            if (definition.b0 == 1.0) {
                continue;
            }
            processed = true;
            value = boundedDSPValue(runtime, value * definition.b0);
            continue;
        }

        processed = true;
        const double output = boundedDSPValue(runtime, definition.b0 * value + stage.state1);
        const double nextState1 = boundedDSPValue(
            runtime,
            definition.b1 * value - definition.a1 * output + stage.state2
        );
        const double nextState2 = boundedDSPValue(
            runtime,
            definition.b2 * value - definition.a2 * output
        );
        stage.state1 = nextState1 != 0.0 && !std::isnormal(nextState1) ? 0.0 : nextState1;
        stage.state2 = nextState2 != 0.0 && !std::isnormal(nextState2) ? 0.0 : nextState2;
        value = output;
    }
    return processed ? normalizedFloatSample(value) : input;
}

float mixSamples(EAUM1Runtime *runtime, float start, float target, double amount) {
    if (amount <= 0.0) {
        return start;
    }
    if (amount >= 1.0) {
        return target;
    }
    return normalizedFloatSample(boundedDSPValue(
        runtime,
        static_cast<double>(start)
            + (static_cast<double>(target) - static_cast<double>(start)) * amount
    ));
}

void completeChainTransitionFrame(EAUM1Runtime *runtime) {
    if (runtime->transitionFrameIndex >= runtime->rampFrameCount) {
        return;
    }
    ++runtime->transitionFrameIndex;
    if (runtime->transitionFrameIndex == runtime->rampFrameCount) {
        runtime->activeSlotIndex.store(
            runtime->transitionTargetSlotIndex,
            std::memory_order_release
        );
        runtime->completedPublicationGeneration.store(
            runtime->callbackPublicationGeneration,
            std::memory_order_release
        );
    }
}

EAUM1Status validateProcessCall(
    EAUM1Runtime *runtime,
    EAUM1AudioBuffer *buffers,
    uint32_t bufferCount,
    uint32_t frameCount
) {
    if (runtime == nullptr) {
        return EAUM1StatusInvalidArgument;
    }
    if (buffers == nullptr) {
        runtime->invalidProcessCallCount.fetch_add(1, std::memory_order_relaxed);
        return EAUM1StatusInvalidArgument;
    }
    if (frameCount > runtime->maximumFrameCount) {
        runtime->invalidProcessCallCount.fetch_add(1, std::memory_order_relaxed);
        return EAUM1StatusCapacityExceeded;
    }
    if (bufferCount != runtime->channelCounts.size()) {
        runtime->invalidProcessCallCount.fetch_add(1, std::memory_order_relaxed);
        return EAUM1StatusTopologyMismatch;
    }
    for (size_t index = 0; index < runtime->channelCounts.size(); ++index) {
        if (buffers[index].channelCount != runtime->channelCounts[index]
            || (frameCount != 0 && buffers[index].samples == nullptr)) {
            runtime->invalidProcessCallCount.fetch_add(1, std::memory_order_relaxed);
            return EAUM1StatusTopologyMismatch;
        }
    }
    return EAUM1StatusOK;
}

void silenceOutputBlock(
    EAUM1AudioBuffer *buffers,
    uint32_t bufferCount,
    uint32_t frameCount
) {
    for (uint32_t bufferIndex = 0; bufferIndex < bufferCount; ++bufferIndex) {
        EAUM1AudioBuffer &buffer = buffers[bufferIndex];
        const size_t sampleCount = static_cast<size_t>(frameCount) * buffer.channelCount;
        for (size_t sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
            buffer.samples[sampleIndex] = 0.0f;
        }
    }
}

void clearPublicationOutcome(EAUM1PublicationOutcome *outcome) {
    outcome->retirementTicket = 0;
    outcome->flags = 0;
    outcome->reserved = 0;
}

EAUM1Status publishCandidate(
    EAUM1Runtime *runtime,
    EAUM1PreparedState *candidate,
    EAUM1PublicationOutcome *outcome
) {
    if (runtime->nextPublicationGeneration == std::numeric_limits<uint64_t>::max()) {
        return EAUM1StatusCapacityExceeded;
    }
    const uint64_t generation = ++runtime->nextPublicationGeneration;
    candidate->publicationGeneration = generation;
    const uint32_t activeSlot = runtime->activeSlotIndex.load(std::memory_order_acquire);
    if (executionPlanMatches(candidate, runtime->slots[activeSlot])) {
        EAUM1PreparedState *old = runtime->activePrepared.exchange(
            candidate,
            std::memory_order_release
        );
        delete old;
        outcome->flags |= EAUM1PublicationCandidatePublished;
        return EAUM1StatusOK;
    }

    const uint32_t targetSlot = 1u - activeSlot;
    copyPreparedToSlot(candidate, &runtime->slots[targetSlot]);
    EAUM1PreparedState *old = runtime->activePrepared.exchange(
        candidate,
        std::memory_order_release
    );
    runtime->retiredPrepared = old;
    runtime->retirementTicket = generation;
    runtime->requestedSlotIndex.store(targetSlot, std::memory_order_relaxed);
    runtime->requestedPublicationGeneration.store(generation, std::memory_order_release);
    outcome->retirementTicket = generation;
    outcome->flags |= EAUM1PublicationCandidatePublished
        | EAUM1PublicationMaintenanceRequired;
    return EAUM1StatusOK;
}

}  // namespace

uint32_t EAUM1RuntimeABIVersion(void) {
    return EAUM1_RUNTIME_ABI_VERSION;
}

EAUM1Status EAUM1RuntimeGetCapabilities(EAUM1RuntimeCapabilities *capabilitiesOut) {
    if (capabilitiesOut == nullptr) {
        return EAUM1StatusInvalidArgument;
    }
    std::atomic<EAUM1PreparedState *> preparedPointer;
    std::atomic<uint64_t> callbackState;
    std::atomic<bool> effectsEnabled;
    std::atomic<uint64_t> diagnosticCounter;
    capabilitiesOut->activePreparedPointerLockFree = preparedPointer.is_lock_free() ? 1 : 0;
    capabilitiesOut->callbackStateLockFree = callbackState.is_lock_free() ? 1 : 0;
    capabilitiesOut->effectsEnabledLockFree = effectsEnabled.is_lock_free() ? 1 : 0;
    capabilitiesOut->diagnosticCountersLockFree = diagnosticCounter.is_lock_free() ? 1 : 0;
    return EAUM1StatusOK;
}

EAUM1Status EAUM1PreparedStateCreate(
    const float *linearGainsByChannel,
    uint32_t channelCount,
    EAUM1PreparedState **preparedOut
) {
    if (preparedOut == nullptr) {
        return EAUM1StatusInvalidArgument;
    }
    *preparedOut = nullptr;
    if (linearGainsByChannel == nullptr || channelCount == 0) {
        return EAUM1StatusInvalidArgument;
    }
    if (channelCount > EAUM1_MAX_PREPARED_STAGE_COUNT) {
        return EAUM1StatusCapacityExceeded;
    }

    std::vector<EAUM1PreparedStage> stages;
    try {
        stages.reserve(channelCount);
        for (uint32_t index = 0; index < channelCount; ++index) {
            if (!isValidTarget(linearGainsByChannel[index])) {
                return EAUM1StatusInvalidArgument;
            }
            stages.push_back(EAUM1PreparedStage{
                .kind = EAUM1PreparedStageGain,
                .channelIndex = index,
                .b0 = static_cast<double>(linearGainsByChannel[index]),
                .b1 = 0.0,
                .b2 = 0.0,
                .a1 = 0.0,
                .a2 = 0.0,
            });
        }
        std::vector<uint32_t> offsets = makeChannelOffsets(stages, channelCount);
        EAUM1PreparedState *prepared = new EAUM1PreparedState(
            channelCount,
            std::move(stages),
            std::move(offsets)
        );
        *preparedOut = prepared;
        return EAUM1StatusOK;
    } catch (const std::bad_alloc &) {
        return EAUM1StatusOutOfMemory;
    } catch (...) {
        return EAUM1StatusInvalidArgument;
    }
}

EAUM1Status EAUM1PreparedStateCreateV2(
    const EAUM1PreparedDescription *description,
    EAUM1PreparedState **preparedOut
) {
    if (preparedOut == nullptr) {
        return EAUM1StatusInvalidArgument;
    }
    *preparedOut = nullptr;
    if (description == nullptr
        || description->channelCount == 0
        || description->stageCount > EAUM1_MAX_PREPARED_STAGE_COUNT
        || (description->stageCount != 0 && description->stages == nullptr)) {
        return EAUM1StatusInvalidArgument;
    }

    uint32_t previousChannel = 0;
    uint32_t stagesForChannel = 0;
    for (uint32_t index = 0; index < description->stageCount; ++index) {
        const EAUM1PreparedStage &stage = description->stages[index];
        if (stage.channelIndex >= description->channelCount
            || (index != 0 && stage.channelIndex < previousChannel)
            || !validateStage(stage)) {
            return EAUM1StatusInvalidArgument;
        }
        if (index == 0 || stage.channelIndex != previousChannel) {
            stagesForChannel = 1;
        } else {
            ++stagesForChannel;
        }
        if (stagesForChannel > EAUM1_MAX_STAGES_PER_CHANNEL) {
            return EAUM1StatusCapacityExceeded;
        }
        previousChannel = stage.channelIndex;
    }

    try {
        std::vector<EAUM1PreparedStage> stages;
        if (description->stageCount != 0) {
            stages.assign(description->stages, description->stages + description->stageCount);
        }
        std::vector<uint32_t> offsets = makeChannelOffsets(stages, description->channelCount);
        EAUM1PreparedState *prepared = new EAUM1PreparedState(
            description->channelCount,
            std::move(stages),
            std::move(offsets)
        );
        *preparedOut = prepared;
        return EAUM1StatusOK;
    } catch (const std::bad_alloc &) {
        return EAUM1StatusOutOfMemory;
    } catch (...) {
        return EAUM1StatusInvalidArgument;
    }
}

void EAUM1PreparedStateDestroy(EAUM1PreparedState *prepared) {
    delete prepared;
}

EAUM1Status EAUM1RuntimeCreate(
    const EAUM1RuntimeDescription *description,
    EAUM1PreparedState **initialPreparedInOut,
    EAUM1Runtime **runtimeOut
) {
    if (runtimeOut == nullptr) {
        return EAUM1StatusInvalidArgument;
    }
    *runtimeOut = nullptr;
    if (description == nullptr
        || initialPreparedInOut == nullptr
        || *initialPreparedInOut == nullptr
        || !std::isfinite(description->sampleRate)
        || description->sampleRate <= 0
        || description->maximumFrameCount == 0
        || description->bufferCount == 0
        || description->channelCounts == nullptr
        || description->effectsEnabled > 1) {
        return EAUM1StatusInvalidArgument;
    }
    if (!allRequiredAtomicsAreLockFree()) {
        return EAUM1StatusUnsupported;
    }

    uint64_t totalChannelCount = 0;
    for (uint32_t index = 0; index < description->bufferCount; ++index) {
        if (description->channelCounts[index] == 0) {
            return EAUM1StatusInvalidArgument;
        }
        totalChannelCount += description->channelCounts[index];
        if (totalChannelCount > std::numeric_limits<uint32_t>::max()) {
            return EAUM1StatusInvalidArgument;
        }
    }
    if (totalChannelCount != (*initialPreparedInOut)->channelCount) {
        return EAUM1StatusTopologyMismatch;
    }

    const double rampFrames = std::ceil(description->sampleRate * 0.010);
    if (!std::isfinite(rampFrames)
        || rampFrames < 1
        || rampFrames > static_cast<double>(std::numeric_limits<uint32_t>::max())) {
        return EAUM1StatusInvalidArgument;
    }

    try {
        EAUM1Runtime *runtime = new EAUM1Runtime(
            *description,
            static_cast<uint32_t>(totalChannelCount),
            static_cast<uint32_t>(rampFrames),
            *initialPreparedInOut
        );
        copyPreparedToSlot(*initialPreparedInOut, &runtime->slots[0]);
        *initialPreparedInOut = nullptr;
        *runtimeOut = runtime;
        return EAUM1StatusOK;
    } catch (const std::bad_alloc &) {
        return EAUM1StatusOutOfMemory;
    } catch (...) {
        return EAUM1StatusInvalidArgument;
    }
}

EAUM1Status EAUM1RuntimePublishPrepared(
    EAUM1Runtime *runtime,
    EAUM1PreparedState **candidateInOut,
    EAUM1PublicationOutcome *outcomeOut
) {
    if (runtime == nullptr
        || candidateInOut == nullptr
        || *candidateInOut == nullptr
        || outcomeOut == nullptr) {
        return EAUM1StatusInvalidArgument;
    }
    if ((*candidateInOut)->channelCount
        != runtime->activePrepared.load(std::memory_order_acquire)->channelCount) {
        return EAUM1StatusTopologyMismatch;
    }

    clearPublicationOutcome(outcomeOut);
    EAUM1PreparedState *candidate = *candidateInOut;
    if (runtime->retiredPrepared != nullptr) {
        delete runtime->pendingPrepared;
        runtime->pendingPrepared = candidate;
        *candidateInOut = nullptr;
        outcomeOut->retirementTicket = runtime->retirementTicket;
        outcomeOut->flags = EAUM1PublicationCandidateCoalesced
            | EAUM1PublicationMaintenanceRequired;
        return EAUM1StatusOK;
    }

    const EAUM1Status status = publishCandidate(runtime, candidate, outcomeOut);
    if (status == EAUM1StatusOK) {
        *candidateInOut = nullptr;
    }
    return status;
}

EAUM1Status EAUM1RuntimePerformMaintenance(
    EAUM1Runtime *runtime,
    uint64_t retirementTicket,
    EAUM1PublicationOutcome *outcomeOut
) {
    if (runtime == nullptr || outcomeOut == nullptr) {
        return EAUM1StatusInvalidArgument;
    }
    clearPublicationOutcome(outcomeOut);
    if (runtime->retiredPrepared == nullptr
        || runtime->retirementTicket != retirementTicket) {
        return EAUM1StatusStaleRetirementTicket;
    }

    const uint64_t completed = runtime->completedPublicationGeneration.load(
        std::memory_order_acquire
    );
    if (completed != retirementTicket) {
        outcomeOut->retirementTicket = retirementTicket;
        outcomeOut->flags = EAUM1PublicationMaintenanceRequired;
        return EAUM1StatusOK;
    }

    delete runtime->retiredPrepared;
    runtime->retiredPrepared = nullptr;
    runtime->retirementTicket = 0;
    outcomeOut->flags = EAUM1PublicationRetiredReclaimed;

    if (runtime->pendingPrepared != nullptr) {
        EAUM1PreparedState *pending = runtime->pendingPrepared;
        runtime->pendingPrepared = nullptr;
        const EAUM1Status status = publishCandidate(runtime, pending, outcomeOut);
        if (status != EAUM1StatusOK) {
            runtime->pendingPrepared = pending;
            return status;
        }
    }
    return EAUM1StatusOK;
}

EAUM1Status EAUM1RuntimeDiscardPendingPrepared(EAUM1Runtime *runtime) {
    if (runtime == nullptr) {
        return EAUM1StatusInvalidArgument;
    }
    delete runtime->pendingPrepared;
    runtime->pendingPrepared = nullptr;
    return EAUM1StatusOK;
}

void EAUM1RuntimeDestroy(EAUM1Runtime *runtime) {
    delete runtime;
}

EAUM1Status EAUM1RuntimeSetEffectsEnabled(EAUM1Runtime *runtime, uint8_t effectsEnabled) {
    if (runtime == nullptr || effectsEnabled > 1) {
        return EAUM1StatusInvalidArgument;
    }
    runtime->effectsEnabled.store(effectsEnabled != 0, std::memory_order_release);
    return EAUM1StatusOK;
}

EAUM1Status EAUM1RuntimeProcess(
    EAUM1Runtime *runtime,
    EAUM1AudioBuffer *buffers,
    uint32_t bufferCount,
    uint32_t frameCount
) {
    if (runtime == nullptr) {
        return EAUM1StatusInvalidArgument;
    }

    const uint64_t callbackState = runtime->callbackState.fetch_or(
        1,
        std::memory_order_seq_cst
    );
    if ((callbackState & 1u) != 0) {
        runtime->overlappingCallbackCount.fetch_add(1, std::memory_order_relaxed);
        const EAUM1Status overlapValidation = validateProcessCall(
            runtime,
            buffers,
            bufferCount,
            frameCount
        );
        if (overlapValidation == EAUM1StatusOK) {
            silenceOutputBlock(buffers, bufferCount, frameCount);
        }
        return EAUM1StatusCallbackOverlap;
    }

    const EAUM1Status validation = validateProcessCall(runtime, buffers, bufferCount, frameCount);
    if (validation != EAUM1StatusOK) {
        runtime->callbackState.fetch_add(1, std::memory_order_seq_cst);
        return validation;
    }

    beginChainTransitionIfNeeded(runtime);
    beginEffectsTransitionIfNeeded(
        runtime,
        runtime->effectsEnabled.load(std::memory_order_acquire)
    );

    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        advanceEffectsTransition(runtime);
        const bool chainTransitionActive = runtime->transitionFrameIndex < runtime->rampFrameCount;
        const double chainMix = chainTransitionActive
            ? static_cast<double>(runtime->transitionFrameIndex + 1)
                / static_cast<double>(runtime->rampFrameCount)
            : 0.0;
        uint32_t linearChannelIndex = 0;
        for (uint32_t bufferIndex = 0; bufferIndex < bufferCount; ++bufferIndex) {
            EAUM1AudioBuffer &buffer = buffers[bufferIndex];
            for (uint32_t channel = 0; channel < buffer.channelCount; ++channel) {
                const size_t sampleIndex = static_cast<size_t>(frame) * buffer.channelCount + channel;
                const float dry = sanitizeInput(runtime, buffer.samples[sampleIndex]);
                const float activeWet = processChainSample(
                    runtime,
                    &runtime->slots[runtime->activeSlotIndex.load(std::memory_order_relaxed)],
                    linearChannelIndex,
                    dry
                );
                float wet = activeWet;
                if (chainTransitionActive) {
                    const float targetWet = processChainSample(
                        runtime,
                        &runtime->slots[runtime->transitionTargetSlotIndex],
                        linearChannelIndex,
                        dry
                    );
                    wet = mixSamples(runtime, activeWet, targetWet, chainMix);
                }
                buffer.samples[sampleIndex] = mixSamples(
                    runtime,
                    dry,
                    wet,
                    runtime->currentEffectsMix
                );
                ++linearChannelIndex;
            }
        }
        if (chainTransitionActive) {
            completeChainTransitionFrame(runtime);
        }
    }
    runtime->callbackState.fetch_add(1, std::memory_order_seq_cst);
    return EAUM1StatusOK;
}

EAUM1Status EAUM1RuntimeCopyDiagnostics(
    const EAUM1Runtime *runtime,
    EAUM1RuntimeDiagnostics *diagnosticsOut
) {
    if (runtime == nullptr || diagnosticsOut == nullptr) {
        return EAUM1StatusInvalidArgument;
    }
    diagnosticsOut->nonFiniteInputSampleCount =
        runtime->nonFiniteInputSampleCount.load(std::memory_order_relaxed);
    diagnosticsOut->saturatedOutputSampleCount =
        runtime->saturatedOutputSampleCount.load(std::memory_order_relaxed);
    diagnosticsOut->invalidProcessCallCount =
        runtime->invalidProcessCallCount.load(std::memory_order_relaxed);
    return EAUM1StatusOK;
}

EAUM1Status EAUM1RuntimeCopyConcurrencyDiagnostics(
    const EAUM1Runtime *runtime,
    EAUM1ConcurrencyDiagnostics *diagnosticsOut
) {
    if (runtime == nullptr || diagnosticsOut == nullptr) {
        return EAUM1StatusInvalidArgument;
    }
    diagnosticsOut->overlappingCallbackCount =
        runtime->overlappingCallbackCount.load(std::memory_order_relaxed);
    return EAUM1StatusOK;
}

namespace EAUM1TestHooks {

bool acquireCallback(EAUM1Runtime *runtime) {
    if (runtime == nullptr) {
        return false;
    }
    const uint64_t observed = runtime->callbackState.fetch_or(1, std::memory_order_seq_cst);
    return (observed & 1u) == 0;
}

void completeCallback(EAUM1Runtime *runtime) {
    runtime->callbackState.fetch_add(1, std::memory_order_seq_cst);
}

void setCallbackState(EAUM1Runtime *runtime, uint64_t state) {
    runtime->callbackState.store(state, std::memory_order_seq_cst);
}

uint64_t callbackState(const EAUM1Runtime *runtime) {
    return runtime->callbackState.load(std::memory_order_seq_cst);
}

uintptr_t activePrepared(const EAUM1Runtime *runtime) {
    return reinterpret_cast<uintptr_t>(
        runtime->activePrepared.load(std::memory_order_acquire)
    );
}

uintptr_t retiredPrepared(const EAUM1Runtime *runtime) {
    return reinterpret_cast<uintptr_t>(runtime->retiredPrepared);
}

uintptr_t pendingPrepared(const EAUM1Runtime *runtime) {
    return reinterpret_cast<uintptr_t>(runtime->pendingPrepared);
}

uint64_t storedRetirementTicket(const EAUM1Runtime *runtime) {
    return runtime->retirementTicket;
}

uint64_t livePreparedCount() {
    return preparedLiveCount.load(std::memory_order_relaxed);
}

}  // namespace EAUM1TestHooks
