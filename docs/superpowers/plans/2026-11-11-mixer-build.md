# Mixer Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the phase-1 spike into the full Mixer menu bar app: per-app volume/mute through Core Audio process taps, remembered volumes, device following, global shortcuts with a HUD, and launch at login.

**Architecture:** A `@MainActor` `AudioEngine` reconciles live audio processes (grouped into apps by `AppResolver`) against saved settings using a pure `ChannelPlanner`, and owns one `Channel` (private muted-when-tapped tap + private aggregate + C IOProc) per adjusted app. SwiftUI views and the hotkey controller only call engine methods. Pure logic is unit tested; Core Audio paths are verified live with scripts.

**Tech Stack:** Swift 6 / SwiftUI, Core Audio (AudioHardware + CATapDescription), C for the real-time path and crash handler, XCTest, xcodegen, sindresorhus/KeyboardShortcuts (the only dependency).

**Spec:** `PLAN.md` (design, §1–§13). Phase 0 (project) and phase 1 (spike + crash test) are done; crash safety was confirmed by ear on 2026-11-11.

## Global Constraints

- Deployment target macOS 14.2; tested on macOS 27.2 / Xcode 27.2 only.
- Bundle ID `com.jrortizdesign.mixer`; Personal Team `723G9BWXPS`; not sandboxed; `LSUIElement` = YES.
- Taps: `muteBehavior = .mutedWhenTapped` (never `.muted`), `isPrivate = true`; aggregates private, name prefix `Mixer-`.
- Never create a muting tap unless `AudioCapturePermission.status == .granted`.
- Volume range 0–150 %, `gain = (percent/100)²`, soft limiter above unity, 256-frame IO buffer.
- An app gets a channel only if percent ≠ 100 or muted; it keeps it while paused; it releases 10 s after returning to 100 %/unmuted or immediately when the app quits.
- Rows: shown while playing, linger 5 s after audio stops, removed immediately on quit.
- App key: bundle ID, else `path:<executable path>`. Mixer's own PID is never listed or tapped.
- Shortcut defaults: frontmost ±5 % `⌃⌥↑/⌃⌥↓`, pinned ±5 % `⌃⌥⇧↑/⌃⌥⇧↓`, mute frontmost `⌃⌥M`; rebindable.
- Brand tokens: teal `#29A191`, rosa `#E4007C` (boost segment + muted icon only), ink `#121316`, night `#0E0F12`, ink-2 `#55585F`, bone `#F2F3F0`, bone-2 `#E6E7E3`; Figtree / DM Mono / Bricolage Grotesque bundled.
- Rules: never delete files (move to `_to_delete/`); secret scan before every push; commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. FineTune (GPL) is pattern-only: no copied code.
- Tests run with: `xcodebuild test -project Mixer.xcodeproj -scheme Mixer -derivedDataPath build/DerivedData -destination 'platform=macOS' -quiet`. The app must not start the engine when `XCTestConfigurationFilePath` is set.

## Review Focus

1. **Permission denied or revoked while running** → no muting taps are created, and existing ones are torn down rather than left playing silence. Test: `ChannelPlannerTests.testNoChannelsWithoutPermission` (Task 5).
2. **Mono or multichannel output (HDMI 8ch, a mono USB speaker)** → stereo goes to the first two channels; a mono output gets (L+R)/2; extra channels are silent. Test: `DSPTests.testStereoToMonoDownmix`, `testStereoToEightChannels` (Task 1).
3. **Many helpers from one app (Chrome tabs, Electron renderers) appearing and disappearing** → one row and one tap, updated in place. Test: `AppResolverTests.testManyHelpersOneGroup` (Task 3), plus a live check in Task 7.
4. **Rapid slider drags and held-down shortcuts** → no clicks or jumps, and percent clamps at 0 and 150. Test: `DSPTests.testRampIsContinuousAcrossBuffers` (Task 1), `VolumeTests.testNudgeClamps` (Task 2).
5. **Output device vanishes or changes sample rate mid-playback (AirPods taken out, mic engaged)** → the channel rebuilds on the new default without a full-volume burst. Live check in Task 9 (switch AirPods ↔ MacBook speakers with a muted app playing).

---

### Task 1: Test target + DSP hardening

**Files:**
- Modify: `project.yml` (add `MixerTests` unit-test target, hosted by Mixer; add scheme with test action)
- Modify: `Mixer/Engine/MixerDSP.c` (mono downmix when output has 1 channel)
- Modify: `Mixer/App/MixerApp.swift` (skip engine and spike when `XCTestConfigurationFilePath` is set)
- Move: `scripts/crashtest-measured.sh` → `_to_delete/` (the observer approach can't tell muted from unmuted; see PLAN §5.6 notes)
- Test: `MixerTests/DSPTests.swift`

**Interfaces:**
- Consumes: `MixerChannelStateInit/SetGain/GetTargetGain/GetInputPeak`, `MixerProcessInterleaved`, `MixerSoftLimit` (existing).
- Produces: a working `xcodebuild test` command used by every later task.

- [ ] **Step 1: Write failing tests** in `DSPTests`:
  - `testUnityGainCopiesStereo`: gain 1, in `[0.1,-0.2]×64` → out equals in.
  - `testRampReachesTargetAtBufferEnd`: init 0, set 1, 256 frames of 1.0 → `out[0]` ≈ 0, last frame ≥ 0.99, monotonic.
  - `testRampIsContinuousAcrossBuffers`: two 128-frame calls with target set between them → no step between buffer 1's last and buffer 2's first frame larger than one ramp step.
  - `testMuteIsSilentAfterOneBuffer`: gain 1 → set 0 → second buffer all 0.
  - `testLimiterOnlyAboveUnity`: gain 1, sample 0.95 passes unchanged; gain 2.25, sample 0.9 → |out| < 1.0.
  - `testStereoToMonoDownmix`: in L=0.4, R=0.2, outChannels 1 → out 0.3.
  - `testStereoToEightChannels`: outChannels 8 → ch0/ch1 = input, ch2…7 = 0.
  - `testNaNGainTreatedAsZero`: `MixerChannelStateSetGain(nan)` → target 0.
- [ ] **Step 2:** Run tests → mono downmix test FAILS (others may pass).
- [ ] **Step 3:** In `MixerProcessStrided`, when `outCh == 1 && inCh >= 2`, write `(L+R)*0.5` then gain/limit.
- [ ] **Step 4:** Run tests → all PASS; `xcodebuild build` with no warnings.
- [ ] **Step 5:** Commit `test: add MixerTests target and DSP coverage; mono downmix`.

### Task 2: Volume model + settings store (your step 4, the memory half)

**Files:**
- Create: `Mixer/Model/AppVolume.swift`, `Mixer/Model/SettingsStore.swift`
- Test: `MixerTests/VolumeTests.swift`, `MixerTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct AppVolume: Codable, Equatable, Sendable { var percent: Int = 100; var muted = false; static let maxPercent = 150; static let step = 5; var gain: Float /* 0 if muted else (percent/100)² */; var needsChannel: Bool /* percent != 100 || muted */; func nudged(by delta: Int) -> AppVolume /* clamps 0...150 */ }`
  - `@MainActor final class SettingsStore { init(defaults: UserDefaults = .standard); func volume(for key: String) -> AppVolume; func setVolume(_ v: AppVolume, for key: String); var pinnedAppKey: String?; func resetAllVolumes() }`. Storage: one dictionary under `volumes.v1` (key → encoded AppVolume); `pinnedAppKey` under `pinnedAppKey`. Default-volume entries (100 %, unmuted) are removed instead of stored.

- [ ] **Step 1: Write failing tests:** `testGainTaper` (50 → 0.25, 100 → 1, 150 → 2.25, muted → 0), `testNeedsChannel` (100/unmuted false; 99 true; 100/muted true), `testNudgeClamps` (145 +5 → 150, +5 again → 150; 3 −5 → 0); `SettingsStoreTests` with `UserDefaults(suiteName: UUID().uuidString)`: round trip, unknown key → default, default value not persisted, pinned key round trip, reset clears volumes but keeps pin.
- [ ] **Step 2:** Run → FAIL (types missing).
- [ ] **Step 3:** Implement both files.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: volume model and settings store`.

### Task 3: AppResolver (helper folding)

**Files:**
- Create: `Mixer/Engine/AppResolver.swift` (pure logic), `Mixer/Engine/SystemProcessInfo.swift` (real source)
- Test: `MixerTests/AppResolverTests.swift`

**Interfaces:**
- Produces:
  - `struct RunningAppInfo: Equatable, Sendable { let pid: pid_t; let bundleID: String?; let name: String; let bundleURL: URL?; let isRegular: Bool }`
  - `protocol ProcessInfoSource { func runningApp(pid: pid_t) -> RunningAppInfo?; func responsiblePID(for pid: pid_t) -> pid_t?; func parentPID(of pid: pid_t) -> pid_t?; func executablePath(pid: pid_t) -> String? }`
  - `struct AppIdentity: Hashable, Sendable { let key: String; let name: String; let bundleURL: URL?; let ownerPID: pid_t }`
  - `struct AppResolver { init(source: ProcessInfoSource, selfPID: pid_t = getpid()); func resolve(pid: pid_t) -> AppIdentity? /* nil for Mixer itself */ }`
  - `final class SystemProcessInfo: ProcessInfoSource` uses `NSRunningApplication(processIdentifier:)` (`isRegular` = `.regular` policy), `responsibility_get_pid_responsible_for_pid` via `dlsym` (nil if missing), `sysctl KERN_PROC_PID` for the parent, `proc_pidpath` for the path.
- Rules, in order (PLAN §5.2): (1) the pid itself is a regular app → own owner; (2) responsible pid is an app with a `.app` bundle → that; (3) walk parents (max 16, stop at pid ≤ 1) to the first app with a `.app` bundle URL; (4) itself, keyed `path:<executable>` (or `pid:<n>` if there's no path), named by the executable's last path component. Key = owner's bundle ID, else `path:<owner executable>`.

- [ ] **Step 1: Write failing tests** with a `FakeProcessSource` table:
  - `testRegularAppIsItsOwnOwner` (Spotify pid → `com.spotify.client`).
  - `testTerminalLaunchedGameNotFoldedIntoTerminal` (regular game whose parent is Terminal → game's key).
  - `testOOTDmhostIsOneRowWithLauncher`: dmhost pid regular with bundle ID `org.nxnative.0400486024dec000`, parent nxnative with the same ID → both resolve to key `org.nxnative.0400486024dec000`.
  - `testChromeHelperWalksToParent` (helper not regular, no responsible pid, parent Chrome → `com.google.Chrome`).
  - `testWebKitXPCUsesResponsiblePID` (WebContent parent launchd, responsible = Safari → `com.apple.Safari`).
  - `testOpenEmuHelperFoldsIntoOpenEmu`.
  - `testCLIProcessUsesPathKey` (afplay, no app, parent zsh → `path:/usr/bin/afplay`, name `afplay`).
  - `testSelfIsExcluded` (selfPID → nil).
  - `testManyHelpersOneGroup` (10 Chrome helpers → one identical key).
  - `testParentCycleTerminates` (a parent loop doesn't hang).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement `AppResolver` and `SystemProcessInfo`.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: app resolver with general helper folding`.

### Task 4: ProcessMonitor

**Files:**
- Create: `Mixer/Engine/ProcessMonitor.swift`
- Modify: `Mixer/Engine/CoreAudioHelpers.swift` (add `addListener(_ selector:, queue:, block:) -> ListenerToken`, `ListenerToken.cancel()`)

**Interfaces:**
- Consumes: `AppResolver.resolve(pid:)`.
- Produces:
  - `struct AudioProcess: Equatable, Sendable { let objectID: AudioObjectID; let pid: pid_t; let isRunningOutput: Bool }`
  - `struct AppGroup: Equatable, Sendable { let identity: AppIdentity; var processObjects: [AudioObjectID] /* sorted */; var isPlaying: Bool }`
  - `@MainActor final class ProcessMonitor { init(resolver: AppResolver); var onChange: (([AppGroup]) -> Void)?; func start(); func stop(); private(set) var groups: [AppGroup] }`. It listens to `kAudioHardwarePropertyProcessObjectList` and, per process, `kAudioProcessPropertyIsRunningOutput` (listeners added and removed as processes come and go; callbacks hop to main). It also refreshes on `NSWorkspace.didTerminateApplicationNotification`.

- [ ] **Step 1:** Implement (live Core Audio; unit tests covered the logic in Task 3).
- [ ] **Step 2: Live check:** temporary `--list-processes` launch flag logs groups to `~/Library/Logs/Mixer/engine.log` on every change. Start `afplay scripts/out/tone.wav`, then Spotify and Chrome (YouTube) playing. Expected: groups `path:/usr/bin/afplay`, `com.spotify.client`, `com.google.Chrome` with `isPlaying=true`; Chrome is one group; killing afplay removes its group within 1 s.
- [ ] **Step 3:** Commit `feat: process monitor with live grouping`.

### Task 5: ChannelPlanner + RowVisibility (pure policy)

**Files:**
- Create: `Mixer/Engine/ChannelPlanner.swift`
- Test: `MixerTests/ChannelPlannerTests.swift`

**Interfaces:**
- Consumes: `AppGroup`, `AppVolume`.
- Produces:
  - `struct ChannelPlan: Equatable { var create: [String]; var update: [String] /* process list changed */; var destroy: [String] }`
  - `struct ChannelPlanner { static let releaseDelay: TimeInterval = 10; mutating func plan(groups: [AppGroup], volume: (String) -> AppVolume, existing: [String: [AudioObjectID]], permissionGranted: Bool, now: Date) -> ChannelPlan }`. It tracks internally when each key last became `!needsChannel`.
  - `struct RowVisibility { static let linger: TimeInterval = 5; mutating func visibleKeys(groups: [AppGroup], now: Date) -> [String] /* sorted by name */ }`. A key lingers 5 s after `isPlaying` goes false; it's removed immediately when its group disappears.

- [ ] **Step 1: Write failing tests:**
  - `testSavedVolumeCreatesChannelBeforePlaying` (group present, `isPlaying=false`, saved 60 % → create).
  - `testDefaultVolumeNoChannel`.
  - `testPausedAppKeepsChannel` (existing, `isPlaying=false`, 60 % → no destroy).
  - `testQuitDestroysImmediately` (existing key, group gone → destroy).
  - `testReleaseAfterTenSecondsAtDefault` (100 % at t0 → nothing at t0+9, destroy at t0+10; moving back to 60 % at t0+5 cancels).
  - `testMuteCreatesChannel`.
  - `testHelperChangeIsUpdate` (process list differs → update, not destroy+create).
  - `testNoChannelsWithoutPermission` (permission false → create empty; existing → destroy all).
  - RowVisibility: `testRowLingersFiveSeconds`, `testRowRemovedImmediatelyOnQuit`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: channel planner and row visibility policy`.

### Task 6: Channel + CrashGuard + OrphanSweep

**Files:**
- Create: `Mixer/Engine/Channel.swift`, `Mixer/Engine/MixerCrashGuard.c`, `Mixer/Engine/MixerCrashGuard.h`, `Mixer/Engine/OrphanSweep.swift`
- Modify: `Mixer/Engine/Mixer-Bridging-Header.h` (import `MixerCrashGuard.h`)

**Interfaces:**
- Produces:
  - `@MainActor final class Channel { let key: String; init(key: String, processObjects: [AudioObjectID], outputUID: String, gain: Float, visibleForDebug: Bool = false) throws; func setGain(_ gain: Float); func updateProcesses(_ objects: [AudioObjectID]) throws; func move(toOutputUID uid: String) throws; func invalidate(); var callbackCount: UInt64 { get }; var inputPeak: Float { get } }`
    - Create in the spike's order (tap → aggregate → 256-frame buffer → IOProc with `MixerIOProc` → start). Tap name and aggregate name are `Mixer-<key>`. Owns its `MixerChannelState` allocation and frees it only after `AudioDeviceDestroyIOProcID`.
    - `updateProcesses`: set `kAudioTapPropertyDescription` with the edited `CATapDescription`; on failure, build a new tap + aggregate first, start it, then tear down the old one (make-before-break).
    - `move(toOutputUID:)`: a new aggregate with the same tap UUID on the new device, started before the old aggregate is destroyed; fall back to a full rebuild if that fails.
    - `invalidate()`: stop → destroy IOProc → destroy aggregate → destroy tap; idempotent.
  - C: `void MixerCrashGuardInstall(void); void MixerCrashGuardTrack(AudioObjectID aggregate, AudioObjectID tap); void MixerCrashGuardUntrack(AudioObjectID aggregate, AudioObjectID tap);`. A fixed 64-slot static array; the handler for SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP resets to `SIG_DFL`, destroys every tracked aggregate then tap, and re-raises.
  - `enum OrphanSweep { @discardableResult static func run() -> Int }` destroys visible aggregates and taps named `Mixer-*` (logic from `scripts/ca-sweep.swift`).
  - `visibleForDebug` (from the `debugVisibleDevices` UserDefault, Debug builds only) makes the tap and aggregate non-private so they show in Audio MIDI Setup.

- [ ] **Step 1:** Implement.
- [ ] **Step 2: Live check** via a temporary `--channel-pid <pid> --gain <g>` flag. With afplay playing: `callbackCount` grows about 188/s and `inputPeak > 0`. Call `setGain(0)` then `1.0` from a timer: audibly mute, then normal. `invalidate()` with `debugVisibleDevices` on → `scripts/out/ca-list` shows 0 after. `kill -ABRT` with visible devices → the handler leaves 0 visible objects.
- [ ] **Step 3:** Commit `feat: channel with make-before-break, crash guard, orphan sweep`.

### Task 7: AudioEngine (your step 2) + engine verification + OOT test

**Files:**
- Create: `Mixer/Engine/AudioEngine.swift`
- Modify: `Mixer/App/MixerApp.swift` (create the engine at launch: `CrashGuard` install → `OrphanSweep.run()` → permission check → `ProcessMonitor.start()`; `applicationWillTerminate` → `engine.shutdown()`); remove the temporary flags from Tasks 4 and 6 (keep `SpikeTap`, which the crash-test scripts use)
- Test: `MixerTests/AudioEngineTests.swift` (pure parts only: `rows` derivation with an injected monitor feed)

**Interfaces:**
- Consumes: Tasks 2–6.
- Produces:
  - `struct AppRow: Identifiable, Equatable { let id: String /* app key */; let name: String; let bundleURL: URL?; let pid: pid_t; var volume: AppVolume; var isPlaying: Bool; var isPinned: Bool }`
  - `@MainActor @Observable final class AudioEngine { private(set) var rows: [AppRow]; private(set) var permission: AudioCapturePermission.Status; func setPercent(_ p: Int, for key: String); func setMuted(_ m: Bool, for key: String); func toggleMute(for key: String) -> AppVolume; func nudge(_ key: String, by delta: Int) -> AppVolume; func requestPermission(); func shutdown(); var diagnostics: EngineDiagnostics /* channel count, per-channel callbacks/peak */ }`
  - The engine applies a volume by writing the gain to a live channel immediately, saving to `SettingsStore`, then reconciling (create/update/destroy from `ChannelPlanner`). It re-plans on monitor change and on a 1 s timer (release delay, row linger). It holds an `NSProcessInfo` activity (`.userInitiated`, latency-critical) so App Nap can't delay slider and hotkey handling (the spike showed a 1.8 s timer stall).
- [ ] **Step 1:** Write a failing `AudioEngineTests.testRowsFollowVisibilityAndSettings` (fake groups → rows sorted by name with saved volumes and pin flag).
- [ ] **Step 2:** Implement; run tests → PASS.
- [ ] **Step 3: Live verification (PLAN §9 items 1, 3, 5, 6, 10)** with a temporary diagnostics window listing rows plus a slider:
  - Spotify, Chrome, and Music playing: set 30 % / 100 % / muted independently → each is audibly independent; Chrome has 0 channels at 100 %.
  - Quit Spotify → row and channel gone (diagnostics count, and `ca-list` with `debugVisibleDevices`).
  - Quit Mixer → all three play normally.
  - `kill -9` Mixer with a muted app → it comes back (repeat of the phase-1 check, now with the real engine).
  - Safari and one Electron app (Slack or Discord if installed, otherwise Claude) → one row each.
- [ ] **Step 4: OOT test (your request).** Launch with `open --env DM_LAUNCHER=0 ~/Downloads/OOT-main/OOT.app` (skips the launcher window). Expected: one row named "The Legend of Zelda: Ocarina of Time" keyed `org.nxnative.0400486024dec000`; its channel's `inputPeak > 0`. Set 20 %: the game is audibly quieter while Spotify is unchanged. Quit the game, relaunch: the 20 % applies before the first sound (check `engine.log`: channel created before `isPlaying` first becomes true).
- [ ] **Step 5:** Commit `feat: audio engine`, then **first push**: `brew install gitleaks` → `gitleaks detect --source . --no-banner` plus `git grep -nE '(api[_-]?key|secret|token|password|BEGIN [A-Z ]*PRIVATE KEY)'`; if clean, `gh repo create jrotzdesign/mixer --private --source . --push`.

### Task 8: Menu bar UI + brand (your step 3)

**Files:**
- Create: `Mixer/UI/Theme.swift`, `Mixer/UI/MenuBarView.swift`, `Mixer/UI/AppRowView.swift`, `Mixer/UI/MasterRowView.swift`, `Mixer/UI/VolumeSlider.swift`, `Mixer/UI/FirstRunView.swift`, `Mixer/Resources/Fonts/` (Figtree, DM Mono, Bricolage Grotesque TTFs from the google/fonts repo, OFL, with license files)
- Modify: `Mixer/Resources/Info.plist` (`ATSApplicationFontsPath` = `Fonts`), `Mixer/App/MixerApp.swift` (`MenuBarExtra(.window)` hosting `MenuBarView`; first-run window when the permission isn't granted)

**Interfaces:**
- Consumes: `AudioEngine`, `AppRow`, and `DeviceMonitor` for the master row (Task 9; until then the master row is hidden).
- Produces: `struct VolumeSlider: View { @Binding var percent: Int; var max: Int = 150; var muted: Bool }`. It snaps to 100 within ±2, double-click resets to 100, has a tick at 100, fills teal up to min(percent, 100) and rosa from 100 to percent.
- Layout as in PLAN §5.9: 300 pt wide, 12 pt padding, 10 pt row gap, 28 pt icons, DM Mono caps header `MIXER · N APPS PLAYING`, percent in DM Mono, mute button (rosa icon when muted), a pin button on hover, footer with Settings and Quit. Popover material background. Empty state: "Nothing's playing." Permission banner with "Open System Settings" (`x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`).
- Diagnostics: holding ⌥ while opening the popover shows a footer section with the live channel count, each channel's callbacks/s and peak, and (Debug builds) a "Crash Mixer (abort)" button for verify item 6. This replaces the temporary diagnostics window from Task 7.
- First-run copy (exact): headline "Every app, its own volume." (teal period, Bricolage); body "macOS calls this permission "System Audio Recording." Mixer uses it to route each app's sound through itself so it can change the volume, then plays it straight back. Nothing is recorded, saved, or sent anywhere."; button "Continue".
- [ ] **Step 1:** Write a failing `VolumeSliderTests.testSnapAndClamp` (a pure helper `VolumeSlider.snapped(_ raw: Double) -> Int`: 98.5 → 100, 103 → 103, −4 → 0, 160 → 150).
- [ ] **Step 2:** Implement; tests PASS.
- [ ] **Step 3: Live check:** screenshot the popover in light and dark mode (`screencapture -l <window id>`) and check against the tokens; dragging a slider changes audio with no audible lag.
- [ ] **Step 4:** Commit `feat: menu bar UI with JRO tokens`.

### Task 9: Device following + master volume (your step 5)

**Files:**
- Create: `Mixer/Engine/DeviceMonitor.swift`
- Modify: `Mixer/Engine/AudioEngine.swift`, `Mixer/UI/MasterRowView.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class DeviceMonitor { private(set) var defaultOutputUID: String; private(set) var defaultOutputName: String; private(set) var masterPercent: Int?; private(set) var masterMuted: Bool; func setMaster(percent: Int); func setMasterMuted(_ m: Bool); var onDefaultOutputChange: ((String) -> Void)?; var onServiceRestart: (() -> Void)? }`. It listens to `kAudioHardwarePropertyDefaultOutputDevice`, `kAudioHardwarePropertyServiceRestarted`, `NSWorkspace.didWakeNotification`, and on the current device `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` + `kAudioDevicePropertyMute` (output scope). `masterPercent == nil` means no software volume (the master slider is disabled).
- Engine: on an output change → `channel.move(toOutputUID:)` for every channel; on a restart or wake → invalidate everything, `OrphanSweep.run()`, re-plan from scratch. On a tap format change (sample rate) → rebuild that channel make-before-break.
- [ ] **Step 1:** Implement.
- [ ] **Step 2: Live check (PLAN §9 item 4)**: with Spotify at 40 % and Chrome muted, switch the default output programmatically between "Nando airpods" and "MacBook Pro Speakers" 5 times (`kAudioHardwarePropertyDefaultOutputDevice` write from a small script). Expected: audio follows each switch, Chrome stays silent throughout, the channel count stays 1–2 (no leaks), and the output is restored to the original device at the end. Then you switch by hand with AirPods mid-song.
- [ ] **Step 3:** Commit `feat: follow default output, master volume`.

### Task 10: Global shortcuts + HUD

**Files:**
- Modify: `project.yml` (SPM package `KeyboardShortcuts`, from `https://github.com/sindresorhus/KeyboardShortcuts`, latest 2.x tag at least two weeks old)
- Create: `Mixer/Hotkeys/HotkeyController.swift`, `Mixer/Hotkeys/TargetResolver.swift`, `Mixer/HUD/HUDPanel.swift`, `Mixer/HUD/HUDView.swift`
- Test: `MixerTests/TargetResolverTests.swift`

**Interfaces:**
- Produces:
  - `extension KeyboardShortcuts.Name { static let frontmostUp, frontmostDown, pinnedUp, pinnedDown, frontmostMute }` with the global-constraint defaults.
  - `struct TargetResolver { func frontmostKey(frontmostPID: pid_t?, resolver: AppResolver) -> AppIdentity?; func pinnedKey(store: SettingsStore) -> String? }`
  - `@MainActor final class HUDPanel { func show(icon: NSImage?, name: String, volume: AppVolume) }`: a non-activating borderless `NSPanel`, `level = .screenSaver`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `ignoresMouseEvents = true`, centered in the lower third of the screen with the key window, about 220×220, night background at 85 %, teal level bar (rosa above 100), DM Mono percent or "MUTED". Shown with `orderFrontRegardless()` (never `makeKey`); fades in over 0.12 s and out over 0.4 s after 1.2 s, and repeated shows reset the timer.
  - `HotkeyController` maps each shortcut → `engine.nudge` / `toggleMute` → `hud.show`. A frontmost app that isn't playing still gets its saved volume changed.
- [ ] **Step 1: Write failing tests:** `testFrontmostResolvesThroughResolver` (dmhost pid → OOT key), `testFrontmostSelfIgnored` (Mixer frontmost → nil), `testPinnedKeyFromStore`.
- [ ] **Step 2:** Implement; tests PASS.
- [ ] **Step 3: Live check (PLAN §9 item 8)**: OOT in full screen and focused; press each shortcut. Expected: the volume changes, the HUD shows over the game, the game keeps focus (check `NSWorkspace.frontmostApplication` is still dmhost), and the game doesn't react to the keys. Your hands-on run with the game confirms it.
- [ ] **Step 4:** Commit `feat: global shortcuts and HUD`.

### Task 11: Settings window + launch at login + pin (your step 6)

**Files:**
- Create: `Mixer/UI/SettingsView.swift`
- Modify: `Mixer/App/MixerApp.swift` (`Settings` scene), `Mixer/UI/AppRowView.swift` (pin toggle writes `SettingsStore.pinnedAppKey`)

**Interfaces:**
- Settings contents: "Launch at login" toggle (`SMAppService.mainApp.register()/unregister()`, state read from `.status`); five `KeyboardShortcuts.Recorder`s; a pinned-app picker (from recent rows plus the current pin); "Reset saved volumes" button; a Debug-only "Show Mixer devices in Audio MIDI Setup" toggle.
- [ ] **Step 1:** Implement.
- [ ] **Step 2: Live check:** turn on launch at login → `SMAppService.mainApp.status == .enabled` and Mixer appears in System Settings → General → Login Items; turn off → removed. (A reboot check is left to you.)
- [ ] **Step 3:** Commit `feat: settings, launch at login, pin`.

### Task 12: Review, verify, report

- [ ] **Step 1:** Run `/code-review` on the branch; fix confirmed findings (with a test where it's logic).
- [ ] **Step 2:** Run `/simplify`; apply what's real.
- [ ] **Step 3:** Full test suite PASS; full PLAN §9 verify list, noting which items you need to run hands-on (7, 8, 9 with OOT; 11 with a reboot).
- [ ] **Step 4:** Secret scan (gitleaks + grep) → push.
- [ ] **Step 5:** Report: done / what to test / known limits / files moved to `_to_delete/`.
