#ifndef EAUM1_AUDIO_IO_HOST_H
#define EAUM1_AUDIO_IO_HOST_H

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

#include "EAUM1Runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EAUM1AudioIOHost EAUM1AudioIOHost;
typedef struct EAUM1CaptureRegistration EAUM1CaptureRegistration;
typedef struct EAUM1OutputRegistration EAUM1OutputRegistration;

typedef struct EAUM1AudioIOHostDescription {
    EAUM1Runtime *runtime;
    uint32_t inputBufferCount;
    const uint32_t *inputChannelCounts;
    uint32_t channelCount;
    uint32_t maximumFrameCount;
    uint32_t ringCapacityFrames;
    uint32_t primeFrames;
    uint32_t targetBacklogFrames;
} EAUM1AudioIOHostDescription;

typedef struct EAUM1AudioIOHostDiagnostics {
    uint64_t capturedFrameCount;
    uint64_t renderedFrameCount;
    uint64_t overflowedBlockCount;
    uint64_t underrunBlockCount;
    uint64_t droppedBacklogFrameCount;
    uint64_t invalidCallbackCount;
    uint64_t overlappingRenderCallbackCount;
} EAUM1AudioIOHostDiagnostics;

typedef struct EAUM1AudioIOHostCapabilities {
    uint8_t booleanAtomicsLockFree;
    uint8_t counterAtomicsLockFree;
} EAUM1AudioIOHostCapabilities;

typedef struct EAUM1OutputDiagnostics {
    AudioObjectID currentDevice;
    AudioStreamBasicDescription deviceFormat;
    AudioStreamBasicDescription clientFormat;
    uint32_t maximumFrames;
    uint8_t isRunning;
} EAUM1OutputDiagnostics;

EAUM1Status EAUM1AudioIOHostCreate(
    const EAUM1AudioIOHostDescription *description,
    EAUM1AudioIOHost **hostOut
);

void EAUM1AudioIOHostBeginStopping(EAUM1AudioIOHost *host);
void EAUM1AudioIOHostRequestFadeOut(EAUM1AudioIOHost *host, uint32_t frameCount);
uint8_t EAUM1AudioIOHostIsFadeComplete(const EAUM1AudioIOHost *host);
uint8_t EAUM1AudioIOHostIsQuiescent(const EAUM1AudioIOHost *host);
void EAUM1AudioIOHostDestroy(EAUM1AudioIOHost *host);

EAUM1Status EAUM1AudioIOHostCapture(
    EAUM1AudioIOHost *host,
    const AudioBufferList *inputData,
    uint32_t frameCount
);

EAUM1Status EAUM1AudioIOHostRender(
    EAUM1AudioIOHost *host,
    AudioUnitRenderActionFlags *actionFlags,
    AudioBufferList *outputData,
    uint32_t frameCount
);

EAUM1Status EAUM1AudioIOHostCopyDiagnostics(
    const EAUM1AudioIOHost *host,
    EAUM1AudioIOHostDiagnostics *diagnosticsOut
);

EAUM1Status EAUM1AudioIOHostGetCapabilities(
    EAUM1AudioIOHostCapabilities *capabilitiesOut
);

OSStatus EAUM1CaptureRegistrationCreate(
    AudioObjectID aggregateDevice,
    EAUM1AudioIOHost *host,
    EAUM1CaptureRegistration **registrationOut
);
OSStatus EAUM1CaptureRegistrationStart(EAUM1CaptureRegistration *registration);
OSStatus EAUM1CaptureRegistrationStop(EAUM1CaptureRegistration *registration);
OSStatus EAUM1CaptureRegistrationDestroy(EAUM1CaptureRegistration *registration);

OSStatus EAUM1OutputRegistrationCreate(
    AudioObjectID outputDevice,
    double sampleRate,
    uint32_t channelCount,
    uint32_t maximumFrameCount,
    EAUM1AudioIOHost *host,
    EAUM1OutputRegistration **registrationOut
);
/* A non-null registrationOut is owned by the caller even when creation fails. */
OSStatus EAUM1OutputRegistrationStart(EAUM1OutputRegistration *registration);
OSStatus EAUM1OutputRegistrationStop(EAUM1OutputRegistration *registration);
OSStatus EAUM1OutputRegistrationCopyDiagnostics(
    EAUM1OutputRegistration *registration,
    EAUM1OutputDiagnostics *diagnosticsOut
);
OSStatus EAUM1OutputRegistrationDestroy(EAUM1OutputRegistration *registration);

#ifdef __cplusplus
}
#endif

#endif
