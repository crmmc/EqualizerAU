#pragma once

#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EAUAudioIOBridge EAUAudioIOBridge;
typedef struct EAUAudioIORegistration EAUAudioIORegistration;
typedef struct EAUAudioOutputUnit EAUAudioOutputUnit;
typedef struct EAUSyntheticToneOutput EAUSyntheticToneOutput;
typedef struct EAUTapDrainRegistration EAUTapDrainRegistration;

typedef struct {
    OSType componentSubType;
    AudioObjectID currentDevice;
    AudioStreamBasicDescription deviceFormat;
    AudioStreamBasicDescription clientFormat;
    UInt32 maximumFrames;
    UInt32 isRunning;
    AudioUnitParameterValue volume;
    OSStatus isRunningStatus;
    OSStatus volumeStatus;
} EAUAudioOutputUnitDiagnostics;

typedef enum {
    EAUAudioIORegistrationCapture = 0,
} EAUAudioIORegistrationKind;

typedef struct {
    uint64_t captureCallbackCount;
    uint64_t outputCallbackCount;
    uint64_t capturedFrames;
    uint64_t renderedFrames;
    uint64_t nonZeroSampleCount;
    uint64_t renderedNonZeroSampleCount;
    uint64_t captureLastHostTime;
    uint64_t outputLastHostTime;
    uint64_t underrunBlocks;
    uint64_t overflowFrames;
    uint64_t droppedFrames;
    uint64_t primingBlocks;
    uint64_t backlogCorrections;
    uint64_t renderActionSilenceInputBlocks;
    uint64_t renderActionSilenceClearedBlocks;
    uint64_t outputSilenceBlocks;
    uint64_t outputNonSilenceBlocks;
    uint32_t ringFillFrames;
    uint32_t maxObservedFrames;
    uint32_t faultFlags;
    uint32_t inFlightCallbacks;
    bool fadeComplete;
} EAUAudioIOBridgeSnapshot;

typedef struct {
    uint64_t callbackCount;
    uint64_t renderedFrames;
    uint64_t nonZeroSampleCount;
    uint64_t lastHostTime;
    uint32_t maxObservedFrames;
    uint32_t faultFlags;
    uint32_t inFlightCallbacks;
    uint64_t silenceBlocks;
    uint64_t nonSilenceBlocks;
    bool completed;
} EAUSyntheticToneSnapshot;

typedef struct {
    uint64_t callbackCount;
    uint64_t capturedFrames;
    uint64_t nonZeroSampleCount;
    uint64_t lastHostTime;
    uint32_t maxObservedFrames;
    uint32_t faultFlags;
    uint32_t inFlightCallbacks;
} EAUTapDrainSnapshot;

typedef struct {
    uint64_t sequence;
    uint64_t firstHostTime;
    uint64_t droppedFrames;
    uint32_t frameCount;
    uint32_t channelCount;
} EAUTapDrainSignalCaptureMetadata;

typedef enum {
    EAUAudioSignalProbeCapture = 0,
    EAUAudioSignalProbePostDSP = 1,
    EAUAudioSignalProbeAppleSubmit = 2,
} EAUAudioSignalProbeStage;

typedef struct {
    EAUAudioSignalProbeStage stage;
    uint64_t sequence;
    uint64_t hostTime;
    uint64_t droppedFrames;
    uint32_t frameCount;
    uint32_t channelCount;
} EAUAudioSignalProbeMetadata;

enum {
    EAUAudioIOFaultNone = 0,
    EAUAudioIOFaultMissingBuffer = 1u << 0,
    EAUAudioIOFaultLayoutMismatch = 1u << 1,
    EAUAudioIOFaultFrameCapacityExceeded = 1u << 2,
};

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
);

bool EAUAudioIOBridgeReset(EAUAudioIOBridge *bridge);
void EAUAudioIOBridgeCancelFadeOut(EAUAudioIOBridge *bridge);
void EAUAudioIOBridgeRequestFadeOut(EAUAudioIOBridge *bridge, uint32_t fadeFrames);
bool EAUAudioIOBridgeIsFadeComplete(const EAUAudioIOBridge *bridge);
void EAUAudioIOBridgeBeginStopping(EAUAudioIOBridge *bridge);
bool EAUAudioIOBridgeIsQuiescent(const EAUAudioIOBridge *bridge);
void EAUAudioIOBridgeDestroy(EAUAudioIOBridge *bridge);
EAUAudioIOBridgeSnapshot EAUAudioIOBridgeGetSnapshot(const EAUAudioIOBridge *bridge);
uint32_t EAUAudioIOBridgeGetSignalProbeFrameCapacity(const EAUAudioIOBridge *bridge);
uint32_t EAUAudioIOBridgeGetSignalProbeChannelCount(const EAUAudioIOBridge *bridge);
uint32_t EAUAudioIOBridgeCopyLatestSignalProbe(
    EAUAudioIOBridge *bridge,
    EAUAudioSignalProbeStage stage,
    float *samples,
    uint32_t sampleCapacity,
    EAUAudioSignalProbeMetadata *metadata
);

uint64_t EAUAudioDSPProcessInterleaved(
    const float *input,
    float *output,
    uint32_t frameCount,
    uint32_t channelCount,
    float outputGain,
    float outputLimit
);

OSStatus EAUAudioIOBridgeCapture(
    EAUAudioIOBridge *bridge,
    const AudioTimeStamp *now,
    const AudioBufferList *inputData
);
OSStatus EAUAudioIOBridgeRender(
    EAUAudioIOBridge *bridge,
    const AudioTimeStamp *now,
    AudioBufferList *outputData
);
OSStatus EAUAudioIOBridgeRenderWithActionFlags(
    EAUAudioIOBridge *bridge,
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *now,
    AudioBufferList *outputData
);
OSStatus EAUAudioIOBridgeRenderFramesWithActionFlags(
    EAUAudioIOBridge *bridge,
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *now,
    UInt32 frameCount,
    AudioBufferList *outputData
);

OSStatus EAUAudioIORegistrationCreate(
    AudioObjectID device,
    EAUAudioIOBridge *bridge,
    EAUAudioIORegistrationKind kind,
    EAUAudioIORegistration **registration
);
OSStatus EAUAudioIORegistrationStart(EAUAudioIORegistration *registration);
OSStatus EAUAudioIORegistrationStop(EAUAudioIORegistration *registration);
OSStatus EAUAudioIORegistrationDestroy(EAUAudioIORegistration *registration);

OSStatus EAUAudioOutputUnitCreate(
    AudioObjectID device,
    EAUAudioIOBridge *bridge,
    Float64 sampleRate,
    UInt32 channelCount,
    UInt32 maximumFrames,
    EAUAudioOutputUnit **outputUnit
);
OSStatus EAUAudioHALOutputUnitCreate(
    AudioObjectID device,
    EAUAudioIOBridge *bridge,
    Float64 sampleRate,
    UInt32 channelCount,
    UInt32 maximumFrames,
    EAUAudioOutputUnit **outputUnit
);
OSStatus EAUAudioOutputUnitStart(EAUAudioOutputUnit *outputUnit);
OSStatus EAUAudioOutputUnitStop(EAUAudioOutputUnit *outputUnit);
OSStatus EAUAudioOutputUnitGetDiagnostics(
    EAUAudioOutputUnit *outputUnit,
    EAUAudioOutputUnitDiagnostics *diagnostics
);
OSStatus EAUAudioOutputUnitDestroy(EAUAudioOutputUnit *outputUnit);
uint64_t EAUAudioOutputUnitGetCreationCount(void);

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
);
OSStatus EAUSyntheticSignalOutputCreate(
    AudioObjectID device,
    Float64 sampleRate,
    UInt32 channelCount,
    UInt32 maximumFrames,
    const float *monoSamples,
    UInt32 durationFrames,
    EAUSyntheticToneOutput **output
);
OSStatus EAUSyntheticToneOutputStart(EAUSyntheticToneOutput *output);
OSStatus EAUSyntheticToneOutputStop(EAUSyntheticToneOutput *output);
bool EAUSyntheticToneOutputIsQuiescent(const EAUSyntheticToneOutput *output);
OSStatus EAUSyntheticToneOutputReset(EAUSyntheticToneOutput *output);
EAUSyntheticToneSnapshot EAUSyntheticToneOutputGetSnapshot(
    const EAUSyntheticToneOutput *output
);
OSStatus EAUSyntheticToneOutputGetDiagnostics(
    EAUSyntheticToneOutput *output,
    EAUAudioOutputUnitDiagnostics *diagnostics
);
OSStatus EAUSyntheticToneOutputRender(
    EAUSyntheticToneOutput *output,
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    UInt32 frameCount,
    AudioBufferList *outputData
);
OSStatus EAUSyntheticToneOutputDestroy(EAUSyntheticToneOutput *output);

OSStatus EAUTapDrainRegistrationCreate(
    AudioObjectID device,
    UInt32 expectedChannelCount,
    UInt32 maximumFrames,
    UInt32 signalCaptureFrameCapacity,
    EAUTapDrainRegistration **registration
);
OSStatus EAUTapDrainRegistrationStart(EAUTapDrainRegistration *registration);
OSStatus EAUTapDrainRegistrationStop(EAUTapDrainRegistration *registration);
bool EAUTapDrainRegistrationIsQuiescent(const EAUTapDrainRegistration *registration);
EAUTapDrainSnapshot EAUTapDrainRegistrationGetSnapshot(
    const EAUTapDrainRegistration *registration
);
OSStatus EAUTapDrainRegistrationBeginSignalCapture(EAUTapDrainRegistration *registration);
OSStatus EAUTapDrainRegistrationEndSignalCapture(EAUTapDrainRegistration *registration);
bool EAUTapDrainRegistrationSignalCaptureIsQuiescent(
    const EAUTapDrainRegistration *registration
);
EAUTapDrainSignalCaptureMetadata EAUTapDrainRegistrationGetSignalCaptureMetadata(
    const EAUTapDrainRegistration *registration
);
uint32_t EAUTapDrainRegistrationCopySignalCapture(
    const EAUTapDrainRegistration *registration,
    float *samples,
    uint32_t sampleCapacity
);
OSStatus EAUTapDrainRegistrationDestroy(EAUTapDrainRegistration *registration);

#ifdef __cplusplus
}
#endif
