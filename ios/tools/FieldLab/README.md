# Field Lab

`Field.metal`, rendered off disk, rebuilding on save.

```bash
ios/tools/FieldLab/run.sh
```

A macOS window with the field in it, a form picker, a palette picker, a time
scale, the phone's gestures on a mouse, and four sliders. Save `Field.metal` in
any editor and the window has the new shader in about a second. Nothing is
copied into this directory — it compiles the app's own `Form.swift`,
`FieldState.swift` and `Uniforms.swift`, and reads `Field.metal` at runtime.

## Why

The app compiles `Field.metal` at build time, so seeing a shader change meant an
Xcode build and a deploy: about ninety seconds, during which you forget what you
were comparing against. The bloom pass took six of those rounds, and the
overshoot in the middle of them — a threshold that filled the frame with haze —
would have been obvious in about four seconds with a slider.

The tuning table in [../../README.md](../../README.md) is full of values that
are not what the maths predicts. That is not a series of mistakes; it is what
tuning a shader is. It just needs a loop short enough that being wrong is cheap.

## The window

**Form / palette** — every combination the app ships, live.

**Time** — 0.1x to 8x, log scaled, with pause and restart. The field is a
feedback system, so most of what you see at any moment is the previous twenty
seconds of itself. *Restart* clears the accumulation buffers, which is the only
way to see the first frame of what you just wrote rather than a dissolve into it
from what you wrote before.

**Aspect** — the field renders into a 19.5:9 box by default rather than the
window. Framing is aspect-dependent; the tunnel's vanishing point sits at a
different fraction of the frame on a phone than in a square window, and tuning
it wide then shipping it tall is a mistake you only find on the device.

**Gestures** — click for a tap, click-and-rest for the hold, right-click-and-hold
to ground. Same delays and the same 0.22s tap throttle as
[FieldView.swift](../../Mycelium/Mycelium/Field/FieldView.swift), because the
point of judging a hold here is that it is judged the same way. *Burst* fires
four taps at the throttle interval — one tap tells you almost nothing about the
bloom envelope, and whether four of them sum into a swell or stack into a flash
is a safety property.

**Audio** — a synthetic room for the field's mic-reactivity. Off, it is four
band sliders (bass/mid/treble/onset); sine and pulse are waveforms with a rate
slider. Either way the level reaches `state.audioLevel` through the same
`AudioEnvelope` smoothing the phone's analyser applies, so what you tune
against here is what the microphone will produce there. `--audio` is the same
thing headless (see the flag table), and being able to sweep a *rate* at a
fixed timestep matters: the capture loop is the only instrument in this repo
that can sample above the ~2.8Hz ceiling that killed the screenshot-based
flicker measurement.

**Compile errors** appear over the field, and the previous good shader keeps
running underneath. That is deliberate: the question you are asking is "what did
I just break", and you want the thing you broke still on screen.

## The sliders

The four sliders drive `u.lab.x` through `u.lab.w`, which every form function
receives as its `lab` parameter and no form reads.

To sweep a constant, point it at a slider:

```metal
// shade = ... * (1.0 + TUNNEL_CORE * hot + ...)
   shade = ... * (1.0 + lab.x     * hot + ...)
```

Save, drag, watch, copy the value out with the button next to it, put the
constant back with the number in it. Each slider's range is editable because the
constants worth sweeping are not all 0…1 — `TUNNEL_SPEED` is 0.62 and
`TUNNEL_CORE_TIGHT` is 420.

**Nothing committed may read `lab`.** The app sends zero, so a form that reads it
looks right in the lab and renders with that whole term missing on a phone.

## Capture

The same renderer, headless, to a PNG:

```bash
ios/tools/FieldLab/run.sh --capture /tmp/t.png --form tunnel --at 12 --stats
```

`--at` is seconds of simulated time at a fixed 1/60 step, not wall clock, and
the seed is pinned. Two runs of the same command produce byte-identical files,
which is the entire point — an early version of this inherited the app's random
per-session seed and produced two visibly different frames from an unmodified
shader.

| flag | |
|---|---|
| `--capture <path>` | render offscreen and exit |
| `--at <seconds>` | simulated time to render to (default 10) |
| `--form <name\|n>` | mycelial, kaleidoscope, lobes |
| `--palette <n>` | index into that form's palettes |
| `--seed <n>` | default 42 |
| `--lab a,b,c,d` | slider values, so a sweep can be a shell loop |
| `--audio <spec>` | a synthetic room: `const:x[,y,z,w]`, `sine:<hz>`, `pulse:<hz>`, `ramp:<s>` |
| `--width` / `--height` | default 402x874, an iPhone 17 Pro in points |
| `--stats` | print mean luminance, near-black % and blown-out % |

`--stats` exists because the useful question about this shader has repeatedly not
been "does it look nice" but "how much of this frame is actually black, and how
much is actually blown out". Reference footage runs 1.5–2.2% of pixels genuinely
blown; every form here sat at 0.0% for months while looking, to everyone who
looked at it, like it had bright parts. Screens adapt and so do eyes.

**Measure at a fixed `--at`.** The tunnel's tonal stats swing hard with time —
near-black moves between 9.6% and 26.8% on roughly an eight-second cycle from
the travelling mortar wave alone. Comparing two shaders at two different times
measures the clock.

## Build

`swiftc` directly, no SwiftPM. One binary, no manifest, no resolved-package
file, nothing to explain; the cost is that every run is a full rebuild, and at
nine files that is a few seconds. It is also why the app's own sources can just
be listed in `run.sh` — a package would need them inside its own directory or
symlinked in, and a symlinked copy of `FieldState.swift` is exactly the kind of
thing that quietly stops being the same file.

`-swift-version 5`, matching the app target. Strict concurrency has opinions
about `MTLDevice` that would need answering here and nowhere else.
