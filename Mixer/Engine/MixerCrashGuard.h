// MixerCrashGuard: on a crash signal, destroy every live Mixer tap and
// aggregate device before the process dies, so no app is left muted.
// Muted-when-tapped taps already unmute when Mixer stops reading them; this
// is the second layer (PLAN §5.6). State is a fixed static array so the
// signal handler touches no heap or Swift runtime.

#ifndef MixerCrashGuard_h
#define MixerCrashGuard_h

#include <CoreAudio/CoreAudio.h>

CF_ASSUME_NONNULL_BEGIN

/// Installs handlers for SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP. Call once at launch.
void MixerCrashGuardInstall(void);

/// Records a live object. `isTap` = 1 for a process tap, 0 for an aggregate device.
void MixerCrashGuardTrack(AudioObjectID object, int isTap);

/// Forgets an object after it has been destroyed normally.
void MixerCrashGuardUntrack(AudioObjectID object);

/// Number of tracked objects (diagnostics and tests).
int MixerCrashGuardTrackedCount(void);

CF_ASSUME_NONNULL_END

#endif /* MixerCrashGuard_h */
