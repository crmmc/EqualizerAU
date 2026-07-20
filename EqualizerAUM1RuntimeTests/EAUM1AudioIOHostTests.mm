#import <XCTest/XCTest.h>

#include "EAUM1AudioIOHost.h"

#include <array>
#include <cstring>

namespace EAUM1AudioIOHostTestHooks {
bool acquireRender(EAUM1AudioIOHost *host);
void releaseRender(EAUM1AudioIOHost *host);
}

namespace {

struct TwoBufferList {
    UInt32 count;
    AudioBuffer buffers[2];
};

struct HostFixture {
    EAUM1Runtime *runtime = nullptr;
    EAUM1AudioIOHost *host = nullptr;

    HostFixture() = default;
    HostFixture(const HostFixture &) = delete;
    HostFixture &operator=(const HostFixture &) = delete;
    HostFixture(HostFixture &&other) noexcept : runtime(other.runtime), host(other.host) {
        other.runtime = nullptr;
        other.host = nullptr;
    }

    ~HostFixture() {
        EAUM1AudioIOHostDestroy(host);
        EAUM1RuntimeDestroy(runtime);
    }
};

HostFixture makeHost(
    uint32_t maximumFrames = 4,
    uint32_t ringFrames = 8,
    uint32_t primeFrames = 0,
    uint32_t backlogFrames = 4
) {
    HostFixture fixture;
    const float targets[] = {1.0f, 1.0f};
    EAUM1PreparedState *prepared = nullptr;
    XCTAssertEqual(EAUM1PreparedStateCreate(targets, 2, &prepared), EAUM1StatusOK);
    const uint32_t runtimeChannels = 2;
    const EAUM1RuntimeDescription runtimeDescription = {
        .sampleRate = 1000.0,
        .maximumFrameCount = maximumFrames,
        .bufferCount = 1,
        .channelCounts = &runtimeChannels,
        .effectsEnabled = 1,
    };
    XCTAssertEqual(
        EAUM1RuntimeCreate(&runtimeDescription, &prepared, &fixture.runtime),
        EAUM1StatusOK
    );
    const uint32_t inputChannels[] = {1, 1};
    const EAUM1AudioIOHostDescription hostDescription = {
        .runtime = fixture.runtime,
        .inputBufferCount = 2,
        .inputChannelCounts = inputChannels,
        .channelCount = 2,
        .maximumFrameCount = maximumFrames,
        .ringCapacityFrames = ringFrames,
        .primeFrames = primeFrames,
        .targetBacklogFrames = backlogFrames,
    };
    XCTAssertEqual(EAUM1AudioIOHostCreate(&hostDescription, &fixture.host), EAUM1StatusOK);
    return fixture;
}

TwoBufferList captureList(float *left, float *right, uint32_t frames) {
    return TwoBufferList{
        2,
        {
            {1, frames * static_cast<UInt32>(sizeof(float)), left},
            {1, frames * static_cast<UInt32>(sizeof(float)), right},
        },
    };
}

AudioBufferList outputList(float *samples, uint32_t frames) {
    return AudioBufferList{
        1,
        {{2, frames * 2 * static_cast<UInt32>(sizeof(float)), samples}},
    };
}

} // namespace

@interface EAUM1AudioIOHostTests : XCTestCase
@end

@implementation EAUM1AudioIOHostTests

- (void)testRequiredHostAtomicsAreLockFree {
    EAUM1AudioIOHostCapabilities capabilities = {};
    XCTAssertEqual(EAUM1AudioIOHostGetCapabilities(&capabilities), EAUM1StatusOK);
    XCTAssertEqual(capabilities.booleanAtomicsLockFree, 1u);
    XCTAssertEqual(capabilities.counterAtomicsLockFree, 1u);
    XCTAssertEqual(EAUM1AudioIOHostGetCapabilities(nullptr), EAUM1StatusInvalidArgument);
}

- (void)testHostRejectsUnsafeBacklogAndTopology {
    const float targets[] = {1.0f, 1.0f};
    EAUM1PreparedState *prepared = nullptr;
    XCTAssertEqual(EAUM1PreparedStateCreate(targets, 2, &prepared), EAUM1StatusOK);
    const uint32_t runtimeChannels = 2;
    const EAUM1RuntimeDescription runtimeDescription = {
        .sampleRate = 48000.0,
        .maximumFrameCount = 4,
        .bufferCount = 1,
        .channelCounts = &runtimeChannels,
        .effectsEnabled = 1,
    };
    EAUM1Runtime *runtime = nullptr;
    XCTAssertEqual(EAUM1RuntimeCreate(&runtimeDescription, &prepared, &runtime), EAUM1StatusOK);

    const uint32_t channels[] = {1, 1};
    EAUM1AudioIOHostDescription description = {
        .runtime = runtime,
        .inputBufferCount = 2,
        .inputChannelCounts = channels,
        .channelCount = 2,
        .maximumFrameCount = 4,
        .ringCapacityFrames = 8,
        .primeFrames = 0,
        .targetBacklogFrames = 3,
    };
    EAUM1AudioIOHost *host = nullptr;
    XCTAssertEqual(EAUM1AudioIOHostCreate(&description, &host), EAUM1StatusInvalidArgument);
    XCTAssertEqual(host, nullptr);
    description.targetBacklogFrames = 4;
    description.channelCount = 3;
    XCTAssertEqual(EAUM1AudioIOHostCreate(&description, &host), EAUM1StatusTopologyMismatch);
    EAUM1RuntimeDestroy(runtime);
}

- (void)testCaptureFlattensMultipleBuffersAndRenderRestoresInterleaving {
    HostFixture fixture = makeHost();
    float left[] = {1.0f, 2.0f};
    float right[] = {10.0f, 20.0f};
    TwoBufferList capture = captureList(left, right, 2);
    XCTAssertEqual(
        EAUM1AudioIOHostCapture(
            fixture.host,
            reinterpret_cast<AudioBufferList *>(&capture),
            2
        ),
        EAUM1StatusOK
    );

    float output[] = {-1.0f, -1.0f, -1.0f, -1.0f};
    AudioBufferList list = outputList(output, 2);
    AudioUnitRenderActionFlags flags = kAudioUnitRenderAction_OutputIsSilence;
    XCTAssertEqual(EAUM1AudioIOHostRender(fixture.host, &flags, &list, 2), EAUM1StatusOK);
    const float expected[] = {1.0f, 10.0f, 2.0f, 20.0f};
    XCTAssertEqual(std::memcmp(output, expected, sizeof(expected)), 0);
    XCTAssertEqual(flags & kAudioUnitRenderAction_OutputIsSilence, 0u);
    EAUM1AudioIOHostDiagnostics diagnostics = {};
    XCTAssertEqual(EAUM1AudioIOHostCopyDiagnostics(fixture.host, &diagnostics), EAUM1StatusOK);
    XCTAssertEqual(diagnostics.capturedFrameCount, 2u);
    XCTAssertEqual(diagnostics.renderedFrameCount, 2u);
}

- (void)testOverflowAndUnderrunAreWholeBlockAndObservable {
    HostFixture fixture = makeHost(4, 4, 0, 4);
    float left[] = {1, 2, 3, 4};
    float right[] = {5, 6, 7, 8};
    TwoBufferList capture = captureList(left, right, 4);
    auto *captureABL = reinterpret_cast<AudioBufferList *>(&capture);
    XCTAssertEqual(EAUM1AudioIOHostCapture(fixture.host, captureABL, 4), EAUM1StatusOK);
    TwoBufferList oneFrameCapture = captureList(left, right, 1);
    XCTAssertEqual(
        EAUM1AudioIOHostCapture(
            fixture.host,
            reinterpret_cast<AudioBufferList *>(&oneFrameCapture),
            1
        ),
        EAUM1StatusCapacityExceeded
    );

    float output[8] = {};
    AudioBufferList list = outputList(output, 4);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(EAUM1AudioIOHostRender(fixture.host, &flags, &list, 4), EAUM1StatusOK);
    std::fill(std::begin(output), std::end(output), 9.0f);
    flags = 0;
    XCTAssertEqual(EAUM1AudioIOHostRender(fixture.host, &flags, &list, 4), EAUM1StatusOK);
    for (float sample : output) { XCTAssertEqual(sample, 0.0f); }
    XCTAssertNotEqual(flags & kAudioUnitRenderAction_OutputIsSilence, 0u);

    EAUM1AudioIOHostDiagnostics diagnostics = {};
    XCTAssertEqual(EAUM1AudioIOHostCopyDiagnostics(fixture.host, &diagnostics), EAUM1StatusOK);
    XCTAssertEqual(diagnostics.overflowedBlockCount, 1u);
    XCTAssertEqual(diagnostics.underrunBlockCount, 1u);
}

- (void)testCaptureRejectsNonExactBufferSizesWithoutPublishingFrames {
    HostFixture fixture = makeHost();
    float left[] = {1.0f, 2.0f};
    float right[] = {3.0f, 4.0f};
    TwoBufferList capture = captureList(left, right, 2);
    capture.buffers[1].mDataByteSize -= 1;
    XCTAssertEqual(
        EAUM1AudioIOHostCapture(
            fixture.host,
            reinterpret_cast<AudioBufferList *>(&capture),
            2
        ),
        EAUM1StatusInvalidArgument
    );
    EAUM1AudioIOHostDiagnostics diagnostics = {};
    XCTAssertEqual(EAUM1AudioIOHostCopyDiagnostics(fixture.host, &diagnostics), EAUM1StatusOK);
    XCTAssertEqual(diagnostics.capturedFrameCount, 0u);
    XCTAssertEqual(diagnostics.invalidCallbackCount, 1u);
}

- (void)testFadeIsContinuousAcrossBlocksAndRemainsSilent {
    HostFixture fixture = makeHost(4, 12, 0, 4);
    float left[] = {1, 1, 1, 1};
    float right[] = {1, 1, 1, 1};
    TwoBufferList capture = captureList(left, right, 4);
    auto *captureABL = reinterpret_cast<AudioBufferList *>(&capture);
    XCTAssertEqual(EAUM1AudioIOHostCapture(fixture.host, captureABL, 4), EAUM1StatusOK);
    XCTAssertEqual(EAUM1AudioIOHostCapture(fixture.host, captureABL, 4), EAUM1StatusOK);
    EAUM1AudioIOHostRequestFadeOut(fixture.host, 6);

    float first[8] = {};
    AudioBufferList firstList = outputList(first, 4);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(EAUM1AudioIOHostRender(fixture.host, &flags, &firstList, 4), EAUM1StatusOK);
    const float firstExpected[] = {5.0f/6, 5.0f/6, 4.0f/6, 4.0f/6, 3.0f/6, 3.0f/6, 2.0f/6, 2.0f/6};
    for (size_t index = 0; index < 8; ++index) {
        XCTAssertEqualWithAccuracy(first[index], firstExpected[index], 1e-6f);
    }

    float second[8] = {};
    AudioBufferList secondList = outputList(second, 4);
    XCTAssertEqual(EAUM1AudioIOHostRender(fixture.host, &flags, &secondList, 4), EAUM1StatusOK);
    const float secondExpected[] = {1.0f/6, 1.0f/6, 0, 0, 0, 0, 0, 0};
    for (size_t index = 0; index < 8; ++index) {
        XCTAssertEqualWithAccuracy(second[index], secondExpected[index], 1e-6f);
    }
    XCTAssertEqual(EAUM1AudioIOHostIsFadeComplete(fixture.host), 1);
}

- (void)testRenderOverlapClearsOutputWithoutConsumingRing {
    HostFixture fixture = makeHost();
    float left[] = {1.0f};
    float right[] = {2.0f};
    TwoBufferList capture = captureList(left, right, 1);
    XCTAssertEqual(
        EAUM1AudioIOHostCapture(
            fixture.host,
            reinterpret_cast<AudioBufferList *>(&capture),
            1
        ),
        EAUM1StatusOK
    );
    XCTAssertTrue(EAUM1AudioIOHostTestHooks::acquireRender(fixture.host));
    float output[] = {9.0f, 9.0f};
    AudioBufferList list = outputList(output, 1);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(
        EAUM1AudioIOHostRender(fixture.host, &flags, &list, 1),
        EAUM1StatusCallbackOverlap
    );
    XCTAssertEqual(output[0], 0.0f);
    XCTAssertEqual(output[1], 0.0f);
    EAUM1AudioIOHostTestHooks::releaseRender(fixture.host);

    XCTAssertEqual(EAUM1AudioIOHostRender(fixture.host, &flags, &list, 1), EAUM1StatusOK);
    XCTAssertEqual(output[0], 1.0f);
    XCTAssertEqual(output[1], 2.0f);
    EAUM1AudioIOHostDiagnostics diagnostics = {};
    XCTAssertEqual(EAUM1AudioIOHostCopyDiagnostics(fixture.host, &diagnostics), EAUM1StatusOK);
    XCTAssertEqual(diagnostics.overlappingRenderCallbackCount, 1u);
}

- (void)testStoppingAlwaysRendersSilence {
    HostFixture fixture = makeHost();
    EAUM1AudioIOHostBeginStopping(fixture.host);
    float output[] = {7.0f, 8.0f};
    AudioBufferList list = outputList(output, 1);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(EAUM1AudioIOHostRender(fixture.host, &flags, &list, 1), EAUM1StatusOK);
    XCTAssertEqual(output[0], 0.0f);
    XCTAssertEqual(output[1], 0.0f);
    XCTAssertNotEqual(flags & kAudioUnitRenderAction_OutputIsSilence, 0u);
}

@end
