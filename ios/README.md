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
| the colony's size, growth and tap response | `Colony` in **`FieldState.swift`**, not the shader — `start`, `full`, `regrowTau`, `tapPullback`, `pushRate`, `floorReach`. A tap changes these and a tap is an event; the shader has nowhere to keep one |
| how ragged the growing margin is | `COLONY_BRANCH_ANG` (**must be a whole number**) and `COLONY_BRANCH_RAD` shape the fingers. See below for why it's log-polar |
| how *branched* it looks | `COLONY_RESIST` — how much harder the worst direction is than the best. 0 is a circle; above ~8 it's a starfish. `COLONY_RESIST_YOUNG` is the same knob for a seedling, where a starfish is right |
| the connectivity march | `COLONY_STEP` / `COLONY_MARCH_MAX`, and `COLONY_SEED` / `COLONY_SPAN`. **Read the note below before touching any of them** — the guarantee that nothing appears in mid air lives in the shape of this loop |
| brightness of the growing edge | `MARGIN_LINE` |
| how growth stages behind the margin | `AGE_EMERGE`, `AGE_TIP`, `AGE_THICK`, `AGE_MID`, `AGE_FINE`, `AGE_SETTLE` — in octaves of retreat, so ~22s each at the current rate. This staging is the whole growth model, see below |
| how legible the deep interior is | `MAT_SETTLED_DIM`, `MAT_FINE_SETTLED`, `MAT_CELL`, `MAT_GAMMA`. **Read the note below before touching these** — they're the answer to "there's too much going on to see the branching", not decoration |
| tunnel travel speed | `TUNNEL_SPEED` — rows per second. **Safety constant, see below** |
| tunnel bead count | `TUNNEL_COLUMNS` (**must be a whole number**) and `TUNNEL_ROW`, which is *derived*: `(TAU / COLUMNS) * 0.866` for a staggered circle packing. Move one and the other has to follow |
| tunnel spiral amount | `TUNNEL_TWIST` — swept through zero by a slow sine, so it passes through concentric rings both ways. Capped by the packing, see below |
| tunnel flow | `TUNNEL_LOBES` (**must be a whole number**), `TUNNEL_LOBE_R`, `TUNNEL_LOBE_A`. Amplitude is capped by shape, not taste — see below |
| how fast the beads change colour | `TUNNEL_HUE_SLOW` and `TUNNEL_HUE_SPAN`, in rad/sec. Each bead draws its own rate from that range; **never give them a shared one** |
| how reflective the beads look | `env` — a banded environment looked up by the surface normal. Weight it into `detail`; it's a broad term and broad terms fog through the feedback |
| tunnel bead size | `TUNNEL_BEAD`, in column widths. Useful up to ~0.577; past 0.5 beads meet along flat contacts, which is what packed marbles do |
| how deep the corridor looks | `TUNNEL_COLUMNS`. Fewer beads around means each is bigger *and* each row is taller in log-radius, so fewer rings fit before the vanishing point. 22 was a shaft; 17 is a bowl |
| how 3D the beads read | `TUNNEL_AMBIENT` and the contact-shading `mix(1.0, 0.62, ...)`, both via the `shade` channel. See below — this cannot go through `t` |
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
| `AGE_SETTLE` ~38s | and then the mat quiets down again |

The staging is the point, and the cord *width* ramp is the load-bearing half of
it. A hypha at the tip is a thread and the same hypha a minute later is a rope;
fade a full-width cord up instead and it reads as something being switched on
rather than something extending. Turn all three nets on at once and the colony
simply materialises at full complexity wherever the margin happens to be — which
is the "already there, just uncovered" read, arrived at from a different
direction.

#### Making the interior legible

Rendered at one intensity everywhere, the deep interior of the mat is so dense
that the branching cannot be read through it. The margin was the only part
anyone could follow — and the margin is a thin ring around a screenful of noise.
Three changes, all of them legibility decisions before they're aesthetic ones:

- **Old mat quiets down.** Past `AGE_SETTLE` it loses most of its fine hyphae
  and drops to `MAT_SETTLED_DIM` brightness, so the light is where the growth
  is. This also happens to be true of the real thing: the active edge is the
  bright part.
- **Fewer, larger cells** (`MAT_CELL`). The old frequencies put around fifteen
  coarse cells across a screen — a convincing mat, and too many to follow. Ten
  still reads as grown rather than drawn (four would be a diagram) and leaves
  each cord long enough to trace from one junction to the next.
- **Crushed mid-tones** (`MAT_GAMMA`), so cords separate from the fuzz instead
  of sitting in the same tonal band as it.

The test for all three: can you pick one cord at the margin and follow it inward
through two junctions? If not, they've drifted back.

#### Nothing appears that isn't connected to something

The version before this thresholded a radius: a noise field said how far the
colony had got at each angle, and anything inside that was grown. It looked like
branching and it wasn't, because **the test at a point never asked about the
points between it and the middle.** Wherever the noise peaked, mat appeared with
nothing joining it to the rest — branches materialising in mid air.

The fix is to stop asking *is this point inside the margin* and start asking
*how hard was it to get here*:

```
cost(r) = integral from the seed out to r of (1 + RESIST * resistance)
```

The integrand is strictly positive, so cost only ever increases going outward,
and that single property is the whole guarantee: the grown region is an interval
along every ray, so it's star-shaped, so every grown point has an unbroken trail
of grown material back to the middle. Connectivity is never checked or enforced
anywhere — it cannot fail. Branching survives and now happens for the right
reason: growth runs far up the cheap channels and stalls in the expensive ones,
and the channels fork.

**Fixed step size, not a fixed sample count**, and this is the part that bites.
Spreading N samples across the whole span — the obvious midpoint rule — moves
every sample point as the radius grows, so the quadrature error wanders with it.
Six samples of a noisy integrand wander enough that cost sometimes *decreases*
outward, and every place it does is an island with a gap behind it: the exact
bug this march exists to prevent, reintroduced by the arithmetic. Fixed
positions mean going outward only ever adds terms, so the sum is monotone by
construction rather than by luck.

`COLONY_MARCH_MAX * COLONY_STEP` must cover the widest span that can be on
screen. Past it the field returns unreached rather than trusting a truncated
integral — an undercounted cost reads as *grown*, which is the worst way for
this to fail.

**Two unit traps, both found by looking.** `budget` and `cost` are in cost
units, which inflate with `RESIST` — left unnormalised, a fourteen-second-old
seedling's centre came out twenty-six octaves old and rendered as fully settled
mat. And nothing capped age to how long the colony had actually existed, so a
fresh session arrived pre-aged; `min(age, time * MYCELIAL_GROW_RATE)` fixes that.

**Proving it, rather than arguing it.** The claim was checked by temporarily
rendering the mask alone — `age > 0` as flat white — which showed a single
connected star with no islands. Worth doing again after any change here, because
the failure is invisible in a normal render: what you see instead is scraps.

#### The advancing front is drawn, not implied

Even with a provably connected mask, the *render* can look disconnected. Every
other term is the mat multiplied by an age factor, so a finger whose tip lands
on a cell interior renders near black and the fingertip beyond it reads as a
detached scrap — the mid-air-branch complaint arriving through the renderer
instead of the model.

`frontLine` (`emerge * tip`, scaled by `MARGIN_LINE`) draws the margin as a
thing in its own right, independent of what the mat happens to contain there.
It's also truer: a real colony's leading edge is a continuous advancing hyphal
front, brighter than anything behind it.

#### The margin, and why fingers need two dimensions

**Ridged noise, not fbm.** A ridged field's high ground is a *connected network
with junctions*, so a boundary riding on it throws fingers that split. Plain fbm
has closed level sets and can only ever give you an amoeba.

**In log-polar, not on a circle.** The version before this sampled one ridge
field on the unit circle (identical at every radius, so radial) and one on the
plane, and multiplied them. Cheap, and wrong in a way that took a while to see —
*a field sampled on a circle is one-dimensional, and a one-dimensional ridge
field has no junctions at all.* It can only produce isolated spikes, which is
exactly what it produced: fingers that were individual thin lines rather than
anything branching.

The fix is a genuinely 2-D ridge field in `(log r, theta)`. That space is
conformal to the screen, so a feature that's long in the log-radius axis and
narrow in the angular one comes back as a finger reaching outward — at every
radius, with a real ridge network's junctions in it, and without any of it being
drawn as a line. `COLONY_BRANCH_RAD` sets how stretched: a feature spans
`r/RAD` radially against `r*TAU/ANG` tangentially, so smaller is longer.

`COLONY_BRANCH_ANG` **must be a whole number**, because one of those axes is an
angle. `ridgedP` wraps its lattice *index* by exactly that value rather than
wrapping the coordinate — the cells either side of the seam really are the same
cells, so there's nothing to blend and nothing to show. The octave step is
exactly 2.0 and the period doubles with it, so every octave stays whole.

(The old form of this bug is worth remembering too: an angle taken straight out
of `atan2` jumps a full turn across the negative x-axis, and any noise driven by
it leaves a hard seam down that line. That shipped once.)

**The margin has to be measured in screen space, not world space.** The camera
is retreating at the same time, so a margin pinned in world space gets dragged
inward and shrinks to a dot however fast you grow it.

#### Tap to make room

At rest the mat owns the whole frame — which is what it should do, and also
means the only part of it that's *doing* anything is off-screen. So a tap shoves
the camera back by `Colony.tapPullback` octaves, the mat shrinks to a blob, and
it has to grow into the frame again over the next twenty-odd seconds.

This is why `Colony` lives in `FieldState.swift` and not in the shader: a tap is
an event, and the shader is a pure function of what it's handed with nowhere to
keep a consequence. Three things make it work:

- **The pullback is added to the zoom phase**, `fract(time * RATE + push)`. The
  octave cross-fade is seamless at *every* value of k, so the camera can be
  shoved anywhere along the zoom at any moment and there is nothing to stitch.
- **Reach and camera are driven off the same eased delta**, rather than the
  reach being set outright at the moment of the tap. The mat shrinks at exactly
  the rate the view pulls back, so the margin never slides against the texture.
- **The feedback contraction gets this frame's share of the push.** Without it
  the trail stays locked to the idle retreat while the camera is doing something
  four times faster, and the one moment the view really moves is the one moment
  the ghost lags behind it.

Gated on the form in `addBloom`, or tapping the kaleidoscope would quietly
shrink a colony you aren't looking at and you'd come back to a speck.

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

**`TUNNEL_BEAD` is not capped at half the neighbour distance**, and an earlier
version of this section said it was. That was true of the code that tested only
the pixel's own rectangular cell, where going over the cap fused rows of beads
into columns. It stopped being true the moment the nine-way nearest-centre
search went in, and the reason is worth keeping: **with nearest-site assignment,
two overlapping discs meet along the perpendicular bisector between their
centres rather than blending into a blob.** Overlap is a *flat contact* — which
is what a jar of marbles under its own weight actually looks like. The useful
range runs to about 0.577, the circumradius of the packing, where the last
triple-point gaps close and there's no mortar left at all.

One split worth preserving: **hue dominates `t`, body shading goes in `detail`.**
`t` is the palette coordinate, so anything that moves it moves colour. An early
version gave the bead's dome enough weight in `t` that shading swept the hue
across each bead, turning every one into its own small rainbow. The two
highlights are the deliberate exception — they're tight enough to read as glints
rather than as a gradient, and the fact that they move `t` by *different* amounts
is exactly what makes them different colours, which is the one thing that says
glass rather than painted plastic.

#### `shade`, and why lighting can't go through `t`

Forms return a palette coordinate. That is enough for almost everything, and it
is *not* enough for a lit surface, which is worth understanding before adding
another form that has one.

`t` can only move a colour **along** the palette. Darkening a bead by scaling
its `t` walks it toward zero — which these palettes do render as black, so the
endpoint is right — but the trip there crosses most of the colour wheel, and
every bead comes out a rainbow. That is the same failure the dome shading caused
in the first version of this form, arrived at from a third direction.

So `fieldFragment` takes a third output: `shade`, a straight brightness multiply
applied after the palette and before the contrast curve. Forms that light
nothing return 1. The tunnel uses it for real diffuse falloff with a real
terminator, plus contact shading toward each bead's silhouette — a sphere is
legible as a sphere because of where it goes **dark**, and nothing that only
brightens can say that.

#### Making it flow instead of spin

A rigid lattice being rotated reads exactly like a rigid lattice being rotated —
marbles spinning, not a corridor flowing. The lobes bend the log-polar
coordinates *before* anything is tiled, so the whole packing waves: rows swell
and pinch, beads slide against their neighbours, and their highlights travel
across them because the surface underneath moved.

**`TUNNEL_LOBES` must be a whole number**, same rule as `TUNNEL_COLUMNS` and for
the same reason — it's driven off the raw angle, which jumps a full turn at the
seam, and `sin(a * L)` only survives that if `L` is an integer.

**Amplitude is capped by shape, not taste.** The warp is not conformal: its
derivative with respect to the angle shears the row axis, so a bead that is a
circle in the warped coordinates comes back as an ellipse, and the stretch
scales with `LOBE_R * LOBES`. At 0.085 with three lobes every bead was an egg
and the packed-marble read was gone.

Two other things sell the material, and both are about what the pattern is a
function of:

**The beads each change colour at their own rate.** Two hashes, not one — the
second gives every bead its own speed to travel its hue at, so they never come
round together. A shared rate is a whole-field rhythm, which is the thing this
shader must never have, and the version before this had every bead sitting on
its colour and staying there, which is most of what made them look painted.

**The reflection is looked up by the surface normal, not by position.** That's
the part that reads as reflective: the bands are fixed in the world, so they
slide across a bead whenever the surface under them turns and two neighbours
show different parts of the same room. A pattern in bead-local coordinates looks
like decoration on the ball however shiny you make it.

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
