#include "MixerDSP.h"
#include <math.h>
#include <string.h>

#define MIXER_MAX_CHANNELS 32
#define MIXER_LIMIT_KNEE 0.891f     // -1 dBFS: below this, samples pass untouched
#define MIXER_LIMIT_CEILING 0.98f   // limiter output never reaches full scale

void MixerChannelStateInit(MixerChannelState *state, float gain) {
    atomic_store_explicit(&state->targetGain, gain, memory_order_relaxed);
    state->currentGain = gain;
    atomic_store_explicit(&state->inputPeak, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&state->callbackCount, 0, memory_order_relaxed);
}

void MixerChannelStateSetGain(MixerChannelState *state, float gain) {
    if (!(gain >= 0.0f)) gain = 0.0f;  // also catches NaN
    atomic_store_explicit(&state->targetGain, gain, memory_order_relaxed);
}

float MixerChannelStateGetTargetGain(MixerChannelState *state) {
    return atomic_load_explicit(&state->targetGain, memory_order_relaxed);
}

float MixerChannelStateGetInputPeak(MixerChannelState *state) {
    return atomic_load_explicit(&state->inputPeak, memory_order_relaxed);
}

uint64_t MixerChannelStateGetCallbackCount(MixerChannelState *state) {
    return atomic_load_explicit(&state->callbackCount, memory_order_relaxed);
}

float MixerSoftLimit(float x) {
    float a = fabsf(x);
    if (a <= MIXER_LIMIT_KNEE) return x;
    float range = MIXER_LIMIT_CEILING - MIXER_LIMIT_KNEE;
    float y = MIXER_LIMIT_KNEE + range * tanhf((a - MIXER_LIMIT_KNEE) / range);
    return x < 0.0f ? -y : y;
}

/// Core loop over strided channel pointers. Input channel i feeds output
/// channel i; extra output channels are silenced, extra input channels dropped.
static void MixerProcessStrided(MixerChannelState *state,
                                const float *const *inPtr, const uint32_t *inStride, uint32_t inCh,
                                float *const *outPtr, const uint32_t *outStride, uint32_t outCh,
                                uint32_t frames) {
    float g0 = state->currentGain;
    float g1 = atomic_load_explicit(&state->targetGain, memory_order_relaxed);
    float step = frames > 0 ? (g1 - g0) / (float)frames : 0.0f;
    int limit = (g0 > 1.0f || g1 > 1.0f);
    float peak = 0.0f;

    if (outCh == 1 && inCh >= 2) {
        // Mono output: average the stereo pair.
        float *o = outPtr[0];
        uint32_t os = outStride[0];
        for (uint32_t f = 0; f < frames; f++) {
            float l = inPtr[0][f * inStride[0]];
            float r = inPtr[1][f * inStride[1]];
            float al = fabsf(l), ar = fabsf(r);
            if (al > peak) peak = al;
            if (ar > peak) peak = ar;
            float y = (l + r) * 0.5f * (g0 + step * (float)f);
            o[f * os] = limit ? MixerSoftLimit(y) : y;
        }
        outCh = 0;  // skip the per-channel loop below
    }

    for (uint32_t c = 0; c < outCh; c++) {
        float *o = outPtr[c];
        uint32_t os = outStride[c];
        if (c >= inCh) {
            for (uint32_t f = 0; f < frames; f++) o[f * os] = 0.0f;
            continue;
        }
        const float *i = inPtr[c];
        uint32_t is = inStride[c];
        for (uint32_t f = 0; f < frames; f++) {
            float s = i[f * is];
            float a = fabsf(s);
            if (a > peak) peak = a;
            float y = s * (g0 + step * (float)f);
            o[f * os] = limit ? MixerSoftLimit(y) : y;
        }
    }

    state->currentGain = g1;
    atomic_store_explicit(&state->inputPeak, peak, memory_order_relaxed);
}

void MixerProcessInterleaved(MixerChannelState *state,
                             const float *in, uint32_t inChannels,
                             float *out, uint32_t outChannels,
                             uint32_t frames) {
    const float *inPtr[MIXER_MAX_CHANNELS];
    uint32_t inStride[MIXER_MAX_CHANNELS];
    float *outPtr[MIXER_MAX_CHANNELS];
    uint32_t outStride[MIXER_MAX_CHANNELS];
    if (inChannels > MIXER_MAX_CHANNELS) inChannels = MIXER_MAX_CHANNELS;
    if (outChannels > MIXER_MAX_CHANNELS) outChannels = MIXER_MAX_CHANNELS;
    for (uint32_t c = 0; c < inChannels; c++) { inPtr[c] = in + c; inStride[c] = inChannels; }
    for (uint32_t c = 0; c < outChannels; c++) { outPtr[c] = out + c; outStride[c] = outChannels; }
    MixerProcessStrided(state, inPtr, inStride, inChannels, outPtr, outStride, outChannels, frames);
}

/// Flatten an AudioBufferList into per-channel pointers and strides.
/// Returns the channel count and the smallest frame count across buffers.
static uint32_t MixerMapBuffers(const AudioBufferList *list, float **ptr, uint32_t *stride, uint32_t *framesOut) {
    uint32_t ch = 0;
    uint32_t frames = UINT32_MAX;
    if (list == NULL) { *framesOut = 0; return 0; }
    for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
        const AudioBuffer *buf = &list->mBuffers[b];
        uint32_t n = buf->mNumberChannels;
        if (buf->mData == NULL || n == 0) continue;
        uint32_t bf = buf->mDataByteSize / (uint32_t)(sizeof(float) * n);
        if (bf < frames) frames = bf;
        for (uint32_t c = 0; c < n && ch < MIXER_MAX_CHANNELS; c++) {
            ptr[ch] = (float *)buf->mData + c;
            stride[ch] = n;
            ch++;
        }
    }
    *framesOut = (frames == UINT32_MAX) ? 0 : frames;
    return ch;
}

OSStatus MixerIOProc(AudioObjectID inDevice,
                     const AudioTimeStamp *inNow,
                     const AudioBufferList *inInputData,
                     const AudioTimeStamp *inInputTime,
                     AudioBufferList *outOutputData,
                     const AudioTimeStamp *inOutputTime,
                     void *inClientData) {
    (void)inDevice; (void)inNow; (void)inInputTime; (void)inOutputTime;
    MixerChannelState *state = (MixerChannelState *)inClientData;
    if (state == NULL || outOutputData == NULL) return noErr;
    atomic_fetch_add_explicit(&state->callbackCount, 1, memory_order_relaxed);

    float *inPtr[MIXER_MAX_CHANNELS];
    uint32_t inStride[MIXER_MAX_CHANNELS];
    float *outPtr[MIXER_MAX_CHANNELS];
    uint32_t outStride[MIXER_MAX_CHANNELS];
    uint32_t inFrames = 0, outFrames = 0;
    uint32_t inCh = MixerMapBuffers(inInputData, inPtr, inStride, &inFrames);
    uint32_t outCh = MixerMapBuffers(outOutputData, outPtr, outStride, &outFrames);

    // Silence everything first; the strided loop then overwrites what it can.
    for (UInt32 b = 0; b < outOutputData->mNumberBuffers; b++) {
        AudioBuffer *buf = &outOutputData->mBuffers[b];
        if (buf->mData) memset(buf->mData, 0, buf->mDataByteSize);
    }
    if (inCh == 0 || outCh == 0) return noErr;

    uint32_t frames = inFrames < outFrames ? inFrames : outFrames;
    MixerProcessStrided(state, (const float *const *)inPtr, inStride, inCh,
                        outPtr, outStride, outCh, frames);
    return noErr;
}
