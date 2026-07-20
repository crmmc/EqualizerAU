#include "EAUM1AudioIOHost.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>
#include <stdexcept>
#include <vector>

namespace {

struct CallbackScope {
    explicit CallbackScope(std::atomic<uint64_t> &count) : count(count) {
        count.fetch_add(1, std::memory_order_seq_cst);
    }
    ~CallbackScope() { count.fetch_sub(1, std::memory_order_seq_cst); }
    std::atomic<uint64_t> &count;
};

struct RenderOwnership {
    explicit RenderOwnership(std::atomic<bool> &busy) : busy(busy) {
        bool expected = false;
        acquired = busy.compare_exchange_strong(
            expected,
            true,
            std::memory_order_seq_cst,
            std::memory_order_seq_cst
        );
    }
    ~RenderOwnership() {
        if (acquired) {
            busy.store(false, std::memory_order_seq_cst);
        }
    }
    std::atomic<bool> &busy;
    bool acquired = false;
};

bool checkedSampleCount(uint32_t frames, uint32_t channels, size_t &result) {
    const uint64_t count = static_cast<uint64_t>(frames) * channels;
    if (count > std::numeric_limits<size_t>::max()) {
        return false;
    }
    result = static_cast<size_t>(count);
    return true;
}

} // namespace

struct EAUM1AudioIOHost {
    EAUM1Runtime *runtime;
    std::vector<uint32_t> inputChannelCounts;
    uint32_t channelCount;
    uint32_t maximumFrameCount;
    uint32_t ringCapacityFrames;
    uint32_t primeFrames;
    uint32_t targetBacklogFrames;
    std::vector<float> ring;
    std::vector<float> renderScratch;
    std::atomic<uint64_t> writeFrame{0};
    std::atomic<uint64_t> readFrame{0};
    std::atomic<uint64_t> callbacksInFlight{0};
    std::atomic<bool> stopping{false};
    std::atomic<bool> priming{true};
    std::atomic<bool> renderBusy{false};
    std::atomic<uint64_t> fadeState{0};
    std::atomic<uint64_t> capturedFrameCount{0};
    std::atomic<uint64_t> renderedFrameCount{0};
    std::atomic<uint64_t> overflowedBlockCount{0};
    std::atomic<uint64_t> underrunBlockCount{0};
    std::atomic<uint64_t> droppedBacklogFrameCount{0};
    std::atomic<uint64_t> invalidCallbackCount{0};
    std::atomic<uint64_t> overlappingRenderCallbackCount{0};
};

struct EAUM1CaptureRegistration {
    AudioObjectID device;
    AudioDeviceIOProcID ioProc;
    EAUM1AudioIOHost *host;
    bool started;
};

struct EAUM1OutputRegistration {
    AudioUnit unit;
    EAUM1AudioIOHost *host;
    bool initialized;
    bool started;
};

namespace {

bool validateABL(
    const AudioBufferList *data,
    const std::vector<uint32_t> &channelCounts,
    uint32_t frames
) {
    if (data == nullptr || data->mNumberBuffers != channelCounts.size()) {
        return false;
    }
    for (uint32_t index = 0; index < data->mNumberBuffers; ++index) {
        const AudioBuffer &buffer = data->mBuffers[index];
        if (buffer.mNumberChannels != channelCounts[index] || buffer.mData == nullptr) {
            return false;
        }
        size_t samples = 0;
        if (!checkedSampleCount(frames, buffer.mNumberChannels, samples)
            || samples > std::numeric_limits<uint32_t>::max() / sizeof(float)
            || buffer.mDataByteSize != samples * sizeof(float)) {
            return false;
        }
    }
    return true;
}

bool validateInterleavedOutput(
    const AudioBufferList *data,
    uint32_t channels,
    uint32_t frames
) {
    if (data == nullptr || data->mNumberBuffers != 1) {
        return false;
    }
    const AudioBuffer &buffer = data->mBuffers[0];
    size_t samples = 0;
    return buffer.mNumberChannels == channels
        && buffer.mData != nullptr
        && checkedSampleCount(frames, channels, samples)
        && samples <= std::numeric_limits<uint32_t>::max() / sizeof(float)
        && buffer.mDataByteSize >= samples * sizeof(float);
}

void clearOutput(AudioBufferList *output, uint32_t channels, uint32_t frames) {
    if (!validateInterleavedOutput(output, channels, frames)) {
        return;
    }
    size_t samples = 0;
    checkedSampleCount(frames, channels, samples);
    std::memset(output->mBuffers[0].mData, 0, samples * sizeof(float));
}

void setSilenceFlag(AudioUnitRenderActionFlags *flags, bool silent) {
    if (flags == nullptr) {
        return;
    }
    if (silent) {
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
    } else {
        *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
    }
}

uint64_t availableFrames(EAUM1AudioIOHost *host) {
    const uint64_t write = host->writeFrame.load(std::memory_order_acquire);
    const uint64_t read = host->readFrame.load(std::memory_order_acquire);
    return write - read;
}

OSStatus captureCallback(
    AudioObjectID,
    const AudioTimeStamp *,
    const AudioBufferList *inputData,
    const AudioTimeStamp *,
    AudioBufferList *,
    const AudioTimeStamp *,
    void *context
) {
    EAUM1AudioIOHost *host = static_cast<EAUM1AudioIOHost *>(context);
    if (host == nullptr || inputData == nullptr || inputData->mNumberBuffers == 0) {
        return kAudio_ParamError;
    }
    const AudioBuffer &first = inputData->mBuffers[0];
    if (first.mNumberChannels == 0) {
        return kAudio_ParamError;
    }
    const uint32_t frames = first.mDataByteSize / (first.mNumberChannels * sizeof(float));
    const EAUM1Status status = EAUM1AudioIOHostCapture(host, inputData, frames);
    return status == EAUM1StatusOK || status == EAUM1StatusCapacityExceeded
        ? static_cast<OSStatus>(noErr)
        : static_cast<OSStatus>(kAudio_ParamError);
}

OSStatus renderCallback(
    void *context,
    AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *,
    UInt32,
    UInt32 frameCount,
    AudioBufferList *outputData
) {
    const EAUM1Status status = EAUM1AudioIOHostRender(
        static_cast<EAUM1AudioIOHost *>(context),
        flags,
        outputData,
        frameCount
    );
    return status == EAUM1StatusOK || status == EAUM1StatusCallbackOverlap
        ? static_cast<OSStatus>(noErr)
        : static_cast<OSStatus>(kAudio_ParamError);
}

} // namespace

EAUM1Status EAUM1AudioIOHostCreate(
    const EAUM1AudioIOHostDescription *description,
    EAUM1AudioIOHost **hostOut
) {
    if (description == nullptr || hostOut == nullptr || *hostOut != nullptr
        || description->runtime == nullptr || description->inputBufferCount == 0
        || description->inputChannelCounts == nullptr || description->channelCount == 0
        || description->maximumFrameCount == 0
        || description->ringCapacityFrames < description->maximumFrameCount
        || description->primeFrames > description->ringCapacityFrames
        || description->targetBacklogFrames < description->maximumFrameCount
        || description->targetBacklogFrames > description->ringCapacityFrames) {
        return EAUM1StatusInvalidArgument;
    }
    uint64_t inputChannels = 0;
    for (uint32_t index = 0; index < description->inputBufferCount; ++index) {
        if (description->inputChannelCounts[index] == 0) {
            return EAUM1StatusInvalidArgument;
        }
        inputChannels += description->inputChannelCounts[index];
    }
    if (inputChannels != description->channelCount) {
        return EAUM1StatusTopologyMismatch;
    }
    size_t ringSamples = 0;
    size_t scratchSamples = 0;
    if (!checkedSampleCount(description->ringCapacityFrames, description->channelCount, ringSamples)
        || !checkedSampleCount(description->maximumFrameCount, description->channelCount, scratchSamples)) {
        return EAUM1StatusCapacityExceeded;
    }

    try {
        auto *host = new EAUM1AudioIOHost{
            description->runtime,
            std::vector<uint32_t>(
                description->inputChannelCounts,
                description->inputChannelCounts + description->inputBufferCount
            ),
            description->channelCount,
            description->maximumFrameCount,
            description->ringCapacityFrames,
            description->primeFrames,
            description->targetBacklogFrames,
            std::vector<float>(ringSamples),
            std::vector<float>(scratchSamples),
        };
        *hostOut = host;
        return EAUM1StatusOK;
    } catch (const std::bad_alloc &) {
        return EAUM1StatusOutOfMemory;
    } catch (const std::length_error &) {
        return EAUM1StatusCapacityExceeded;
    } catch (...) {
        return EAUM1StatusUnsupported;
    }
}

void EAUM1AudioIOHostBeginStopping(EAUM1AudioIOHost *host) {
    if (host != nullptr) {
        host->stopping.store(true, std::memory_order_seq_cst);
    }
}

void EAUM1AudioIOHostRequestFadeOut(EAUM1AudioIOHost *host, uint32_t frameCount) {
    if (host != nullptr) {
        const uint64_t state = (static_cast<uint64_t>(frameCount) << 32) | frameCount;
        host->fadeState.store(state, std::memory_order_seq_cst);
    }
}

uint8_t EAUM1AudioIOHostIsFadeComplete(const EAUM1AudioIOHost *host) {
    return host != nullptr
        && static_cast<uint32_t>(host->fadeState.load(std::memory_order_seq_cst)) == 0;
}

uint8_t EAUM1AudioIOHostIsQuiescent(const EAUM1AudioIOHost *host) {
    return host != nullptr && host->callbacksInFlight.load(std::memory_order_seq_cst) == 0;
}

void EAUM1AudioIOHostDestroy(EAUM1AudioIOHost *host) {
    delete host;
}

EAUM1Status EAUM1AudioIOHostCapture(
    EAUM1AudioIOHost *host,
    const AudioBufferList *inputData,
    uint32_t frameCount
) {
    if (host == nullptr) {
        return EAUM1StatusInvalidArgument;
    }
    CallbackScope scope(host->callbacksInFlight);
    if (host->stopping.load(std::memory_order_seq_cst)) {
        return EAUM1StatusOK;
    }
    if (frameCount == 0 || frameCount > host->maximumFrameCount
        || !validateABL(inputData, host->inputChannelCounts, frameCount)) {
        host->invalidCallbackCount.fetch_add(1, std::memory_order_relaxed);
        return EAUM1StatusInvalidArgument;
    }
    const uint64_t available = availableFrames(host);
    if (frameCount > host->ringCapacityFrames - std::min<uint64_t>(available, host->ringCapacityFrames)) {
        host->overflowedBlockCount.fetch_add(1, std::memory_order_relaxed);
        return EAUM1StatusCapacityExceeded;
    }

    const uint64_t write = host->writeFrame.load(std::memory_order_relaxed);
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        uint32_t linearChannel = 0;
        const uint32_t ringFrame = static_cast<uint32_t>((write + frame) % host->ringCapacityFrames);
        for (uint32_t bufferIndex = 0; bufferIndex < inputData->mNumberBuffers; ++bufferIndex) {
            const AudioBuffer &buffer = inputData->mBuffers[bufferIndex];
            const float *samples = static_cast<const float *>(buffer.mData);
            for (uint32_t channel = 0; channel < buffer.mNumberChannels; ++channel) {
                host->ring[static_cast<size_t>(ringFrame) * host->channelCount + linearChannel] =
                    samples[static_cast<size_t>(frame) * buffer.mNumberChannels + channel];
                ++linearChannel;
            }
        }
    }
    host->writeFrame.store(write + frameCount, std::memory_order_release);
    host->capturedFrameCount.fetch_add(frameCount, std::memory_order_relaxed);
    return EAUM1StatusOK;
}

EAUM1Status EAUM1AudioIOHostRender(
    EAUM1AudioIOHost *host,
    AudioUnitRenderActionFlags *actionFlags,
    AudioBufferList *outputData,
    uint32_t frameCount
) {
    if (host == nullptr) {
        return EAUM1StatusInvalidArgument;
    }
    CallbackScope scope(host->callbacksInFlight);
    RenderOwnership ownership(host->renderBusy);
    if (!ownership.acquired) {
        host->overlappingRenderCallbackCount.fetch_add(1, std::memory_order_relaxed);
        if (validateInterleavedOutput(outputData, host->channelCount, frameCount)) {
            clearOutput(outputData, host->channelCount, frameCount);
        }
        setSilenceFlag(actionFlags, true);
        return EAUM1StatusCallbackOverlap;
    }
    if (frameCount == 0 || frameCount > host->maximumFrameCount
        || !validateInterleavedOutput(outputData, host->channelCount, frameCount)) {
        host->invalidCallbackCount.fetch_add(1, std::memory_order_relaxed);
        setSilenceFlag(actionFlags, true);
        return EAUM1StatusInvalidArgument;
    }
    if (host->stopping.load(std::memory_order_seq_cst)) {
        clearOutput(outputData, host->channelCount, frameCount);
        setSilenceFlag(actionFlags, true);
        return EAUM1StatusOK;
    }

    uint64_t available = availableFrames(host);
    if (host->priming.load(std::memory_order_acquire)) {
        if (available < host->primeFrames) {
            clearOutput(outputData, host->channelCount, frameCount);
            setSilenceFlag(actionFlags, true);
            return EAUM1StatusOK;
        }
        host->priming.store(false, std::memory_order_release);
    }
    if (available < frameCount) {
        host->readFrame.fetch_add(available, std::memory_order_release);
        host->priming.store(true, std::memory_order_release);
        host->underrunBlockCount.fetch_add(1, std::memory_order_relaxed);
        clearOutput(outputData, host->channelCount, frameCount);
        setSilenceFlag(actionFlags, true);
        return EAUM1StatusOK;
    }
    if (available > static_cast<uint64_t>(host->targetBacklogFrames) + frameCount) {
        const uint64_t drop = available - host->targetBacklogFrames;
        host->readFrame.fetch_add(drop, std::memory_order_release);
        host->droppedBacklogFrameCount.fetch_add(drop, std::memory_order_relaxed);
        available -= drop;
    }

    const uint64_t read = host->readFrame.load(std::memory_order_relaxed);
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        const uint32_t ringFrame = static_cast<uint32_t>((read + frame) % host->ringCapacityFrames);
        std::memcpy(
            &host->renderScratch[static_cast<size_t>(frame) * host->channelCount],
            &host->ring[static_cast<size_t>(ringFrame) * host->channelCount],
            host->channelCount * sizeof(float)
        );
    }
    host->readFrame.store(read + frameCount, std::memory_order_release);

    EAUM1AudioBuffer runtimeBuffer{host->renderScratch.data(), host->channelCount};
    const EAUM1Status processStatus = EAUM1RuntimeProcess(host->runtime, &runtimeBuffer, 1, frameCount);
    float *destination = static_cast<float *>(outputData->mBuffers[0].mData);
    bool silent = true;
    const uint64_t loadedFadeState = host->fadeState.load(std::memory_order_seq_cst);
    const uint32_t fadeTotal = static_cast<uint32_t>(loadedFadeState >> 32);
    uint32_t fadeRemaining = static_cast<uint32_t>(loadedFadeState);
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        float fade = 1.0f;
        if (fadeTotal > 0) {
            if (fadeRemaining > 0) {
                fade = static_cast<float>(fadeRemaining - 1) / fadeTotal;
                --fadeRemaining;
            } else {
                fade = 0.0f;
            }
        }
        for (uint32_t channel = 0; channel < host->channelCount; ++channel) {
            const size_t index = static_cast<size_t>(frame) * host->channelCount + channel;
            const float value = host->renderScratch[index] * fade;
            destination[index] = value;
            silent = silent && value == 0.0f;
        }
    }
    uint64_t expectedFadeState = loadedFadeState;
    const uint64_t updatedFadeState = (static_cast<uint64_t>(fadeTotal) << 32) | fadeRemaining;
    host->fadeState.compare_exchange_strong(
        expectedFadeState,
        updatedFadeState,
        std::memory_order_seq_cst,
        std::memory_order_seq_cst
    );
    host->renderedFrameCount.fetch_add(frameCount, std::memory_order_relaxed);
    setSilenceFlag(actionFlags, silent);
    return processStatus;
}

EAUM1Status EAUM1AudioIOHostCopyDiagnostics(
    const EAUM1AudioIOHost *host,
    EAUM1AudioIOHostDiagnostics *diagnosticsOut
) {
    if (host == nullptr || diagnosticsOut == nullptr) {
        return EAUM1StatusInvalidArgument;
    }
    *diagnosticsOut = EAUM1AudioIOHostDiagnostics{
        host->capturedFrameCount.load(std::memory_order_relaxed),
        host->renderedFrameCount.load(std::memory_order_relaxed),
        host->overflowedBlockCount.load(std::memory_order_relaxed),
        host->underrunBlockCount.load(std::memory_order_relaxed),
        host->droppedBacklogFrameCount.load(std::memory_order_relaxed),
        host->invalidCallbackCount.load(std::memory_order_relaxed),
        host->overlappingRenderCallbackCount.load(std::memory_order_relaxed),
    };
    return EAUM1StatusOK;
}

OSStatus EAUM1CaptureRegistrationCreate(
    AudioObjectID aggregateDevice,
    EAUM1AudioIOHost *host,
    EAUM1CaptureRegistration **registrationOut
) {
    if (aggregateDevice == kAudioObjectUnknown || host == nullptr || registrationOut == nullptr
        || *registrationOut != nullptr) {
        return kAudio_ParamError;
    }
    auto *registration = new (std::nothrow) EAUM1CaptureRegistration{
        aggregateDevice, nullptr, host, false,
    };
    if (registration == nullptr) {
        return memFullErr;
    }
    const OSStatus status = AudioDeviceCreateIOProcID(
        aggregateDevice,
        captureCallback,
        host,
        &registration->ioProc
    );
    if (status != noErr) {
        delete registration;
        return status;
    }
    *registrationOut = registration;
    return noErr;
}

OSStatus EAUM1CaptureRegistrationStart(EAUM1CaptureRegistration *registration) {
    if (registration == nullptr) { return kAudio_ParamError; }
    if (registration->started) { return noErr; }
    const OSStatus status = AudioDeviceStart(registration->device, registration->ioProc);
    if (status == noErr) { registration->started = true; }
    return status;
}

OSStatus EAUM1CaptureRegistrationStop(EAUM1CaptureRegistration *registration) {
    if (registration == nullptr) { return kAudio_ParamError; }
    if (!registration->started) { return noErr; }
    const OSStatus status = AudioDeviceStop(registration->device, registration->ioProc);
    if (status == noErr) { registration->started = false; }
    return status;
}

OSStatus EAUM1CaptureRegistrationDestroy(EAUM1CaptureRegistration *registration) {
    if (registration == nullptr || registration->started) { return kAudio_ParamError; }
    const OSStatus status = AudioDeviceDestroyIOProcID(registration->device, registration->ioProc);
    if (status == noErr) { delete registration; }
    return status;
}

OSStatus EAUM1OutputRegistrationCreate(
    AudioObjectID outputDevice,
    double sampleRate,
    uint32_t channelCount,
    uint32_t maximumFrameCount,
    EAUM1AudioIOHost *host,
    EAUM1OutputRegistration **registrationOut
) {
    if (outputDevice == kAudioObjectUnknown || !std::isfinite(sampleRate) || sampleRate <= 0
        || channelCount == 0 || maximumFrameCount == 0 || host == nullptr
        || registrationOut == nullptr || *registrationOut != nullptr) {
        return kAudio_ParamError;
    }
    AudioComponentDescription componentDescription{
        kAudioUnitType_Output,
        kAudioUnitSubType_DefaultOutput,
        kAudioUnitManufacturer_Apple,
        0,
        0,
    };
    AudioComponent component = AudioComponentFindNext(nullptr, &componentDescription);
    if (component == nullptr) { return kAudioUnitErr_InvalidElement; }
    auto *registration = new (std::nothrow) EAUM1OutputRegistration{
        nullptr,
        host,
        false,
        false,
    };
    if (registration == nullptr) { return memFullErr; }
    OSStatus status = AudioComponentInstanceNew(component, &registration->unit);
    if (status != noErr) {
        delete registration;
        return status;
    }
    AudioUnit unit = registration->unit;

    status = AudioUnitSetProperty(
        unit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &outputDevice,
        sizeof(outputDevice)
    );
    AudioStreamBasicDescription format{
        sampleRate,
        kAudioFormatLinearPCM,
        kAudioFormatFlagsNativeFloatPacked,
        static_cast<UInt32>(channelCount * sizeof(float)),
        1,
        static_cast<UInt32>(channelCount * sizeof(float)),
        channelCount,
        32,
        0,
    };
    if (status == noErr) {
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            sizeof(format)
        );
    }
    if (status == noErr) {
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFrameCount,
            sizeof(maximumFrameCount)
        );
    }
    AURenderCallbackStruct callback{renderCallback, host};
    if (status == noErr) {
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            sizeof(callback)
        );
    }
    if (status == noErr) {
        status = AudioUnitInitialize(unit);
        registration->initialized = status == noErr;
    }
    if (status != noErr) {
        *registrationOut = registration;
        return status;
    }
    *registrationOut = registration;
    return noErr;
}

OSStatus EAUM1OutputRegistrationStart(EAUM1OutputRegistration *registration) {
    if (registration == nullptr || !registration->initialized) { return kAudio_ParamError; }
    if (registration->started) { return noErr; }
    const OSStatus status = AudioOutputUnitStart(registration->unit);
    if (status == noErr) { registration->started = true; }
    return status;
}

OSStatus EAUM1OutputRegistrationStop(EAUM1OutputRegistration *registration) {
    if (registration == nullptr) { return kAudio_ParamError; }
    if (!registration->started) { return noErr; }
    const OSStatus status = AudioOutputUnitStop(registration->unit);
    if (status == noErr) { registration->started = false; }
    return status;
}

OSStatus EAUM1OutputRegistrationCopyDiagnostics(
    EAUM1OutputRegistration *registration,
    EAUM1OutputDiagnostics *diagnosticsOut
) {
    if (registration == nullptr || diagnosticsOut == nullptr) { return kAudio_ParamError; }
    EAUM1OutputDiagnostics value{};
    UInt32 size = sizeof(value.currentDevice);
    OSStatus status = AudioUnitGetProperty(
        registration->unit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &value.currentDevice,
        &size
    );
    size = sizeof(value.deviceFormat);
    if (status == noErr) {
        status = AudioUnitGetProperty(
            registration->unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            0,
            &value.deviceFormat,
            &size
        );
    }
    size = sizeof(value.clientFormat);
    if (status == noErr) {
        status = AudioUnitGetProperty(
            registration->unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &value.clientFormat,
            &size
        );
    }
    size = sizeof(value.maximumFrames);
    if (status == noErr) {
        status = AudioUnitGetProperty(
            registration->unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &value.maximumFrames,
            &size
        );
    }
    UInt32 running = 0;
    size = sizeof(running);
    if (status == noErr) {
        status = AudioUnitGetProperty(
            registration->unit,
            kAudioOutputUnitProperty_IsRunning,
            kAudioUnitScope_Global,
            0,
            &running,
            &size
        );
    }
    value.isRunning = running != 0;
    if (status == noErr) { *diagnosticsOut = value; }
    return status;
}

OSStatus EAUM1OutputRegistrationDestroy(EAUM1OutputRegistration *registration) {
    if (registration == nullptr || registration->started) { return kAudio_ParamError; }
    OSStatus status = noErr;
    if (registration->initialized) {
        status = AudioUnitUninitialize(registration->unit);
        if (status == noErr) { registration->initialized = false; }
    }
    if (status == noErr) {
        status = AudioComponentInstanceDispose(registration->unit);
    }
    if (status == noErr) { delete registration; }
    return status;
}

namespace EAUM1AudioIOHostTestHooks {

bool acquireRender(EAUM1AudioIOHost *host) {
    if (host == nullptr) { return false; }
    bool expected = false;
    return host->renderBusy.compare_exchange_strong(
        expected,
        true,
        std::memory_order_seq_cst,
        std::memory_order_seq_cst
    );
}

void releaseRender(EAUM1AudioIOHost *host) {
    if (host != nullptr) {
        host->renderBusy.store(false, std::memory_order_seq_cst);
    }
}

} // namespace EAUM1AudioIOHostTestHooks
