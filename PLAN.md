# Mixer: Plan

A native macOS menu bar app with a volume slider and mute button for every app that's playing audio.

Status: **waiting for "go"**. No code exists yet.

---

## 1. Why this exists

The moment that started it: a stream playing in Chrome while Ocarina of Time runs in an emulator, with no way to turn the game down without also turning the stream down. The main job is **a game and a stream at the same time, each with its own volume, adjustable without leaving the game.**

Success looks like this:
- Two sliders, one per app. Moving either one changes the sound right away.
- No crackle, no lag, no audio drop.
- Global shortcuts that work while the game has keyboard focus, with a small on-screen popup showing the new level.
- Set a game's volume once and it comes back that way the next time the game starts, before it makes any sound.

## 2. Goals, non-goals, anti-goals

**Goals**
- Per-app volume (0–150%) and mute for every app playing audio, including games and emulators (SDL, OpenAL, Core Audio), browsers, and Electron apps.
- Helper processes are grouped under the app that owns them: Chrome, Safari/WebKit, Discord, Slack, OpenEmu, and so on.
- Global shortcuts: frontmost app up/down, pinned app up/down, and mute/unmute for the frontmost app. Each one shows a popup in the style of the macOS volume indicator, including over full-screen games.
- Volumes are remembered by bundle ID and applied the moment an app's audio starts.
- Audio follows output device changes (AirPods, speakers, HDMI) without dropping out.
- Launch at login.
- Crash safety: if Mixer crashes or is force-quit, every app's audio comes back on its own.

**Non-goals (v1)**
- Per-tab browser volume. The OS only sees one stream per browser.
- Sending different apps to different output devices.
- EQ, audio effects, level meters, recording.
- The App Store, notarization, other users, Intel Macs.

**Anti-goals (any of these makes it a failure, even if everything else works)**
- Any app left silent after Mixer quits, crashes, or is force-quit.
- Audible lag, crackle, or a lower-quality sound compared with normal playback.
- Shortcuts that don't fire while a game has focus, or a popup that steals focus from the game.
- A game blasting at full volume when it was saved at 20%.

## 3. Constraints

- macOS 14.2+ as the deployment target. **Only tested on this Mac (macOS 27.2, Xcode 27.2).**
- Swift + SwiftUI. An Xcode project generated with **xcodegen** from `project.yml` (installed). The generated `.xcodeproj` is committed so it opens directly in Xcode.
- Core Audio process taps only. No virtual audio driver, no kernel extension.
- Signed with a free Apple ID (Personal Team). Not sandboxed (personal use; it uses two private Apple functions, listed in §6).
- Folder `~/Projects/mixer`. Private GitHub repo `jrotzdesign/mixer`.
- Rules: never delete files (move them to `_to_delete/` and list them); scan for keys and tokens before every push; run /code-review and /simplify once the engine works.

**Prerequisite (you, one time):** This Mac has no code-signing identity yet. In Xcode → Settings → Accounts, add your Apple ID. That creates the free "Personal Team" certificate. Without it the app can still be signed to run locally, but macOS would then ask for the audio permission again after every rebuild.

## 4. References: what I'm borrowing

I read the source of each of these. Patterns only: **no code is copied**, which matters for the GPL and AGPL projects.

| Project | License | What I'm borrowing as a pattern |
|---|---|---|
| [insidegui/AudioCap](https://github.com/insidegui/AudioCap) (Apple-sample-style reference, 512★) | BSD-2 | The core recipe: `CATapDescription(stereoMixdownOfProcesses:)` → `AudioHardwareCreateProcessTap` → private aggregate device with the output as main sub-device, the tap in `TapList` with drift compensation, and `TapAutoStart` → IOProc. Teardown order (stop → destroy IOProc → destroy aggregate → destroy tap). Permission check and request through the TCC preflight/request functions (`kTCCServiceAudioCapture`). One fix: AudioCap uses the *system alert* output device; Mixer will use the *default* output device. |
| [ronitsingh10/FineTune](https://github.com/ronitsingh10/FineTune) (the most-used open-source mixer, 10k★) | GPL-3 | **Helper folding:** `responsibility_get_pid_responsible_for_pid` (the function Activity Monitor uses for XPC helpers like Safari's WebKit processes), falling back to walking parent PIDs up to the first real `.app`. **Crash guard:** a signal handler that destroys the tracked aggregate devices from a fixed C buffer on SIGABRT, SIGSEGV, and SIGBUS. **Orphan sweep** at launch for name-prefixed devices. A soft limiter for boost. Global shortcuts through the KeyboardShortcuts library. |
| [pharaujo/audiocontrol](https://github.com/pharaujo/audiocontrol) | MIT | **Only tap apps that need it:** apps at 100% and unmuted get no tap, so they have zero added latency. **Make-before-break:** build the replacement tap or device before destroying the old one, so a muted app never bursts through during a device switch or helper change. Its "known limits" section was a useful list of what to test (for example, a new helper process playing unadjusted for about 50–200 ms). |
| [aaronzzheng/VolBoost](https://github.com/aaronzzheng/VolBoost) | none stated | Warning I'm acting on: when the permission is denied, creating a tap can still *succeed* but deliver silence. Combined with "mute the original," that would silence the app. So Mixer never creates a muting tap until the permission is confirmed. |
| [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | MIT | **Used as a dependency** (the only one). It uses Carbon `RegisterEventHotKey`, which fires even when another app (the game) is frontmost and needs no Accessibility permission. It also comes with a shortcut recorder for Settings. |

Also checked: cyc115/dB and altuzar/sonicflow (MIT, same core recipe), and the macOS 26 `CATapDescription.bundleIDs` / process-restore API (taps that attach by bundle ID before a process exists). I'm **not** using the bundle-ID API in v1: it's barely documented and needs a separate code path for macOS 26+. I've noted it as a possible later fix for the first-buffer gap (§11).

## 5. How it works

### 5.1 Pieces

```
MixerApp (SwiftUI, menu bar only: LSUIElement)
├── AudioEngine         owns every channel; reacts to process and device changes
│   ├── ProcessMonitor   lists audio processes, watches IsRunningOutput, groups helpers
│   ├── AppResolver      PID → owning app (bundle ID, name, icon), with helper folding
│   ├── Channel          one per adjusted app: tap + private aggregate + IOProc
│   ├── DeviceMonitor    default-output changes, volume of the output device
│   └── CrashGuard       signal handler + launch-time orphan sweep
├── MixerDSP.c           the real-time gain/ramp/limiter function (plain C)
├── SettingsStore        saved volume/mute by app key, pinned app, preferences
├── HotkeyController     KeyboardShortcuts bindings → engine actions → HUD
├── HUDWindow            non-activating panel above full-screen apps
└── Views                popover, rows, master, first-run, settings
```

### 5.2 Finding apps and grouping helpers

- Read `kAudioHardwarePropertyProcessObjectList` and listen for changes to it. Also listen to `kAudioProcessPropertyIsRunningOutput` on each process.
- For each process, read its PID and bundle ID, then **resolve its owning app**:
  1. If the process is itself a regular app (`NSRunningApplication` with `.regular` activation policy), it is its own owner. This rule comes first so that a game launched from Terminal isn't folded into Terminal.
  2. Otherwise use the responsible-PID function (covers Safari/WebKit XPC and other XPC services).
  3. Otherwise walk parent PIDs to the first `.app` bundle (covers Chrome, Electron, OpenEmu's `OpenEmuHelperApp`).
  4. Otherwise keep it as its own row, named by its executable.
- **App key** (for saved settings): bundle ID if there is one, otherwise `path:<executable path>`. Name and icon come from `NSRunningApplication`, falling back to the bundle on disk, then the executable name with a generic icon.
- Mixer's own process is never listed or tapped.

### 5.3 Channels (one per adjusted app)

- **When a channel exists:** an app gets a channel when its volume isn't 100% or it's muted. That includes saved settings: an app saved at 60% gets its channel **as soon as its process appears in the list**, which is normally when it sets up audio and before it plays anything. This covers requirement 6. Apps at 100% and unmuted are never tapped, so they get zero added latency.
- **What a channel is:** one `CATapDescription` that mixes **all of the app's processes** (the app plus its helpers) down to stereo, with `muteBehavior = .mutedWhenTapped`, `isPrivate = true`, named `Mixer-<appkey>`. Then one private aggregate device: main sub-device = current default output, tap attached with drift compensation, auto-start on. Then one IOProc.
- **Helper joins or leaves:** update the tap's process list in place (`kAudioTapPropertyDescription`). If macOS rejects that, rebuild make-before-break.
- **Teardown:** when the app quits (process objects gone or `NSWorkspace` terminate notification) → stop, destroy IOProc, destroy aggregate, destroy tap. When the user brings the slider back to 100% and unmutes, release after 10 seconds, so a quick drag through 100% doesn't cause a gap.
- **Change from your brief:** the brief says to tear the tap down when the app *stops* playing. I'd keep it alive while the app is paused, because tearing it down on pause means that on resume the app plays at full volume until the tap is rebuilt. That's exactly the "game blasts at full volume" failure. Open question 2 (§12).

### 5.4 The real-time audio path

- The IOProc is a plain C function (`MixerDSP.c`), registered with `AudioDeviceCreateIOProcID` and given a context pointer. No Swift, no allocation, no locks, no Objective-C on the audio thread.
- **Gain:** the UI writes a target gain into an atomic float. Each buffer ramps linearly from the last gain to the target, so changes land within one buffer (about 5 ms) with no zipper noise or clicks.
- **Taper:** `gain = (percent/100)²`, so the slider feels even to the ear (50% ≈ half as loud). 150% = 2.25× (+7 dB). This is my call and easy to tune.
- **Boost safety:** above 100%, a soft limiter (knee at about −1 dBFS) keeps boosted audio from clipping and crackling. At 100% or below, the samples are only multiplied.
- **Latency:** ask for a 256-frame IO buffer on the aggregate (about 5 ms at 48 kHz). Expected total added latency is about 10–15 ms, and only for adjusted apps. If 256 frames crackles under load, go to 512.
- **Channels:** stereo tap → the first two channels of the output, which handles HDMI and multichannel devices.

### 5.5 Following output device changes

- Listen to `kAudioHardwarePropertyDefaultOutputDevice` (and to the device dying or disappearing).
- On a change, **make-before-break** for each channel: build a new aggregate on the new device using the *same tap*, start it, then stop and destroy the old one. If one tap can't be shared by two aggregates, build a full new channel first, then destroy the old one. Both are muted taps, so the app never bursts through at full volume.
- Handle sample-rate changes (AirPods move between 48 kHz and lower rates when a mic is in use) by reading the tap format again and rebuilding the channel.
- On a Core Audio restart (`kAudioHardwarePropertyServiceRestarted`) or wake from sleep, rebuild every channel from saved state.

### 5.6 Crash safety (layered)

1. **Private objects:** private taps and private aggregates belong to Mixer's process, and Core Audio should tear them down when that process dies, including `kill -9`. **This is the first thing I test (phase 1)**, before building on top of it.
2. **Crash signal handler** (FineTune pattern): on SIGABRT, SIGSEGV, SIGBUS, SIGILL, or SIGTRAP, destroy every tracked aggregate and tap from a fixed C buffer, then re-raise the signal.
3. **Normal quit:** tear everything down in `applicationWillTerminate`.
4. **Launch sweep:** destroy any leftover `Mixer-*` devices or taps before creating new ones.
5. **Backup plan if (1) fails the `kill -9` test:** switch to named, non-private objects plus a tiny LaunchAgent watchdog that sweeps them when Mixer's PID disappears. I'll tell you if this is needed.

### 5.7 Permission ("System Audio Recording Only")

- `NSAudioCaptureUsageDescription`: "Mixer routes each app's sound through itself so it can change that app's volume. Nothing is recorded, saved, or sent anywhere."
- **First run:** a small window explains in plain words why macOS calls this "recording," what Mixer does with the audio (changes its volume and plays it straight back), and that nothing leaves the Mac. A "Continue" button triggers the system prompt.
- Check at every launch with the TCC preflight function. If the permission is denied or was revoked: create **no** muting taps, and show a banner in the popover with an "Open System Settings" button that goes straight to the right privacy pane. Sliders can still be changed and saved; they apply once the permission is granted.

### 5.8 Shortcuts and the on-screen popup

- Shortcuts use KeyboardShortcuts (Carbon hotkeys), so they fire while a game or emulator has focus, need no Accessibility permission, and the game never sees the key.
- **Defaults** (my call, you can change them in Settings):
  - Frontmost app: `⌃⌥↑` / `⌃⌥↓` (±5%)
  - Pinned app: `⌃⌥⇧↑` / `⌃⌥⇧↓` (±5%)
  - Mute/unmute frontmost app: `⌃⌥M`
- **Frontmost app** = `NSWorkspace.frontmostApplication`, resolved to its app key. If it isn't playing yet, the shortcut still changes and saves its volume, which is another way to set a game quieter ahead of time.
- **Pinned app:** chosen once from a pin button on any row (or in Settings), saved by app key, so it survives relaunches of both apps.
- **Popup:** a non-activating `NSPanel` (never takes focus), floating above full-screen Spaces (`.canJoinAllSpaces`, `.fullScreenAuxiliary`, high window level), ignores the mouse. It shows the app icon, name, a level bar, and the percentage (or "Muted"), then fades out after about 1.2 s. Repeated presses update it in place.

### 5.9 Menu bar popover

```
┌───────────────────────────────────┐
│ MIXER · 3 APPS PLAYING            │  ← mono label
│ 🔈 ━━━━━━━━━━━━━━━━○━━━━  72%   🔇│  ← master (output device volume)
│───────────────────────────────────│
│ [icon] Ship / OpenEmu         📌  │
│        ━━━━━━○━━━━━━━━  40%   🔇  │
│ [icon] Google Chrome              │
│        ━━━━━━━━━━━━○━━  100%  🔇  │
│ [icon] Spotify                    │
│        ━━━━━━━━━━━━━━━━┃━○ 130% 🔇│  ← past 100% the bar turns rosa
│───────────────────────────────────│
│ ⚙ Settings                 Quit   │
└───────────────────────────────────┘
```

- **Master slider = the output device's own volume** (the same one the keyboard volume keys move). My call: it's native and adds no taps. If a device has no software volume (some HDMI), the master slider is shown disabled with a short note.
- Rows show apps that are playing now. After an app stops, its row stays for 5 seconds so it doesn't flicker between tracks, then hides. A quit app's row goes away right away.
- The slider has a small tick at 100% and snaps there (±2%) so getting back to normal is easy. Double-click resets to 100%. Hovering a row shows the pin button.
- **Settings window:** Launch at login (`SMAppService.mainApp`), shortcut recorders, pinned app, "Reset saved volumes."

### 5.10 Design (JRO brand, adapted for a native utility)

Tokens confirmed from the jrortizdesign.com stylesheet:

| Token | Value | Used for |
|---|---|---|
| accent (JRO teal) | `#29A191` | slider fill, active toggles, the pin when on. One accent per view. |
| rosa | `#E4007C` | only as a pop: the part of a slider above 100% (boost) and the muted icon |
| ink / night | `#121316` / `#0E0F12` | text on light / HUD background in dark |
| ink-2 | `#55585F` | secondary text on light |
| bone / bone-2 | `#F2F3F0` / `#E6E7E3` | text on dark / light surfaces |
| line | ink at 12% (paper at 15% on dark) | thin dividers |
| ease | `cubic-bezier(.22,1,.36,1)` | HUD fade, row in/out |

- **Background:** the native popover material (light and dark follow the system), so it feels like part of macOS. Brand colors go on top.
- **Type:** Figtree for app names and body text, DM Mono in caps with wide tracking for labels and percentages ("MIXER · 3 APPS PLAYING", "72%"). Bricolage Grotesque only on the first-run headline ("Every app, its own volume." with a teal period). All three are open-source Google Fonts, bundled in the app.
- **Spacing:** a 4-pt grid. 12-pt padding, 10-pt between rows, 28-pt app icons, 300-pt popover width.
- **Motion:** rows fade and slide in, staggered. The HUD fades in quickly and out slowly. Nothing bounces.

## 6. Private API use (personal build only)

- `responsibility_get_pid_responsible_for_pid` (looked up with `dlsym`) for helper folding. Falls back to parent-PID walking if it's missing.
- `TCCAccessPreflight` / `TCCAccessRequest` (with `dlopen` on TCC.framework) for permission checks, the same as AudioCap. Falls back to letting the first tap trigger the prompt.

Both are why the app isn't sandboxed and couldn't ship in the App Store, which is fine for personal use.

## 7. Build phases

Each phase ends with something you can run.

| # | Phase | Covers | Ends with |
|---|---|---|---|
| 0 | Project setup | folder, git, xcodegen project, signing, Info.plist, fonts, private repo | Empty menu bar app that launches and is signed |
| 1 | **Engine spike** | One tap on one app at a fixed 30% gain, played to the default output. **Test `kill -9` crash safety here.** | Proof that the core recipe and crash cleanup work on this Mac |
| 2 | Audio engine | ProcessMonitor, AppResolver/helper folding, Channel lifecycle, C DSP (ramp, taper, limiter), permission gate, CrashGuard, orphan sweep | Engine driven by a debug list: apps appear and disappear, volume and mute work |
| 3 | Menu bar UI | popover, rows, master, first-run window, brand tokens | Your step 3 |
| 4 | Memory | SettingsStore, apply saved volume at process appear | Your step 4 |
| 5 | Device switching | DeviceMonitor, make-before-break, sample-rate rebuild, wake/restart rebuild | Your step 5 |
| 6 | Shortcuts + HUD | KeyboardShortcuts, frontmost/pinned resolution, HUD panel | Shortcuts work with a game focused |
| 7 | Launch at login + Settings | SMAppService, Settings window | Your step 6 |
| 8 | Review | /code-review, then /simplify, fix what's real, full verify pass | Report |

After "go," I'll turn this into a task-by-task build list and work straight through it, stopping only if something blocks.

## 8. Testing

- **Unit tests (XCTest)** for the logic that doesn't need live audio: helper-folding resolver (with fake process tables: Chrome, Safari/WebKit, Electron, OpenEmu, a Terminal-launched game), app-key fallback, taper and limiter math, ramp math (the C DSP is called directly on test buffers), settings store, shortcut target resolution, the "does this app need a channel" rule.
- **Live checks** (I run what I can from here, using `afplay`/`say` and real apps through Spotify and Chrome): channel create and destroy counts, a diagnostics menu item (hold ⌥ while opening the popover) showing live taps and aggregates, and a debug build flag that makes aggregates *visible* in Audio MIDI Setup. Private ones never show there, so "nothing left in Audio MIDI Setup" can only be checked with that flag on.

## 9. Verify list (done means all of these pass)

1. Spotify, Chrome, and Music playing at once, each with independent volume and mute.
2. No crackling or noticeable delay compared with normal playback (adjusted apps get about 10–15 ms; apps at 100% get none).
3. Quitting an app removes its row immediately, with no leaked taps or aggregates (diagnostics count, plus Audio MIDI Setup with the debug flag).
4. Switching to AirPods mid-playback keeps working at the same levels, and a muted app stays silent through the switch.
5. Quitting Mixer gives every app normal audio back.
6. **Crash safety:** `kill -9` on Mixer, and a forced crash from a debug menu item: every app's audio comes back on its own.
7. **Games:** OoT in your emulator plus a Chrome stream, independent volumes. Sliders respond immediately while playing.
8. **Shortcuts with the game focused:** frontmost, pinned, and mute keys all fire. The game never sees the keys, and the popup shows over the full-screen game without taking focus.
9. **Pre-set volume:** set the game to 20%, quit it, relaunch: no full-volume first sound (beyond the first-buffer limit in §11).
10. **Helper folding:** Chrome, Safari, Discord or Slack, and OpenEmu each show as one row.
11. Launch at login turns on and off and survives a reboot.

Items 7–9 need you at the keyboard with the game. I'll prepare exact steps.

## 10. Repo hygiene

- `.gitignore` for Xcode (DerivedData, xcuserdata, build products).
- **Before every push:** a secret scan with gitleaks (install via Homebrew; it isn't installed now), plus a grep for common key and token patterns. The push stops if anything is found.
- Never delete: anything removed goes to `_to_delete/`, listed in the final report.
- Commits end with the Claude co-author line.

## 11. Known limits (expected)

- **First buffer of a brand-new process:** Core Audio can't tap a process before it registers with the audio system. A saved volume applies as the process registers, which is normally before it plays, but a helper that spawns *and* plays in the same instant can be heard unadjusted for about 50–200 ms. The macOS 26 bundle-ID tap API could close this later.
- **Added latency** of about 10–15 ms for adjusted apps (none at 100%). AirPods add their own Bluetooth delay as always.
- **Short gap** (a few ms) the first time an app moves off 100%, while its tap starts.
- **Games that take over the display in "exclusive" full-screen mode** (rare on modern macOS; some older SDL builds) may draw over the popup. Shortcuts still work.
- Apps that choose their own output device (DAWs, some games) get moved to the default output while adjusted.
- Safari/WebKit helper processes may be shared between Safari and other WebKit apps. If the responsible-PID lookup can't tell them apart, they show as one row.
- Personal Team signing: macOS may ask for the audio permission again if the signing certificate changes.
- Tested only on macOS 27.2.

## 12. Decisions (answered 2026-11-11)

1. **OoT = `~/Downloads/OOT-main/OOT.app`**, launched by double-click. What I found by inspecting the bundle:
   - Bundle ID `org.nxnative.0400486024dec000`, display name "The Legend of Zelda: Ocarina of Time", signed ad hoc.
   - **Two processes.** `nxnative` (the bundle's main executable) is a small SwiftUI launcher with a settings window. It `posix_spawn`s `Contents/MacOS/dmhost`, the actual game host.
   - **`dmhost` makes the sound**, through AudioToolbox's AudioUnit output (`AudioComponentInstanceNew` → `AudioOutputUnitStart`, plus an `AudioConverter`). **Not SDL, not OpenAL.** It's plain Core Audio, so a process tap catches it like any other app.
   - `dmhost` makes itself a regular app (`setActivationPolicy:`) and uses native macOS full screen (`toggleFullScreen:`), so the full-screen popup approach (`.fullScreenAuxiliary`) applies. It reads the keyboard through normal app key events (`keyCode`/`modifierFlags`) and controllers through GameController/IOHID. A shortcut taken by a Carbon hotkey never reaches it.
   - For Mixer: `dmhost` lives inside the bundle, so it reports the same bundle ID. Rule 1 in §5.2 (a regular app is its own owner) gives one row, keyed by `org.nxnative.0400486024dec000`, whether or not `nxnative` stays alive. I'll confirm this with the game running.
2. **Keep taps through pauses: yes.** An adjusted app keeps its tap until it quits (or sits at 100% and unmuted for 10 s).
3. **Apps at 100% skip Mixer: yes.**
4. **Shortcut clash check:** there's no `~/.hammerspoon` (Hammerspoon isn't installed). None of the 20 macOS system shortcuts use `⌃⌥`, there are no custom app key equivalents, and no hotkey utilities are installed (Raycast, Alfred, Rectangle, BetterTouchTool, Karabiner, skhd, and others checked). The only custom LaunchAgent is `com.jro.text-scrubber`, a Node server with no global hotkeys. **The `⌃⌥` defaults stand** and stay rebindable in Settings.
5. **FineTune (GPL):** patterns only, no copied code.

**Build order change:** phase 1 (the force-quit cleanup test) runs and gets reported **before** anything else in the engine is built.

## 13. Calls I made (check these)

- xcodegen for the project, with the generated `.xcodeproj` committed.
- Master slider = output device volume, not a multiplier over all apps.
- Taper `(percent/100)²`; 150% = 2.25× with a soft limiter.
- Default shortcuts `⌃⌥↑/↓`, `⌃⌥⇧↑/↓`, `⌃⌥M`, with 5% steps.
- Rows linger 5 s after audio stops; taps release 10 s after returning to 100% and unmuted.
- IO callback in plain C for real-time safety.
- Not sandboxed; two private functions, with fallbacks.
- No macOS 26 bundle-ID taps in v1.
- Native popover material with JRO tokens on top; Figtree / DM Mono / Bricolage bundled.
- Bundle ID `com.jrortizdesign.mixer`.
