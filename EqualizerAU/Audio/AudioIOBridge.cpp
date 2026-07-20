#include "AudioIOBridge.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

namespace {

constexpr uint32_t kSignalProbeStageCount = 3;
constexpr uint32_t kSignalProbeSlotCount = 3;
constexpr uint32_t kMaximumSignalProbeFrames = 4096;
constexpr uint64_t kTapSignalCaptureEnabled = uint64_t{1} << 63;
constexpr uint64_t kTapSignalCaptureWriterMask = ~kTapSignalCaptureEnabled;
constexpr double kPi = 3.14159265358979323846;
std::atomic<uint64_t> gAudioOutputUnitCreationCount{0};

enum SignalProbeSlotState : uint32_t {
    SignalProbeSlotFree = 0,
    SignalProbeSlotWriting = 1,
    SignalProbeSlotReady = 2,
    SignalProbeSlotReading = 3,
};

struct SignalProbeSlot {
    std::vector<float> samples;
    std::atomic<uint32_t> state{SignalProbeSlotFree};
    uint64_t sequence = 0;
    uint64_t hostTime = 0;
    uint32_t frameCount = 0;
};

struct SignalProbe {
    std::array<SignalProbeSlot, kSignalProbeSlotCount> slots;
    std::atomic<uint64_t> sequence{0};
    std::atomic<uint64_t> droppedFrames{0};
    int32_t activeSlot = -1;
};

} // namespace

struct EAUAudioIOBridge {
    std::vector<uint32_t> inputChannels;
    std::vector<uint32_t> outputChannels;
    std::vector<float> ring;
    std::vector<float> captureScratch;
    std::vector<float> outputScratch;
    std::vector<float> processedScratch;
    std::vector<float> submitScratch;
    std::array<SignalProbe, kSignalProbeStageCount> signalProbes;
    uint32_t channelCount = 0;
    uint32_t maxFrames = 0;
    uint32_t ringCapacityFrames = 0;
    uint32_t primeFrames = 0;
    uint32_t targetBacklogFrames = 0;
    uint32_t signalProbeFrameCapacity = 0;
    float outputGain = 1.0f;
    float outputLimit = 1.0f;

    alignas(64) std::atomic<uint64_t> writeFrame{0};
    alignas(64) std::atomic<uint64_t> readFrame{0};
    std::atomic<bool> primed{false};
    std::atomic<bool> stopping{false};
    std::atomic<uint32_t> fadeFramesRemaining{0};
    std::atomic<uint32_t> fadeFramesTotal{0};
    std::atomic<bool> fadeComplete{true};
    std::atomic<bool> fadeRequested{false};
    std::atomic<uint32_t> inFlight{0};
    std::atomic<uint64_t> captureCallbackCount{0};
    std::atomic<uint64_t> outputCallbackCount{0};
    std::atomic<uint64_t> capturedFrames{0};
    std::atomic<uint64_t> renderedFrames{0};
    std::atomic<uint64_t> nonZeroSampleCount{0};
    std::atomic<uint64_t> renderedNonZeroSampleCount{0};
    std::atomic<uint64_t> captureLastHostTime{0};
    std::atomic<uint64_t> outputLastHostTime{0};
    std::atomic<uint64_t> underrunBlocks{0};
    std::atomic<uint64_t> overflowFrames{0};
    std::atomic<uint64_t> droppedFrames{0};
    std::atomic<uint64_t> primingBlocks{0};
    std::atomic<uint64_t> backlogCorrections{0};
    std::atomic<uint64_t> renderActionSilenceInputBlocks{0};
    std::atomic<uint64_t> renderActionSilenceClearedBlocks{0};
    std::atomic<uint64_t> outputSilenceBlocks{0};
    std::atomic<uint64_t> outputNonSilenceBlocks{0};
    std::atomic<uint32_t> maxObservedFrames{0};
    std::atomic<uint32_t> faultFlags{EAUAudioIOFaultNone};
};

struct EAUAudioIORegistration {
    AudioObjectID device;
    AudioDeviceIOProcID ioProcID;
};

struct EAUAudioOutputUnit {
    AudioUnit unit;
    bool initialized;
    OSType componentSubType;
};

struct EAUSyntheticToneOutput {
    AudioUnit unit;
    bool initialized;
    OSType componentSubType;
    std::vector<float> samples;
    uint32_t channelCount;
    uint32_t maximumFrames;
    uint32_t durationFrames;
    std::atomic<uint64_t> nextFrame{0};
    std::atomic<uint64_t> callbackCount{0};
    std::atomic<uint64_t> renderedFrames{0};
    std::atomic<uint64_t> nonZeroSampleCount{0};
    std::atomic<uint64_t> lastHostTime{0};
    std::atomic<uint64_t> silenceBlocks{0};
    std::atomic<uint64_t> nonSilenceBlocks{0};
    std::atomic<uint32_t> maxObservedFrames{0};
    std::atomic<uint32_t> faultFlags{EAUAudioIOFaultNone};
    std::atomic<uint32_t> inFlight{0};
    std::atomic<bool> started{false};
};

struct EAUTapDrainRegistration {
    AudioObjectID device;
    AudioDeviceIOProcID ioProcID;
    uint32_t expectedChannelCount;
    uint32_t maximumFrames;
    uint32_t signalCaptureFrameCapacity;
    std::vector<float> signalCaptureSamples;
    std::atomic<uint64_t> callbackCount{0};
    std::atomic<uint64_t> capturedFrames{0};
    std::atomic<uint64_t> nonZeroSampleCount{0};
    std::atomic<uint64_t> lastHostTime{0};
    std::atomic<uint32_t> maxObservedFrames{0};
    std::atomic<uint32_t> faultFlags{EAUAudioIOFaultNone};
    std::atomic<uint32_t> inFlight{0};
    std::atomic<uint64_t> signalCaptureState{0};
    std::atomic<uint64_t> signalCaptureSequence{0};
    std::atomic<uint64_t> signalCaptureFirstHostTime{0};
    std::atomic<uint64_t> signalCaptureReservedFrames{0};
    std::atomic<uint64_t> signalCaptureDroppedFrames{0};
    std::atomic<bool> started{false};
};

namespace {

class CallbackScope {
public:
    explicit CallbackScope(EAUAudioIOBridge *bridge) noexcept : bridge_(bridge) {
        bridge_->inFlight.fetch_add(1, std::memory_order_acq_rel);
    }
    ~CallbackScope() { bridge_->inFlight.fetch_sub(1, std::memory_order_acq_rel); }
private:
    EAUAudioIOBridge *bridge_;
};

class AtomicCallbackScope {
public:
    explicit AtomicCallbackScope(std::atomic<uint32_t> &counter) noexcept : counter_(counter) {
        counter_.fetch_add(1, std::memory_order_acq_rel);
    }
    ~AtomicCallbackScope() { counter_.fetch_sub(1, std::memory_order_acq_rel); }
private:
    std::atomic<uint32_t> &counter_;
};

class TapSignalCaptureWriteScope {
public:
    explicit TapSignalCaptureWriteScope(EAUTapDrainRegistration *drain) noexcept
        : drain_(drain), acquired_(false) {
        uint64_t state = drain_->signalCaptureState.load(std::memory_order_acquire);
        while ((state & kTapSignalCaptureEnabled) != 0) {
            if ((state & kTapSignalCaptureWriterMask) == kTapSignalCaptureWriterMask) return;
            if (drain_->signalCaptureState.compare_exchange_weak(
                    state, state + 1, std::memory_order_acq_rel, std::memory_order_acquire)) {
                acquired_ = true;
                return;
            }
        }
    }

    ~TapSignalCaptureWriteScope() {
        if (acquired_) drain_->signalCaptureState.fetch_sub(1, std::memory_order_release);
    }

    bool acquired() const noexcept { return acquired_; }

private:
    EAUTapDrainRegistration *drain_;
    bool acquired_;
};

void zeroOutputs(AudioBufferList *outputData) noexcept {
    if (outputData == nullptr) return;
    for (uint32_t index = 0; index < outputData->mNumberBuffers; ++index) {
        AudioBuffer &buffer = outputData->mBuffers[index];
        if (buffer.mData != nullptr && buffer.mDataByteSize > 0) {
            std::memset(buffer.mData, 0, buffer.mDataByteSize);
        }
    }
}

void setFault(EAUAudioIOBridge *bridge, uint32_t fault) noexcept {
    bridge->faultFlags.fetch_or(fault, std::memory_order_relaxed);
}

void updateMaximum(std::atomic<uint32_t> &maximum, uint32_t value) noexcept {
    uint32_t current = maximum.load(std::memory_order_relaxed);
    while (current < value &&
           !maximum.compare_exchange_weak(current, value, std::memory_order_relaxed)) {}
}

uint64_t validHostTime(const AudioTimeStamp *timestamp) noexcept {
    return timestamp != nullptr && (timestamp->mFlags & kAudioTimeStampHostTimeValid) != 0
        ? timestamp->mHostTime
        : 0;
}

int32_t acquireSignalProbeSlot(SignalProbe &probe) noexcept {
    for (uint32_t index = 0; index < probe.slots.size(); ++index) {
        uint32_t expected = SignalProbeSlotFree;
        if (probe.slots[index].state.compare_exchange_strong(
                expected, SignalProbeSlotWriting, std::memory_order_acq_rel)) {
            probe.slots[index].frameCount = 0;
            probe.slots[index].hostTime = 0;
            return static_cast<int32_t>(index);
        }
    }
    return -1;
}

void appendSignalProbe(
    EAUAudioIOBridge *bridge,
    EAUAudioSignalProbeStage stage,
    const float *samples,
    uint32_t frameCount,
    uint64_t hostTime
) noexcept {
    const uint32_t stageIndex = static_cast<uint32_t>(stage);
    if (samples == nullptr || frameCount == 0 || stageIndex >= kSignalProbeStageCount) return;
    SignalProbe &probe = bridge->signalProbes[stageIndex];
    uint32_t sourceFrame = 0;
    while (sourceFrame < frameCount) {
        if (probe.activeSlot < 0) probe.activeSlot = acquireSignalProbeSlot(probe);
        if (probe.activeSlot < 0) {
            probe.droppedFrames.fetch_add(frameCount - sourceFrame, std::memory_order_relaxed);
            return;
        }

        SignalProbeSlot &slot = probe.slots[static_cast<uint32_t>(probe.activeSlot)];
        if (slot.frameCount == 0) slot.hostTime = hostTime;
        const uint32_t available = bridge->signalProbeFrameCapacity - slot.frameCount;
        const uint32_t copiedFrames = std::min(available, frameCount - sourceFrame);
        const size_t sourceOffset = static_cast<size_t>(sourceFrame) * bridge->channelCount;
        const size_t destinationOffset = static_cast<size_t>(slot.frameCount) * bridge->channelCount;
        std::memcpy(
            &slot.samples[destinationOffset],
            &samples[sourceOffset],
            static_cast<size_t>(copiedFrames) * bridge->channelCount * sizeof(float)
        );
        slot.frameCount += copiedFrames;
        sourceFrame += copiedFrames;

        if (slot.frameCount == bridge->signalProbeFrameCapacity) {
            slot.sequence = probe.sequence.fetch_add(1, std::memory_order_relaxed) + 1;
            slot.state.store(SignalProbeSlotReady, std::memory_order_release);
            probe.activeSlot = -1;
        }
    }
}

void advanceFade(EAUAudioIOBridge *bridge, uint32_t frames) noexcept {
    uint32_t remaining = bridge->fadeFramesRemaining.load(std::memory_order_acquire);
    if (remaining == 0) return;
    remaining = frames >= remaining ? 0 : remaining - frames;
    bridge->fadeFramesRemaining.store(remaining, std::memory_order_release);
    if (remaining == 0) bridge->fadeComplete.store(true, std::memory_order_release);
}

uint32_t sumChannels(const uint32_t *channels, uint32_t count) noexcept {
    uint64_t total = 0;
    for (uint32_t index = 0; index < count; ++index) total += channels[index];
    return total <= std::numeric_limits<uint32_t>::max() ? static_cast<uint32_t>(total) : 0;
}

bool validateInput(
    EAUAudioIOBridge *bridge,
    const AudioBufferList *data,
    uint32_t &frames
) noexcept {
    if (data == nullptr) {
        setFault(bridge, EAUAudioIOFaultMissingBuffer);
        return false;
    }
    if (data->mNumberBuffers != bridge->inputChannels.size()) {
        setFault(bridge, EAUAudioIOFaultLayoutMismatch);
        return false;
    }
    frames = 0;
    for (uint32_t index = 0; index < data->mNumberBuffers; ++index) {
        const AudioBuffer &buffer = data->mBuffers[index];
        const uint32_t channels = bridge->inputChannels[index];
        const uint64_t bytesPerFrame = static_cast<uint64_t>(channels) * sizeof(float);
        if (buffer.mData == nullptr || buffer.mNumberChannels != channels ||
            bytesPerFrame == 0 || buffer.mDataByteSize % bytesPerFrame != 0) {
            setFault(bridge, buffer.mData == nullptr ? EAUAudioIOFaultMissingBuffer
                                                    : EAUAudioIOFaultLayoutMismatch);
            return false;
        }
        const uint32_t bufferFrames = static_cast<uint32_t>(buffer.mDataByteSize / bytesPerFrame);
        if ((frames != 0 && frames != bufferFrames) || bufferFrames > bridge->maxFrames) {
            setFault(bridge, bufferFrames > bridge->maxFrames
                                 ? EAUAudioIOFaultFrameCapacityExceeded
                                 : EAUAudioIOFaultLayoutMismatch);
            return false;
        }
        frames = bufferFrames;
    }
    return frames > 0;
}

bool validateOutput(
    EAUAudioIOBridge *bridge,
    AudioBufferList *data,
    uint32_t requestedFrames,
    uint32_t &frames
) noexcept {
    if (data == nullptr) return false;
    if (data->mNumberBuffers != bridge->outputChannels.size()) {
        setFault(bridge, EAUAudioIOFaultLayoutMismatch);
        return false;
    }
    if (requestedFrames > bridge->maxFrames) {
        setFault(bridge, EAUAudioIOFaultFrameCapacityExceeded);
        return false;
    }
    frames = requestedFrames;
    for (uint32_t index = 0; index < data->mNumberBuffers; ++index) {
        const AudioBuffer &buffer = data->mBuffers[index];
        const uint32_t channels = bridge->outputChannels[index];
        const uint64_t bytesPerFrame = static_cast<uint64_t>(channels) * sizeof(float);
        if (buffer.mData == nullptr || buffer.mNumberChannels != channels ||
            bytesPerFrame == 0 || buffer.mDataByteSize % bytesPerFrame != 0) {
            setFault(bridge, buffer.mData == nullptr ? EAUAudioIOFaultMissingBuffer
                                                    : EAUAudioIOFaultLayoutMismatch);
            return false;
        }
        const uint32_t bufferFrames = static_cast<uint32_t>(buffer.mDataByteSize / bytesPerFrame);
        if ((requestedFrames == 0 && frames != 0 && frames != bufferFrames) ||
            bufferFrames > bridge->maxFrames ||
            (requestedFrames > 0 && bufferFrames < requestedFrames)) {
            setFault(bridge, bufferFrames > bridge->maxFrames
                                 ? EAUAudioIOFaultFrameCapacityExceeded
                                 : EAUAudioIOFaultLayoutMismatch);
            return false;
        }
        if (requestedFrames == 0) frames = bufferFrames;
    }
    return frames > 0;
}

OSStatus captureIOProc(
    AudioObjectID,
    const AudioTimeStamp *now,
    const AudioBufferList *inputData,
    const AudioTimeStamp *,
    AudioBufferList *,
    const AudioTimeStamp *,
    void *clientData
) {
    return EAUAudioIOBridgeCapture(static_cast<EAUAudioIOBridge *>(clientData), now, inputData);
}

OSStatus outputRenderCallback(
    void *clientData,
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    UInt32,
    UInt32 frameCount,
    AudioBufferList *outputData
) {
    return EAUAudioIOBridgeRenderFramesWithActionFlags(
        static_cast<EAUAudioIOBridge *>(clientData), actionFlags, timestamp,
        frameCount, outputData);
}

OSStatus syntheticToneRenderCallback(
    void *clientData,
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    UInt32,
    UInt32 frameCount,
    AudioBufferList *outputData
) {
    return EAUSyntheticToneOutputRender(
        static_cast<EAUSyntheticToneOutput *>(clientData), actionFlags,
        timestamp, frameCount, outputData);
}

OSStatus tapDrainIOProc(
    AudioObjectID,
    const AudioTimeStamp *,
    const AudioBufferList *inputData,
    const AudioTimeStamp *inputTime,
    AudioBufferList *,
    const AudioTimeStamp *,
    void *clientData
) {
    auto *drain = static_cast<EAUTapDrainRegistration *>(clientData);
    if (drain == nullptr) return noErr;
    TapSignalCaptureWriteScope signalCaptureScope(drain);
    AtomicCallbackScope scope(drain->inFlight);
    drain->callbackCount.fetch_add(1, std::memory_order_relaxed);
    drain->lastHostTime.store(validHostTime(inputTime), std::memory_order_relaxed);
    if (inputData == nullptr || inputData->mNumberBuffers == 0) {
        drain->faultFlags.fetch_or(EAUAudioIOFaultMissingBuffer, std::memory_order_relaxed);
        return noErr;
    }

    uint32_t frames = 0;
    uint32_t totalChannels = 0;
    uint64_t nonZero = 0;
    for (uint32_t index = 0; index < inputData->mNumberBuffers; ++index) {
        const AudioBuffer &buffer = inputData->mBuffers[index];
        const uint64_t bytesPerFrame = static_cast<uint64_t>(buffer.mNumberChannels) * sizeof(float);
        if (buffer.mData == nullptr || buffer.mNumberChannels == 0 || bytesPerFrame == 0 ||
            buffer.mDataByteSize % bytesPerFrame != 0) {
            drain->faultFlags.fetch_or(
                buffer.mData == nullptr ? EAUAudioIOFaultMissingBuffer
                                        : EAUAudioIOFaultLayoutMismatch,
                std::memory_order_relaxed);
            return noErr;
        }
        const uint32_t bufferFrames = static_cast<uint32_t>(buffer.mDataByteSize / bytesPerFrame);
        if ((frames != 0 && frames != bufferFrames) || bufferFrames > drain->maximumFrames) {
            drain->faultFlags.fetch_or(
                bufferFrames > drain->maximumFrames ? EAUAudioIOFaultFrameCapacityExceeded
                                                     : EAUAudioIOFaultLayoutMismatch,
                std::memory_order_relaxed);
            return noErr;
        }
        frames = bufferFrames;
        totalChannels += buffer.mNumberChannels;
        const float *samples = static_cast<const float *>(buffer.mData);
        const size_t sampleCount = static_cast<size_t>(bufferFrames) * buffer.mNumberChannels;
        for (size_t sample = 0; sample < sampleCount; ++sample) {
            if (samples[sample] != 0.0f) ++nonZero;
        }
    }
    if (frames == 0 || totalChannels != drain->expectedChannelCount) {
        drain->faultFlags.fetch_or(EAUAudioIOFaultLayoutMismatch, std::memory_order_relaxed);
        return noErr;
    }
    drain->capturedFrames.fetch_add(frames, std::memory_order_relaxed);
    drain->nonZeroSampleCount.fetch_add(nonZero, std::memory_order_relaxed);
    updateMaximum(drain->maxObservedFrames, frames);

    if (signalCaptureScope.acquired()) {
        const uint64_t reserved = drain->signalCaptureReservedFrames.fetch_add(
            frames, std::memory_order_relaxed);
        const uint64_t capacity = drain->signalCaptureFrameCapacity;
        const uint32_t copiedFrames = reserved < capacity
            ? static_cast<uint32_t>(std::min<uint64_t>(frames, capacity - reserved))
            : 0;
        if (copiedFrames > 0) {
            uint64_t expectedHostTime = 0;
            const uint64_t hostTime = validHostTime(inputTime);
            drain->signalCaptureFirstHostTime.compare_exchange_strong(
                expectedHostTime, hostTime, std::memory_order_relaxed);

            uint32_t channelBase = 0;
            for (uint32_t bufferIndex = 0; bufferIndex < inputData->mNumberBuffers;
                 ++bufferIndex) {
                const AudioBuffer &buffer = inputData->mBuffers[bufferIndex];
                const float *source = static_cast<const float *>(buffer.mData);
                for (uint32_t frame = 0; frame < copiedFrames; ++frame) {
                    const size_t sourceBase = static_cast<size_t>(frame) * buffer.mNumberChannels;
                    const size_t destinationBase =
                        static_cast<size_t>(reserved + frame) * drain->expectedChannelCount +
                        channelBase;
                    std::memcpy(
                        &drain->signalCaptureSamples[destinationBase], &source[sourceBase],
                        static_cast<size_t>(buffer.mNumberChannels) * sizeof(float));
                }
                channelBase += buffer.mNumberChannels;
            }
        }
        if (copiedFrames < frames) {
            drain->signalCaptureDroppedFrames.fetch_add(
                frames - copiedFrames, std::memory_order_relaxed);
        }
    }
    return noErr;
}

OSStatus readOutputUnitDiagnostics(
    AudioUnit unit,
    OSType componentSubType,
    EAUAudioOutputUnitDiagnostics *diagnostics
) {
    if (unit == nullptr || diagnostics == nullptr) return kAudio_ParamError;
    *diagnostics = {};
    diagnostics->componentSubType = componentSubType;

    UInt32 size = sizeof(diagnostics->currentDevice);
    OSStatus status = AudioUnitGetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0, &diagnostics->currentDevice, &size);
    if (status != noErr) return status;

    size = sizeof(diagnostics->deviceFormat);
    status = AudioUnitGetProperty(
        unit, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output, 0, &diagnostics->deviceFormat, &size);
    if (status != noErr) return status;

    size = sizeof(diagnostics->clientFormat);
    status = AudioUnitGetProperty(
        unit, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input, 0, &diagnostics->clientFormat, &size);
    if (status != noErr) return status;

    size = sizeof(diagnostics->maximumFrames);
    status = AudioUnitGetProperty(
        unit, kAudioUnitProperty_MaximumFramesPerSlice,
        kAudioUnitScope_Global, 0, &diagnostics->maximumFrames, &size);
    if (status != noErr) return status;

    size = sizeof(diagnostics->isRunning);
    diagnostics->isRunningStatus = AudioUnitGetProperty(
        unit, kAudioOutputUnitProperty_IsRunning,
        kAudioUnitScope_Global, 0, &diagnostics->isRunning, &size);
    diagnostics->volumeStatus = AudioUnitGetParameter(
        unit, kHALOutputParam_Volume,
        kAudioUnitScope_Global, 0, &diagnostics->volume);
    return noErr;
}

OSStatus createAudioOutputUnit(
    AudioObjectID device,
    EAUAudioIOBridge *bridge,
    Float64 sampleRate,
    UInt32 channelCount,
    UInt32 maximumFrames,
    OSType componentSubType,
    EAUAudioOutputUnit **outputUnit
) {
    if (device == kAudioObjectUnknown || bridge == nullptr || !std::isfinite(sampleRate) ||
        sampleRate <= 0.0 || channelCount == 0 || maximumFrames == 0 || outputUnit == nullptr) {
        return kAudio_ParamError;
    }

    AudioComponentDescription description{};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = componentSubType;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (component == nullptr) return kAudioHardwareUnsupportedOperationError;

    AudioUnit unit = nullptr;
    OSStatus status = AudioComponentInstanceNew(component, &unit);
    if (status != noErr) return status;
    gAudioOutputUnitCreationCount.fetch_add(1, std::memory_order_relaxed);

    auto *value = new (std::nothrow) EAUAudioOutputUnit{
        unit, false, description.componentSubType
    };
    if (value == nullptr) {
        AudioComponentInstanceDispose(unit);
        return kAudioHardwareUnspecifiedError;
    }

    // Output-only units do not use the EnableIO sequence required by AUHAL input.
    status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                  kAudioUnitScope_Global, 0, &device, sizeof(device));

    AudioStreamBasicDescription format{};
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    format.mBytesPerPacket = channelCount * sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = channelCount * sizeof(float);
    format.mChannelsPerFrame = channelCount;
    format.mBitsPerChannel = 8 * sizeof(float);
    if (status == noErr) {
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 0, &format, sizeof(format));
    }
    if (status == noErr) {
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                      kAudioUnitScope_Global, 0, &maximumFrames,
                                      sizeof(maximumFrames));
    }
    AURenderCallbackStruct callback{outputRenderCallback, bridge};
    if (status == noErr) {
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    }
    if (status == noErr) {
        status = AudioUnitInitialize(unit);
        if (status == noErr) value->initialized = true;
    }
    if (status != noErr) {
        if (value->initialized) AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        delete value;
        return status;
    }
    *outputUnit = value;
    return noErr;
}

} // namespace

EAUAudioIOBridge *EAUAudioIOBridgeCreate(
    const uint32_t *inputChannels,
    uint32_t inputBufferCount,
    const uint32_t *outputChannels,
    uint32_t outputBufferCount,
    uint32_t bytesPerSample,
    uint32_t maxFrames,
    uint32_t ringCapacityFrames,
    uint32_t primeFrames,
    uint32_t targetBacklogFrames,
    float outputGain,
    float outputLimit
) {
    if (inputChannels == nullptr || outputChannels == nullptr || inputBufferCount == 0 ||
        outputBufferCount == 0 || bytesPerSample != sizeof(float) || maxFrames == 0 ||
        ringCapacityFrames < maxFrames || primeFrames == 0 ||
        primeFrames > ringCapacityFrames || targetBacklogFrames < maxFrames ||
        targetBacklogFrames > ringCapacityFrames || !std::isfinite(outputGain) ||
        !std::isfinite(outputLimit) || outputGain <= 0.0f || outputGain > 1.0f ||
        outputLimit <= 0.0f) return nullptr;
    const uint32_t inputTotal = sumChannels(inputChannels, inputBufferCount);
    const uint32_t outputTotal = sumChannels(outputChannels, outputBufferCount);
    if (inputTotal == 0 || inputTotal != outputTotal) return nullptr;

    auto *bridge = new (std::nothrow) EAUAudioIOBridge;
    if (bridge == nullptr) return nullptr;
    try {
        bridge->inputChannels.assign(inputChannels, inputChannels + inputBufferCount);
        bridge->outputChannels.assign(outputChannels, outputChannels + outputBufferCount);
        bridge->ring.resize(static_cast<size_t>(ringCapacityFrames) * inputTotal);
        bridge->captureScratch.resize(static_cast<size_t>(maxFrames) * inputTotal);
        bridge->outputScratch.resize(static_cast<size_t>(maxFrames) * inputTotal);
        bridge->processedScratch.resize(static_cast<size_t>(maxFrames) * inputTotal);
        bridge->submitScratch.resize(static_cast<size_t>(maxFrames) * inputTotal);
        const uint32_t probeFrames = std::min(maxFrames, kMaximumSignalProbeFrames);
        for (SignalProbe &probe : bridge->signalProbes) {
            for (SignalProbeSlot &slot : probe.slots) {
                slot.samples.resize(static_cast<size_t>(probeFrames) * inputTotal);
            }
        }
    } catch (...) {
        delete bridge;
        return nullptr;
    }
    bridge->channelCount = inputTotal;
    bridge->maxFrames = maxFrames;
    bridge->ringCapacityFrames = ringCapacityFrames;
    bridge->primeFrames = primeFrames;
    bridge->targetBacklogFrames = targetBacklogFrames;
    bridge->signalProbeFrameCapacity = std::min(maxFrames, kMaximumSignalProbeFrames);
    bridge->outputGain = outputGain;
    bridge->outputLimit = outputLimit;
    return bridge;
}

bool EAUAudioIOBridgeReset(EAUAudioIOBridge *bridge) {
    if (bridge == nullptr ||
        bridge->inFlight.load(std::memory_order_acquire) != 0 ||
        bridge->stopping.load(std::memory_order_acquire)) return false;
    bridge->writeFrame.store(0, std::memory_order_release);
    bridge->readFrame.store(0, std::memory_order_release);
    bridge->primed.store(false, std::memory_order_release);
    bridge->fadeFramesRemaining.store(0, std::memory_order_release);
    bridge->fadeFramesTotal.store(0, std::memory_order_release);
    bridge->fadeComplete.store(true, std::memory_order_release);
    bridge->fadeRequested.store(false, std::memory_order_release);
    bridge->captureCallbackCount.store(0, std::memory_order_relaxed);
    bridge->outputCallbackCount.store(0, std::memory_order_relaxed);
    bridge->capturedFrames.store(0, std::memory_order_relaxed);
    bridge->renderedFrames.store(0, std::memory_order_relaxed);
    bridge->nonZeroSampleCount.store(0, std::memory_order_relaxed);
    bridge->renderedNonZeroSampleCount.store(0, std::memory_order_relaxed);
    bridge->captureLastHostTime.store(0, std::memory_order_relaxed);
    bridge->outputLastHostTime.store(0, std::memory_order_relaxed);
    bridge->underrunBlocks.store(0, std::memory_order_relaxed);
    bridge->overflowFrames.store(0, std::memory_order_relaxed);
    bridge->droppedFrames.store(0, std::memory_order_relaxed);
    bridge->primingBlocks.store(0, std::memory_order_relaxed);
    bridge->backlogCorrections.store(0, std::memory_order_relaxed);
    bridge->renderActionSilenceInputBlocks.store(0, std::memory_order_relaxed);
    bridge->renderActionSilenceClearedBlocks.store(0, std::memory_order_relaxed);
    bridge->outputSilenceBlocks.store(0, std::memory_order_relaxed);
    bridge->outputNonSilenceBlocks.store(0, std::memory_order_relaxed);
    bridge->maxObservedFrames.store(0, std::memory_order_relaxed);
    bridge->faultFlags.store(EAUAudioIOFaultNone, std::memory_order_release);
    for (SignalProbe &probe : bridge->signalProbes) {
        probe.activeSlot = -1;
        probe.sequence.store(0, std::memory_order_relaxed);
        probe.droppedFrames.store(0, std::memory_order_relaxed);
        for (SignalProbeSlot &slot : probe.slots) {
            slot.sequence = 0;
            slot.hostTime = 0;
            slot.frameCount = 0;
            slot.state.store(SignalProbeSlotFree, std::memory_order_release);
        }
    }
    return true;
}

void EAUAudioIOBridgeCancelFadeOut(EAUAudioIOBridge *bridge) {
    if (bridge == nullptr) return;
    bridge->fadeFramesRemaining.store(0, std::memory_order_release);
    bridge->fadeFramesTotal.store(0, std::memory_order_release);
    bridge->fadeComplete.store(true, std::memory_order_release);
    bridge->fadeRequested.store(false, std::memory_order_release);
}

void EAUAudioIOBridgeRequestFadeOut(EAUAudioIOBridge *bridge, uint32_t fadeFrames) {
    if (bridge == nullptr) return;
    bool expected = false;
    if (!bridge->fadeRequested.compare_exchange_strong(
            expected, true, std::memory_order_acq_rel)) return;
    bridge->fadeFramesTotal.store(fadeFrames, std::memory_order_relaxed);
    bridge->fadeFramesRemaining.store(fadeFrames, std::memory_order_release);
    bridge->fadeComplete.store(fadeFrames == 0, std::memory_order_release);
}

bool EAUAudioIOBridgeIsFadeComplete(const EAUAudioIOBridge *bridge) {
    return bridge == nullptr || bridge->fadeComplete.load(std::memory_order_acquire);
}

void EAUAudioIOBridgeBeginStopping(EAUAudioIOBridge *bridge) {
    if (bridge != nullptr) bridge->stopping.store(true, std::memory_order_release);
}

bool EAUAudioIOBridgeIsQuiescent(const EAUAudioIOBridge *bridge) {
    return bridge == nullptr || bridge->inFlight.load(std::memory_order_acquire) == 0;
}

void EAUAudioIOBridgeDestroy(EAUAudioIOBridge *bridge) { delete bridge; }

EAUAudioIOBridgeSnapshot EAUAudioIOBridgeGetSnapshot(const EAUAudioIOBridge *bridge) {
    if (bridge == nullptr) return {};
    const uint64_t write = bridge->writeFrame.load(std::memory_order_acquire);
    const uint64_t read = bridge->readFrame.load(std::memory_order_acquire);
    const uint64_t fill = write >= read ? write - read : 0;
    return {
        bridge->captureCallbackCount.load(std::memory_order_relaxed),
        bridge->outputCallbackCount.load(std::memory_order_relaxed),
        bridge->capturedFrames.load(std::memory_order_relaxed),
        bridge->renderedFrames.load(std::memory_order_relaxed),
        bridge->nonZeroSampleCount.load(std::memory_order_relaxed),
        bridge->renderedNonZeroSampleCount.load(std::memory_order_relaxed),
        bridge->captureLastHostTime.load(std::memory_order_relaxed),
        bridge->outputLastHostTime.load(std::memory_order_relaxed),
        bridge->underrunBlocks.load(std::memory_order_relaxed),
        bridge->overflowFrames.load(std::memory_order_relaxed),
        bridge->droppedFrames.load(std::memory_order_relaxed),
        bridge->primingBlocks.load(std::memory_order_relaxed),
        bridge->backlogCorrections.load(std::memory_order_relaxed),
        bridge->renderActionSilenceInputBlocks.load(std::memory_order_relaxed),
        bridge->renderActionSilenceClearedBlocks.load(std::memory_order_relaxed),
        bridge->outputSilenceBlocks.load(std::memory_order_relaxed),
        bridge->outputNonSilenceBlocks.load(std::memory_order_relaxed),
        static_cast<uint32_t>(std::min<uint64_t>(fill, bridge->ringCapacityFrames)),
        bridge->maxObservedFrames.load(std::memory_order_relaxed),
        bridge->faultFlags.load(std::memory_order_relaxed),
        bridge->inFlight.load(std::memory_order_acquire),
        bridge->fadeComplete.load(std::memory_order_acquire),
    };
}

uint32_t EAUAudioIOBridgeGetSignalProbeFrameCapacity(const EAUAudioIOBridge *bridge) {
    return bridge == nullptr ? 0 : bridge->signalProbeFrameCapacity;
}

uint32_t EAUAudioIOBridgeGetSignalProbeChannelCount(const EAUAudioIOBridge *bridge) {
    return bridge == nullptr ? 0 : bridge->channelCount;
}

uint32_t EAUAudioIOBridgeCopyLatestSignalProbe(
    EAUAudioIOBridge *bridge,
    EAUAudioSignalProbeStage stage,
    float *samples,
    uint32_t sampleCapacity,
    EAUAudioSignalProbeMetadata *metadata
) {
    const uint32_t stageIndex = static_cast<uint32_t>(stage);
    if (bridge == nullptr || samples == nullptr || metadata == nullptr ||
        stageIndex >= kSignalProbeStageCount) return 0;

    SignalProbe &probe = bridge->signalProbes[stageIndex];
    for (uint32_t attempt = 0; attempt < kSignalProbeSlotCount; ++attempt) {
        int32_t selectedIndex = -1;
        uint64_t selectedSequence = 0;
        for (uint32_t index = 0; index < probe.slots.size(); ++index) {
            SignalProbeSlot &slot = probe.slots[index];
            if (slot.state.load(std::memory_order_acquire) == SignalProbeSlotReady &&
                slot.sequence > selectedSequence) {
                selectedIndex = static_cast<int32_t>(index);
                selectedSequence = slot.sequence;
            }
        }
        if (selectedIndex < 0) return 0;

        SignalProbeSlot &selected = probe.slots[static_cast<uint32_t>(selectedIndex)];
        const uint64_t sampleCount64 = static_cast<uint64_t>(selected.frameCount) * bridge->channelCount;
        if (sampleCount64 > sampleCapacity || sampleCount64 > std::numeric_limits<uint32_t>::max()) {
            return 0;
        }
        uint32_t expected = SignalProbeSlotReady;
        if (!selected.state.compare_exchange_strong(
                expected, SignalProbeSlotReading, std::memory_order_acq_rel)) continue;

        const uint32_t sampleCount = static_cast<uint32_t>(sampleCount64);
        std::memcpy(samples, selected.samples.data(), static_cast<size_t>(sampleCount) * sizeof(float));
        *metadata = {
            stage,
            selected.sequence,
            selected.hostTime,
            probe.droppedFrames.load(std::memory_order_relaxed),
            selected.frameCount,
            bridge->channelCount,
        };
        selected.state.store(SignalProbeSlotFree, std::memory_order_release);

        for (SignalProbeSlot &slot : probe.slots) {
            if (&slot == &selected ||
                slot.state.load(std::memory_order_acquire) != SignalProbeSlotReady ||
                slot.sequence >= selectedSequence) continue;
            expected = SignalProbeSlotReady;
            if (slot.state.compare_exchange_strong(
                    expected, SignalProbeSlotReading, std::memory_order_acq_rel)) {
                slot.state.store(SignalProbeSlotFree, std::memory_order_release);
            }
        }
        return sampleCount;
    }
    return 0;
}

uint64_t EAUAudioDSPProcessInterleaved(
    const float *input,
    float *output,
    uint32_t frameCount,
    uint32_t channelCount,
    float outputGain,
    float outputLimit
) {
    if (input == nullptr || output == nullptr || frameCount == 0 || channelCount == 0 ||
        !std::isfinite(outputGain) || !std::isfinite(outputLimit) || outputGain < 0.0f ||
        outputLimit <= 0.0f) return 0;

    uint64_t nonZero = 0;
    const size_t sampleCount = static_cast<size_t>(frameCount) * channelCount;
    for (size_t index = 0; index < sampleCount; ++index) {
        const float finiteSample = std::isfinite(input[index]) ? input[index] : 0.0f;
        const float scaled = finiteSample * outputGain;
        const float value = std::max(-outputLimit, std::min(scaled, outputLimit));
        output[index] = value;
        if (value != 0.0f) ++nonZero;
    }
    return nonZero;
}

OSStatus EAUAudioIOBridgeCapture(
    EAUAudioIOBridge *bridge,
    const AudioTimeStamp *now,
    const AudioBufferList *inputData
) {
    if (bridge == nullptr) return noErr;
    CallbackScope scope(bridge);
    bridge->captureCallbackCount.fetch_add(1, std::memory_order_relaxed);
    if (now != nullptr && (now->mFlags & kAudioTimeStampHostTimeValid) != 0) {
        bridge->captureLastHostTime.store(now->mHostTime, std::memory_order_relaxed);
    }
    if (bridge->stopping.load(std::memory_order_acquire)) return noErr;

    uint32_t frames = 0;
    if (!validateInput(bridge, inputData, frames)) return noErr;
    size_t channelBase = 0;
    uint64_t nonZero = 0;
    for (uint32_t bufferIndex = 0; bufferIndex < inputData->mNumberBuffers; ++bufferIndex) {
        const AudioBuffer &buffer = inputData->mBuffers[bufferIndex];
        const uint32_t channels = bridge->inputChannels[bufferIndex];
        const float *source = static_cast<const float *>(buffer.mData);
        for (uint32_t frame = 0; frame < frames; ++frame) {
            for (uint32_t channel = 0; channel < channels; ++channel) {
                const float sample = source[static_cast<size_t>(frame) * channels + channel];
                bridge->captureScratch[static_cast<size_t>(frame) * bridge->channelCount +
                                       channelBase + channel] = sample;
                if (sample != 0.0f) ++nonZero;
            }
        }
        channelBase += channels;
    }
    appendSignalProbe(
        bridge, EAUAudioSignalProbeCapture, bridge->captureScratch.data(), frames, validHostTime(now));

    const uint64_t write = bridge->writeFrame.load(std::memory_order_relaxed);
    const uint64_t read = bridge->readFrame.load(std::memory_order_acquire);
    const uint64_t used = write >= read ? write - read : bridge->ringCapacityFrames;
    if (frames > bridge->ringCapacityFrames - std::min<uint64_t>(used, bridge->ringCapacityFrames)) {
        bridge->overflowFrames.fetch_add(frames, std::memory_order_relaxed);
        bridge->droppedFrames.fetch_add(frames, std::memory_order_relaxed);
        return noErr;
    }
    for (uint32_t frame = 0; frame < frames; ++frame) {
        const size_t ringBase = static_cast<size_t>((write + frame) % bridge->ringCapacityFrames) *
                                bridge->channelCount;
        const size_t scratchBase = static_cast<size_t>(frame) * bridge->channelCount;
        std::memcpy(&bridge->ring[ringBase], &bridge->captureScratch[scratchBase],
                    static_cast<size_t>(bridge->channelCount) * sizeof(float));
    }
    bridge->writeFrame.store(write + frames, std::memory_order_release);
    bridge->capturedFrames.fetch_add(frames, std::memory_order_relaxed);
    bridge->nonZeroSampleCount.fetch_add(nonZero, std::memory_order_relaxed);
    updateMaximum(bridge->maxObservedFrames, frames);
    return noErr;
}

OSStatus EAUAudioIOBridgeRender(
    EAUAudioIOBridge *bridge,
    const AudioTimeStamp *now,
    AudioBufferList *outputData
) {
    return EAUAudioIOBridgeRenderWithActionFlags(bridge, nullptr, now, outputData);
}

OSStatus EAUAudioIOBridgeRenderWithActionFlags(
    EAUAudioIOBridge *bridge,
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *now,
    AudioBufferList *outputData
) {
    return EAUAudioIOBridgeRenderFramesWithActionFlags(
        bridge, actionFlags, now, 0, outputData);
}

OSStatus EAUAudioIOBridgeRenderFramesWithActionFlags(
    EAUAudioIOBridge *bridge,
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *now,
    UInt32 requestedFrames,
    AudioBufferList *outputData
) {
    const AudioUnitRenderActionFlags silenceFlag = kAudioUnitRenderAction_OutputIsSilence;
    const bool incomingSilence = actionFlags != nullptr && (*actionFlags & silenceFlag) != 0;
    if (bridge == nullptr || outputData == nullptr) {
        if (actionFlags != nullptr) *actionFlags |= silenceFlag;
        return noErr;
    }
    CallbackScope scope(bridge);
    if (incomingSilence) {
        bridge->renderActionSilenceInputBlocks.fetch_add(1, std::memory_order_relaxed);
    }
    const auto markSilence = [bridge, actionFlags, silenceFlag]() noexcept {
        if (actionFlags != nullptr) *actionFlags |= silenceFlag;
        bridge->outputSilenceBlocks.fetch_add(1, std::memory_order_relaxed);
    };
    bridge->outputCallbackCount.fetch_add(1, std::memory_order_relaxed);
    if (now != nullptr && (now->mFlags & kAudioTimeStampHostTimeValid) != 0) {
        bridge->outputLastHostTime.store(now->mHostTime, std::memory_order_relaxed);
    }
    zeroOutputs(outputData);
    if (bridge->stopping.load(std::memory_order_acquire)) {
        markSilence();
        return noErr;
    }

    uint32_t frames = 0;
    if (!validateOutput(bridge, outputData, requestedFrames, frames)) {
        markSilence();
        return noErr;
    }
    uint64_t read = bridge->readFrame.load(std::memory_order_relaxed);
    const uint64_t write = bridge->writeFrame.load(std::memory_order_acquire);
    uint64_t available = write >= read ? write - read : 0;

    if (!bridge->primed.load(std::memory_order_acquire)) {
        if (available < bridge->primeFrames) {
            bridge->primingBlocks.fetch_add(1, std::memory_order_relaxed);
            advanceFade(bridge, frames);
            markSilence();
            return noErr;
        }
        bridge->primed.store(true, std::memory_order_release);
    }

    if (available > static_cast<uint64_t>(bridge->targetBacklogFrames) + bridge->maxFrames) {
        const uint64_t drop = available - bridge->targetBacklogFrames;
        read += drop;
        available -= drop;
        bridge->readFrame.store(read, std::memory_order_release);
        bridge->droppedFrames.fetch_add(drop, std::memory_order_relaxed);
        bridge->backlogCorrections.fetch_add(1, std::memory_order_relaxed);
    }
    if (available < frames) {
        bridge->underrunBlocks.fetch_add(1, std::memory_order_relaxed);
        bridge->primed.store(false, std::memory_order_release);
        if (available > 0) {
            bridge->readFrame.store(read + available, std::memory_order_release);
            bridge->droppedFrames.fetch_add(available, std::memory_order_relaxed);
        }
        advanceFade(bridge, frames);
        markSilence();
        return noErr;
    }

    for (uint32_t frame = 0; frame < frames; ++frame) {
        const size_t ringBase = static_cast<size_t>((read + frame) % bridge->ringCapacityFrames) *
                                bridge->channelCount;
        const size_t scratchBase = static_cast<size_t>(frame) * bridge->channelCount;
        std::memcpy(&bridge->outputScratch[scratchBase], &bridge->ring[ringBase],
                    static_cast<size_t>(bridge->channelCount) * sizeof(float));
    }
    bridge->readFrame.store(read + frames, std::memory_order_release);

    uint64_t renderedNonZero = 0;
    uint32_t fadeRemaining = bridge->fadeFramesRemaining.load(std::memory_order_acquire);
    const uint32_t fadeTotal = bridge->fadeFramesTotal.load(std::memory_order_relaxed);
    uint32_t localFade = fadeRemaining;
    for (uint32_t frame = 0; frame < frames; ++frame) {
        const float gain = localFade > 0 && fadeTotal > 0
            ? static_cast<float>(localFade) / static_cast<float>(fadeTotal)
            : (fadeTotal == 0 ? 1.0f : 0.0f);
        const size_t sampleBase = static_cast<size_t>(frame) * bridge->channelCount;
        renderedNonZero += EAUAudioDSPProcessInterleaved(
            &bridge->outputScratch[sampleBase], &bridge->processedScratch[sampleBase],
            1, bridge->channelCount, bridge->outputGain * gain, bridge->outputLimit);
        if (localFade > 0) --localFade;
    }
    appendSignalProbe(
        bridge, EAUAudioSignalProbePostDSP, bridge->processedScratch.data(), frames,
        validHostTime(now));

    size_t channelBase = 0;
    for (uint32_t bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; ++bufferIndex) {
        AudioBuffer &buffer = outputData->mBuffers[bufferIndex];
        const uint32_t channels = bridge->outputChannels[bufferIndex];
        float *destination = static_cast<float *>(buffer.mData);
        for (uint32_t frame = 0; frame < frames; ++frame) {
            const size_t sourceBase = static_cast<size_t>(frame) * bridge->channelCount + channelBase;
            const size_t destinationBase = static_cast<size_t>(frame) * channels;
            std::memcpy(
                &destination[destinationBase], &bridge->processedScratch[sourceBase],
                static_cast<size_t>(channels) * sizeof(float));
            std::memcpy(
                &bridge->submitScratch[sourceBase], &destination[destinationBase],
                static_cast<size_t>(channels) * sizeof(float));
        }
        channelBase += channels;
    }
    appendSignalProbe(
        bridge, EAUAudioSignalProbeAppleSubmit, bridge->submitScratch.data(), frames,
        validHostTime(now));
    if (fadeRemaining > 0) {
        advanceFade(bridge, frames);
    }
    bridge->renderedFrames.fetch_add(frames, std::memory_order_relaxed);
    bridge->renderedNonZeroSampleCount.fetch_add(renderedNonZero, std::memory_order_relaxed);
    updateMaximum(bridge->maxObservedFrames, frames);
    if (renderedNonZero == 0) {
        markSilence();
    } else {
        if (actionFlags != nullptr) {
            *actionFlags &= ~silenceFlag;
            if (incomingSilence) {
                bridge->renderActionSilenceClearedBlocks.fetch_add(1, std::memory_order_relaxed);
            }
        }
        bridge->outputNonSilenceBlocks.fetch_add(1, std::memory_order_relaxed);
    }
    return noErr;
}

OSStatus EAUAudioIORegistrationCreate(
    AudioObjectID device,
    EAUAudioIOBridge *bridge,
    EAUAudioIORegistrationKind kind,
    EAUAudioIORegistration **registration
) {
    if (bridge == nullptr || registration == nullptr) return kAudio_ParamError;
    auto *value = new (std::nothrow) EAUAudioIORegistration{device, nullptr};
    if (value == nullptr) return kAudioHardwareUnspecifiedError;
    if (kind != EAUAudioIORegistrationCapture) {
        delete value;
        return kAudio_ParamError;
    }
    const OSStatus status = AudioDeviceCreateIOProcID(device, captureIOProc, bridge, &value->ioProcID);
    if (status != noErr) {
        delete value;
        return status;
    }
    *registration = value;
    return noErr;
}

OSStatus EAUAudioIORegistrationStart(EAUAudioIORegistration *registration) {
    return registration == nullptr ? kAudio_ParamError
                                   : AudioDeviceStart(registration->device, registration->ioProcID);
}

OSStatus EAUAudioIORegistrationStop(EAUAudioIORegistration *registration) {
    return registration == nullptr ? kAudio_ParamError
                                   : AudioDeviceStop(registration->device, registration->ioProcID);
}

OSStatus EAUAudioIORegistrationDestroy(EAUAudioIORegistration *registration) {
    if (registration == nullptr) return noErr;
    const OSStatus status = AudioDeviceDestroyIOProcID(registration->device, registration->ioProcID);
    if (status == noErr) delete registration;
    return status;
}

OSStatus EAUAudioOutputUnitCreate(
    AudioObjectID device,
    EAUAudioIOBridge *bridge,
    Float64 sampleRate,
    UInt32 channelCount,
    UInt32 maximumFrames,
    EAUAudioOutputUnit **outputUnit
) {
    return createAudioOutputUnit(
        device, bridge, sampleRate, channelCount, maximumFrames,
        kAudioUnitSubType_DefaultOutput, outputUnit);
}

OSStatus EAUAudioHALOutputUnitCreate(
    AudioObjectID device,
    EAUAudioIOBridge *bridge,
    Float64 sampleRate,
    UInt32 channelCount,
    UInt32 maximumFrames,
    EAUAudioOutputUnit **outputUnit
) {
    return createAudioOutputUnit(
        device, bridge, sampleRate, channelCount, maximumFrames,
        kAudioUnitSubType_HALOutput, outputUnit);
}

OSStatus EAUAudioOutputUnitStart(EAUAudioOutputUnit *outputUnit) {
    return outputUnit == nullptr ? kAudio_ParamError : AudioOutputUnitStart(outputUnit->unit);
}

OSStatus EAUAudioOutputUnitStop(EAUAudioOutputUnit *outputUnit) {
    return outputUnit == nullptr ? kAudio_ParamError : AudioOutputUnitStop(outputUnit->unit);
}

OSStatus EAUAudioOutputUnitGetDiagnostics(
    EAUAudioOutputUnit *outputUnit,
    EAUAudioOutputUnitDiagnostics *diagnostics
) {
    return outputUnit == nullptr
        ? kAudio_ParamError
        : readOutputUnitDiagnostics(outputUnit->unit, outputUnit->componentSubType, diagnostics);
}

OSStatus EAUAudioOutputUnitDestroy(EAUAudioOutputUnit *outputUnit) {
    if (outputUnit == nullptr) return noErr;
    if (outputUnit->initialized) {
        const OSStatus status = AudioUnitUninitialize(outputUnit->unit);
        if (status != noErr) return status;
        outputUnit->initialized = false;
    }
    const OSStatus disposeStatus = AudioComponentInstanceDispose(outputUnit->unit);
    if (disposeStatus == noErr) delete outputUnit;
    return disposeStatus;
}

uint64_t EAUAudioOutputUnitGetCreationCount(void) {
    return gAudioOutputUnitCreationCount.load(std::memory_order_relaxed);
}

OSStatus EAUSyntheticToneOutputCreate(
    AudioObjectID device,
    Float64 sampleRate,
    UInt32 channelCount,
    UInt32 maximumFrames,
    Float64 frequency,
    float amplitude,
    UInt32 durationFrames,
    UInt32 fadeFrames,
    EAUSyntheticToneOutput **output
) {
    if (device == kAudioObjectUnknown || !std::isfinite(sampleRate) || sampleRate <= 0.0 ||
        channelCount == 0 || maximumFrames == 0 || !std::isfinite(frequency) ||
        frequency < 20.0 || frequency >= sampleRate * 0.5 || !std::isfinite(amplitude) ||
        amplitude <= 0.0f || amplitude > 0.05f || durationFrames == 0 ||
        durationFrames > static_cast<uint64_t>(sampleRate * 3.0) ||
        fadeFrames > durationFrames / 2 || output == nullptr) {
        return kAudio_ParamError;
    }

    std::vector<float> monoSamples;
    try {
        monoSamples.resize(durationFrames);
    } catch (...) {
        return kAudioHardwareUnspecifiedError;
    }

    for (uint32_t frame = 0; frame < durationFrames; ++frame) {
        double envelope = 1.0;
        if (fadeFrames > 0 && frame < fadeFrames) {
            envelope *= 0.5 - 0.5 * std::cos(kPi * frame / fadeFrames);
        }
        const uint32_t remaining = durationFrames - 1 - frame;
        if (fadeFrames > 0 && remaining < fadeFrames) {
            envelope *= 0.5 - 0.5 * std::cos(kPi * remaining / fadeFrames);
        }
        monoSamples[frame] = static_cast<float>(
            amplitude * envelope * std::sin(2.0 * kPi * frequency * frame / sampleRate));
    }

    return EAUSyntheticSignalOutputCreate(
        device, sampleRate, channelCount, maximumFrames, monoSamples.data(),
        durationFrames, output);
}

OSStatus EAUSyntheticSignalOutputCreate(
    AudioObjectID device,
    Float64 sampleRate,
    UInt32 channelCount,
    UInt32 maximumFrames,
    const float *monoSamples,
    UInt32 durationFrames,
    EAUSyntheticToneOutput **output
) {
    if (device == kAudioObjectUnknown || !std::isfinite(sampleRate) || sampleRate <= 0.0 ||
        channelCount == 0 || maximumFrames == 0 || monoSamples == nullptr ||
        durationFrames == 0 || durationFrames > static_cast<uint64_t>(sampleRate * 3.0) ||
        output == nullptr) {
        return kAudio_ParamError;
    }
    for (uint32_t frame = 0; frame < durationFrames; ++frame) {
        if (!std::isfinite(monoSamples[frame]) || std::abs(monoSamples[frame]) > 0.05f) {
            return kAudio_ParamError;
        }
    }

    auto *value = new (std::nothrow) EAUSyntheticToneOutput;
    if (value == nullptr) return kAudioHardwareUnspecifiedError;
    value->unit = nullptr;
    value->initialized = false;
    value->componentSubType = kAudioUnitSubType_DefaultOutput;
    value->channelCount = channelCount;
    value->maximumFrames = maximumFrames;
    value->durationFrames = durationFrames;
    try {
        value->samples.resize(static_cast<size_t>(durationFrames) * channelCount);
    } catch (...) {
        delete value;
        return kAudioHardwareUnspecifiedError;
    }
    for (uint32_t frame = 0; frame < durationFrames; ++frame) {
        const size_t base = static_cast<size_t>(frame) * channelCount;
        for (uint32_t channel = 0; channel < channelCount; ++channel) {
            value->samples[base + channel] = monoSamples[frame];
        }
    }

    AudioComponentDescription description{};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_DefaultOutput;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (component == nullptr) {
        delete value;
        return kAudioHardwareUnsupportedOperationError;
    }

    OSStatus status = AudioComponentInstanceNew(component, &value->unit);
    if (status == noErr) {
        gAudioOutputUnitCreationCount.fetch_add(1, std::memory_order_relaxed);
    }
    if (status == noErr) {
        status = AudioUnitSetProperty(
            value->unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, sizeof(device));
    }
    AudioStreamBasicDescription format{};
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    format.mBytesPerPacket = channelCount * sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = channelCount * sizeof(float);
    format.mChannelsPerFrame = channelCount;
    format.mBitsPerChannel = 8 * sizeof(float);
    if (status == noErr) {
        status = AudioUnitSetProperty(
            value->unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &format, sizeof(format));
    }
    if (status == noErr) {
        status = AudioUnitSetProperty(
            value->unit, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &maximumFrames, sizeof(maximumFrames));
    }
    AURenderCallbackStruct callback{syntheticToneRenderCallback, value};
    if (status == noErr) {
        status = AudioUnitSetProperty(
            value->unit, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    }
    if (status == noErr) {
        status = AudioUnitInitialize(value->unit);
        if (status == noErr) value->initialized = true;
    }
    if (status != noErr) {
        if (value->initialized) AudioUnitUninitialize(value->unit);
        if (value->unit != nullptr) AudioComponentInstanceDispose(value->unit);
        delete value;
        return status;
    }
    *output = value;
    return noErr;
}

OSStatus EAUSyntheticToneOutputStart(EAUSyntheticToneOutput *output) {
    if (output == nullptr) return kAudio_ParamError;
    if (output->started.load(std::memory_order_acquire)) return noErr;
    const OSStatus status = AudioOutputUnitStart(output->unit);
    if (status == noErr) output->started.store(true, std::memory_order_release);
    return status;
}

OSStatus EAUSyntheticToneOutputStop(EAUSyntheticToneOutput *output) {
    if (output == nullptr) return kAudio_ParamError;
    if (!output->started.load(std::memory_order_acquire)) return noErr;
    const OSStatus status = AudioOutputUnitStop(output->unit);
    if (status == noErr) output->started.store(false, std::memory_order_release);
    return status;
}

bool EAUSyntheticToneOutputIsQuiescent(const EAUSyntheticToneOutput *output) {
    return output == nullptr || output->inFlight.load(std::memory_order_acquire) == 0;
}

OSStatus EAUSyntheticToneOutputReset(EAUSyntheticToneOutput *output) {
    if (output == nullptr || output->started.load(std::memory_order_acquire) ||
        !EAUSyntheticToneOutputIsQuiescent(output)) {
        return kAudioHardwareIllegalOperationError;
    }
    output->nextFrame.store(0, std::memory_order_release);
    output->callbackCount.store(0, std::memory_order_relaxed);
    output->renderedFrames.store(0, std::memory_order_relaxed);
    output->nonZeroSampleCount.store(0, std::memory_order_relaxed);
    output->lastHostTime.store(0, std::memory_order_relaxed);
    output->silenceBlocks.store(0, std::memory_order_relaxed);
    output->nonSilenceBlocks.store(0, std::memory_order_relaxed);
    output->maxObservedFrames.store(0, std::memory_order_relaxed);
    output->faultFlags.store(EAUAudioIOFaultNone, std::memory_order_relaxed);
    return noErr;
}

EAUSyntheticToneSnapshot EAUSyntheticToneOutputGetSnapshot(
    const EAUSyntheticToneOutput *output
) {
    if (output == nullptr) return {};
    return {
        output->callbackCount.load(std::memory_order_relaxed),
        output->renderedFrames.load(std::memory_order_relaxed),
        output->nonZeroSampleCount.load(std::memory_order_relaxed),
        output->lastHostTime.load(std::memory_order_relaxed),
        output->maxObservedFrames.load(std::memory_order_relaxed),
        output->faultFlags.load(std::memory_order_relaxed),
        output->inFlight.load(std::memory_order_acquire),
        output->silenceBlocks.load(std::memory_order_relaxed),
        output->nonSilenceBlocks.load(std::memory_order_relaxed),
        output->nextFrame.load(std::memory_order_acquire) >= output->durationFrames,
    };
}

OSStatus EAUSyntheticToneOutputGetDiagnostics(
    EAUSyntheticToneOutput *output,
    EAUAudioOutputUnitDiagnostics *diagnostics
) {
    return output == nullptr
        ? kAudio_ParamError
        : readOutputUnitDiagnostics(output->unit, output->componentSubType, diagnostics);
}

OSStatus EAUSyntheticToneOutputRender(
    EAUSyntheticToneOutput *output,
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    UInt32 frameCount,
    AudioBufferList *outputData
) {
    const AudioUnitRenderActionFlags silenceFlag = kAudioUnitRenderAction_OutputIsSilence;
    if (output == nullptr || outputData == nullptr) {
        if (actionFlags != nullptr) *actionFlags |= silenceFlag;
        return noErr;
    }
    AtomicCallbackScope scope(output->inFlight);
    output->callbackCount.fetch_add(1, std::memory_order_relaxed);
    output->lastHostTime.store(validHostTime(timestamp), std::memory_order_relaxed);
    zeroOutputs(outputData);
    if (outputData->mNumberBuffers != 1 || frameCount == 0 ||
        frameCount > output->maximumFrames) {
        output->faultFlags.fetch_or(
            frameCount > output->maximumFrames ? EAUAudioIOFaultFrameCapacityExceeded
                                               : EAUAudioIOFaultLayoutMismatch,
            std::memory_order_relaxed);
        output->silenceBlocks.fetch_add(1, std::memory_order_relaxed);
        if (actionFlags != nullptr) *actionFlags |= silenceFlag;
        return noErr;
    }
    AudioBuffer &buffer = outputData->mBuffers[0];
    const uint64_t requiredBytes = static_cast<uint64_t>(frameCount) *
                                   output->channelCount * sizeof(float);
    if (buffer.mData == nullptr || buffer.mNumberChannels != output->channelCount ||
        requiredBytes > buffer.mDataByteSize) {
        output->faultFlags.fetch_or(
            buffer.mData == nullptr ? EAUAudioIOFaultMissingBuffer
                                    : EAUAudioIOFaultLayoutMismatch,
            std::memory_order_relaxed);
        output->silenceBlocks.fetch_add(1, std::memory_order_relaxed);
        if (actionFlags != nullptr) *actionFlags |= silenceFlag;
        return noErr;
    }

    const uint64_t start = output->nextFrame.load(std::memory_order_relaxed);
    const uint32_t available = start < output->durationFrames
        ? static_cast<uint32_t>(output->durationFrames - start)
        : 0;
    const uint32_t copiedFrames = std::min(frameCount, available);
    uint64_t nonZero = 0;
    if (copiedFrames > 0) {
        const size_t sourceBase = static_cast<size_t>(start) * output->channelCount;
        const size_t sampleCount = static_cast<size_t>(copiedFrames) * output->channelCount;
        float *destination = static_cast<float *>(buffer.mData);
        std::memcpy(destination, &output->samples[sourceBase], sampleCount * sizeof(float));
        for (size_t index = 0; index < sampleCount; ++index) {
            if (destination[index] != 0.0f) ++nonZero;
        }
        output->nextFrame.store(start + copiedFrames, std::memory_order_release);
        output->renderedFrames.fetch_add(copiedFrames, std::memory_order_relaxed);
        output->nonZeroSampleCount.fetch_add(nonZero, std::memory_order_relaxed);
    }
    updateMaximum(output->maxObservedFrames, frameCount);
    if (nonZero == 0) {
        output->silenceBlocks.fetch_add(1, std::memory_order_relaxed);
        if (actionFlags != nullptr) *actionFlags |= silenceFlag;
    } else {
        output->nonSilenceBlocks.fetch_add(1, std::memory_order_relaxed);
        if (actionFlags != nullptr) *actionFlags &= ~silenceFlag;
    }
    return noErr;
}

OSStatus EAUSyntheticToneOutputDestroy(EAUSyntheticToneOutput *output) {
    if (output == nullptr) return noErr;
    if (output->started.load(std::memory_order_acquire) ||
        output->inFlight.load(std::memory_order_acquire) != 0) {
        return kAudioHardwareIllegalOperationError;
    }
    if (output->initialized) {
        const OSStatus uninitializeStatus = AudioUnitUninitialize(output->unit);
        if (uninitializeStatus != noErr) return uninitializeStatus;
        output->initialized = false;
    }
    const OSStatus status = AudioComponentInstanceDispose(output->unit);
    if (status == noErr) delete output;
    return status;
}

OSStatus EAUTapDrainRegistrationCreate(
    AudioObjectID device,
    UInt32 expectedChannelCount,
    UInt32 maximumFrames,
    UInt32 signalCaptureFrameCapacity,
    EAUTapDrainRegistration **registration
) {
    if (device == kAudioObjectUnknown || expectedChannelCount == 0 || maximumFrames == 0 ||
        signalCaptureFrameCapacity == 0 || registration == nullptr ||
        static_cast<uint64_t>(signalCaptureFrameCapacity) * expectedChannelCount >
            std::numeric_limits<uint32_t>::max()) return kAudio_ParamError;
    auto *value = new (std::nothrow) EAUTapDrainRegistration;
    if (value == nullptr) return kAudioHardwareUnspecifiedError;
    value->device = device;
    value->ioProcID = nullptr;
    value->expectedChannelCount = expectedChannelCount;
    value->maximumFrames = maximumFrames;
    value->signalCaptureFrameCapacity = signalCaptureFrameCapacity;
    try {
        value->signalCaptureSamples.resize(
            static_cast<size_t>(signalCaptureFrameCapacity) * expectedChannelCount);
    } catch (...) {
        delete value;
        return kAudioHardwareUnspecifiedError;
    }
    const OSStatus status = AudioDeviceCreateIOProcID(
        device, tapDrainIOProc, value, &value->ioProcID);
    if (status != noErr) {
        delete value;
        return status;
    }
    *registration = value;
    return noErr;
}

OSStatus EAUTapDrainRegistrationStart(EAUTapDrainRegistration *registration) {
    if (registration == nullptr) return kAudio_ParamError;
    if (registration->started.load(std::memory_order_acquire)) return noErr;
    const OSStatus status = AudioDeviceStart(registration->device, registration->ioProcID);
    if (status == noErr) registration->started.store(true, std::memory_order_release);
    return status;
}

OSStatus EAUTapDrainRegistrationStop(EAUTapDrainRegistration *registration) {
    if (registration == nullptr) return kAudio_ParamError;
    if (!registration->started.load(std::memory_order_acquire)) return noErr;
    const OSStatus status = AudioDeviceStop(registration->device, registration->ioProcID);
    if (status == noErr) registration->started.store(false, std::memory_order_release);
    return status;
}

bool EAUTapDrainRegistrationIsQuiescent(const EAUTapDrainRegistration *registration) {
    return registration == nullptr ||
           registration->inFlight.load(std::memory_order_acquire) == 0;
}

EAUTapDrainSnapshot EAUTapDrainRegistrationGetSnapshot(
    const EAUTapDrainRegistration *registration
) {
    if (registration == nullptr) return {};
    return {
        registration->callbackCount.load(std::memory_order_relaxed),
        registration->capturedFrames.load(std::memory_order_relaxed),
        registration->nonZeroSampleCount.load(std::memory_order_relaxed),
        registration->lastHostTime.load(std::memory_order_relaxed),
        registration->maxObservedFrames.load(std::memory_order_relaxed),
        registration->faultFlags.load(std::memory_order_relaxed),
        registration->inFlight.load(std::memory_order_acquire),
    };
}

OSStatus EAUTapDrainRegistrationBeginSignalCapture(EAUTapDrainRegistration *registration) {
    if (registration == nullptr) return kAudio_ParamError;
    if (!registration->started.load(std::memory_order_acquire) ||
        registration->signalCaptureState.load(std::memory_order_acquire) != 0) {
        return kAudioHardwareIllegalOperationError;
    }
    registration->signalCaptureFirstHostTime.store(0, std::memory_order_relaxed);
    registration->signalCaptureReservedFrames.store(0, std::memory_order_relaxed);
    registration->signalCaptureDroppedFrames.store(0, std::memory_order_relaxed);
    registration->signalCaptureSequence.fetch_add(1, std::memory_order_relaxed);
    uint64_t expectedState = 0;
    if (!registration->signalCaptureState.compare_exchange_strong(
            expectedState, kTapSignalCaptureEnabled,
            std::memory_order_release, std::memory_order_acquire)) {
        return kAudioHardwareIllegalOperationError;
    }
    return noErr;
}

OSStatus EAUTapDrainRegistrationEndSignalCapture(EAUTapDrainRegistration *registration) {
    if (registration == nullptr) return kAudio_ParamError;
    const uint64_t previous = registration->signalCaptureState.fetch_and(
        kTapSignalCaptureWriterMask, std::memory_order_acq_rel);
    if ((previous & kTapSignalCaptureEnabled) == 0) {
        return kAudioHardwareIllegalOperationError;
    }
    return noErr;
}

bool EAUTapDrainRegistrationSignalCaptureIsQuiescent(
    const EAUTapDrainRegistration *registration
) {
    return registration == nullptr ||
           registration->signalCaptureState.load(std::memory_order_acquire) == 0;
}

EAUTapDrainSignalCaptureMetadata EAUTapDrainRegistrationGetSignalCaptureMetadata(
    const EAUTapDrainRegistration *registration
) {
    if (registration == nullptr ||
        !EAUTapDrainRegistrationSignalCaptureIsQuiescent(registration)) return {};
    const uint64_t reserved = registration->signalCaptureReservedFrames.load(
        std::memory_order_acquire);
    return {
        registration->signalCaptureSequence.load(std::memory_order_relaxed),
        registration->signalCaptureFirstHostTime.load(std::memory_order_relaxed),
        registration->signalCaptureDroppedFrames.load(std::memory_order_relaxed),
        static_cast<uint32_t>(std::min<uint64_t>(
            reserved, registration->signalCaptureFrameCapacity)),
        registration->expectedChannelCount,
    };
}

uint32_t EAUTapDrainRegistrationCopySignalCapture(
    const EAUTapDrainRegistration *registration,
    float *samples,
    uint32_t sampleCapacity
) {
    const EAUTapDrainSignalCaptureMetadata metadata =
        EAUTapDrainRegistrationGetSignalCaptureMetadata(registration);
    const uint64_t sampleCount64 = static_cast<uint64_t>(metadata.frameCount) *
                                   metadata.channelCount;
    if (registration == nullptr || samples == nullptr || sampleCount64 == 0 ||
        sampleCount64 > sampleCapacity || sampleCount64 > std::numeric_limits<uint32_t>::max()) {
        return 0;
    }
    const uint32_t sampleCount = static_cast<uint32_t>(sampleCount64);
    std::memcpy(
        samples, registration->signalCaptureSamples.data(),
        static_cast<size_t>(sampleCount) * sizeof(float));
    return sampleCount;
}

OSStatus EAUTapDrainRegistrationDestroy(EAUTapDrainRegistration *registration) {
    if (registration == nullptr) return noErr;
    if (registration->started.load(std::memory_order_acquire) ||
        registration->inFlight.load(std::memory_order_acquire) != 0 ||
        registration->signalCaptureState.load(std::memory_order_acquire) != 0) {
        return kAudioHardwareIllegalOperationError;
    }
    const OSStatus status = AudioDeviceDestroyIOProcID(
        registration->device, registration->ioProcID);
    if (status == noErr) delete registration;
    return status;
}
