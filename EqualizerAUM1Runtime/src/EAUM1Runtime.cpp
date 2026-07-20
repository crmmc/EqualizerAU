#include "EAUM1Runtime.h"

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

}  // namespace

struct EAUM1PreparedState {
    std::vector<float> linearGainsByChannel;

    explicit EAUM1PreparedState(std::vector<float> gains)
        : linearGainsByChannel(std::move(gains)) {
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
    double sampleRate;
    uint32_t maximumFrameCount;
    uint32_t rampFrameCount;
    std::vector<uint32_t> channelCounts;
    std::vector<double> transitionStartGains;
    std::vector<double> transitionTargetGains;
    std::vector<double> currentGains;
    uint32_t transitionFrameIndex;
    std::atomic<bool> effectsEnabled;
    std::atomic<uint64_t> nonFiniteInputSampleCount;
    std::atomic<uint64_t> saturatedOutputSampleCount;
    std::atomic<uint64_t> invalidProcessCallCount;
    std::atomic<uint64_t> overlappingCallbackCount;

    EAUM1Runtime(
        const EAUM1RuntimeDescription &description,
        uint32_t computedRampFrameCount,
        EAUM1PreparedState *prepared
    )
        : activePrepared(prepared),
          callbackState(0),
          retiredPrepared(nullptr),
          pendingPrepared(nullptr),
          retirementTicket(0),
          sampleRate(description.sampleRate),
          maximumFrameCount(description.maximumFrameCount),
          rampFrameCount(computedRampFrameCount),
          channelCounts(description.channelCounts, description.channelCounts + description.bufferCount),
          transitionStartGains(prepared->linearGainsByChannel.size()),
          transitionTargetGains(prepared->linearGainsByChannel.size()),
          currentGains(prepared->linearGainsByChannel.size()),
          transitionFrameIndex(computedRampFrameCount),
          effectsEnabled(description.effectsEnabled != 0),
          nonFiniteInputSampleCount(0),
          saturatedOutputSampleCount(0),
          invalidProcessCallCount(0),
          overlappingCallbackCount(0) {
        const bool initiallyEnabled = description.effectsEnabled != 0;
        for (size_t index = 0; index < currentGains.size(); ++index) {
            const double target = initiallyEnabled
                ? static_cast<double>(prepared->linearGainsByChannel[index])
                : 1.0;
            transitionStartGains[index] = target;
            transitionTargetGains[index] = target;
            currentGains[index] = target;
        }
    }

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

float normalizedFloatGain(double gain) {
    if (gain == 0.0) {
        return 0.0f;
    }
    if (std::abs(gain) < static_cast<double>(std::numeric_limits<float>::min())) {
        return 0.0f;
    }
    const float converted = static_cast<float>(gain);
    if (converted != 0.0f && !std::isnormal(converted)) {
        return 0.0f;
    }
    return converted;
}

bool allRequiredAtomicsAreLockFree() {
    std::atomic<EAUM1PreparedState *> preparedPointer;
    std::atomic<uint64_t> callbackState;
    std::atomic<bool> effectsEnabled;
    std::atomic<uint64_t> diagnosticCounter;
    return preparedPointer.is_lock_free()
        && callbackState.is_lock_free()
        && effectsEnabled.is_lock_free()
        && diagnosticCounter.is_lock_free();
}

bool beginTargetTransitionIfNeeded(
    EAUM1Runtime *runtime,
    const EAUM1PreparedState *prepared,
    bool effectsEnabled
) {
    bool changed = false;
    for (size_t index = 0; index < runtime->transitionTargetGains.size(); ++index) {
        const double target = effectsEnabled
            ? static_cast<double>(prepared->linearGainsByChannel[index])
            : 1.0;
        if (runtime->transitionTargetGains[index] != target) {
            changed = true;
            break;
        }
    }
    if (!changed) {
        return false;
    }

    runtime->transitionFrameIndex = 0;
    for (size_t index = 0; index < runtime->currentGains.size(); ++index) {
        runtime->transitionStartGains[index] = runtime->currentGains[index];
        runtime->transitionTargetGains[index] = effectsEnabled
            ? static_cast<double>(prepared->linearGainsByChannel[index])
            : 1.0;
    }
    return true;
}

void advanceTransition(EAUM1Runtime *runtime) {
    if (runtime->transitionFrameIndex >= runtime->rampFrameCount) {
        return;
    }

    const uint32_t frame = runtime->transitionFrameIndex + 1;
    for (size_t index = 0; index < runtime->currentGains.size(); ++index) {
        double gain;
        if (frame == runtime->rampFrameCount) {
            gain = runtime->transitionTargetGains[index];
        } else {
            const double start = runtime->transitionStartGains[index];
            gain = start
                + (runtime->transitionTargetGains[index] - start)
                    * static_cast<double>(frame)
                    / static_cast<double>(runtime->rampFrameCount);
        }
        runtime->currentGains[index] = static_cast<double>(normalizedFloatGain(gain));
    }
    runtime->transitionFrameIndex = frame;
}

float processSample(EAUM1Runtime *runtime, float input, float gain) {
    if (!std::isfinite(input)) {
        runtime->nonFiniteInputSampleCount.fetch_add(1, std::memory_order_relaxed);
        return 0.0f;
    }
    if (gain == 1.0f) {
        return input;
    }

    const double product = static_cast<double>(input) * static_cast<double>(gain);
    const double maximum = static_cast<double>(std::numeric_limits<float>::max());
    if (product > maximum) {
        runtime->saturatedOutputSampleCount.fetch_add(1, std::memory_order_relaxed);
        return std::numeric_limits<float>::max();
    }
    if (product < -maximum) {
        runtime->saturatedOutputSampleCount.fetch_add(1, std::memory_order_relaxed);
        return -std::numeric_limits<float>::max();
    }
    return static_cast<float>(product);
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

void publishCandidate(
    EAUM1Runtime *runtime,
    EAUM1PreparedState *candidate,
    EAUM1PublicationOutcome *outcome
) {
    EAUM1PreparedState *old = runtime->activePrepared.exchange(
        candidate,
        std::memory_order_seq_cst
    );
    outcome->flags |= EAUM1PublicationCandidatePublished;

    const uint64_t observed = runtime->callbackState.load(std::memory_order_seq_cst);
    if ((observed & 1u) == 0) {
        delete old;
        outcome->flags |= EAUM1PublicationRetiredReclaimed;
        return;
    }

    runtime->retiredPrepared = old;
    runtime->retirementTicket = observed;
    outcome->retirementTicket = observed;
    outcome->flags |= EAUM1PublicationMaintenanceRequired;
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
    for (uint32_t index = 0; index < channelCount; ++index) {
        if (!isValidTarget(linearGainsByChannel[index])) {
            return EAUM1StatusInvalidArgument;
        }
    }

    try {
        EAUM1PreparedState *prepared = new EAUM1PreparedState(
            std::vector<float>(linearGainsByChannel, linearGainsByChannel + channelCount)
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
    if (totalChannelCount != (*initialPreparedInOut)->linearGainsByChannel.size()) {
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
            static_cast<uint32_t>(rampFrames),
            *initialPreparedInOut
        );
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
    if ((*candidateInOut)->linearGainsByChannel.size()
        != runtime->currentGains.size()) {
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

    publishCandidate(runtime, candidate, outcomeOut);
    *candidateInOut = nullptr;
    return EAUM1StatusOK;
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

    const uint64_t observed = runtime->callbackState.load(std::memory_order_seq_cst);
    if (observed == retirementTicket) {
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
        publishCandidate(runtime, pending, outcomeOut);
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
    runtime->effectsEnabled.store(effectsEnabled != 0, std::memory_order_seq_cst);
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

    EAUM1PreparedState *prepared = runtime->activePrepared.load(std::memory_order_seq_cst);
    const bool requestedEffectsEnabled = runtime->effectsEnabled.load(std::memory_order_seq_cst);
    beginTargetTransitionIfNeeded(runtime, prepared, requestedEffectsEnabled);

    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        advanceTransition(runtime);
        size_t linearChannelIndex = 0;
        for (uint32_t bufferIndex = 0; bufferIndex < bufferCount; ++bufferIndex) {
            EAUM1AudioBuffer &buffer = buffers[bufferIndex];
            for (uint32_t channel = 0; channel < buffer.channelCount; ++channel) {
                const size_t sampleIndex = static_cast<size_t>(frame) * buffer.channelCount + channel;
                const float gain = static_cast<float>(runtime->currentGains[linearChannelIndex]);
                buffer.samples[sampleIndex] = processSample(runtime, buffer.samples[sampleIndex], gain);
                ++linearChannelIndex;
            }
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
        runtime->activePrepared.load(std::memory_order_seq_cst)
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
