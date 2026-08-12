# Mycelium — iOS

Steps 1 and 2 of [the plan](../docs/PLAN.md): **The Field** and **Ground Me**.

## Running it

```bash
open ios/Mycelium/Mycelium.xcodeproj
```

Pick a simulator or your device and hit Run. There are no dependencies, no
package manager, and no generator step — the project uses file-system
synchronized groups, so any file you drop into `Mycelium/` is picked up
automatically without touching the project file.

**Before running on a real device:** set your signing team in
Xcode → target *Mycelium* → Signing & Capabilities. `DEVELOPMENT_TEAM` is
deliberately blank so it doesn't fight whichever of you opens it. The bundle ID
is `com.dez.mycelium` — change it if it collides.

## What's here

```
Mycelium/
├── MyceliumApp.swift          entry point
├── Session/RootView.swift     live-preview picker → session ("Before" screen)
├── Field/
│   ├── Field.metal            the shader — this is the product
│   ├── Form.swift             which shape the field takes, and its palettes
│   ├── FieldRenderer.swift    ping-pong feedback + bloom chain + tonemap
│   ├── FieldState.swift       taps, breath, grounding, form, palette index
│   ├── Uniforms.swift         the bytes handed to the shader each frame
│   └── FieldView.swift        MTKView + touch handling
└── Grounding/Haptics.swift    breath-paced haptic pulse

tools/FieldLab/               Field.metal off disk, reloading on save
```

`Uniforms.swift` is its own file rather than living inside the renderer because
Field Lab compiles it too — one Swift declaration, so the app and the lab cannot
disagree. The pairing with `struct Uniforms` in `Field.metal` is still manual and
still unchecked by anything; extend it at the end.

## Forms and their palettes

**Form** is the shape of the visual. Each form carries **its own palettes**.

Those used to be orthogonal — five shared moods, any form in any palette — and
it didn't survive contact. A full-spectrum sweep that looks alive on a loose
form goes garish on the kaleidoscope, because that form already carries its own
structure and doesn't need the colour arguing with it. Curating per form costs a little
duplication and buys every combination being one worth shipping.

| Form | |
|---|---|
| `kaleidoscope` | Sixfold mirror symmetry over a Kali-set inversion fractal, colored by orbit traps, falling into itself forever. |
| `tunnel` | Two spirals of opposite handedness and near-equal curvature, overlapping into circles stacked on each other and travelling outward past you, crossed by a near-radial ray family that turns. Filaments on black, built in log-polar coordinates where a plain sine comes back as this. Endless, seamless, and the cheapest form here. |
| `lobes` | An eight-lobed corridor of pearl beads falling away from you. The beads sit on a grid in (log-radius, angle) rather than in the plane, so their spacing on screen is perspective rather than a texture. The cross-section is a flower, not a circle, and alternate lobes sit slightly near and far, so the corridor has a front and a back. Ported from the WebGL prototype in `experiments/eight-lobe-tunnel`. |
| `mycelial` | Two cellular nets — broad felted cords and a mid net — over a tangle of threads crossing at every angle. Built against a photograph of a real network. Starts as one blob and grows outward forever while the camera retreats from it; what a patch of mat looks like is driven by how long ago the margin passed over it. |

| Form | Palettes |
|---|---|
| `kaleidoscope` | Obsidian · Reef · Bone · Vespers |
| `tunnel` | Prism · Neon · Oilslick · Vapor |
| `lobes` | Pearl · Aurora · Ember · Deep |
| `mycelial` | Spore · Fungal · Deep · Filament |

Mycelial costs two Worley lookups plus two `fbm3` calls and five thread
directions per pixel — and it runs all of that **twice**, because the endless
retreat renders two octaves and cross-fades them. Comfortably the most expensive
form, and the reason the picker caps at four live tiles.

Two things hold that cost down. The growth-front mask is computed *first* and
the whole field skipped where the mask is zero, so black pixels outside the
colony are nearly free — which matters most during the opening blob phase, when
they are most of the screen. And the mask test is a coherent region rather than
scattered pixels, so the branch costs little.

This has only been profiled by eye on the simulator, whose timings say nothing
about a phone. If a device ever drops frames on this form, that doubling is the
first place to look.

The mycelial palettes are built so `t = 0` is exactly black (`a == b`, `d = 0.5`,
so `a + b·cos(π)` vanishes). Every other form fills the screen with colour; that
one is filaments against dark, and it only works if empty space renders empty.

**Adding a form** is three small edits: a case in `Form.swift` with its
palettes, a `somethingField()` function in `Field.metal`, and a branch in
`fieldFragment`. Nothing else needs to know. Next up per the plan: liquid light
(caustics and refraction).

## Gestures

**Picker**

| | |
|---|---|
| tap a tile | enter that form |
| swipe a tile | cycle its palette in place |

Every tile is a real running Field — same shader, same renderer, half frame
rate. Nothing on that screen is a swatch or a mockup.

**In session**

| | |
|---|---|
| one finger, tap | one pulse of shape and color, everywhere at once |
| one finger, press and rest | the field glows and dims in time, for as long as you stay put |
| one finger, drag | nothing — moving is only what cancels the hold |
| one finger, hold the circle | a voice note records while you hold, stops when you lift |
| two fingers, press + hold | Ground Me (engages after 0.35s so a stray touch can't flip it) |
| two fingers, pinch | zoom, both ways (mycelial only — the others have no camera) |
| three fingers, tap | leave the session |

Tap and rest are one gesture told apart by what happens after it lands, so
there's nothing to learn — and since neither cares *where* it lands, there's
nothing to aim at either. That's the requirement: this screen gets used by
people who can't read a UI and shouldn't have to hit a target.

**A touch has no position.** Tapping the corner and tapping dead centre produce
an identical field. Position is still written to the event log — it costs
nothing and the log is what sync and replay are built on — but no shader reads
it. On `mycelial`, where a positional touch would have seeded growth at a point,
a tap instead drives the churn forward, so the *whole* network visibly
reorganises rather than only brightening.

The pulse fires on contact rather than after the gesture is classified, so a tap
never feels late. The hold then engages at 0.4s if the finger hasn't wandered.

## How the Field works

Two render passes per frame:

```
accum[prev] ──▶ fieldFragment ──▶ accum[cur] ──▶ presentFragment ──▶ drawable
```

`fieldFragment` evaluates the selected form, lifts it by whatever taps are still
ringing, colors it through an
[IQ cosine palette](https://iquilezles.org/articles/palettes/), then blends with
the previous frame. That feedback blend is what makes a touch linger and get
woven into the pattern rather than just switching off.

**The field is a pure function of `(time, seed, bloom log, audio envelope)`.**
Nothing about a session is stored in pixels. Sync was the original reason and
sync is cut; the reason that remains is **replay (step 6)** — re-run the logs
against the same seed and the session reproduces exactly. The audio envelope is
the newest input and it obeys the same law: the mic's smoothed band levels are
written to the session log at 10Hz precisely so a replay can re-integrate the
drift they bought. An input that isn't logged is a session that can't be
replayed.

Don't break that property.

### Safety constraints in the shader

These are load-bearing, not stylistic:

- **No strobe.** Every animated term is a slow sine or an exponential decay.
  There is no path through this shader that produces a hard flash.
- **Soft-clamped luminance** in the present pass (`c / (1 + c * 0.50)`), so
  overlapping blooms brighten the field but can never blow out to white.
  (This line used to say 0.55, which is the *tap* saturation constant — the
  in-shader comment at the present pass was right all along.)
- **Grounding never goes to black.** It desaturates toward a calm blue-grey and
  dims to 55%. Going fully dark mid-trip is its own kind of alarming.

Measured on the simulator, grounding takes saturation from 0.75 → 0.11 and
shifts mean color from warm `[20,5,8]` to neutral `[8,8,9]`.

#### Why the tap envelope and `tapInterval` are safety constants

A tap brightens the **whole screen**. That changed the risk profile: full-field
luminance modulation at a rate a finger can produce lands in the 3–60Hz
photosensitivity band, where a localised bloom never could. Two things keep it
out of trouble, and neither is cosmetic:

- **The attack is soft** (`tapEnvelope` rises over ~0.26s rather than stepping).
- **`tapInterval` is 0.22s**, so taps can't come faster than ~4.5Hz, and the
  envelopes overlap enough at that rate to sum into a smooth level.

Modelled swing for a sustained tap train — the shipped combination is 2.6%,
against a ~10% rule of thumb for the danger zone:

| tap spacing | rate | swing |
|---|---|---|
| 0.10s | 10.0Hz | 0.3% |
| 0.15s | 6.7Hz | 0.9% |
| **0.22s** | **4.5Hz** | **2.6%** ← shipped |
| 0.30s | 3.3Hz | 5.9% |
| 0.50s | 2.0Hz | 20.5% (below the 3Hz floor) |

Note the shape: slowing taps down makes the swing *worse*, because the pulses
stop overlapping. If you raise `tapInterval`, check this table rather than
assuming slower is safer. Dragging deliberately emits nothing at all — a stream
of whole-screen flashes at finger speed is exactly the thing being avoided.

#### Why `LOBES_ZOOM` is a safety constant

Beads in the `lobes` form sit on a grid one cell wide in log-radius, so the rate
you travel down the corridor **is** the rate beads pass a fixed point on screen —
`LOBES_ZOOM` in Hz, directly, with no conversion. That makes it the fastest
repeating thing in the form, and it reads like a taste knob, which is the trap.

| | rate |
|---|---|
| beads passing (`LOBES_ZOOM`) | **1.15 Hz** |
| lobe rotation (`0.31 / TAU x 8`) | 0.39 Hz |
| outward pulse (`0.95 / TAU`) | 0.15 Hz |
| portal breath (`0.62 / TAU`) | 0.10 Hz |
| twist drift (`0.075 / TAU`) | 0.01 Hz |

The band starts around 3 Hz. **The prototype ran this at 2.65**, which is not
inside the band but is one "make it faster" away from it — and the value carries
nothing in its name to say so. 1.15 is the same journey with headroom, and it
fixed something unrelated on the way: at 2.65 the beads crawled against the pixel
grid near the rim, where the cells are only a few pixels apart.

## Audio

Two features share one microphone: the field moves with the music in the room,
and holding the circle records a voice note. One `AVAudioEngine`, one input
tap, two customers — [`Audio/AudioPipeline.swift`](Mycelium/Mycelium/Audio/AudioPipeline.swift)
owns the session and the fan-out, [`Audio/AudioAnalyser.swift`](Mycelium/Mycelium/Audio/AudioAnalyser.swift)
turns buffers into four floats, [`Session/CaptureRecorder.swift`](Mycelium/Mycelium/Session/CaptureRecorder.swift)
turns them into an m4a when armed.

**The mic is the only route.** iOS will not let an app tap another app's
output, so there is no reading Spotify directly — the field hears the room the
way you do. This works with a speaker regardless of whose phone is playing, and
it is also why echo cancellation stays OFF: voice processing exists to remove
what this phone's own speaker is playing, which is exactly the signal we want.

```
mic ─▶ ring buffer ─▶ RMS gate ─▶ Hann ─▶ 2048-pt FFT ─▶ band powers
                      (−60dBFS)                             │
       loudness = dB above a clamped noise floor ◀───────────┤
       bands    = that loudness × spectral share ◀───────────┘
      ─▶ envelope (taus below) ─▶ 30Hz publish ─▶ state.audioLevel ─▶ u.audio
                                ─▶ 10Hz        ─▶ audio.jsonl (replay's copy)
```

### The smoothing is the safety story

The photosensitivity waiver for this feature is on record, but the design
doesn't lean on it. Every seam audio reaches modulates **phase, hue, or the
amplitude of an existing slow oscillation — never `col`, never `shade`** — and
the attack/release envelopes (`AudioDynamics`, FieldState.swift) keep the
driving signal itself below the 3–60Hz band. A 130bpm kick is 2.2Hz; through a
0.15s attack / 0.9s release follower it arrives as swell, not strobe. The old
argument for this shader was "read it — nothing oscillates fast"; the mic is
the first input whose frequency content can't be read off the page, so the
smoothing stage is what keeps that argument true.

| channel | attack τ | release τ | reaches |
|---|---|---|---|
| bass (x) | 0.15s | 0.9s | mycelial churn |
| mid (y) | 0.25s | 1.2s | drift rate, breath amplitude, kaleido hue |
| treble (z) | 0.12s | 0.7s | nothing yet — computed and logged |
| onset (w) | 0.05s | 0.35s | nothing yet — computed and logged |

### Turning a room into 0…1 — three wrong answers first

This is the part that shipped broken, and it shipped broken because "the
plumbing is connected" was mistaken for "the feature works". The end-to-end
test that caught it: play music at the simulator, screenshot the field every
two seconds, and compare the frame-to-frame change against a silent run. It
came back **0.97x — no effect whatsoever.**

What a direct unit test of the analyser then showed, feeding it synthetic
audio with no microphone in the loop at all:

| attempt | what it did | how it failed |
|---|---|---|
| mean-FFT-magnitude "dBFS" gate | divided a mean bin magnitude by the window size and called it dB | not dB in any unit. A cliff, not a floor: amplitude 0.5 came through at full scale, **0.05 measured exactly zero**. Room-level music sits below that, so nothing ever moved |
| per-band peak AGC | each band ÷ its own recent maximum | an AGC exists to make loud and quiet sound the same — the exact distinction this feature is. Silence read 0.27, music 0.33. It also destroyed the bands: an 80Hz sine read bass 1.00 **and** mid 1.00 **and** treble 0.87, so "bass drives churn, mid drives drift" was three hats on one signal |
| per-band noise floor | dB above each band's quiet baseline | fixes silence and separation, then fails on the sustained case: after twelve seconds of loud playback the floor has crept up, so the same track twenty decibels quieter reads **zero**. Music plays for the whole session — sustained *is* the case |

What ships: **absolute dBFS above a floor that adapts but is clamped** to
[−70, −45]. Adaptation absorbs whatever microphone this turns out to be; the
ceiling means sustained music can never drag the floor into the useful range
and normalise itself away. Loudness comes from the frame's RMS, and the three
bands split that loudness by spectral share — so the absolute measurement says
whether anything is playing and the spectrum's shape says which channel gets
it.

Measured after, on a continuous timeline through one analyser (the honest rig
— a fresh analyser per signal hides every adaptation bug):

| | bass | mid |
|---|---|---|
| empty room | 0.01 | 0.00 |
| music, loud | 0.55 | 0.78 |
| music, −20dB | 0.21 | 0.22 |
| music, −34dB | 0.07 | 0.02 |
| room again | 0.01 | 0.00 |
| dead silence | 0.00 | 0.00 |

Monotonic in loudness, zero when nothing is playing, and it recovers. That
monotonicity is the property all three earlier versions lacked.

Two things still open, both needing a real phone rather than a simulator. The
floor's [−70, −45] clamp is calibrated for a phone mic in a room and has only
been checked against a Mac's much hotter input, where ambient alone sits at
−30dBFS. And the onset channel is computed and logged but drives no seam. To
check the calibration on a device: play music, then read `audio.jsonl` out of
the session directory — quiet should sit near zero and music well above it.

### The seams, and the multiply that would have been a lurch

| seam | what | constant |
|---|---|---|
| drift | lobes + mycelial read `drift + u.audio.w` | `AudioDynamics.driftRate` 0.8 |
| breath | scale-pulse amplitude `* (1 + AUDIO_BREATH * mid)` | `AUDIO_BREATH` 0.5 |
| churn | mycelial's Worley phase `+ bass * AUDIO_CHURN` | `AUDIO_CHURN` 0.8 |
| hue | kaleidoscope only: `t += AUDIO_HUE * mid` | `AUDIO_HUE` 0.05 |

The obvious drift seam — `drift * (1 + envelope)` — is a trap, and it is the
tunnel's surge lesson pointing the other way. `drift` is absolute time wearing
a grounding factor; multiplying it by an envelope moves **position**, not
speed, and ten minutes in, a 5% envelope dip is a thirty-drift-second lurch
backwards. So Swift integrates `audioDriftTime += dt * rate(audio)` where
there is a dt to integrate with, and the shader only ever adds. An integral
cannot jump.

The kaleidoscope keeps plain `drift`, deliberately: its feedback contraction
assumes `KALEIDO_ZOOM_RATE` against a constant clock, and a trail contracted at
yesterday's speed under a zoom running at today's is the difference between
motion and smear. It hears the music through hue instead.

Measured (seed 42): audio at zero is **bit-identical** to the pre-audio shader
on all three forms; `--audio pulse:0.5` holds near-black and blown inside the
form's own no-audio swing band; `const:1,1,1` at t=60 lands the palette further
round the wheel with no discontinuity.

### Capture

A ~110pt disc at bottom centre, drawn by SwiftUI, hit-tested in
`MetalFieldView`'s own touch pipeline — **not** an overlay button, because a
button swallows touches and a swallowed touch is one the grounding counter
never saw. A capture press still counts toward the two- and three-finger
totals, so grounding stays reachable and the exit works with a thumb on the
circle. `CaptureZone` is one definition shared by the hit test and the glyph,
so they cannot drift apart.

Its rules: hold to record, lift to keep. No drag-to-cancel — a cancel gesture
is a precision gesture. **Nothing discards a recording** — not a three-finger
exit, not a phone call, not touch cancellation — except a grazed circle
released inside 0.5s, and even that leaves a `captureDiscard` line in the log.
Grounding during capture grounds normally; the haptic pulse is faintly audible
in the note, and that is accepted. AAC mono 64kbps (~0.5MB/min), CAF fallback
if the encoder refuses the hardware format.

### The session record

Entering a session now builds a **fresh FieldState — new seed, clock at
zero** — where re-entry used to resume the old clock. The log is why: a
timestamp only means something against a clock that started when the session
did.

```
Documents/sessions/20260809-102228-s4.5/     (app container, never the repo)
    session.json     {"startedAt": …, "seed": …, "form": …, "paletteIndex": …}
    events.jsonl     bloom / captureStart / captureEnd / captureDiscard /
                     ground / end — one JSON object per line, t in elapsed s
    audio.jsonl      the envelope at ~10Hz ({"t","b","m","tr","o"})
    note-001-t0083.m4a
```

JSONL through `FileHandle` appends, never a rewritten document — append-only is
crash-honest, and a session that dies at minute forty keeps forty minutes. The
`startedAt` in the header is the only wall-clock date anywhere in the app; the
field itself never learns what day it is. Known gap: pinch/zoom events are not
logged, so a mycelial replay's growth cap can drift from its session — scoped
out with the Morning View.

### The audio session, and the constants that are really decisions

Configured once at session entry, never reconfigured mid-session (reconfiguring
a live session is the classic way to stall `CHHapticEngine`, and grounding
haptics during a capture is the design working, not an edge case):

- `.playAndRecord` + `.mixWithOthers` — a plain `.record` category **pauses
  Spotify**. The music this feature exists to hear is usually on this phone.
- `.allowBluetoothA2DP` — without it a record-capable session drags a Bluetooth
  speaker down to the HFP phone-call codec. With it, output stays A2DP, input
  stays the built-in mic.
- Permission is asked on the **home screen**, sober, never mid-session. Denied
  means the field doesn't react and the circle never appears — the session is
  exactly the app that shipped before this feature.
- The engine runs only during sessions: the mic indicator is lit for a whole
  session (inherent, not a bug) and provably off at home.
- Sessions accumulate recordings with no deletion UI yet — the Morning View's
  problem, noted here so it isn't rediscovered as a surprise.

Interruptions (calls, Siri) finalize-and-keep any live recording and restart
the engine when the system hands the mic back.

## Field Lab

**Use this for shader work.** [`tools/FieldLab/run.sh`](tools/FieldLab/README.md)
opens a macOS window that renders `Field.metal` off disk and reloads it about a
second after you save, with form and palette pickers, a 0.1x–8x time scale, the
gestures, and four live sliders wired to `u.lab`. It compiles this target's own
`Form.swift`, `FieldState.swift` and `Uniforms.swift`, so it cannot drift away
from what the app does.

```bash
ios/tools/FieldLab/run.sh
```

It also renders headless, which is how the numbers in the next section were
measured:

```bash
ios/tools/FieldLab/run.sh --capture /tmp/t.png --form tunnel --at 12 --stats
```

Fixed timestep and a pinned seed, so the same command gives a byte-identical
file. That matters more than it sounds — **the tunnel's tonal statistics swing
between 15% and 28% near-black depending only on when you look**, as bright
filaments cross the frame. Two measurements taken at two different moments are
measuring the clock, not the change you made. Everything below was taken at a
fixed `--at`.

The seed barely matters by comparison (10.0% to 12.7% across three seeds at the
same instant), which is the opposite of what you would guess, and is why the
capture pins the time rather than averaging over seeds.

Everything Xcode is still needed for is below; this is only for the shader.

## Development shortcuts

`#if DEBUG` only — these can't ship:

```bash
# jump straight into the Field, skipping the picker
xcrun simctl launch <udid> com.dez.mycelium -field filament

# pick a form too — note the palette name has to belong to that form
xcrun simctl launch <udid> com.dez.mycelium -form kaleidoscope -field reef

# inject taps 5s in (for screenshots — you can't tap a headless sim)
xcrun simctl launch <udid> com.dez.mycelium -form mycelial -field spore -blooms

# twenty taps in a row, the case that used to blow the field out
xcrun simctl launch <udid> com.dez.mycelium -form lobes -field pearl -burst

# start already grounded, to compare against normal
xcrun simctl launch <udid> com.dez.mycelium -form lobes -field deep -ground

# start with the hold pulse engaged (you can't rest a finger on a headless sim)
xcrun simctl launch <udid> com.dez.mycelium -form kaleidoscope -field bone -hold
```

`-form` takes any form name. `-field` takes a palette name **belonging to that
form** — pass `-form` first, since the palette is resolved against whichever
form is currently selected.

## Tuning

Most of the feel lives in a handful of constants:

| what | where |
|---|---|
| how long strokes persist | `persistence` in `Field.metal` — above ~0.55 a fresh bloom drowns in its own history |
| overall contrast | `col = col * col * (3 - 2 * col)` in `fieldFragment` — remove it and everything goes washed out again |
| color richness | the saturation lift in `presentFragment`; the tonemap desaturates as it rolls off and this puts it back |
| how much a *flurry* of taps piles up | the `tap / (1 + tap * 0.55)` saturation. Raise the constant to let bursts hit harder; remove it and mashing the screen blows the field to white |
| minimum spacing between taps | `tapInterval` in `FieldView.swift` — **also load-bearing, see below** |
| how hard a tap hits | `tap * 0.95` (brightness), `* 0.22` (hue), `* 0.045` (shape swell) |
| tap attack and decay | `tapEnvelope` — the `2.2` sets how long it rings, the `6.0` how fast it arrives. **The soft attack is load-bearing, see below** |
| how hard a tap hits *per form* | `GLOW_ORGANIC` / `GLOW_STRUCTURED` |
| kaleidoscope zoom speed | `KALEIDO_ZOOM_RATE` — octaves per second, currently 0.20 (a doubling every 5s). Past ~0.25 it stops being hypnotic and starts feeling like falling. **Changing this alone is enough; the feedback trail follows it automatically** |
| how much of the kaleidoscope is flat wash | `trapSum` in `kaliLayer` and its two weights. The min-traps go quiet where the orbit settles early; this one keeps accumulating and is what puts structure in those regions. **Weight it into `detail`, not `t`** — see below |
| the colony's shape | `TREE_TRUNK`, `TREE_SHRINK`, `TREE_SPREAD`, `TREE_BEND` in `Field.metal`. BEND is what stops it being a diagram of a tree; **read the note below before removing the tangent rotation that goes with it** |
| how thick the cords are | `TREE_WIDTH` and `TREE_TAPER` |
| how ragged the rim is | `TREE_STOP` and `TREE_STUNT` — a ninth of tips give up. **Stunted, never terminated**, see below |
| how much it webs vs. how much it's a tree | `TREE_HALO` and `TREE_HALO_FLOOR`. The floor is the one that matters: it's what lets neighbouring limbs' sheaths overlap and bridge |
| how far the colony gets, and how fast | `Colony` in **`FieldState.swift`**, not the shader — `levels`, `genSeconds`, `genShrink`, `genFloor`, `tapPullback`, `levelsPerOctave`. `levels` is a **legibility** budget, not a coverage one; see below |
| brightness of the growing edge | `MARGIN_LINE` |
| how growth stages behind each tip | `AGE_EMERGE`, `AGE_TIP`, `AGE_THICK`, `AGE_MID`, `AGE_FINE`, `AGE_SETTLE` — in **levels**, not seconds, so a trunk spends far longer thickening than a twig does |
| the mat texture on the cords | `MAT_SETTLED_DIM`, `MAT_FINE_SETTLED`, `MAT_CELL`, `MAT_GAMMA`, `MAT_THREAD_FREQ`, `TREE_TEX_SCALE`. The Worley layer is a sheath now, not the form |
| tunnel travel speed | `TUNNEL_SPEED` — log-radius per second. **Safety constant, see below** |
| tunnel filament sharpness | the `mix(1.0, 5.0, res)` in `tunnelField`. 1 is a plain sine, 5 is a thin bright strand on black. It rides `res` because sharpening is also what aliases |
| tunnel arm counts | the `5.0` and `3.0` in `ph1` / `ph2`. **Both must be whole numbers** — atan2 wraps at the negative x-axis. Keep them coprime or the interference locks into a grid |
| tunnel radial frequency | the `1.90` and `1.35`. **Work out the flicker rate before changing either** — see the safety note; it is these times `TUNNEL_SPEED`, minus the rotation's contribution |
| how fast the tunnel turns | `TUNNEL_SPIN`, rad/sec, applied to family B only. **Rotation is carried by the ray family being wound differently from the arms** — nothing else in the form can show it, see below. Jointly a safety constant with `TUNNEL_ARMS_B`: 8 × 0.55 / TAU = 0.70Hz, the largest flicker term here |
| the tunnel's rays | `TUNNEL_ARMS_B` (how many), `TUNNEL_PITCH_B` (how straight — 0.15 is 7° off radial, and its being near-radial is the whole mechanism), `TUNNEL_MIX_B` / `TUNNEL_MIX_C` (how bright the rays and the swirl are against the rings; both well under 1 on purpose) |
| how fast the tunnel's colour travels | `TUNNEL_HUE_K`, in colour cycles per unit log-radius. 0.70; it was 0.30 and that put nearly all the colour in the middle of the frame — see below |
| tunnel glow | `TUNNEL_GLOW` — how far past white a filament core goes, which is the only reason the bloom pass has anything to catch |
| the tunnel's vanishing point | the `240.0` in `core` and its `0.35` weight. It multiplies the palette rather than adding white, so it brightens the far distance in the corridor's own colour. The weight was 1.7 and that was still a blob — the filaments converge and brighten on their own, so most of what a big weight adds is a hot spot on structure that didn't need it |
| how much of the screen the field renders at | `FieldRenderer.fieldScale`. The biggest lever on frame time in the app; see Performance |
| how bright anything gets | `BLOOM_THRESHOLD` / `BLOOM_STRENGTH` / `BLACK_POINT` in the present pass, and the two emitters: `TUNNEL_GLOW`, `MAT_TIP_HEAT` |
| lobe count | `LOBES_N`. Not a free knob — everything the prototype keyed to `smoothstep(5, 8, u_lobes)` was folded out at eight, and a different count needs those mixes back. |
| how bright the beads are | `LOBES_GAIN`, and `LOBES_GLOW` for the boost inside a core. Keyed to `core`, not to the light — see the note there. |
| how far the eight lobes reach around the palette | `LOBES_HUE_SPAN`. At 1.0 it is confetti. |
| how fast you fall down the corridor | `LOBES_ZOOM` — **safety constant**, see below |
| how hard the breath opens the corridor | `breathing` in `lobeLayer`. The most exposure-sensitive number in the form and it does not look like one. |
| edge crispness | `persistBase` — tunnel and lobes hold far less history than the other two, because feedback is exactly what softens a hard edge |
| mycelial cord weight | `0.22 + 0.16 * wr.x` — the noise term is what makes cords read as felted masses instead of drawn strokes |
| mycelial cell scale | the `7.0` and `17.0` frequencies. Roughly 15 coarse cells across a screen reads as a mat; 4 reads as a diagram |
| thread density | `228.0 + 19.0 * fk` — spacing per direction. **Each layer needs its own**, see below |
| thread count | the `k < 5` loop. More directions cost almost nothing; each is a dot product and a sine |
| how packed the cells look | the `threads * 0.55` weight. Empty cells are what make it read as a net rather than a living mat |
| cell irregularity | the `* 0.85` domain warp before the cell layers, plus the radial shove `dir * (wr.y - 0.5) * 0.38`. **Load-bearing** — unwarped Worley gives near-uniform cells and the whole thing reads as crystalline foam. 0.85 is near the ceiling: much past 1.0 the displacement map folds over itself |
| thread orientation | `turn` — a noise field rotating the whole set of directions. **Its frequency matters as much as its amplitude**, see below |

Two traps in `mycelialField`, both found by looking at renders next to the
reference:

**Cells can't fill cells.** The fine layer was a third, finer Worley net at
first. It could never look right, because the level set of a cell field
*encloses* regions — it can only subdivide into smaller cells, never cross
itself. A real mat is fibres running straight through each other, and the
crossings are most of what reads as webbing. The fine layer is five directions
of straight threads now, and the change is night and day.

**Shared noise across the thread layers makes lace.** All five directions using
the same spacing and the same perturbation means they cross at coherent points,
and the result is a repeating rosette. Each layer gets its own spacing, its own
share of the warp field, and a constant phase offset — the coherence disappears
for no extra sampling. If threads ever start looking woven rather than tangled,
this is why.

**Evenly spaced directions tile.** Five directions 72° apart *are* a triangular
lattice, and once the age gating opened the interior of the mat up, large
patches of that lattice were the single most artificial-looking thing in the
form — a drawn mesh sitting behind the network. Two fixes, both needed. The
spacing is now 1.1731 rad, which folded into 0..π leaves the five unevenly
spread so they never close into a rosette. And `turn` rotates the whole set as
you move across the field, so no orientation gets to establish anywhere.

`turn`'s **frequency** is as load-bearing as its amplitude, and getting it wrong
looks nothing like getting the angles wrong. At `q * 1.1` it varied over about
the width of the screen, so the entire frame got one orientation and the threads
came out as long parallel arcs sweeping across everything — brushed hair rather
than a mat. It has to turn several times within the frame to be doing anything.
| tap surge | `tap * 1.2` inside `churn` — a tap drives the whole network's reorganisation forward, since it has no position to grow from |
| hold pulse depth | `holdSwing * 0.78` (brightness), `* 0.06` (shape swell), `* 0.09` (hue) |
| hold pulse rhythm | `Breath.holdPulseSeconds` in `FieldState.swift` |
| how fast the hold engages / releases | `holdRate` in `FieldState.advance` (asymmetric on purpose), `holdDelay` and `holdSlop` in `FieldView.swift` |
| ambient motion speed | the `drift * 0.0xx` coefficients in each form function |
| kaleidoscope symmetry | `segments = 6.0` |
| how fast the network reorganises | `drift * 0.012` inside `churn`. Cut from 0.05, and deliberately: a mat still rearranging itself long after it grew is a mat that was never growing. Settled behind the margin, live at the margin |
| breath pacing | `Breath` in `FieldState.swift` — grounded is 11s (resonant breathing, 5.5/min); that number is the point of the mode |
| how fast grounding eases in | `easeRate` in `FieldState.advance` |

### How the endless zoom works

The kaleidoscope uses this. Mycelial used to, in the opposite direction, and
**the removal is written up under "Tap to make room"** — the constant retreat was
most of why that form read as expanding rather than growing. What follows is
therefore about the kaleidoscope, and the measurements below were taken on
mycelial back when it ran the same machinery.

The field is rendered **twice per frame, exactly one octave apart**, and
cross-faded:

```
// kaleidoscope — falling in
k = fract(time * KALEIDO_ZOOM_RATE)
near = kali(q * exp2(-k))        // scale 1.0 → 0.5
far  = kali(q * exp2(1 - k))     // scale 2.0 → 1.0
out  = mix(near, far, k)

// the retreat is the same construction, mirrored — this is what mycelial ran
k = fract(time * RATE)
near = layer(p * exp2(k))        // scale 1.0 → 2.0
far  = layer(p * exp2(k - 1))    // scale 0.5 → 1.0
out  = mix(near, far, k)
```

On mycelial this isn't decoration — without it the form cannot exist. Cell size
on screen halves every octave, so a single layer scaled up without limit is
finer than a pixel within a minute and aliases into grey mush.

At `k = 1` the far layer sits at scale 1.0 — precisely where the near layer
started at `k = 0`. The two are identical at the wrap, so the handoff is
invisible and the fall never lands.

Two things worth understanding before touching it:

**The seamlessness comes from the octave spacing, not from the fractal being
self-similar.** The Kali set isn't, exactly. That's the good part — you keep
arriving somewhere genuinely new that still looks like home. Swap in any other
field function and the trick still works.

**The crossfade is linear, and it has to stay that way.** `smoothstep(k)` is
equally seamless at the wrap, but it lingers on one layer and then dissolves
fast through the middle, and that dissolve reads as an *event*. Linear spreads
the double-exposure evenly so nothing ever appears to happen, which is the whole
point. This was tried both ways; linear won.

Cost is 20 fractal iterations per pixel instead of 10. Fine at 60fps, and fine
on the 30fps preview tiles.

The tunnel gets all of this for free and pays none of it — see below.

**The rate constant is not the rate you see, and the gap is large.** Measured on
mycelial by correlating frames against rescaled later frames and finding the peak:

| | nominal | measured |
|---|---|---|
| over 6s at a nominal 0.045 octaves/s | 1.206× | **1.060×** (r = 0.987) |
| over 2s | 1.064× | 0.97–0.98× |

The cause is the cross-fade itself. Within one octave the weight slides from the
near layer to the far layer, and the far layer sits at *half* the scale — twice
magnified. So the weight shift makes features grow at the same time as the
retreat makes them shrink, and the two partly cancel. The residue is small
enough that over short windows the apparent direction can even invert, which is
what the 2s rows are.

None of that is a defect — across a 90-second capture the growth reads correctly
and the scale never drifts — but it means **you cannot reason about the visual
speed from the constant.** Set it by looking, and don't "fix" a measurement that
disagrees with the number.

**Verify a zoom by measuring it, not by looking at two screenshots.** A pair of
stills can show a seamless wrap while the zoom itself is invisible in motion —
that mistake was made here once already. The check that works is: rescale a later
frame by a range of candidate factors, correlate each against the earlier frame,
and confirm there's a *sharp peak* away from 1.0. A broad, flat curve means
nothing was proven. `r` at scale 1.000 was 0.20 against 0.99 at the peak, which
is what real motion looks like.

**The wrap was verified seamless, not assumed.** A frame pair straddling the
octave wrap correlated at r = 0.963; the control pair inside an octave managed
0.945. No discontinuity — the pair crossing the boundary is, if anything, the
better-behaved of the two.

**The feedback trail has to be locked to the zoom rate.** This is the part that
actually made the zoom visible, and it isn't obvious. The accumulation blend
samples history at `(uv - 0.5) * contract + 0.5`, and that constant was a fixed
`0.998` — which at 60fps drifts the trail outward at **11.3%/second**. The
kaleidoscope was zooming at 3.9%/second. A ghost travelling 2.9x faster than the
thing casting it doesn't read as motion; it reads as blur, and it buried the
zoom completely. The contraction is now `exp2(-KALEIDO_ZOOM_RATE * dt)` for that
form, using the real frame delta passed in `holdParams.z`, so history lands
exactly where the pattern is going.

The sign is worth understanding even now that only one form zooms. Under 1,
history is sampled inward and so drifts outward, which is where the kaleidoscope
is heading as it magnifies. A form that *retreats* — everything on screen
travelling inward — needs a factor above 1 instead. Mycelial ran that way for
three versions and its trail is now `exp2(pushDelta)`, which is exactly 1 at rest
and above it only during a tap pullback. Getting this sign wrong doesn't look
like a bug; it looks like the form is merely blurry.

If you add a form that moves the whole field coherently, it needs the same
treatment. A fixed contraction only works for forms that churn in place.

**A contraction above 1 samples outside the frame, and that leaves marks.**
Mycelial is the one with a factor above 1, which means near the border it asks
for history from just *outside* the drawable, where there has never been
anything. Clamped addressing answers with the edge pixel instead, and the
retreat then walks that replicated strip inward — which showed up as small
hard-edged blocks drifting in from the margins. The fix is a three-percent fade
of the history term as `fbUV` leaves `0..1`. It costs nothing on the forms that
contract inward and never sample out there, and it lives under the vignette
either way.

**How much history a form wants is a property of the form.** These used to be
two buckets, crisp and not, and the kaleidoscope was lumped in with mycelial at
0.66 — a quarter of every pixel was trail, filling the open areas of the fractal
with a smear of where they had just been. Half of that form's "blurry solid
patches" was this and not the fractal at all. It sits at 0.50 now; mycelial keeps
0.66 because a felted look is genuinely what that form is for; tunnel and lobes
stay at 0.34 because feedback is exactly what softens a hard edge.

### Flat washes in an orbit-trap fractal

The kaleidoscope's colour comes from two orbit traps, both *minimums* over the
iteration. A min stops moving the instant it's attained — so anywhere the
orbit's closest approach happens on an early pass, both traps are constant for
the rest of the loop and neighbouring pixels agree with each other. That is a
wide, smooth, featureless area, and it is where the form's flat washes came from.

The fix is a third trap that is a **running total** rather than a third minimum:

```
trapSum += exp(-dot(z, z) * 1.8)      // every pass contributes
```

It keeps taking from every iteration, so it still varies exactly where the other
two have gone quiet. Iteration count went 9 → 10 at the same time (more passes,
more chances for the orbit to put a crease through a plateau); 12 was tried and
is too many — past about ten the new structure is finer than a pixel, so it stops
reading as detail and starts reading as noise.

**Weight it into `detail`, not `t`.** `t` is the palette coordinate and this term
is nonzero everywhere, so pushed hard into `t` it recolours the entire form — the
fractal stops being the thing choosing the colours and the palettes stop meaning
what they were tuned to mean. That was tried at 2.2 and every palette went gold.
`detail` lifts brightness and leaves hue alone, which is the job.

### The colony is a tree

Three versions of this form treated growth as a **region** — a boundary that
advanced, with mat drawn inside it. All three failed, and the last two failed in
ways that are worth keeping because each one looked like a tuning problem and
wasn't.

**Version one** was a mask: a ragged circle got bigger and uncovered a mat that
had been sitting there the whole time. Which is exactly what it looked like, and
the note it drew back was that the form read as "a pre-defined grid that was
already set in place and is just getting bigger."

**Version two** replaced the mask with an age model. A point's age was
`log2(front / r)` — how many octaves ago the retreating camera carried it past
the margin — so cords could arrive thin and thicken in place instead of being
revealed. Better, and it introduced a new bug: the test at a point never asked
about the points *between* it and the middle, so wherever the noise peaked, mat
appeared with nothing joining it to anything. Branches materialising in mid air.

**Version three** fixed that with a cost march. A point's age became the budget
minus what the journey out to it cost:

```
cost(r) = integral from the seed out to r of (1 + RESIST * resistance)
```

The integrand is strictly positive, so cost only ever increases going outward,
so the grown region is exactly one interval along every ray. Star-shaped, and
therefore connected by construction — nothing checked it and nothing could break
it. It was a real guarantee and it held.

**And it is precisely why that version could never web.** A star-shaped set whose
boundary is a function of angle is a blob with a wiggly edge. There is no
branching topology anywhere in it — no junction, no fork, nothing that is the
child of anything. What looked like branching was the Worley mat underneath,
which is a space-filling foam drawn everywhere the blob had reached, and the
blob itself just got steadily bigger. That is what "it's slowly expanding, it's
not webbing" is describing, and no amount of moving the resistance knob was ever
going to reach it.

So the colony is a tree now. An actual one, with a root and children.

#### One iteration per level, not one per branch

Ten levels of binary branching from three trunks is about three thousand
branches, and a fragment shader cannot test three thousand of anything. It does
not have to. Every level of a binary tree splits space roughly in half, so a
pixel can walk *down* the tree instead of scanning it: measure the branch you're
on, step to its tip, decide which of the two children you're nearer, repeat in
that child's frame. Ten iterations, not three thousand.

The step that does the deciding is `q.x = abs(q.x)`. After moving the origin to
the tip and orienting the fork symmetrically, folding the negative half onto the
positive one **is** the choice of nearer child, and it costs an absolute value.
Everything else in the loop is bookkeeping to keep the frames straight.

Growth is then not a boundary at all. `grown` is how many levels have arrived, as
a real number, and the fractional part is how far the newest branches have
extended out of their parents:

```metal
float reveal = clamp(grow - float(i), 0.0, 1.0);
if (reveal <= 0.0) break;
float ty = clamp(q.y / len, 0.0, reveal);   // the tip, and it moves
```

Connectivity is no longer a property that has to be argued from an integral. A
level-n branch is a segment starting at the tip of its level-(n-1) parent, and it
cannot be drawn until its parent is complete. Nothing appears detached from
anything because **there is nowhere for a detached thing to live.**

#### The fold is only a bisector if the fork is symmetric

This one cost a probe build to find, and it is the single most important thing on
this page if you ever touch `mycelialTree`.

The obvious way to stop a folded tree looking mirrored is to give each child its
own branch angle from a hash of its own path. Do that and the true bisector
between the two children is no longer the x axis — so `abs` sends a good fraction
of space down the **wrong** subtree. Those pixels then find themselves nowhere
near anything, and because the fold's cells are bounded by straight lines, what
that looks like is hard-edged black polygons cut clean through the colony,
running right off the frame.

They looked like a rendering bug, or a stale-history bug, or an aliasing bug.
What settled it was rendering the branch-density field on its own — flat gold
wherever the descent found material, black where it didn't — which showed the
voids were structural, with straight edges and bisector fans radiating from
branch tips. That probe is two lines and worth rebuilding any time this form
grows holes:

```metal
    TreeHit h = mycelialTree(p, grown, drift);
    detail = 0.0;
    if (h.age <= 0.0) return 0.0;
    return clamp(h.dens * 3.0, 0.0, 1.0);   // PROBE
```

The fix: **the half-angle belongs to the fork, not to either child.** Both leave
at the same angle from the tangent, in opposite directions, which makes `abs` the
exact bisector again. The asymmetry then has to come from somewhere the fold
doesn't depend on — length, curvature, and the subtrees themselves, all of which
still differ per child. Siblings are not mirror images; the *decision boundary*
between them is.

The same logic is why dead tips are stunted rather than terminated. Ending the
descent at a dead tip leaves the whole region that subtree would have served with
nothing, bounded by the same straight lines. A stunted branch still has its
subtree, folded into a knot a third of the size, so there is always something
there.

#### A sum where a minimum was

The cord itself is drawn from the nearest branch — a minimum. The fuzz around it
is not, and the difference is not cosmetic.

A minimum taken over a path that commits to a side at every level *jumps*
wherever the commitment flips. While the fuzz was tight to the cords that jump
happened where both branches were far away and nothing was being drawn, so it
never showed. Widening the sheath so it bridges between limbs — which is what
makes this a web rather than a tree — put the discontinuity right in the middle
of visible material, as straight seams.

So the sheath comes from `hit.dens`, summed over every branch the descent passes,
each weighted by its own thickness and age. A sum has no such flip: when the path
switches, the terms from the shared ancestors are unchanged and dominate, and the
one term that differs is the far one, which is near zero either way.

```metal
float hw = w * TREE_HALO + TREE_HALO_FLOOR;
float rr = d / hw; rr *= rr;
hit.dens += smoothstep(0.0, AGE_MID, age) / (1.0 + rr * rr);
```

Fourth power rather than an exponential: same tight core, much heavier tail —
which is the half that reaches across the gaps — and no transcendental in a loop
that runs thirty times.

`TREE_HALO_FLOOR` is the part that makes it a web. A halo that scales purely with
branch width leaves the voids between major limbs completely empty, and a tree
with clean black gaps between its limbs is a tree, not a mycelium. At 0.021 the
sheaths of neighbouring limbs overlap and the Worley layer — which is
space-filling, and was the whole form once — runs continuously across the gap as
fine hyphae bridging between cords.

#### Straight segments are the tell

A fractal tree built from segments has hard angular kinks at every fork, and no
growing thing does that: a hypha is laid down by a tip that is steering as it
goes, so it arrives somewhere curved. Rendered straight, the first working
version of the tree read as a diagram of a tree rather than a tree.

Each branch is a parabola now, `TREE_BEND` wide at the tip, and the distance is
measured to the curve point at the straight projection's parameter rather than to
the true nearest point — off by O(bend²), which at this amplitude is well inside
the width of the cord being drawn.

The half that matters more is the **tangent**: the child frame is rotated by the
slope at the tip, not by the branch's own chord. Without it every branch
straightens out at every junction and the tree goes back to being made of sticks.
With it, a limb reads as one continuous sweep that happens to shed side branches,
which is what a real cord looks like.

#### Levels are a legibility budget, not a coverage one

`Colony.levels` is where the colony stops. Coverage — the point where the tree
spans the frame — happens around level seven. Every level after that doubles the
branch count inside the same disc, so at twelve the colony came out as a full
screen of dense mat with no branching legible in it at all. Which is the same
complaint the whole form has been answering, arriving from the other direction.

Ten spans the frame and stops while the structure can still be read. The test is
unchanged from the earlier versions: **can you pick one cord at the margin and
follow it inward through two junctions?**

The clock is in `Colony` in `FieldState.swift`, and it is per level rather than
per second, because the thing that is actually constant is the speed of a growing
tip. Branch lengths shrink by `TREE_SHRINK` each level, so a deeper branch is
shorter and takes proportionally less time to put out. Growing every level in the
same wall-clock time instead makes the twigs crawl and the trunk snap out, which
is backwards. Five and a half seconds for the trunk is the whole of "start with a
single line": for the first five seconds there is one filament on screen and
nothing else, and the other two trunks are held back half a level each so it
isn't a three-pointed star either.

#### One tree is a starburst. A mat is many.

The tree fixed the topology and left a composition problem that four rounds of
tuning never touched, because it was never a tuning problem.

Three primaries leaving a single origin is a **starburst**: three fans with hard
black voids between them and an unmistakable centre that everything radiates
from. Worse, one colony reached radius 0.83 against frame corners at 0.55, so a
frame-filling picture meant looking at one colony's *interior* — and the interior
of a branching tree is the sparse part. Every good-looking capture of this form
turned out to have been taken at the moment the growing margin happened to be
crossing the frame. Half a minute later that margin was outside the frame for
good, and what was left on screen was the hollow middle, settled and dimmed:
81.9% of the frame near black, and none of the bright growing edge visible
anywhere, ever again.

So the primaries were scattered. Seven of them now, each with its own seed point
and its own hashed heading, on a golden-angle spiral squashed to the frame's
aspect, and each colony reaching 0.45 instead of 0.83. There is no centre because
there are seven of them; the voids close because neighbouring colonies' sheaths
overlap; and every colony's margin is somewhere inside the frame. Near-black went
81.9% → 58%, which is the reference's neighbourhood, without touching a single
brightness constant.

Two details that are load-bearing rather than tidy:

- **The scatter is an ellipse.** A phone is 0.46 wide for 1.0 tall, so a circular
  scatter of radius 0.4 lands most of the spores past the left and right edges
  and the visible column gets only what grew back inwards. That showed up as two
  dark vertical bands hugging the sides. `TREE_SEED_SQUASH` is one multiply.
- **The headings are hashed, not spread evenly.** Evenly spaced headings on
  scattered origins still read as a pinwheel — the eye finds the shared rotation
  long before it notices the offsets.

#### Lockstep, and why the tips came out as pom-poms

`reveal` was a function of the level number alone, so all 2^n branches of a
generation extended in perfect unison and stopped in perfect unison. What that
looks like is not a growing front — it is a **pom-pom**: a dense simultaneous
shell of tips, arriving and freezing together, and then the next shell.

`TREE_JITTER` gives each branch its own start time on top of its depth. The delay
**accumulates down the tree** rather than being drawn fresh per level, and that
is the whole of it: drawn fresh, a child with a small delay under a parent with a
large one begins before its parent has finished extending, which puts a branch in
mid-air hanging off a tip that has not reached it yet. Accumulated, a child's
start is its parent's completion plus its own wait, so detachment is impossible
for exactly the reason it always was — there is nowhere for a detached thing to
live.

It costs growth rate: the average accumulated wait is ~0.31 levels per level, so
`Colony.levels` and `startLevels` both went up by about a third to reach the same
depth in the same time.

#### The brightest thing in the form was a third of a pixel wide

This form measured **0.00% of its pixels blown out** for months while looking, to
everyone who looked at it, like it had bright tips. Two separate causes, both
invisible by eye and both obvious the moment the histogram was asked:

1. The tip light was gated on `core`, a geometric test against `w` — and `w` is
   the cord's half-width scaled by `mix(0.26, 1, thicken)`. At a tip, where
   `thicken` is zero *by definition*, a deep branch is 0.0007 field units across.
   That is a third of a pixel. The highlight was real, correct, and never more
   than a third-covered on any pixel it touched. It has its own radius with a
   two-pixel floor now, and does not reuse `core`.

2. The early-out `if (core <= 0 && near < 0.02) return 0;` ran *before the line
   that lights the tip.* `near` is `h.dens`, which weights every branch by
   `smoothstep(0, AGE_MID, age)` — so a brand new branch contributes almost
   nothing to it, deliberately. A tip out ahead of the mat therefore failed both
   halves of the test and returned black with `shade` left at 1.0. **The leading
   tips, the only part of this form that was ever meant to be bright, were being
   discarded for being too new.**

One thing the metric still won't show, and it is a property of the palette rather
than a defect: `blown` requires all three channels over 250, and the mycelial
palettes are built with `a == b` so that `t = 0` is exactly black. Spore's
amplitude is (0.42, 0.36, 0.26), so red clips at roughly half the drive blue
needs. The brightest tip is (255, 242, 190) — a hot warm white with red fully
clipped, which reads correctly and scores 0.00%. Compare peak channel values on
this form, not `blown`.

#### Zoom is a control, not a side effect

The pullback was a **ratchet**. It was a side effect of tapping and `zoomPush`
only ever increased, so around three taps in you hit the `TREE_LEVELS = 17` loop
bound and every further tap shrank the colony without buying any growth at all.
There was no path back.

It is a two-way pinch now, clamped to `Colony.zoomIn … zoomOut`, and the tap is
out of it entirely — one gesture, one job. Three things worth knowing:

- **Growth stays monotone whatever the fingers do.** The cap reads
  `max(zoomPush, 0)`, so zooming *out* buys levels and zooming back *in* does not
  take them away. Un-growing a colony reads as the mat retracting, which nothing
  living does — and it means zooming out and back in leaves you with a denser mat
  than you started with, which is the right reward for having made room.
- **Ground Me and pinch share two fingers, and grounding wins ties.** Two that
  stay put ground; two that move apart or together zoom. The pinch has to travel
  `pinchSlop` = 14% before it is recognised at all, and once grounding has
  actually engaged the pinch cannot take it away — it can only claim fingers from
  a rest that is still pending. Grounding is the gesture that must never be
  missed.
- **The pinch is anchored, not accumulated.** `beginZoom` snapshots where the
  zoom was; `updateZoom` takes the gesture's absolute scale against that. Pinch
  out and back the same amount and you are exactly where you began rather than
  somewhere near it. The mapping is `-log2(scale)`, since `zoomPush` is in
  octaves — which is what makes a pinch feel the same whether it starts from
  close in or far out.

**A dead end, if colony die-back ever comes up again.** It was built and pulled
the same afternoon. Each colony ran its own life — grow, hold, fade, reseed
elsewhere — off a free-running clock, which made growth genuinely endless and
removed the need for any reset. Two bugs were found and fixed on the way (a dying
colony kept *winning* the nearest-branch minimum while drawing nothing, so it
punched holes through the healthy mat behind it; and thinning cords all the way
out sent them through sub-pixel width, where a line does not fade, it samples,
and breaks into a crawling dotted twinkle). Both fixes worked and it still went,
because a mat that is always partly dissolving is a busier thing to look at than
one that is simply there. It is in the history.

#### Pinch to make room

Pinching out shrinks everything on screen, and shrinking it is exactly what buys
room for finer levels: an octave of pull-back is worth `ln2 / -ln(TREE_SHRINK)` =
4.98 more of them. So the pinch gets you a smaller colony **and** somewhere new
for it to grow, and it grows there over the next few seconds.

The camera is otherwise completely still, and that stillness is half of why this
form reads as growing now. The version before it cross-faded two octaves of mat
while retreating at a constant rate, so every pixel on screen drifted outward at
the same speed forever. That is a zoom. Growth is tips extending into empty space
while everything behind them stays exactly where it is, and you cannot have both.

The feedback trail follows `pushDelta` and nothing else, so it is stationary at
rest and locked to the camera during a pullback.

#### Settled mat no longer dims, and that is a taste call

`settle` faded material past about age 1.25 to 60% brightness and dropped a third
of its fine hyphae, so the interior went quiet behind an advancing bright margin.
It was justified as legibility — at one intensity everywhere the interior is
dense enough to be hard to trace — and it was, but what it *looked* like is the
middle of the colony dying while the edge lived. Which is a real thing mycelium
does, and it is not the thing this form is for.

`MAT_SETTLED_DIM` and `MAT_FINE_SETTLED` are now 1.00 and 0.60, which makes
`settle` a no-op; the constants stay so the mechanic is one edit away rather than
a rewrite. Near-black went 57% → 35% and the mat reads as one continuous
organism. If the interior ever gets too dense to trace again, the legibility
answer is fewer levels, not a dimmer middle.

### The tunnel — cut 2026-08-07

Everything below this heading described a form that is no longer in the app. It
is kept, unedited, because four of the things learned building it are general and
the next form will hit at least one of them:

- **A surge has to be an integral, not a multiplier.** `travel` is a position, so
  multiplying speed by something that rises and falls drags the picture backwards
  every time it falls. Integrate the extra distance instead — monotone by
  construction, and the surge you feel is its derivative.
- **What makes a palette match itself is `a`, not `c`.** A neutral base with
  differing channel frequencies reaches every hue on the wheel. Confining it is
  the amplitude's job: a channel with a small `b` can never take the lead.
- **Parallax is not pitch.** Pitch is how a family is wound, and so what it is
  *seen as*. Rate is how fast it arrives, and so how far away it reads. One
  shared rate makes the whole frame a single sheet of pattern being scrolled.
- **Bright lines need something in the gaps.** The unsharpened field — the value
  you were about to raise to a power anyway — is free and is exactly the right
  shape.

It was cut because Jacob cut it, not because it stopped working; it had just had
its best round. The reasoning is the same one that retired the mycelial as a
selectable form on the same day, and it is worth writing down plainly: **the
forms that have worked in this project worked almost immediately.** Kaleidoscope
has never drawn a complaint. Lobes landed on its first showing. The tunnel and
the mycelial between them absorbed nearly every round ever spent here, and
neither converged. Rounds spent are a signal, not an investment to protect.

### The mycelial — retired as a form, kept as the home screen

Same day, different fate. It is not in the picker any more and it is not a place
you go; it is what grows in behind the Before screen while you sit there.

That changed where it starts. A scatter through the middle grows *outward* from
several centres, so the busiest part of the picture ends up exactly where the
title and the cards are. Seeded around the **perimeter** facing inward, the frame
fills from its margins and the middle is the last place to arrive — which is the
right shape for something that has to sit behind type.

- Perimeter position comes from walking the rectangle **by arc length**, so the
  long sides get proportionally more spores than the short ones and a phone's
  tall frame doesn't crowd them all onto the top and bottom. A golden-ratio step
  means no two land on the same side.
- The spores sit just *outside* the frame (`TREE_EDGE_OUT`), so germination
  happens off-screen and what you see is hyphae arriving over the edge rather
  than dots appearing on the border and sprouting.
- Headings are inward plus a wide hashed spray. Dead-on inward gives you eleven
  parallel columns marching at the frame.
- `TREE_EDGE_W` is a **constant** 0.46 rather than the live aspect. Feeding it a
  real aspect would slide every spore along the edge on a resize, and a
  background that reshuffles itself on rotation is worse than one slightly off on
  an iPad.
- The clock is much slower than it was — about three minutes from bare edges to
  meeting in the middle — and it belongs to *this visit* to the home screen. Go
  into a session and come back and it starts over. That was the ask: "only when
  you're on that home screen."
- Opacity is applied by the view, not the shader. Sitting behind type is a
  property of this screen; the form still has to render at full strength in Field
  Lab, where it gets judged.

### The tunnel, and why it's the cheap one

Take `(log r, theta)` instead of `(x, y)` and two things become true. A
logarithmic spiral turns into a straight line, so a plain sine in that space
comes back to the screen as this vortex. And zooming turns into **translation**,
which is the whole reason this form costs so little: the kaleidoscope and
mycelial both pay double to cross-fade two octaves so their zoom can be endless,
and this one needs none of it. It just scrolls, forever.

#### What makes a palette match itself is `a`, not `c`

The tunnel palettes were near-neutral — Prism was a flat (0.5, 0.5, 0.5) — with
the three channels on slightly different frequencies so the hue keeps travelling
as `t` rises. A neutral base plus differing frequencies can reach **every** hue on
the wheel, so the corridor came out magenta against gold against cyan and the
arcs stopped reading as parts of one object.

The frequency spread is what makes the colour move and is worth keeping. What
confines where it moves *to* is the amplitude: a channel with a small `b` can
never take the lead however far the phase runs. So each palette is now one family
with a low channel it cannot escape — Ember caps blue, Abyss caps red, Orchid
caps green, Sap caps blue hardest of the four.

One correction that cost a round: capping a channel is necessary but not
sufficient. Where the two *large* channels both dip toward zero, the small one is
all that is left, and a wide frequency spread guarantees that happens somewhere —
Ember at a 0.32 spread had indigo arcs cutting through the fire. Tightening to
0.18–0.20 keeps the channels in enough phase that the low one is never alone.

#### Parallax and atmosphere

Two things the form had none of, both cheap, and between them the reason it reads
as somewhere rather than as wallpaper.

**Parallax.** All three families shared one travel rate, so however differently
they were wound the whole frame was a single sheet of pattern being scrolled and
nothing on screen ever passed anything else. They have their own rates now
(`TUNNEL_PAR_*`), slower reading as further off. The payoff is A against C: those
are the two loop families whose overlap makes the flower-of-life, and at a shared
rate that flower is a rigid stencil sliding by. At different rates it **opens and
closes** as the two sets of arcs walk through each other.

Note this is not the pitch. Pitch decides how a family is wound and therefore
what it is *seen as*; rate decides how fast it arrives and therefore how far away
it reads. Flicker is the product, so it is worked out per family — A stays at
0.80 Hz, C drops to 0.36, B's travel term is 0.09 on top of the 0.70 it gets from
spin, and all of them roughly double at the surge crest.

**Atmosphere.** The form gave up faking depth with geometry and was then left
with no depth cue at all, which is why an evenly lit frame read as flat however
fast it scrolled. `TUNNEL_HAZE` falls light off toward the rim so everything
converges on light at the centre. It is a *lighting* gradient rather than a
shape, which is why it doesn't reintroduce what was abandoned, and it costs one
exponential. Not applied to `core`, which sits at r = 0 where the falloff is 1.0
anyway and which is the light everything is falling off towards.

The first pass at it was much too strong — haze 2.6 with a 0.22 floor took the
frame from 23% near-black to 55% and killed every highlight. 1.9 with a 0.38
floor, plus `TUNNEL_GLOW` from 2.6 to 3.9 to pay for it, keeps the corridor
lit while the rim still falls away.

#### What it used to be, and why that was abandoned

For four rounds the tunnel was a hexagonal packing of glass beads in log-polar
space — cylinder normals, a hot core, an emissive mortar band in the gaps — all
of it trying to read as a corridor you were flying down.

It never did, and the reason was structural rather than a tuning failure. A
corridor reads as a corridor because of depth cues: atmospheric falloff, a size
gradient, one continuous material with light travelling over it. A tile mosaic
gives you none of those, so every round went into decorating the tiles — and the
tiles were never the problem. The verdict, once it was finally looked at
side-by-side with a measurement rather than by eye, was that **it was faking 3D
on a flat screen and the flat screen was winning.**

What survived the rewrite is the part that had always worked: travel into a
centre with the colour changing as you go. What went is the pretence of depth.
The form is now a flat pattern that admits it is one.

Two alternatives were built and rejected at the same time. Both are one-line
reverts away in the history if they are ever wanted:

- **Rings** — no angular term at all, so concentric ripples wobbled off-round by
  two low harmonics. The cleanest of the three and the best tonal numbers (44%
  near-black against the vortex's 24%), but it is a single idea and you have seen
  all of it in ten seconds.
- **Smoke** — the same spiral domain-warped by value noise sampled on the unit
  circle. Genuinely good, but it is the `liquid light` form from the plan wearing
  the tunnel's name. It should be its own form later rather than this one now.

#### `shade`, and why structure can't go through `t`

**This is the single most repeated mistake in this file.** It has been made three
times, in three different disguises, and each time it cost a debugging session:

1. a per-bead random hue hash
2. per-bead dome shading, weighted into `t`
3. the emissive mortar band, added to `t`

Every one produced the same symptom — a rainbow smeared across something that
should have been one colour lit unevenly — and every one took a while to
recognise, because the immediate appearance is "the colours look wrong" rather
than "I put brightness in the wrong variable".

The cause is always the same. `t` is a **palette coordinate**. It can only move a
colour *along* the palette, and these palettes are IQ cosines, so they wrap:
every large excursion in `t` is a trip round the colour wheel. Darkening
something by scaling `t` walks it toward zero, which for the tunnel and mycelial
palettes really is black — correct at the end, and a full rainbow on the way.

`shade` is the answer. It is applied as `col *= shade` **after** the palette, so
it is a straight brightness multiply that cannot move a hue anywhere. Zero is
genuinely black; anything above one is genuinely overbright and is what the bloom
pass exists to catch.

The current tunnel is built so this mistake is not available:

```
t     = hue, and nothing else       — a function of travel alone
shade = the entire structure        — filaments, glow, vanishing point
```

There is no term in `tunnelField` that could accidentally add structure to `t`,
because `t` is one function call with one argument. That is not tidiness for its
own sake; it is the only version of this form that hasn't hit the wall.

It also means the dark between the filaments needed no work at all. It is black
because nothing is lighting it, not because a floor constant was tuned until it
looked black.

#### Keeping the vanishing point alive

Everything in this form is periodic in log-radius, so the closer to the centre a
pixel sits, the more cycles fall inside it. Untreated, the middle of the frame is
a boiling moiré — and it is far worse in motion than in a still, which is exactly
how you fail to notice it while tuning against screenshots.

The first bead version gave up on this early: it faded structure out below
`r = 0.075` and left a flat disc. That is a ninth of the screen height rendered
as one solid colour, sitting precisely where the depth cue should be. It read as
a dead pixel, not as distance.

Aliasing is fixed by knowing how big a pixel is, not by deleting the detail.
`tunnelResolve` compares the pattern's local frequency against the pixel size and
fades the *sharpening* — not the pattern — toward its own mean. Structure now
survives to within a few pixels of the centre and dissolves rather than aliases,
and because it fades toward the mean rather than to a constant, the far distance
goes smooth and **bright** instead of smooth and grey.

The hue gets the same treatment through the `res` argument to `tunnelHue`, at a
sixteenth of the frequency, so it only bites in the last few pixels. Those are
the pixels everything converges on, and colour crawl there would be the most
visible place it could possibly happen.

`pxSize` is computed exactly rather than with `fwidth`: `p` is a linear function
of `uv`, so one pixel is just `zoom / res.y`. That also sidesteps `fwidth` of
anything built on `fract()` or `atan2`, which blows up on the one line where the
input is discontinuous.

The centre glow is **kept deliberately small**, and this constraint outlived the
rewrite: this form's history is sampled slightly inward every frame, so whatever
sits at the centre gets dragged outward across the whole screen and re-added. A
glow that looks modest in a single frame comes back as pale fog over everything a
few seconds later.

#### The feedback contraction has to match the travel

`fbContract` for this form is `exp(-TUNNEL_SPEED * dt)` — the history is
contracted at exactly the rate the content moves outward, so the trail sits on
the filaments instead of sliding against them.

It read `exp(-TUNNEL_ROW * TUNNEL_SPEED * dt)` until the rewrite, because the
bead version measured speed in *rows* and a row was `TUNNEL_ROW` of log-radius.
The new form has no rows and `TUNNEL_SPEED` is already in the right units, so
carrying the old expression across would have contracted the history at a third
of the true rate. **That would not have looked like a bug.** It would have looked
like the trail smearing slightly, which is a thing trails do.

#### Making it rotate took four attempts and the first three were all one mistake

"Make the rings rotate" sounds like a one-line change. It is. It is none of the
three lines you reach for first, and all three fail for the same underlying
reason, which took until the fourth attempt to see.

**Attempt one: add a rotation term to the arms' phase.** Invisible. Rotating a
logarithmic spiral is identical to scaling it — the same identity that makes this
form cheap — so this is a change to the travel speed wearing a different name.
The arithmetic below.

**Attempt two: bend the space into rotating lobes.** This does rotate, and it is
the wrong kind of rotation. Lobes rotate by *deforming*: the rings come out as
rounded triangles that wobble round. The verdict was "they're kinda like
distorting, not spinning" — a shape that changes as it turns reads as a
distortion, and the eye credits the motion to the shape rather than to a turn.

**Attempt three: light the rings unevenly and turn the light.** This is correct
in principle and it was still barely legible. A two-arc brightness gradient is a
very low spatial frequency, so it reads as the picture breathing rather than as
anything spinning. The verdict was, again, "it's not spinning".

##### What was actually wrong

All three attempts assumed the question was *what moves*. It isn't. Every arm in
the form was wound within 3° of every other one, and that alone decided that
nothing could ever look like it was turning.

> **A striped pattern can only be seen to move perpendicular to its own
> stripes.** This is the aperture problem, and it is the same reason a rotating
> barber pole looks like it moves upward.

Both families were wound within 3° of each other — 67° and 70° from radial.
Perpendicular to a nearly-tangential arm is *radial*, so every visible motion in
the frame was resolved as zoom, no matter what the underlying maths was doing.
The arms were in fact sweeping past at about 1 rad/s the whole time. It was never
invisible; it was visible as the wrong thing.

##### The fix: families wound differently

Give the form a family that is nearly **radial** — `TUNNEL_ARMS_B` = 8 rays at
`TUNNEL_PITCH_B` = 0.15, which is 7° off radial. Perpendicular to a nearly-radial
ray is tangential, so the rays are seen to *turn*. Every family is driven by the
same two clocks; what makes one look like spin and another like zoom is only how
it is wound.

This also un-breaks attempt one. The spiral/scaling degeneracy is **per family**:
a family with pitch (k, m) has its phase advanced by `k·SPEED` from travel and by
`m·SPIN/TAU` from rotation, so two families whose k/m differ are moved
*differently* by the two, and spin becomes a real degree of freedom. A is 1.90/5,
B is 0.15/8 — a ratio of sixty. `TUNNEL_SPIN` is applied to B only.

#### Pitch has two jobs and they pull opposite ways

```
A   five arms,  TAU·1.90/5 = 2.39   67° from radial  ┐ close to each other
C   three arms, TAU·1.35/3 = 2.83   70°              ┘
B   eight rays, TAU·0.15/8 = 0.12    7°                far from both
```

**A and C have to be close.** Two arcs of near-equal curvature, offset from one
another, overlap in lens shapes and read as **circles of the same size stacked on
top of each other** — the flower-of-life look, and the thing this form is
actually for. Three degrees apart does it.

**B has to be far.** That is the rotation mechanism above, and it wants the
biggest pitch gap the form can give it.

So the loops carry the look and the rays carry the motion, and neither can do the
other's job. One parameter, two requirements, in opposite directions.

##### The round that cost: "rings" does not mean concentric

Removing the 3-arm family when the rays went in drew "there isn't rings anymore",
which was correct — half the loops had gone with it. The fix applied was to *also*
drop A from five arms to two, on a reading of **rings** as *concentric*.

That does produce concentric rings. It also destroys the overlap, because it
widens the A–C pitch gap from 3° to 10°: the arcs stop looking like equal circles
offset from one another and start looking like one curve crossing a different
curve. The correction came back as "I liked when it was the circles stacked on top
of each other like the flower of life kinda", which names the actual property —
**equal size and offset**, not concentric.

Zero arms is further along the same wrong axis and worse than either: true
concentric circles plus radial rays is a wagon wheel, symmetric enough that the
form stops looking like travel through anything at all.

The general trap: *the word described the output, and two different structures
could produce something answering to it.* The distinguishing property was never
in the word. Worth one round to find out; should not cost a second.

##### The weights are not one knob

A at 1, C at **0.78**, B at 0.55, and the two secondary numbers want opposite
things. C sits near parity because the overlap only reads when both arcs look
like the same kind of thing — at 0.45 it became a bright curve with a faint one
behind it, which is a different picture. B stays well under because the rays
should be seen *crossing* the loops rather than competing with them; they came
down from 0.85 and cost no rotation at all, since that comes from pitch, not from
brightness.

The general lesson, which is not the one attempt three wrote down: **when a form
has a symmetry, and when every part of it is oriented the same way, motion along
that direction is unreadable.** Breaking the symmetry with brightness is one
answer and it is a weak one. Breaking it with *orientation* is much stronger,
because orientation is what the visual system uses to resolve motion in the
first place.

One useful consequence for verifying any of this: travel dominates any still, so
two frames two seconds apart tell you nothing. Probe `TUNNEL_SPEED` to zero with
a Field Lab slider first. With travel frozen the arms sit in identical positions
and the only thing that can move is the rotation — which is how the fourth
attempt was confirmed and how the third was caught.

#### A spiral cannot spin separately from moving — if there is only one of it

**Rotating a logarithmic spiral is identical to scaling it.** That is exactly why
this form is cheap — it is the same statement as "zoom is translation in
log-polar space" — and it cuts the other way too. Add rotation to an arm's phase
and every point of the arm slides along the arm's own path; the picture at any
instant is unchanged, and all you have altered is the effective travel speed.

Work out how fast a constant-phase arm sweeps at fixed radius and the point lands
hard. Before any rotation term existed:

```
family 1:   0.42 × 1.90 × TAU/5  =  +0.80 rad/s
family 2:  −0.42 × 1.35 × TAU/3  =  −1.19 rad/s
```

The arms were already counter-rotating at about a revolution every six seconds,
purely from travelling outward. A first attempt added ±0.22 rad/s on top and was
invisible, which is what you would expect from a 20% nudge to something already
moving — and for one family it made it *slower*. It read as "nothing happened"
rather than as "that was the wrong lever", which is how it survived being written
down as a fix.

The escape is in the qualifier. The degeneracy holds for *a* spiral, not for a
field made of two of them at different pitches — see above. **When a motion is
already implied by the geometry, adding more of it is a parameter change; making
a second thing that responds to it differently is a new degree of freedom.**

#### All the colour was in the middle of the frame

`TUNNEL_HUE_K` was 0.30 and the form looked tame in a way that was hard to name.
The cause is the log, and it is worth writing down because it applies to every
quantity this form varies with radius.

On a 402x874 frame the visible radius runs from about a pixel to about 2.2 — five
and a bit units of log-radius. But the outer **four fifths of the screen area**
live in the last one and a half of them. At 0.30 that is under half a colour
cycle across almost the whole picture: one pale wash, with a small rainbow
rosette buried in the few hundred pixels nearest the vanishing point. Every
screenshot in the tuning history shows it and none of the numbers did.

0.70 puts three or four bands across the frame with two of them out in the wide
part. **Anything keyed to log-radius spends most of its range on a small
fraction of the pixels** — check the outer part of the frame specifically, because
that is where nearly all of them are.

#### On `TUNNEL_SPEED` and what has *not* been verified

High-contrast filaments sweeping outward is periodic whole-field luminance
modulation, so the rate at which a fixed screen point cycles bright-to-dark **is
a flicker frequency in Hz**. It is each family's radial frequency times the
travel speed:

```
A:  1.90 × 0.42  =  0.80 Hz
C:  1.35 × 0.42  =  0.57 Hz
```

The rays add a third term, and it is now the largest one:

```
rays:  8 × 0.55 / TAU  =  0.70 Hz     (TUNNEL_ARMS_B × TUNNEL_SPIN / TAU)
     + 0.15 × 0.42     =  0.06 Hz     (what family B picks up from travel)
```

**`TUNNEL_ARMS_B` and `TUNNEL_SPIN` are jointly a safety constant, and that is
easy to miss because each one on its own reads as a taste knob.** Raising the ray
count from 8 to 20 is a look decision. Raising the spin from 0.55 to 1.4 is a
look decision. Together they are 4.5 Hz, which is inside the band. This is the
same trap as `TUNNEL_SPEED` × radial frequency, one level less obvious, because
the two numbers do not appear on the same line of the shader.

The photosensitive band starts around 3Hz and is worst near 15, so there is a
factor of four of headroom on the largest term. The way to spend it by accident
is to raise two things that each looked fine because the pattern seemed too
sparse. **Change one at a time and multiply them out.** It looks like a taste
adjustment right up until you do the arithmetic.

Every other animated term is slower still: the hue cycle at 0.13Hz, the breath at
13 seconds. Nothing in the function oscillates faster. You can check that by
reading it — which is the actual safety basis here, because the measurement
below failed.

One number worth knowing: fitting a similarity transform between successive
frames of the reference clips put their travel at **0.145–0.335 log-radius per
second**. The old bead form ran 0.198, inside that band. This one runs 0.42,
which is about 25% above the top of it — a deliberate choice after "speed it up",
not an oversight, but it is the one parameter here that is faster than anything
that was ever measured. It is also the parameter you cannot judge from a
screenshot, so judge it in Field Lab with the time scale at 1x.

An attempt to measure the luminance trace directly **failed and was abandoned**,
for two reasons worth recording so nobody repeats it:

- The simulator restores the previous scene rather than cold-launching, so
  `simctl launch -form tunnel` repeatedly came up on a different form and the
  captures were of the wrong thing. Two full runs were thrown away to this.
- More fundamentally, `simctl io screenshot` samples at best around 2.8Hz. By
  Nyquist that cannot see anything above ~1.4Hz, so **screenshot sampling can
  never test the 3–60Hz band at all**, however clean the run.

Verifying this properly needs an in-app luminance probe writing to a log, or real
device frame capture. Field Lab's `--capture` makes the first of those much
easier than it was — it renders at a fixed timestep, so a sweep of `--at` values
samples the luminance trace at whatever rate you like, with no Nyquist limit at
all. Nobody has done it yet. Until someone does, treat the safety basis as the
code-reading argument above.

### Porting the eight-lobe field out of WebGL

`lobes` came from a standalone WebGL page in `experiments/eight-lobe-tunnel`,
and the port is worth writing down because almost none of the difficulty was in
the geometry.

The geometry transcribed nearly line for line. What did not, and could not, was
the colour: that page computes RGB directly, runs its own three-stop ramp, and
tone-maps with `1 - exp(-c)`. This app's contract is a palette **coordinate**
plus a `shade` multiplier, with the palette living in `Form.swift` and a
contrast curve and a bloom chain downstream. So the colour half is a rewrite and
only the shape half is a transcription.

Three things that cost time:

**The whole frame was mid-tone.** First measurement was 89.8% near-black and
0.00% above white. Raising the gain fixed near-black and did nothing at all for
the top end — the frame just became a brighter grey. The reason is that the
tunnel's `fil` is sharpened by a `pow` up to 7 before its glow cube sees it, so
the cube only lifts the filament cores; bead light is not sharpened, and its halo
is as broad as its core, so the same trick lifted everything equally. Keying the
boost to `core` — about 1 inside a bead, 0 outside — is what separated them.

**The palette made confetti.** The prototype's ramp is three analogous colours,
so eight lobes span roughly a third of a colour wheel and read as one family.
Mapping the lobe index straight onto `t` spans the *whole* wheel, and eight lobes
a quarter-turn apart stop looking like one object. `LOBES_HUE_SPAN` narrows it
back. This is a general hazard when lifting anything into this file: the app's
palettes are full wheels, so any form that uses `t` as an index rather than as a
gradient has to say how much of the wheel it wants.

**The breath was the exposure knob, and it doesn't look like one.** Measured over
six times, blown pixels ranged 0.38% to 6.79% — seventeenfold, against the
tunnel's twofold. The suspect was the outward `pulse` crest; halving its
amplitude changed the spread by *nothing*. The tell was in the sample times: the
bright frames were about 13 seconds apart, which is `ambientCycleSeconds`, not
the 6.6s of the pulse. `breathing` scales `tunnelR`, and `tunnelR` feeds two
steep smoothsteps — bead radius and depth shade — so a 10% section pulse walks a
large fraction of the beads across both thresholds at once. At 0.035 instead of
the prototype's 0.105 the corridor still visibly opens and closes and the range
collapses to sixfold.

Final: 1.84% blown averaged over six times, range 0.58–3.13%, against reference
footage at 1.5–2.2%.

Near-black sits around 35%, well under the reference's 67.5%, and that is not
being ignored — it is the same call the tunnel made at ~22%. Reference clips are
mostly empty frame with one bright object; both of these forms fill the frame
with structure by design. Blown percentage is the number that transfers between
them, and near-black is not.

### One trap worth knowing

The kaleidoscope fold uses `atan2`, which returns `-pi..pi`, and `fmod` keeps
the sign of its dividend. Folding a negative angle straight through `fmod`
leaves hard seams down the mirror lines — a discontinuity through the center
and straight edges radiating out. The angle gets lifted by `TAU` first for
exactly this reason. If you touch that fold, check it full-screen: the bug is
nearly invisible in a small preview tile.

### Nothing in this app was ever bright

The single most useful measurement this project has produced, and it took
looking at reference footage frame by frame to notice, because on its own the
app looked fine.

Take three reference clips and our own four forms, convert to greyscale, and
count two numbers: what fraction of pixels is near-black, and what fraction is
genuinely blown out.

| | near-black | blown out (>200/255) |
|---|---|---|
| reference — tunnel | 67.5% | 2.2% |
| reference — petals | 10–36% | 1.5–2.2% |
| ours — tunnel | 25.8% | **0.0%** |
| ours — mycelial | 70.5% | **0.0%** |

Not "few". **None**, in any frame of any form. The accumulation buffer had been
`rgba16Float` since the first commit specifically so brightness could exceed 1,
and in nine months nothing had ever put anything there. Every form lived
entirely in the midtones, and every attempt to fix "it looks flat" had been an
attempt to fix it with *colour* — because `t`, the palette coordinate, is the
channel everything reached for, and a palette has no values above white in it.
You cannot spell "bright" in a coordinate whose range is a hue.

So: sources are allowed past white now (`TUNNEL_CORE`, `TUNNEL_GAP_GLOW`,
`MAT_TIP_HEAT`), a bloom pass spreads what's up there into its neighbours, and
the shadow lift at the end of `presentFragment` was replaced with a black point.
Those are one change, not three. Overbright with no bloom is a white dot with
hard edges; bloom with nothing overbright is a haze; and either one over lifted
shadows has no dark to be bright against.

#### Brightness is not a colour, and this is the third time

Removing the mortar's brightness floor put its glow into `t`, so a bright band
became a band *further along the palette* — 0.43 of the way, which in these
palettes is cream. The corridor came out black in the shadowed sectors and a
pale wash in the lit ones, which is worse than the floor it replaced.

That is the same mistake as the per-bead hue hash and the per-bead reflection
before it, arriving from a third direction. `t` moves colour. `shade` multiplies
after the palette and has no ceiling. A bright thing goes in `shade`, always,
and the tell that you have it backwards is that the bright thing is also a
*different colour* from its surroundings rather than a brighter version of them.

The fix is worth stating positively, because it is now the pattern for every
emitter in the app: keep `t` low so the object sits in the dark end of the ramp
with everything around it, and put all of the brightness in `shade`. A saturated
dark colour multiplied past white is an emitting object. A pale colour is a pale
object.

#### A gaussian of a gaussian is not two gaussians

The bloom runs two blur scales, tight and wide, because light doesn't have one
size — a hard core inside a broad faint halo is most of what makes something
read as emitting. The obvious implementation is to run the separable blur twice
at different tap spacings, ping-ponging between two textures.

That is wrong, and it is invisible on anything large. Chained, the wide pass
consumes the tight pass's output, so there is no tight component left anywhere
in the result — you get one wide gaussian and a slightly misleading comment. It
looked correct on the tunnel, whose core is a hundred pixels across and barely
notices being spread.

It fails completely on small sources, and the reason is energy. A gaussian
conserves total brightness, so it spreads a source over its own area and the
peak drops as roughly the square of how far it spread. A mycelial tip is three
pixels across; blurred over thirty it keeps about 1% of its peak. The tips had
`MAT_TIP_HEAT` on them, they were rendering at over three times white, and they
had no halo at all.

Summed, the tight scale survives underneath the wide one at full strength and a
three-pixel tip gets a three-pixel glow. That needs a third bloom texture and
one extra pipeline with additive blending — the wide vertical pass draws onto
the tight result with `.load` and one/one blend factors, which is also the only
pass in the chain that must not use `loadAction = .dontCare`.

#### And the curve that would have silently eaten it

`col * col * (3 - 2 * col)` is smoothstep's polynomial. It is monotonic on
`[0,1]`, turns over at 1, returns to zero at 1.5, and goes **negative** past
that. It had been the contrast curve since the first commit and it was always
safe, because until this change nothing in the shader ever exceeded 1.

The moment anything is allowed to be a light source it becomes a trap that
points the wrong way: the brightest pixel on screen renders *black*, ringed by a
hard band on the way there. It is now split at white — the polynomial below,
pass-through above — which is bit-for-bit the old curve everywhere the old field
lived. **Any future curve applied to `col` needs the same check.** The question
to ask is not "is this a nice shape" but "what does it do at 4?"

## Performance

The whole app is one fullscreen fragment shader plus a feedback blend, so cost is
almost exactly proportional to **pixels x ALU**, and there is no geometry, no
overdraw and no draw-call count to think about. Two levers, in order of size:

**Render the field below native resolution.** `FieldRenderer.fieldScale`, 0.72
linear, so barely half the fragments. The present pass still runs at full drawable
size and upsamples with a linear sampler. This costs almost nothing here because
none of these forms *have* detail at pixel scale by construction: mycelial's
sheath is a soft falloff, the tunnel fades its filaments toward their own mean as
they approach a pixel across, and every form is then blended with a blurred
copy of the previous frame at 26–66%. A 3x phone renders the field at an
effective 2.2x and the feedback smears it anyway. **If a future form has hard
sub-pixel structure, this is the first thing to put back.**

Watch the one trap: `resTime.xy` has to be the *field* size, not the drawable
size. Getting it wrong doesn't crash — the aspect correction goes subtly off and
the tunnel's anti-aliasing starts lying about how big a pixel is.

**Then the inner loops, which are the ones that run tens of times per pixel.**

- The tree's tangent rotation was `atan(2*bend)` then `sin` and `cos` of it —
  three transcendentals, thirty times a pixel. The slope *is* the tangent of that
  angle, so `cos = rsqrt(1 + slope^2)` gives the whole frame in one hardware op.
- Three `hash21` per level down to two, by reusing `fract(h * 31.7)`.
- The tunnel's nine-way nearest-centre search ran three square roots per
  candidate — twenty-seven — to build a metric whose only job inside the loop is
  to be compared. Squared Euclidean orders the candidates identically for the
  round part and within a few percent for the squared part, and the real
  superellipse distance is computed once, outside, for whichever won.
- `mycelialLayer` ran four `fbm3` calls, which is forty-eight hashes, on most of
  the screen. Two of them wanted noise at almost the same frequency for two
  different jobs; they share one field now, and the thread wander tops it up with
  a single octave instead of a whole second stack.

Not measured on device — the simulator runs on the Mac's GPU and would report
whatever it likes. These are counted reductions, not benchmarked ones.

**The bloom chain is five extra passes and is close to free**, for a reason
worth keeping in mind if you add more of them. The bright pass downsamples 4x on
the way in, so all five run at a sixteenth of the field's already-reduced pixel
count — together about a third of one field pass in fragments, and each one is
five texture fetches against the field shader's hundreds of ALU ops.

Blurring at a quarter rate is not a compromise, either. A gaussian's whole job
is to throw detail away, so resolving it finely is paying for something you are
about to discard; the only visible consequence is that the glow cannot have a
hard edge, which is not a thing glows have. It also multiplies the reach for
free — one texel of tap at that rate covers four field pixels, so the same five
taps spread light four times as far.

What this *does* add is encoder count: five per renderer per frame, and the
picker screen runs four preview renderers at once. Twenty extra encoders a frame
at 30fps is fine, but it is the number to watch if the picker ever grows.

## Not built yet

Steps 5–7: the intention screen, the Morning View, and the polish pass. Sync
(step 3) is cut; capture (step 4) shipped 2026-08-09 alongside audio
reactivity. See [the plan](../docs/PLAN.md).

The Morning View's inputs are already on disk: every session leaves
`session.json`, `events.jsonl`, `audio.jsonl` and its recordings in the app
container (see the Audio section). What's missing is the screen that replays
them.
