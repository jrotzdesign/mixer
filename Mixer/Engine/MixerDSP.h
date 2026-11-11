// MixerDSP: the real-time audio path. Plain C so nothing on the audio thread
// allocates, locks, or touches the Swift/ObjC runtime.

#ifndef MixerDSP_h
#define MixerDSP_h

#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN

/// Shared between the UI (writes targetGain) and the IOProc (reads it).
/// Allocate once per channel and keep alive until after the IOProc is destroyed.
typedef struct MixerChannelState {
    _Atomic float targetGain;        // linear amplitude, written by UI
    float currentGain;               // audio thread only
    _Atomic float inputPeak;         // max |sample| of the last buffer, for diagnostics
    _Atomic uint64_t callbackCount;  // number of IOProc calls, for diagnostics
} MixerChannelState;

/// Initialise state with a starting gain (no ramp on the first buffer).
void MixerChannelStateInit(MixerChannelState *state, float gain);

/// Set the target gain from any thread. The IOProc ramps to it over one buffer.
void MixerChannelStateSetGain(MixerChannelState *state, float gain);

/// Diagnostics readers (Swift can't read _Atomic fields directly).
float MixerChannelStateGetTargetGain(MixerChannelState *state);
float MixerChannelStateGetInputPeak(MixerChannelState *state);
uint64_t MixerChannelStateGetCallbackCount(MixerChannelState *state);

/// Process one block: copy `frames` frames of `inChannels`-wide input to the
/// output, applying a linear ramp from currentGain to targetGain and a soft
/// limiter when the gain is above 1. Exposed separately for unit tests.
void MixerProcessInterleaved(MixerChannelState *state,
                             const float *in, uint32_t inChannels,
                             float *out, uint32_t outChannels,
                             uint32_t frames);

/// AudioDeviceIOProc for a tap aggregate device. inClientData = MixerChannelState*.
OSStatus MixerIOProc(AudioObjectID inDevice,
                     const AudioTimeStamp *inNow,
                     const AudioBufferList *inInputData,
                     const AudioTimeStamp *inInputTime,
                     AudioBufferList *outOutputData,
                     const AudioTimeStamp *inOutputTime,
                     void *_Nullable inClientData);

/// Soft limiter used above unity gain (exposed for unit tests).
float MixerSoftLimit(float x);

CF_ASSUME_NONNULL_END

#endif /* MixerDSP_h */
