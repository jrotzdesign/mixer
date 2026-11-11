#include "MixerCrashGuard.h"
#include <signal.h>

// Declared in <CoreAudio/AudioHardwareTapping.h>, which is Objective-C only.
extern OSStatus AudioHardwareDestroyProcessTap(AudioObjectID inTapID);

#define MIXER_GUARD_SLOTS 128

typedef struct {
    volatile AudioObjectID object;
    volatile int isTap;
} MixerGuardSlot;

static MixerGuardSlot gSlots[MIXER_GUARD_SLOTS];

static void MixerCrashGuardHandler(int sig) {
    // Default action first, so a crash inside the cleanup can't recurse.
    signal(sig, SIG_DFL);
    // Aggregates first (they hold the taps), then taps. Both are Mach IPC to coreaudiod.
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < MIXER_GUARD_SLOTS; i++) {
            AudioObjectID obj = gSlots[i].object;
            if (obj == kAudioObjectUnknown || gSlots[i].isTap != pass) continue;
            if (pass == 0) AudioHardwareDestroyAggregateDevice(obj);
            else AudioHardwareDestroyProcessTap(obj);
        }
    }
    raise(sig);
}

void MixerCrashGuardInstall(void) {
    signal(SIGABRT, MixerCrashGuardHandler);
    signal(SIGSEGV, MixerCrashGuardHandler);
    signal(SIGBUS, MixerCrashGuardHandler);
    signal(SIGILL, MixerCrashGuardHandler);
    signal(SIGTRAP, MixerCrashGuardHandler);
}

void MixerCrashGuardTrack(AudioObjectID object, int isTap) {
    if (object == kAudioObjectUnknown) return;
    for (int i = 0; i < MIXER_GUARD_SLOTS; i++) {
        if (gSlots[i].object == kAudioObjectUnknown) {
            gSlots[i].isTap = isTap ? 1 : 0;
            gSlots[i].object = object;
            return;
        }
    }
}

void MixerCrashGuardUntrack(AudioObjectID object) {
    for (int i = 0; i < MIXER_GUARD_SLOTS; i++) {
        if (gSlots[i].object == object) gSlots[i].object = kAudioObjectUnknown;
    }
}

int MixerCrashGuardTrackedCount(void) {
    int n = 0;
    for (int i = 0; i < MIXER_GUARD_SLOTS; i++) {
        if (gSlots[i].object != kAudioObjectUnknown) n++;
    }
    return n;
}
