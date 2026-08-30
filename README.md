# observance

A ShadowPlay-style replay recorder for EVE Online on macOS. ScreenCaptureKit →
VideoToolbox → a segmented in-memory ring. **Nothing reaches the disk until you
press the key.**

`⌥⌘S` opens a clip containing everything currently buffered *and keeps
recording live* until you press it again. Video is muxed passthrough, so saving
a minute of buffered past costs about ten milliseconds and re-encodes nothing.

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

**Prove the audio grant first.** Play anything, then:

```
'.build/Observance Spike.app/Contents/MacOS/spike' --check --audio all
```

A denied System Audio Recording grant is invisible — every Core Audio call
returns `noErr` and the buffers are zeros. `--check` is the only honest test.

**Then run it.** Undock first: a process only enters the tap once it has opened
an output stream, so a silent docked client will not be found. `--list` shows
everything Core Audio can currently see.

```
'.build/Observance Spike.app/Contents/MacOS/spike' --audio EVE.app,com.hnc.Discord --length 300
```

`⌥⌘S` starts a clip, `⌥⌘S` again saves it, `⌥⌘Q` quits (saving anything still
open). `⌥` is Option, not Shift. An overlay at the bottom of the screen confirms
each one — it draws over fullscreen EVE.

Everything is also in the **menu bar**: current state and buffer fill, start and
stop, replay length, the clips folder, and quit. There is no dock icon and no
main menu — the app is `.accessory` so it can never take focus from EVE — which
makes the status item the only way to reach it without a hotkey, and the only
way to quit if the terminal is gone. Failing that:

```bash
pkill -f 'Observance Spike'
```

`--overlay-sample <dir>` renders every overlay state to PNG, so the stationery
can be iterated on without a capture run and a lucky frame grab.

`--selftest` runs the whole path — fill the ring, save a clip, verify the file —
with no key press, which is how to check a change did not break the save.

### Naming processes is harder than it looks

- **Electron apps never play audio from their main bundle.** Discord's sound
  comes out of `com.hnc.Discord.helper`. Bundle IDs therefore match as prefixes.
- **EVE's client reports no bundle ID at all.** It runs as `exefile`, out of
  `…/SharedCache/tq/EVE.app`, and Core Audio has no bundle for it. So a name
  also matches an executable name or a path fragment, and `--audio game` means
  the path fragment `EVE.app`.

That second one has a consequence: `CATapDescription.processRestoreEnabled`
saves tapped processes **by bundle ID**, so it re-attaches Discord after a
restart and can never re-attach EVE. So the app watches the audio process list
itself — see below.

## Surviving EVE relaunching

Quitting to character select kills the client's audio process. Nothing reports
this: the tap keeps delivering buffers, it just stops carrying the game, and
every clip from then on is silent.

So an `AudioObjectAddPropertyListenerBlock` sits on
`kAudioHardwarePropertyProcessObjectList`. The list churns constantly — every
helper that opens an output stream moves it — so changes are coalesced over
600 ms and then compared against *the set we actually matched*, not the list as
a whole. A real change tears the tap down and rebuilds it. A global tap
(`--audio all`) follows the machine rather than a process, so it is not watched
at all.

Three things this has to get right:

- **Stop accepting before stopping the device.** Core Audio hands back one more
  buffer as the IOProc tears down, timestamped in the old session. Letting that
  into the ring puts a half-second lie in the audio timeline, which the
  gap-filler then dutifully pads out with silence. Measured: 503 ms of false
  drift before the guard, 36 ms after.
- **Drift across a rebuild is a seam, not drift.** The previous audio PTS
  belongs to a stream that no longer exists, so the comparison is reset rather
  than allowed to poison the metric.
- **A rebuild can come back in a different format.** If the sample rate changed,
  audio already buffered cannot be muxed alongside what follows, so the ring
  drops it. Video is untouched. If a clip was open at the time, it says so.

With no tap attached at all, a clip still saves — video only, and it warns
rather than letting you find out in the edit.

## Measured against a live EVE client (2026-08-30)

Native capture, 60-second ring, EVE undocked with Discord running.

```
capture   3024×1964 @ 60  ·  3920 frames  ·  57.5 fps  ·  0 dropped
ring      60 s held  ·  0.05 GB  ·  0 segment breaks  ·  0 cap evictions
clip      66.0 s (61 buffered + 5 live)  ·  59 MB  ·  muxed in 0.01 s
          video 66.0 s / audio 66.0 s
```

Two things to watch:

- **57.5, not 60.** Consistent — identical idle and against a live client, which
  points at `minimumFrameInterval` scheduling rather than a shortfall. Whether
  *EVE* drops frames is a separate question only a human watching the client
  can answer.
- **A/V drift is a constant**, roughly ±30 ms, from the tap's IOProc and
  aggregate-device latency. Inside the acceptable window. Worth measuring once
  and subtracting rather than shipping a systematic offset.

## Two bugs this found, both silent

Recording them because both produce output that looks fine.

**`kAudioTapPropertyFormat` lies about the sample rate.** It advertised 48000 Hz
while the aggregate device ran at 44100, and the tap really delivered 44201
frames/s. Every audio timestamp was derived 8.8% too fast, so the audio track
came out 8.8% shorter than the video and slid steadily out of sync. The tap's
advertised rate is nominal; once it sits in an aggregate device, **the device's
rate wins**. Read `kAudioDevicePropertyNominalSampleRate` off the aggregate and
believe that instead.

**A tap is not gapless.** When no tapped process is producing output the tap
delivers nothing at all. AVAssetWriter concatenates whatever it is handed, so an
unfilled gap does not leave a hole — it drags every later sample earlier. Gaps
have to be paid for in generated silence.

Neither throws. Neither logs. Both give you a file that plays.

## The stationery

The overlay is dressed as Ministry stationery per `docs/stationery.md` in the
estate repo: ink ground, a hairline `--line` rule, Geist Mono micro-caps with
0.18em tracking, and **the office seal** struck at the left of the row, rotated
−5° as the front page wears it.

The detail line's colour carries meaning, using the palette's own semantics:
`--sage` for held and filed, `--bright` while witnessing, `--fog` for nothing
held, `--blood` for a failure.

The seal cannot be re-rendered locally, and the failure is silent: its ring text
is Zilla Slab on a `textPath`, and under any wider fallback the string overruns
the path and SVG **drops the characters that fall off each end** without a
warning. `rsvg-convert` with Georgia produces a seal with no ring text at all.
So the plate is lifted from the estate's own struck wallpaper, where Playwright
loaded the real face — see `Resources/STRIKE.md` for exactly how, and
`Resources/seal.svg` beside it as the source of record.

The **glyph** — the triangle and eye at the seal's centre — is drawn in Core
Graphics rather than loaded, because the menu bar needs it crisp at 15pt where a
scaled seal is mud. That is the same division the stationery makes: the seal
goes on the document, the glyph goes on the rail.

The instrument observes. It does not record.

| State | Stamp |
|---|---|
| `OBSERVING` | buffer live, or nothing held |
| `WITNESSING` | how far back the clip reaches |
| `FILING` | in hand |
| `FILED` | the clip's length |
| `NOT FILED` | failed |

Neither Zilla Slab nor Geist Mono is installed on this machine, so the overlay
currently sets its micro-caps in the system monospace. Installing Geist Mono
would make it exact; nothing else changes.

## The sounds

The office does not chime. It stamps.

| Cue | When | Length |
|---|---|---|
| `latch.wav` | the record is opened | 70 ms |
| `stamp.wav` | the record is filed | 150 ms |

A drawer catching, then rubber on paper on desk. Both are struck by
`Resources/strike-sounds.py` from arithmetic — no samples, no licences, no
dependencies, and the same impression every run. Neither ever reaches a clip:
under `--audio all` the tap excludes this process, and under per-process mode we
were never in it.

## How the ring works

- **Segments, not one buffer.** Display sleep, a resolution change, the stream
  restarting — each produces a new `CMFormatDescription`, and frames either side
  of that boundary cannot be concatenated without re-encoding. A clip is cut
  from one segment; if the window spans a break the clip is short and says so.
- **Measured in PTS, not frames.** ScreenCaptureKit only delivers on change.
  Docked with the station spin off, EVE emits almost nothing, and a ring that
  counted frames would quietly hold forty minutes instead of five.
- **Trimmed to keyframes.** 1-second GOP, no B-frames. The trim keeps the last
  keyframe that still leaves a full window behind it, so the buffer always
  starts somewhere legal to decode from.
- **A byte cap as well as a time window.** A five-minute window during a fight
  is far bigger than five minutes docked, so time alone is not a memory bound.
  At the cap, whole leading GOPs are evicted.
- **The handoff is locked.** A frame encoded between snapshotting the ring and
  the clip existing would otherwise fall into a gap and go missing from the
  middle of the save.
- **We exclude ourselves from the capture**, or every clip would carry our own
  overlay into the edit. This is why the overlay window is put on screen before
  ScreenCaptureKit is asked what is shareable: an application with no on-screen
  window does not appear in `SCShareableContent`, and an app you cannot name is
  an app you cannot exclude. If that lookup ever fails, the preflight says so
  rather than silently recording the HUD.

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
- No recovery from display sleep or a resolution change. The ring is built in
  segments ready for it, but that path has never actually run — untested
  recovery code is a guess.
- No relaunch watcher for EVE. Quitting to character select drops the audio tap
  for the rest of the session, and `processRestoreEnabled` cannot help because
  EVE has no bundle ID.

## Where this sits with CCP's rules

CCP's [Third Party Policies](https://support.eveonline.com/hc/en-us/articles/8564030965660-Third-Party-Policies)
draw the line at modifying the client, not at watching the screen. The
prohibitions it cites from the EULA are:

> **6.A.2** You may not use your own or third-party software to modify any
> content appearing within the Game environment or change how the Game is
> played.
>
> **6.A.3** You may not use your own or any third-party software, macros or
> other stored rapid keystrokes … that facilitate acquisition of items,
> currency, objects, character attributes, rank or status at an accelerated
> rate …
>
> **9.C** You may not reverse engineer, disassemble or decompile … or analyze,
> decipher, "sniff" or derive code … from any packet stream …

And the tolerance:

> We may, in our discretion, tolerate the use of applications or other software
> that simply enhance player enjoyment in a way that maintains fair gameplay.
> For instance, the use of programs that provide in-game overlays (Mumble,
> Teamspeak) is not something we plan to actively police at this time.

This app stays on the safe side of all of it, and the design should keep it
there:

- **Nothing is injected.** No code runs in EVE's address space, no memory is
  read, no DLL or dylib is loaded into the client. The overlay is a separate
  `NSWindow` composited by WindowServer — strictly less invasive than the
  Mumble/TeamSpeak overlays CCP names, which hook the graphics API.
- **Capture is an OS read.** ScreenCaptureKit reads the framebuffer and Core
  Audio taps output streams. Identical to OBS or QuickTime.
- **The hotkey receives, never sends.** `RegisterEventHotKey` observes a global
  key event. Nothing is ever synthesised into EVE. No macros, no keystrokes.
- **No packets, no cache, no game data.** Nothing is parsed, scraped or
  decoded. The app cannot tell a fleet fight from a screensaver.

**The constraint that keeps it that way:** never make the app react to game
state. No OCR of the overview, no pixel-watching to auto-save, no log parsing.
The moment it derives meaning from what is on screen, it stops being a video
recorder and starts looking like something that reads game data. It records
pixels and sound; a human presses the key.

CCP is explicit that none of this is a guarantee — "any use of third party
tools is done entirely at your own risk", and they decline to publish a list of
approved configurations. This is a reading of the policy, not permission from
CCP.

### Publishing the footage

Separate policy: the
[Content Creation Terms of Use](https://support.eveonline.com/hc/en-us/articles/8563917741084-EVE-Online-Content-Creation-Terms-of-Use).
YouTube ad revenue is explicitly fine; paywalling is not.

> **Non-Commercial** – your content must be available free of charge to everyone
> and cannot be blocked behind a paywall or premium subscription.
>
> **Monetization** – you can monetize the content by generating revenue through
> appropriate passive advertisement, e.g., pre-roll video ads, website ads,
> sponsor ad overlays. Soliciting personal donations or offering
> subscription-based content is also permissible …

Content that could be mistaken for CCP's own work needs their exact wording:

> This material is used with limited permission of CCP Games. No official
> affiliation or endorsement by CCP Games is stated or implied.

CCP also reserve "the unconditional right to request the removal of any
user-generated content for any reason".
