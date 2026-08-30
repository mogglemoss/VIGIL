# observance spike

Not the app. A throwaway that answers four questions, so we don't build the
real thing on top of an assumption:

1. Can ScreenCaptureKit pull the display at 60 fps while EVE is fullscreen,
   without costing EVE frames?
2. Does a Core Audio process tap actually produce non-zero samples?
3. Do tap timestamps line up with ScreenCaptureKit frame timestamps?
4. Does a Carbon hotkey fire while EVE holds fullscreen focus?

There is no ring buffer, no menu bar, no UI. Those are v1, and they are only
worth building if the answers here are yes.

## Build

```
./bundle.sh
```

Produces `.build/Observance Spike.app`, signed with your Apple Development
identity. That signature matters: TCC grants are keyed to it, so an ad-hoc
signature would re-prompt on every rebuild.

## Run

Launch the inner binary directly, so stdout lands in your terminal. TCC still
attributes to the bundle.

```
'.build/Observance Spike.app/Contents/MacOS/spike' --help
```

**First, prove the audio grant on its own.** Play anything, then:

```
'.build/Observance Spike.app/Contents/MacOS/spike' --check --audio all
```

A denied System Audio Recording grant is invisible — every Core Audio call
returns `noErr` and the buffers are zeros. `--check` is the only honest test.
If it reports `-inf`, answer the prompt, or `tccutil reset AudioCapture
app.observance.spike` and rerun.

**If nothing matches, look before guessing.**

```
'.build/Observance Spike.app/Contents/MacOS/spike' --list
```

**Then the real run.** Undock first — a process only enters the tap once it has
opened an output stream, so a silent docked client will not be found.

```
'.build/Observance Spike.app/Contents/MacOS/spike' --audio game
'.build/Observance Spike.app/Contents/MacOS/spike' --audio EVE.app,com.hnc.Discord
'.build/Observance Spike.app/Contents/MacOS/spike' --audio all --codec h264
```

### Naming processes is harder than it looks

Two things that cost an hour and will cost you another one if you forget them:

- **Electron apps never play audio from their main bundle.** Discord's sound
  comes out of `com.hnc.Discord.helper`. So bundle IDs match as prefixes.
- **EVE's client reports no bundle ID at all.** It runs as `exefile`, out of
  `…/SharedCache/tq/EVE.app`, and Core Audio has no bundle for it. So a name
  also matches an executable name or a path fragment, and `--audio game` means
  the path fragment `EVE.app` rather than `com.ccpgames.eveonline`.

That second one has a v1 consequence: `CATapDescription.processRestoreEnabled`
saves tapped processes **by bundle ID**, so it will re-attach Discord after a
restart and will never re-attach EVE. The real app needs its own relaunch
watcher for the game.

Go fly. Press **Option-Command-S** whenever anything happens — that is the
hotkey reliability test, not a convenience. `⌥` is Option, not Shift.
**Option-Command-Q** stops and prints the verdict.

You should see a panel at the bottom of the screen: `● RECORDING` on start,
`◆ MARKER n` on each press, `■ SAVED` on stop. If `● RECORDING` never appears,
stop and say so — that is a different problem from the hotkey not firing, and
the two are indistinguishable without it.

If the overlay is invisible while EVE is fullscreen but visible on the desktop,
EVE is using exclusive fullscreen and has the display captured. No window can
draw above that. Switch EVE to **Windowed** in its display settings — which is
what you want for a recorder anyway.

Watch **EVE's** frame rate while this runs. That is the measurement. The numbers
this prints only tell you whether the capture kept up, not whether it cost you
the fight.

## Measured against a live EVE client (2026-08-30)

EVE undocked, in space, sound on, Discord running.

```
capture   3024×1964 @ 60   ·   1261 frames   ·   57.57 fps avg   ·   0 dropped
audio     1885 buffers     ·   peak -29.0 dBFS ·   0 dropped
sync      max |drift| 37.5 ms, consistently NEGATIVE
file      2 tracks, both populated, 21.9 s video / 20.1 s audio
```

Three of the four questions answer yes. The fourth — does `⌥⌘S` fire while EVE
holds fullscreen focus — has to be pressed by a human and is still open.

Two things to watch:

- **57.5, not 60.** Consistent — identical on an idle desktop and against a
  live client, which points at `minimumFrameInterval` scheduling rather than a
  shortfall. The number that matters is whether *EVE* drops frames, not this
  one, and only a human watching the client can say.
- **The bitrate ceiling was never reached.** 6 Mbps against a 28.5 Mbps target,
  because a ship sitting in space compresses to almost nothing. A real fight
  will run far closer to the cap — size the ring against the cap, not against
  this measurement.
- **The drift is a constant, not noise.** Every sample is negative, roughly
  -20 to -37 ms — the tap's IOProc buffer and aggregate-device latency. It sits
  inside the acceptable window so the spike passes it, but v1 should measure the
  offset once and subtract it rather than shipping a systematic 25 ms audio lag.
  Do not add a fudge factor before the EVE run; the number may move under load.

## Choices worth knowing about

- **Native resolution by default** (`--scale 1.0`). It is the performance worst
  case, which is what a spike should measure, and it is the best source material
  for an editor. `--scale 0.75` is the fallback if capture cannot keep up.
  Note `SCDisplay.width`/`height` are **points**, not pixels — multiplying by
  `SCContentFilter.pointPixelScale` is what gets you the real 3024×1964. Asking
  for `display.width` directly captures quarter resolution and looks fine.
- **HEVC by default**, `--codec h264` if your editor is unhappy with HEVC.
- **1-second keyframes, no B-frames.** Irrelevant to this file, load-bearing for
  v1: saving a clip without re-encoding means starting on an IDR.
- **4:2:0, not BGRA.** Half the bandwidth off the capture path, and it is what
  the encoder wants anyway.
- **AVAssetWriter, not a raw VTCompressionSession.** v1 needs the raw session so
  encoded frames can go to a ring instead of a file, but it is the same hardware
  encoder, so the performance number transfers — and it saves ~300 lines we
  would throw away.
- **`capturesAudio = false`.** SCK's audio follows the content filter, so
  "whole display, EVE + Discord audio only" is unreachable through it. The tap
  owns audio.
- **Carbon `RegisterEventHotKey`, not a CGEventTap.** It fires under a fullscreen
  game and needs no Accessibility grant.
- **Swift language mode v5.** Deliberate. Proving feasibility is the job; v1 gets
  real actor boundaries.

## Known gaps, on purpose

- Your display is 3024×1964 — not 16:9. YouTube will pillarbox it. Fine for a
  spike; worth deciding before v1 whether you record on an external 16:9 panel.
- No recovery from display sleep or resolution change. v1 needs it, and it is
  why the ring has to be a list of segments rather than one buffer.
- **The overlay is captured into the recording.** Deliberate here — scrubbing
  the clip to find `◆ MARKER 3` is how you confirm a press landed. v1 must
  exclude it, via `SCContentFilter(display:excludingApplications:)` on our own
  process, or every saved clip carries our HUD into the edit.
