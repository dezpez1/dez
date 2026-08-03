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
| `kaleidoscope` | Sixfold mirror symmetry over a Kali-set inversion fractal, colored by orbit traps. Self-similar detail at every scale. |

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
| one finger, tap or drag | bloom |
| two fingers, press + hold | Ground Me (engages after 0.35s so a stray touch can't flip it) |
| three fingers, tap | leave the session |

## How the Field works

Two render passes per frame:

```
accum[prev] ──▶ fieldFragment ──▶ accum[cur] ──▶ presentFragment ──▶ drawable
```

`fieldFragment` computes two-level domain-warped fbm, adds touch blooms, colors
it through an [IQ cosine palette](https://iquilezles.org/articles/palettes/),
then blends with the previous frame. That feedback blend is what makes strokes
persist and slowly become part of the pattern rather than just fading out.

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
```

`-form` takes `smoke` or `kaleidoscope`; `-field` takes any mood.

## Tuning

Most of the feel lives in a handful of constants:

| what | where |
|---|---|
| how long strokes persist | `persistence` in `Field.metal` — above ~0.55 a fresh bloom drowns in its own history |
| overall contrast | `col = col * col * (3 - 2 * col)` in `fieldFragment` — remove it and everything goes washed out again |
| color richness | the saturation lift in `presentFragment`; the tonemap desaturates as it rolls off and this puts it back |
| bloom brightness | the `glow * 1.05` term |
| bloom size and travel | `radius = age * 0.30`, and the `* 5.5` ring tightness |
| how hard a touch hits | `warp * 0.26` (displacement) and `shock * 0.30` (hue push) |
| ambient motion speed | the `drift * 0.0xx` coefficients in `smokeField`, `rot` in `kaleidoscopeField` |
| kaleidoscope symmetry | `segments = 6.0` |
| smoke definition | `ridged()` and the `detail * 0.42` mix — this is what pulls veins out of the wash |
| breath pacing | `Breath` in `FieldState.swift` — grounded is 11s (resonant breathing, 5.5/min); that number is the point of the mode |
| how fast grounding eases in | `easeRate` in `FieldState.advance` |

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
