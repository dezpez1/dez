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
│   ├── FieldRenderer.swift    two-pass ping-pong renderer
│   ├── FieldState.swift       taps, breath, grounding, form, palette index
│   └── FieldView.swift        MTKView + touch handling
└── Grounding/Haptics.swift    breath-paced haptic pulse
```

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
| `lattice` | Two hexagonal grids at a small relative angle. What you see is the moiré between them, not either grid. Pure geometry, no noise anywhere. |
| `weave` | Truchet tiling — every cell holds two quarter-arcs flipped by a hash, and they always meet at the edges, so it's one unbroken ribbon that never repeats. |
| `mycelial` | Two cellular nets — broad felted cords and a mid net — over a tangle of straight threads crossing at every angle. Built against a photograph of a real network. Starts as one blob and spreads while the camera retreats from it forever. |

| Form | Palettes |
|---|---|
| `kaleidoscope` | Obsidian · Reef · Bone · Vespers |
| `lattice` | Neon · Chrome · Ultraviolet · Signal |
| `weave` | Rust · Jade · Ash · Saffron |
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
| two fingers, press + hold | Ground Me (engages after 0.35s so a stray touch can't flip it) |
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
xcrun simctl launch <udid> com.dez.mycelium -field filament

# pick a form too — note the palette name has to belong to that form
xcrun simctl launch <udid> com.dez.mycelium -form kaleidoscope -field reef

# inject taps 5s in (for screenshots — you can't tap a headless sim)
xcrun simctl launch <udid> com.dez.mycelium -form mycelial -field spore -blooms

# twenty taps in a row, the case that used to blow the field out
xcrun simctl launch <udid> com.dez.mycelium -form weave -field rust -burst

# start already grounded, to compare against normal
xcrun simctl launch <udid> com.dez.mycelium -form weave -field ash -ground

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
| kaleidoscope zoom speed | `KALEIDO_ZOOM_RATE` — octaves per second, currently 0.16 (a doubling every 6.3s). Past ~0.25 it stops being hypnotic and starts feeling like falling. **Changing this alone is enough; the feedback trail follows it automatically** |
| mycelial retreat speed | `MYCELIAL_GROW_RATE` — the same mechanism run backwards, currently 0.045. **This is not the perceived rate**, see below |
| how big the colony starts | `COLONY_START` — screen radius in field units, where the visible area is ~0.46 wide and 1.0 tall |
| how far it spreads, and how long it takes | `COLONY_SETTLE` and `COLONY_SPREAD_SECONDS`. Settle is past the screen corners (~0.55), so at rest the mat covers the frame and only the ragged margin bares a corner |
| how ragged the growing margin is | the ring `fbm3` at `2.6` sets the lobes; `rough * front * 0.42` sets the filaments and detached islands. **Both are needed**, see below |
| lattice moiré scale | `split` in `latticeField` — the *relative* angle between the two grids. The interesting range is only about a tenth of a radian wide; outside it you get one screen-sized blob or invisible grain |
| lattice fineness | `scale = 110.0` — how many grid periods fit on screen |
| weave tile size and line width | `q * 7.5` and the two `smoothstep` widths in `weaveField` |
| edge crispness | `persistBase` — lattice and weave hold far less history than the other two, because feedback is exactly what softens a hard edge |
| mycelial cord weight | `0.22 + 0.16 * wr.x` — the noise term is what makes cords read as felted masses instead of drawn strokes |
| mycelial cell scale | the `7.0` and `17.0` frequencies. Roughly 15 coarse cells across a screen reads as a mat; 4 reads as a diagram |
| thread density | `228.0 + 19.0 * fk` — spacing per direction. **Each layer needs its own**, see below |
| thread count | the `k < 5` loop. More directions cost almost nothing; each is a dot product and a sine |
| how packed the cells look | the `threads * 0.85` weight. Empty cells are what make it read as a net rather than a living mat |
| cell irregularity | the `* 0.60` domain warp before the cell layers. **Load-bearing** — unwarped Worley gives near-uniform cells and the whole thing reads as crystalline foam |

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
| tap surge | `tap * 1.2` inside `churn` — a tap drives the whole network's reorganisation forward, since it has no position to grow from |
| hold pulse depth | `holdSwing * 0.78` (brightness), `* 0.06` (shape swell), `* 0.09` (hue) |
| hold pulse rhythm | `Breath.holdPulseSeconds` in `FieldState.swift` |
| how fast the hold engages / releases | `holdRate` in `FieldState.advance` (asymmetric on purpose), `holdDelay` and `holdSlop` in `FieldView.swift` |
| ambient motion speed | the `drift * 0.0xx` coefficients in each form function |
| kaleidoscope symmetry | `segments = 6.0` |
| how fast the network reorganises | `drift * 0.05` inside `churn` |
| breath pacing | `Breath` in `FieldState.swift` — grounded is 11s (resonant breathing, 5.5/min); that number is the point of the mode |
| how fast grounding eases in | `easeRate` in `FieldState.advance` |

### How the endless zoom works

Two forms use this, in opposite directions. The kaleidoscope magnifies forever;
mycelial retreats forever. Both render their field **twice per frame, exactly
one octave apart**, and cross-fade:

```
// kaleidoscope — falling in
k = fract(time * KALEIDO_ZOOM_RATE)
near = kali(q * exp2(-k))        // scale 1.0 → 0.5
far  = kali(q * exp2(1 - k))     // scale 2.0 → 1.0
out  = mix(near, far, k)

// mycelial — pulling back. Same construction, mirrored.
k = fract(time * MYCELIAL_GROW_RATE)
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

Cost is 18 fractal iterations per pixel instead of 9. Fine at 60fps, and fine
on the 30fps preview tiles.

**The rate constant is not the rate you see, and the gap is large.** Measured on
mycelial by correlating frames against rescaled later frames and finding the peak:

| | nominal | measured |
|---|---|---|
| over 6s at `MYCELIAL_GROW_RATE = 0.045` | 1.206× | **1.060×** (r = 0.987) |
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

Mycelial gets the same treatment with the **sign flipped**:
`exp2(+MYCELIAL_GROW_RATE * dt)`. Under 1, history is sampled inward and so
drifts outward, which is where the kaleidoscope is heading as it magnifies.
Mycelial retreats — everything on screen travels inward — so its history has to
travel inward too, and that needs a factor above 1. Getting this sign wrong
doesn't look like a bug; it looks like the form is merely blurry.

If you add a form that moves the whole field coherently, it needs the same
treatment. A fixed contraction only works for forms that churn in place.

### The growth front

The colony starts as a blob and spreads to fill the frame over
`COLONY_SPREAD_SECONDS`. Two details are load-bearing:

**The front is measured in screen space, not world space.** The camera is
retreating at the same time, so a front pinned in world space gets dragged
inward by the retreat and shrinks to a dot however fast you grow it.

**Ring noise alone cannot make a ragged margin.** Modulating the front radius by
noise around the ring only ever yields a wobbly circle: every point at a given
angle advances together, so the boundary stays a single closed curve. Filaments
running out ahead of the front, and small islands breaking off it, need the
radius *itself* perturbed by 2D noise (`rough * front * 0.42`). The first version
had only the ring term and read as a cotton ball with a soft halo.

The ring noise is sampled on the unit circle rather than from `atan2`. An angle
taken straight out of `atan2` jumps a full turn across the negative x-axis, and
any noise driven by it leaves a hard seam down that line — a bug that shipped
once already in an earlier version of this form.

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
