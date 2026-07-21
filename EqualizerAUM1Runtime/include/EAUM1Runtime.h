#ifndef EAUM1_RUNTIME_H
#define EAUM1_RUNTIME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define EAUM1_RUNTIME_ABI_VERSION 2u
#define EAUM1_MAX_STAGES_PER_CHANNEL 512u
#define EAUM1_MAX_PREPARED_STAGE_COUNT 4096u

typedef int32_t EAUM1Status;

enum {
    EAUM1StatusOK = 0,
    EAUM1StatusInvalidArgument = 1,
    EAUM1StatusOutOfMemory = 2,
    EAUM1StatusUnsupported = 3,
    EAUM1StatusTopologyMismatch = 4,
    EAUM1StatusCapacityExceeded = 5,
    EAUM1StatusCallbackOverlap = 6,
    EAUM1StatusStaleRetirementTicket = 7,
};

enum {
    EAUM1PublicationCandidatePublished = 1u << 0,
    EAUM1PublicationCandidateCoalesced = 1u << 1,
    EAUM1PublicationRetiredReclaimed = 1u << 2,
    EAUM1PublicationMaintenanceRequired = 1u << 3,
};

typedef struct EAUM1PreparedState EAUM1PreparedState;
typedef struct EAUM1Runtime EAUM1Runtime;

typedef struct EAUM1RuntimeCapabilities {
    uint8_t activePreparedPointerLockFree;
    uint8_t callbackStateLockFree;
    uint8_t effectsEnabledLockFree;
    uint8_t diagnosticCountersLockFree;
} EAUM1RuntimeCapabilities;

typedef struct EAUM1RuntimeDescription {
    double sampleRate;
    uint32_t maximumFrameCount;
    uint32_t bufferCount;
    const uint32_t *channelCounts;
    uint8_t effectsEnabled;
} EAUM1RuntimeDescription;

typedef uint32_t EAUM1PreparedStageKind;

enum {
    EAUM1PreparedStageGain = 1,
    EAUM1PreparedStageBiquad = 2,
};

typedef struct EAUM1PreparedStage {
    EAUM1PreparedStageKind kind;
    uint32_t channelIndex;
    double b0;
    double b1;
    double b2;
    double a1;
    double a2;
} EAUM1PreparedStage;

typedef struct EAUM1PreparedDescription {
    uint32_t channelCount;
    uint32_t stageCount;
    const EAUM1PreparedStage *stages;
} EAUM1PreparedDescription;

typedef struct EAUM1AudioBuffer {
    float *samples;
    uint32_t channelCount;
} EAUM1AudioBuffer;

typedef struct EAUM1RuntimeDiagnostics {
    uint64_t nonFiniteInputSampleCount;
    uint64_t saturatedOutputSampleCount;
    uint64_t invalidProcessCallCount;
} EAUM1RuntimeDiagnostics;

typedef struct EAUM1PublicationOutcome {
    uint64_t retirementTicket;
    uint32_t flags;
    uint32_t reserved;
} EAUM1PublicationOutcome;

typedef struct EAUM1ConcurrencyDiagnostics {
    uint64_t overlappingCallbackCount;
} EAUM1ConcurrencyDiagnostics;

uint32_t EAUM1RuntimeABIVersion(void);

EAUM1Status EAUM1RuntimeGetCapabilities(EAUM1RuntimeCapabilities *capabilitiesOut);

/* Copies the target array. Targets must be zero or positive finite normal Float32 values. */
EAUM1Status EAUM1PreparedStateCreate(
    const float *linearGainsByChannel,
    uint32_t channelCount,
    EAUM1PreparedState **preparedOut
);

/*
 * Copies a channel-major ordered stage array. Each channel may contain at most
 * EAUM1_MAX_STAGES_PER_CHANNEL stages. Biquad coefficients use normalized a0=1
 * transposed direct-form II coefficients generated off the realtime thread.
 */
EAUM1Status EAUM1PreparedStateCreateV2(
    const EAUM1PreparedDescription *description,
    EAUM1PreparedState **preparedOut
);

/* Valid only before publication or after runtime retirement returns ownership. */
void EAUM1PreparedStateDestroy(EAUM1PreparedState *prepared);

/*
 * On success, consumes *initialPreparedInOut and sets it to null. On failure,
 * ownership remains with the caller. The description arrays are copied.
 */
EAUM1Status EAUM1RuntimeCreate(
    const EAUM1RuntimeDescription *description,
    EAUM1PreparedState **initialPreparedInOut,
    EAUM1Runtime **runtimeOut
);

/*
 * Control-thread operations. Calls on the same runtime must be serialized.
 * A successful publish consumes and nulls *candidateInOut. The old and new
 * execution slots crossfade for 10 ms. If that transition is still active,
 * the latest candidate replaces the prior pending candidate.
 */
EAUM1Status EAUM1RuntimePublishPrepared(
    EAUM1Runtime *runtime,
    EAUM1PreparedState **candidateInOut,
    EAUM1PublicationOutcome *outcomeOut
);

/*
 * Polls one exact transition ticket. A stale ticket never reclaims memory.
 * Control owns the 1 ms polling cadence, 100 ms deadline and bridge generation.
 */
EAUM1Status EAUM1RuntimePerformMaintenance(
    EAUM1Runtime *runtime,
    uint64_t retirementTicket,
    EAUM1PublicationOutcome *outcomeOut
);

/* Stop-only control operation. The active and retired states are unchanged. */
EAUM1Status EAUM1RuntimeDiscardPendingPrepared(EAUM1Runtime *runtime);

/*
 * The caller must prove that no process call is in flight and no control call
 * can overlap before destruction.
 */
void EAUM1RuntimeDestroy(EAUM1Runtime *runtime);

/* Control-thread operation. The callback reads this lock-free value once per block. */
EAUM1Status EAUM1RuntimeSetEffectsEnabled(EAUM1Runtime *runtime, uint8_t effectsEnabled);

/*
 * In-place processing for the topology supplied at runtime creation. An
 * overlapping call with a valid descriptor clears its own output block and
 * returns EAUM1StatusCallbackOverlap. A malformed overlapping descriptor is
 * counted but cannot be safely cleared and still returns CallbackOverlap.
 */
EAUM1Status EAUM1RuntimeProcess(
    EAUM1Runtime *runtime,
    EAUM1AudioBuffer *buffers,
    uint32_t bufferCount,
    uint32_t frameCount
);

EAUM1Status EAUM1RuntimeCopyDiagnostics(
    const EAUM1Runtime *runtime,
    EAUM1RuntimeDiagnostics *diagnosticsOut
);

EAUM1Status EAUM1RuntimeCopyConcurrencyDiagnostics(
    const EAUM1Runtime *runtime,
    EAUM1ConcurrencyDiagnostics *diagnosticsOut
);

#ifdef __cplusplus
}
#endif

#endif
