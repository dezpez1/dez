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
│   ├── Form.swift             which shape the field takes
│   ├── FieldRenderer.swift    two-pass ping-pong renderer
│   ├── FieldState.swift       blooms, breath, grounding, form, palette
│   └── FieldView.swift        MTKView + touch handling
└── Grounding/Haptics.swift    breath-paced haptic pulse
```

## Two axes: form and mood

**Form** is the shape of the visual. **Mood** is the palette. They're fully
independent — any form renders in any palette.

| Form | |
|---|---|
| `smoke` | Two-level domain-warped fbm with a ridged overlay. Ink bleeding through water. |
| `kaleidoscope` | Sixfold mirror symmetry over a Kali-set inversion fractal, colored by orbit traps, falling into itself forever. |
| `lattice` | Two hexagonal grids at a small relative angle. What you see is the moiré between them, not either grid. Pure geometry, no noise anywhere. |
| `weave` | Truchet tiling — every cell holds two quarter-arcs flipped by a hash, and they always meet at the edges, so it's one unbroken ribbon that never repeats. |

Moods: `drift` `ember` `bloom` `verdant` `aurora`

**Adding a form** is three small edits: a case in `Form.swift`, a
`somethingField()` function in `Field.metal`, and a branch in `fieldFragment`.
Nothing else needs to know. Next up per the plan: mycelial growth (branching
filaments, so two people's touches visibly grow toward each other) and liquid
light (caustics and refraction).

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
| two fingers, press + hold | Ground Me (engages after 0.35s so a stray touch can't flip it) |
| three fingers, tap | leave the session |

Tap and rest are one gesture told apart by what happens after it lands, so
there's nothing to learn — and since neither cares *where* it lands, there's
nothing to aim at either. That's the requirement: this screen gets used by
people who can't read a UI and shouldn't have to hit a target.

**A touch has no position.** Tapping the corner and tapping dead centre produce
an identical field. Position is still written to the event log — it costs
nothing, the log is what sync and replay are built on, and forms that use it are
coming (mycelial growth reaches out from where you touched) — but no shader
reads it today.

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

**The field is a pure function of `(time, seed, bloom log)`.** Nothing about a
session is stored in pixels. That's deliberate — it's what makes both remaining
big features cheap:

- **Sync (step 3):** send bloom events over MultipeerConnectivity, both devices
  render identically. No pixel streaming, no server.
- **Replay (step 6):** re-run the bloom log against the same seed and the
  session reproduces exactly.

Don't break that property.

### Safety constraints in the shader

These are load-bearing, not stylistic:

- **No strobe.** Every animated term is a slow sine or an exponential decay.
  There is no path through this shader that produces a hard flash.
- **Soft-clamped luminance** in the present pass (`c / (1 + c * 0.55)`), so
  overlapping blooms brighten the field but can never blow out to white.
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

## Development shortcuts

`#if DEBUG` only — these can't ship:

```bash
# jump straight into the Field, skipping the picker
xcrun simctl launch <udid> com.dez.mycelium -field bloom

# pick a form too
xcrun simctl launch <udid> com.dez.mycelium -form kaleidoscope -field aurora

# inject blooms 5s in (for screenshots — you can't tap a headless sim)
xcrun simctl launch <udid> com.dez.mycelium -field drift -blooms

# start already grounded, to compare against normal
xcrun simctl launch <udid> com.dez.mycelium -field ember -ground

# start with the hold pulse engaged (you can't rest a finger on a headless sim)
xcrun simctl launch <udid> com.dez.mycelium -form kaleidoscope -field drift -hold
```

`-form` takes any form name (`smoke`, `kaleidoscope`, `lattice`, `weave`);
`-field` takes any mood.

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
| kaleidoscope zoom speed | `ZOOM_RATE` — octaves per second. Past ~0.2 it stops being hypnotic and starts feeling like falling. **Changing this alone is enough; the feedback trail follows it automatically** |
| lattice moiré scale | `split` in `latticeField` — the *relative* angle between the two grids. The interesting range is only about a tenth of a radian wide; outside it you get one screen-sized blob or invisible grain |
| lattice fineness | `scale = 110.0` — how many grid periods fit on screen |
| weave tile size and line width | `q * 7.5` and the two `smoothstep` widths in `weaveField` |
| edge crispness | `persistBase` — lattice and weave hold far less history than smoke and kaleidoscope, because feedback is exactly what softens a hard edge |
| hold pulse depth | `holdSwing * 0.78` (brightness), `* 0.06` (shape swell), `* 0.09` (hue) |
| hold pulse rhythm | `Breath.holdPulseSeconds` in `FieldState.swift` |
| how fast the hold engages / releases | `holdRate` in `FieldState.advance` (asymmetric on purpose), `holdDelay` and `holdSlop` in `FieldView.swift` |
| ambient motion speed | the `drift * 0.0xx` coefficients in `smokeField`, `rot` in `kaleidoscopeField` |
| kaleidoscope symmetry | `segments = 6.0` |
| smoke definition | `ridged()` and the `detail * 0.42` mix — this is what pulls veins out of the wash |
| breath pacing | `Breath` in `FieldState.swift` — grounded is 11s (resonant breathing, 5.5/min); that number is the point of the mode |
| how fast grounding eases in | `easeRate` in `FieldState.advance` |

### How the endless zoom works

The kaleidoscope magnifies forever without ever repeating or seaming. It renders
the fractal **twice per frame, exactly one octave apart**, and cross-fades:

```
k = fract(time * ZOOM_RATE)      // 0 → 1, then wraps
near = kali(q * exp2(-k))        // scale 1.0 → 0.5
far  = kali(q * exp2(1 - k))     // scale 2.0 → 1.0
out  = mix(near, far, k)
```

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

Cost is 18 fractal iterations per pixel instead of 9. Fine at 60fps, and fine
on the 30fps preview tiles.

**The feedback trail has to be locked to the zoom rate.** This is the part that
actually made the zoom visible, and it isn't obvious. The accumulation blend
samples history at `(uv - 0.5) * contract + 0.5`, and that constant was a fixed
`0.998` — which at 60fps drifts the trail outward at **11.3%/second**. The
kaleidoscope was zooming at 3.9%/second. A ghost travelling 2.9x faster than the
thing casting it doesn't read as motion; it reads as blur, and it buried the
zoom completely. The contraction is now `exp2(-ZOOM_RATE * dt)` for that form,
using the real frame delta passed in `holdParams.z`, so history lands exactly
where the pattern is going.

If you add a form that moves the whole field coherently, it needs the same
treatment. A fixed contraction only works for forms that churn in place.

### One trap worth knowing

The kaleidoscope fold uses `atan2`, which returns `-pi..pi`, and `fmod` keeps
the sign of its dividend. Folding a negative angle straight through `fmod`
leaves hard seams down the mirror lines — a discontinuity through the center
and straight edges radiating out. The angle gets lifted by `TAU` first for
exactly this reason. If you touch that fold, check it full-screen: the bug is
nearly invisible in a small preview tile.

## Not built yet

Steps 3–7: sync, voice capture, the intention screen, the Morning View, and the
polish pass. See [the plan](../docs/PLAN.md).
