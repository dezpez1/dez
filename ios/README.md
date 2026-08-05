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
| `tunnel` | A corridor of packed glass beads spiralling away, built in log-polar coordinates — a plain staggered grid in `(log r, theta)` comes back as this. Endless, seamless, and the cheapest form here. |
| `weave` | Truchet tiling — every cell holds two quarter-arcs flipped by a hash, and they always meet at the edges, so it's one unbroken ribbon that never repeats. |
| `mycelial` | Two cellular nets — broad felted cords and a mid net — over a tangle of threads crossing at every angle. Built against a photograph of a real network. Starts as one blob and grows outward forever while the camera retreats from it; what a patch of mat looks like is driven by how long ago the margin passed over it. |

| Form | Palettes |
|---|---|
| `kaleidoscope` | Obsidian · Reef · Bone · Vespers |
| `tunnel` | Prism · Neon · Oilslick · Vapor |
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
| kaleidoscope zoom speed | `KALEIDO_ZOOM_RATE` — octaves per second, currently 0.20 (a doubling every 5s). Past ~0.25 it stops being hypnotic and starts feeling like falling. **Changing this alone is enough; the feedback trail follows it automatically** |
| how much of the kaleidoscope is flat wash | `trapSum` in `kaliLayer` and its two weights. The min-traps go quiet where the orbit settles early; this one keeps accumulating and is what puts structure in those regions. **Weight it into `detail`, not `t`** — see below |
| mycelial retreat speed | `MYCELIAL_GROW_RATE` — the same mechanism run backwards, currently 0.045. **This is not the perceived rate**, see below. It is also the clock every `AGE_*` constant is measured against |
| how big the colony starts | `COLONY_START` — screen radius in field units, where the visible area is ~0.46 wide and 1.0 tall |
| how far it spreads, and how long it takes | `COLONY_SETTLE` and `COLONY_SPREAD_SECONDS`. Settle sits under the screen corners (~0.55) on purpose — put the margin off-screen and the growth becomes invisible |
| how ragged the growing margin is | `COLONY_RIDGE_ANG` / `COLONY_RIDGE_ISO` (the two ridge fields) and `COLONY_BASE` / `COLONY_FINGER` (how far a ridge throws a finger). **Both fields are needed**, see below |
| how growth stages behind the margin | `AGE_EMERGE`, `AGE_TIP`, `AGE_THICK`, `AGE_MID`, `AGE_FINE` — in octaves of retreat, so ~22s each at the current rate. This staging is the whole growth model, see below |
| tunnel travel speed | `TUNNEL_SPEED` — rows per second. **Safety constant, see below** |
| tunnel bead count | `TUNNEL_COLUMNS` (**must be a whole number**) and `TUNNEL_ROW`, which is *derived*: `(TAU / COLUMNS) * 0.866` for a staggered circle packing. Move one and the other has to follow |
| tunnel spiral amount | `TUNNEL_TWIST` — swept through zero by a slow sine, so it passes through concentric rings both ways. Capped by the packing, see below |
| tunnel bead size | `TUNNEL_BEAD`, in column widths. **0.433 is a hard ceiling** and the twist is what sets it, see below |
| tunnel mortar glow | `TUNNEL_GAP_WAVE` / `TUNNEL_GAP_DRIFT` (the travelling pulse) and `TUNNEL_GAP_FLOOR` / `TUNNEL_GAP_SWING` (how dark it gets and how far it swings) |
| weave tile size and line width | `q * 7.5` and the two `smoothstep` widths in `weaveField` |
| edge crispness | `persistBase` — tunnel and weave hold far less history than the other two, because feedback is exactly what softens a hard edge |
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

Cost is 20 fractal iterations per pixel instead of 10. Fine at 60fps, and fine
on the 30fps preview tiles.

The tunnel gets all of this for free and pays none of it — see below.

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
0.66 because a felted look is genuinely what that form is for; tunnel and weave
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

### Growth, and why a moving boundary isn't it

The first two versions of this treated growth as a mask. A ragged circle got
bigger and uncovered a mat that had been sitting there the whole time — which is
exactly what it looked like, and the note it drew back was that the form read as
"a pre-defined grid that was already set in place and is just getting bigger."
Nothing about the mask was wrong. The mistake was thinking growth is a boundary
at all.

**Growth is what a patch of mat has had time to do**, and because the retreat
rate is a known constant, that comes for free:

```
age = log2(frontEff / r)      // in octaves of camera retreat
```

A point sitting at screen radius `r` inside a margin at `frontEff` crossed that
margin exactly `log2(frontEff / r)` octaves ago, because the retreat is the thing
that carried it inward. One logarithm, no state, no simulation — every pixel
knows its own age. At `MYCELIAL_GROW_RATE = 0.045` an octave is about 22
seconds, which is the unit every `AGE_*` constant is written in.

Everything else is that age driving what has had time to appear:

| age | what happens |
|---|---|
| `AGE_EMERGE` ~1s | a cord fades up at the tip |
| `AGE_TIP` ~2.4s | the bright growing edge trails behind it |
| `AGE_MID` ~7s | the mid net starts filling in |
| `AGE_THICK` ~13s | cords reach full width, from 28% at the tip |
| `AGE_FINE` ~18s | the fine hyphae fill the cells, last |

The staging is the point, and the cord *width* ramp is the load-bearing half of
it. A hypha at the tip is a thread and the same hypha a minute later is a rope;
fade a full-width cord up instead and it reads as something being switched on
rather than something extending. Turn all three nets on at once and the colony
simply materialises at full complexity wherever the margin happens to be — which
is the "already there, just uncovered" read, arrived at from a different
direction.

Three things about the margin itself:

**It has to be measured in screen space, not world space.** The camera is
retreating at the same time, so a margin pinned in world space gets dragged
inward and shrinks to a dot however fast you grow it.

**It needs two ridge fields, and neither works alone.** `ridged3` rather than
`fbm3` because a ridged field's high ground is a *connected network with
junctions*, so a boundary riding on it throws fingers that split; plain fbm has
closed level sets and can only ever give you an amoeba. `COLONY_RIDGE_ANG` is
sampled on the unit circle, so its creases are identical at every radius and
give clean radial spikes — a starburst on its own. `COLONY_RIDGE_ISO` is sampled
on the plane and is the same at every angle — isotropic lichen on its own.
Multiplied, the spikes get eaten into along their length, break, and pick up
side branches.

**`COLONY_SETTLE` must stay under the screen corners (~0.55).** An earlier 0.78
put the whole margin off-screen, and once the interesting edge is outside the
frame all you can see is the middle of the mat, which is uniform. The growth
becomes invisible and the form goes back to reading as texture sliding around.

The ring field is sampled on the unit circle rather than from `atan2`. An angle
taken straight out of `atan2` jumps a full turn across the negative x-axis, and
any noise driven by it leaves a hard seam down that line — a bug that shipped
once already in an earlier version of this form.

### The tunnel, and why it's the cheap one

Work in `(log r, theta)` instead of `(x, y)` and two things become true. A
logarithmic spiral turns into a straight line, so an ordinary square grid in
that space comes back to the screen as a spiral corridor. And zooming turns into
*translation*.

That second one is the whole point. The kaleidoscope and mycelial both pay
double — two octaves rendered and cross-faded — to make their zoom endless. The
tunnel needs none of it. Beads just scroll out of an infinite integer grid,
forever, and the distribution of bead sizes on screen never changes, so there's
nothing to alias and nothing to hand off. It is by a distance the cheapest form
in the app while looking like the most elaborate.

Constraints that are structural rather than aesthetic:

**`TUNNEL_COLUMNS` must be a whole number.** Theta wraps at the negative x-axis
and the column coordinate jumps by exactly that value there. An integer jump
lands back on the same point in the packing and nothing shows; anything else
leaves a hard seam down that line. The shear is free to be fractional — it
multiplies the row coordinate, which doesn't jump.

**Per-bead colour has the same constraint, and it's easy to miss.** The hue is
now a *hash* of the cell index — scattered marbles rather than concentric rings
of one colour, which is closer to the reference and also stops the eye locking
onto the rings and reading the whole thing as flat. But a hash of an index that
jumps by `TUNNEL_COLUMNS` gives two different colours either side of a line the
geometry crosses seamlessly. The index is folded back into `0..COLUMNS-1` first,
and that fold is what makes a per-bead random colour legal here at all.

**Nine candidate centres, not one.** A staggered lattice's cells are hexagons,
and the rectangle you get from `floor()` is not that hexagon — near a corner of
the rectangle the nearest bead centre belongs to the row above. Testing only the
pixel's own rectangle clips every circle against the rectangle it fell in, and
what comes out is a grid of rounded squares. That shipped in the first version
of this and is what the second one fixes.

**The beads are measured in real log-polar units.** Index space is neither square
nor orthogonal — a column is `TAU/COLUMNS` wide while a row is `TUNNEL_ROW` tall,
and the shear tilts the row axis on top — so a circle measured there squashes and
leans with the twist. Undone (`e = (f.x - shear*f.y, f.y*aspect)`), the map to
the screen is conformal, and a circle stays a circle at any shear and any radius.

**`TUNNEL_BEAD` is capped at 0.433 by the twist, not by the packing.** Unsheared,
the six nearest neighbours all sit one column width away, so 0.5 would have them
kissing. Shear slides rows past each other, and once it passes half a column the
staggered neighbour is directly overhead — `sqrt(3)/2 = 0.866` away instead of
1.0. Anything above half of that fuses rows into columns every time the twist
sweeps through. The side effect is worth keeping: between there and no shear the
mortar opens and closes on the twist's cycle, so the packing breathes.

One split worth preserving: **hue dominates `t`, body shading goes in `detail`.**
`t` is the palette coordinate, so anything that moves it moves colour. An early
version gave the bead's dome enough weight in `t` that shading swept the hue
across each bead, turning every one into its own small rainbow. The two
highlights are the deliberate exception — they're tight enough to read as glints
rather than as a gradient, and the fact that they move `t` by *different* amounts
is exactly what makes them different colours, which is the one thing that says
glass rather than painted plastic.

#### Keeping the vanishing point alive

Beads shrink without limit toward the centre, and the first version gave up on
them early: it faded the structure out below `r = 0.075` and left a flat disc.
That is a ninth of the screen height rendered as one solid colour, sitting
exactly where the depth cue should be — it read as a dead pixel, not as distance.

The real problem was never the small beads, it was aliasing, and aliasing is
fixed by knowing how big a pixel is rather than by deleting the detail. One
pixel spans `pxSize/(r*ROW)` rows and `pxSize*COLUMNS/(TAU*r)` columns — both
blow up as `1/r`, which is exactly the rate the beads shrink — so widening the
bead's edge by that much makes each one soften into its own average precisely
when it stops being resolvable. Structure now survives to within a few pixels of
the centre and dissolves instead of aliasing.

`pxSize` is computed exactly rather than with `fwidth`: `p` is a linear function
of `uv`, so one pixel is just `zoom / res.y`. That also sidesteps `fwidth` of
anything built on `fract()` or `atan2`, which blows up on the one line where the
input is discontinuous.

The centre glow that replaces the disc is **kept deliberately small**, because
the feedback pass amplifies it in a way nothing else here is subject to: this
form's history is sampled slightly inward every frame, so whatever sits at the
centre gets dragged outward across the whole screen and re-added. A glow that
looks modest in a single frame comes back as pale fog over everything a few
seconds later.

#### On `TUNNEL_SPEED` and what has *not* been verified

Bright beads sweeping past dark mortar is periodic whole-field luminance
modulation at one cycle per row, so the travel rate in rows per second is a
flicker frequency in Hz. The photosensitive band starts around 3Hz. At 0.30
rows/sec the form sits an order of magnitude clear of it.

The mortar glow added later is a second animated term and is safe for a
different reason: it is a **travelling** wave, not a blink. `TUNNEL_GAP_WAVE`
puts about 55 spatial cycles of it on screen at once, so the bright part is
always somewhere — the spatial average barely moves and the whole-field
modulation is negligible. At a *fixed* point the rate is `TUNNEL_GAP_DRIFT/TAU`
= 0.09Hz anyway. The same swing applied globally instead of as a wave would be
whole-field modulation, which is the one thing this shader must never do.

**That is a structural argument, not a measurement.** It rests on every animated
term in `tunnelField` being slow: the row scroll at 0.30Hz, the twist sine at a
180-second period, and the breath at 13 seconds. Nothing in the function
oscillates faster. You can check that by reading it.

An attempt to measure the luminance trace directly **failed and was abandoned**,
for two reasons worth recording so nobody repeats it:

- The simulator restores the previous scene rather than cold-launching, so
  `simctl launch -form tunnel` repeatedly came up on a different form and the
  captures were of the wrong thing. Two full runs were thrown away to this.
- More fundamentally, `simctl io screenshot` samples at best around 2.8Hz. By
  Nyquist that cannot see anything above ~1.4Hz, so **screenshot sampling can
  never test the 3–60Hz band at all**, however clean the run.

Verifying this properly needs an in-app luminance probe writing to a log, or
real device frame capture. Until someone does that, treat the safety basis as
the code-reading argument above.

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
