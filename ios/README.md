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
| the colony's shape | `TREE_TRUNK`, `TREE_SHRINK`, `TREE_SPREAD`, `TREE_BEND` in `Field.metal`. BEND is what stops it being a diagram of a tree; **read the note below before removing the tangent rotation that goes with it** |
| how thick the cords are | `TREE_WIDTH` and `TREE_TAPER` |
| how ragged the rim is | `TREE_STOP` and `TREE_STUNT` — a ninth of tips give up. **Stunted, never terminated**, see below |
| how much it webs vs. how much it's a tree | `TREE_HALO` and `TREE_HALO_FLOOR`. The floor is the one that matters: it's what lets neighbouring limbs' sheaths overlap and bridge |
| how far the colony gets, and how fast | `Colony` in **`FieldState.swift`**, not the shader — `levels`, `genSeconds`, `genShrink`, `genFloor`, `tapPullback`, `levelsPerOctave`. `levels` is a **legibility** budget, not a coverage one; see below |
| brightness of the growing edge | `MARGIN_LINE` |
| how growth stages behind each tip | `AGE_EMERGE`, `AGE_TIP`, `AGE_THICK`, `AGE_MID`, `AGE_FINE`, `AGE_SETTLE` — in **levels**, not seconds, so a trunk spends far longer thickening than a twig does |
| the mat texture on the cords | `MAT_SETTLED_DIM`, `MAT_FINE_SETTLED`, `MAT_CELL`, `MAT_GAMMA`, `MAT_THREAD_FREQ`, `TREE_TEX_SCALE`. The Worley layer is a sheath now, not the form |
| tunnel travel speed | `TUNNEL_SPEED` — rows per second. **Safety constant, see below** |
| the wave running down the corridor | `TUNNEL_WAVE_A` / `_K` / `_RATE` / `_TILT`. A×K is how much it stretches the rows; TILT **must be a whole number**. This is the one warp free to have real amplitude — see below |
| how much the beads spin | `TUNNEL_TWIST` and the `drift` rates on the lobes. All roughly halved once the wave was carrying the motion |
| bead shape | `TUNNEL_SQUARE` (0 = circles, 1 = a rounded square) and `TUNNEL_CYL` (0 = sphere, 1 = a rod). CYL is what makes the highlight a line instead of a dot |
| the light, and how fast its colour travels out | `TUNNEL_SPIRAL_R` / `_A` / `_RATE` and `TUNNEL_LIGHT`. Nothing per bead touches `t` at all — **read the note below before adding anything that does** |
| how much of the screen the field renders at | `FieldRenderer.fieldScale`. The biggest lever on frame time in the app; see Performance |
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

#### Tap to make room

The colony fills the frame and then sits there, which is a finished thing to look
at and nothing to do. A tap shoves the camera back — `zoomPush`, in octaves —
which shrinks the colony on screen, and shrinking it is exactly what buys room
for finer levels: an octave of pull-back is worth `ln2 / -ln(TREE_SHRINK)` = 4.98
more of them. So the tap gets you a smaller colony **and** somewhere new for it
to grow, and it grows there over the next few seconds.

The camera is otherwise completely still, and that stillness is half of why this
form reads as growing now. The version before it cross-faded two octaves of mat
while retreating at a constant rate, so every pixel on screen drifted outward at
the same speed forever. That is a zoom. Growth is tips extending into empty space
while everything behind them stays exactly where it is, and you cannot have both.

The feedback trail follows `pushDelta` and nothing else, so it is stationary at
rest and locked to the camera during a pullback.

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

#### A wave that stretches instead of shears

A rigid lattice being rotated reads exactly like a rigid lattice being rotated —
marbles spinning, not a corridor flowing. Two mechanisms bend the log-polar
coordinates *before* anything is tiled, so the whole packing waves rather than
the beads being animated individually. They are not interchangeable.

**The lobes bend the angle**, and that shears. The warp is not conformal: its
derivative with respect to the angle tilts the row axis, so a bead that is a
circle in the warped coordinates comes back as an ellipse, and the stretch scales
with `LOBE_R * LOBES`. At 0.085 with three lobes every bead was an egg. The
useful amplitude is tiny, which is why the lobes could never be the wave.

**The travelling wave only moves the log-radius**, and its derivative is a pure
stretch along the row axis: rows bunch up and spread apart as it passes and the
beads keep the shape they had. Amplitude is therefore free in a way the lobes'
never was, and `TUNNEL_WAVE_A * TUNNEL_WAVE_K` — the stretch, about a sixth — is
the only thing bounding it. It runs at `RATE / K` = 0.31 log-radius per second
against the beads' own 0.096, so it visibly overtakes them: the corridor flexes
and the beads ride it, rather than the whole lattice sliding as one piece.

Once the wave was carrying the motion, every rotation rate came down by about
half. What they had been adding was spin, and spin was the complaint.

**`TUNNEL_LOBES` and `TUNNEL_WAVE_TILT` must both be whole numbers**, same rule
as `TUNNEL_COLUMNS` and for the same reason — they multiply the raw angle, which
jumps a full turn at the seam, and only an integer multiple survives that.

#### Cylinders, and why the highlight is a line

`u`, the round silhouette coordinate, and the surface **normal** are two
different questions, and answering them with the same value is what makes a
packing read as marbles. A sphere's normal turns in both directions at once and
its highlight is a dot. A cylinder's turns in one, its face stays flat along its
length, and its highlight is a *line* down the axis — which is the whole visual
signature of a polished rod.

`TUNNEL_CYL` is how much of the second. At 0.65 the surface bends mostly across
the corridor, each bead carries one long straight glint running outward, and its
radial ends stay flat and bright the way a cut rod's do. The silhouette, the rim,
the contact shading and the anti-aliasing all still use `u`, because those are
about the outline and the outline hasn't changed.

`TUNNEL_SQUARE` closes the packing without moving any centres: a square of
half-width 0.5 reaches 0.71 into its corners, so the triple-point gaps shrink and
neighbours meet along longer flats. The metric has to be the same one the
nine-way nearest-centre test uses, or the assignment and the silhouette disagree
and beads get clipped against cells they don't belong to.

#### The light changes, the beads don't

Two ways to make a bead look reflective: give it the **colour** of what's around
it, or give it the **brightness** of what's around it. The colour route was tried
twice and failed twice, and the reason is the same both times.

`t` is a scalar into a cosine palette that runs about one full cycle over 0..1.
Anything that sweeps a decent fraction of that range across a *single bead* puts
a complete rainbow on every bead — which is exactly what the original per-bead
hue hash was replaced to stop, arriving by a different route. It got there first
through `TUNNEL_REFLECT` at 1.55, then through the two speculars at nearly a
quarter of the ramp each.

So the colour is purely **emitted** now. There is a light at the vanishing point
whose colour changes, and it travels outward:

```metal
float lightPhase = TAU * (lrRoom * TUNNEL_SPIRAL_R - drift * TUNNEL_SPIRAL_RATE)
                 + a * TUNNEL_SPIRAL_A;
float spiral    = 0.5 + 0.5 * sin(lightPhase);
float lightLift = 1.0 + TUNNEL_LIGHT * sin(lightPhase - 1.5708);
```

A function of position and time and **nothing else** — no hash, no cell index, no
surface normal. Every bead in a ring shares a colour and the colour marches out
through them. `lightLift` is the same wave a quarter turn ahead, carried on
`shade`, so the leading edge of an arm is the bright part; that is what makes it
read as a *light* rather than as a tint. It's built from `lrRoom`, the log-radius
from before the wave and the lobes bent it, so the arm stays clean while the
lattice flexes underneath it rather than pumping along with the rows.

Safe as whole-field modulation because it **travels**: the bright part is always
somewhere, just not here, so total screen luminance barely moves. Same argument
as the mortar pulse.

What makes the beads look polished is then brightness sliding across their faces,
and that has now lived in three different places:

- **In `t`.** A glint that moves the palette coordinate is a different *colour*,
  not a brighter one. Every bead came out striped.
- **In `shade`.** Which seems obviously right — `shade` is a raw multiply applied
  after the palette, so it can't touch hue. But stacking four highlights into it
  pushes pixels to three times white, and nothing downstream is built for that:
  the contrast curve, the tonemap and the saturation lift all clip per channel at
  different points, so what came out was hard-edged rainbow *spikes*. Worse than
  the problem it fixed.
- **In `detail`**, which is where they are. It mixes toward `palette(t + 0.18)`
  at a weight that is clamped to 1. It lifts, it nudges the hue slightly, and it
  cannot blow out — and that bound is the whole reason it's the right channel.

`shade` still carries the diffuse term and the travelling light, and stays near 1.

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

## Performance

The whole app is one fullscreen fragment shader plus a feedback blend, so cost is
almost exactly proportional to **pixels x ALU**, and there is no geometry, no
overdraw and no draw-call count to think about. Two levers, in order of size:

**Render the field below native resolution.** `FieldRenderer.fieldScale`, 0.72
linear, so barely half the fragments. The present pass still runs at full drawable
size and upsamples with a linear sampler. This costs almost nothing here because
none of these forms *have* detail at pixel scale by construction: mycelial's
sheath is a soft falloff, the tunnel anti-aliases its beads to their own average
as they approach a pixel across, and every form is then blended with a blurred
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

## Not built yet

Steps 3–7: sync, voice capture, the intention screen, the Morning View, and the
polish pass. See [the plan](../docs/PLAN.md).
