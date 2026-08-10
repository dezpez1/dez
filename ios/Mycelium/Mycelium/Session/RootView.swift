//
//  RootView.swift
//  The Before screen.
//
//  Every tile is a real, running Field — same shader, same renderer, just
//  smaller and at half frame rate. You pick by looking at the thing itself
//  rather than by reading a word, which is the whole point: nothing here is a
//  swatch or an approximation.
//
//    tap a tile     enter that form
//    swipe a tile   cycle its palette in place
//
//  This screen is used sober, so ordinary UX rules apply. It is the last
//  screen where that's true.
//

import SwiftUI
import MetalKit

// MARK: - A live, non-interactive field for preview tiles

private struct FieldPreviewRepresentable: UIViewRepresentable {
    let state: FieldState

    final class Coordinator { var renderer: FieldRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        // Touches belong to the SwiftUI gestures on the tile, not to the view.
        view.isUserInteractionEnabled = false
        if let r = FieldRenderer(view: view, state: state, preview: true) {
            context.coordinator.renderer = r
            view.delegate = r
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

/// The colony, growing in behind the home screen.
///
/// Its own `FieldState`, so its clock is its own: the growth you see is how long
/// **this visit to the home screen** has lasted, not how long the app has been
/// open. Leaving for a session and coming back starts it over from bare edges,
/// which is the behaviour Jacob asked for — "only when you're on that home
/// screen."
///
/// Held at low opacity rather than dimmed in the shader. Sitting-behind-type is
/// a property of this screen, not of the form, and the form still has to render
/// at full strength in Field Lab where it gets judged.
private struct HomeGrowth: View {
    @State private var state: FieldState = {
        let s = FieldState()
        s.form = .mycelial
        s.paletteIndex = 3          // Filament — the palest of the four
        return s
    }()

    var body: some View {
        FieldPreviewRepresentable(state: state)
            .opacity(0.55)
            .allowsHitTesting(false)
            .ignoresSafeArea()
            // A fresh state on every appearance is what restarts the growth.
            // Resetting the existing one would do it too and would keep the
            // renderer's feedback history, which is a frame of the *old*
            // colony — it would bleed through the first second of the new one.
            .onAppear { state = { let s = FieldState(); s.form = .mycelial
                                  s.paletteIndex = 3; return s }() }
    }
}

// MARK: - One tile

private struct PreviewTile: View {
    let form: Form
    @Binding var paletteIndex: Int
    let onTap: () -> Void

    @State private var state: FieldState
    @State private var nudge: CGFloat = 0

    init(form: Form, paletteIndex: Binding<Int>, onTap: @escaping () -> Void) {
        self.form = form
        self._paletteIndex = paletteIndex
        self.onTap = onTap
        let s = FieldState()
        s.form = form
        s.paletteIndex = paletteIndex.wrappedValue
        self._state = State(initialValue: s)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            FieldPreviewRepresentable(state: state)

            // Keeps the label legible over whatever the field happens to be
            // doing underneath it.
            LinearGradient(colors: [.clear, .black.opacity(0.75)],
                           startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 5) {
                Text(form.title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                Text(form.blurb)
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
                paletteDots
                    .padding(.top, 3)
            }
            .padding(13)
        }
        .aspectRatio(0.56, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        )
        .offset(x: nudge)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .gesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height)
                    else { return }
                    cycle(forward: value.translation.width < 0)
                }
        )
        .onChange(of: paletteIndex) { _, new in state.paletteIndex = new }
    }

    private var paletteDots: some View {
        HStack(spacing: 5) {
            ForEach(form.palettes.indices, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(i == paletteIndex ? 0.85 : 0.22))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private func cycle(forward: Bool) {
        let count = form.palettes.count
        guard count > 1 else { return }
        let next = forward
            ? (paletteIndex + 1) % count
            : (paletteIndex - 1 + count) % count

        // A small shove in the swipe direction so the palette change reads as
        // a response to the gesture rather than a value quietly updating.
        withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) {
            nudge = forward ? -9 : 9
        }
        paletteIndex = next
        withAnimation(.spring(response: 0.42, dampingFraction: 0.7).delay(0.06)) {
            nudge = 0
        }
    }
}

// MARK: - Root

struct RootView: View {
    @State private var session = FieldState()
    @State private var log: SessionLog?
    @State private var inSession = false

    /// Each form remembers the palette you last left it on. Indices, because
    /// the palettes themselves now belong to the form.
    @State private var palettes: [Form: Int] = Dictionary(
        uniqueKeysWithValues: Form.allCases.map { ($0, 0) })

    /// A session is an EVENT now, not a screen: entering builds a fresh
    /// FieldState — new seed, clock at zero — opens the log, and starts the
    /// mic. That is a behavior change from the old single long-lived state
    /// (re-entering used to resume the old clock), and the log is why: a
    /// timestamp only means something against a clock that started when the
    /// session did. It also matches what the home growth already does —
    /// every visit starts over.
    private func enter(form: Form, paletteIndex: Int) {
        let s = FieldState()
        s.form = form
        s.paletteIndex = paletteIndex

        let log = SessionLog(seed: s.seed, form: form, paletteIndex: paletteIndex)
        // Blooms carry their own birth time; grounding needs the clock read
        // at the moment it flips — `s` captured weakly, since the state owns
        // that closure and a strong capture would be a cycle.
        s.onBloom = { b in log?.bloom(b) }
        s.onGround = { [weak s] on in log?.grounding(t: s?.elapsed ?? 0, on: on) }

        session = s
        self.log = log
        AudioPipeline.shared.beginSession(feeding: s, log: log)
        withAnimation(.easeInOut(duration: 0.65)) { inSession = true }
    }

    /// Ordering matters: the pipeline finalizes any live capture (which logs
    /// its end) before the log writes its own end line and closes.
    private func leave() {
        AudioPipeline.shared.endSession()
        log?.end(t: session.elapsed)
        log = nil
        inSession = false
    }

    var body: some View {
        Group {
            if inSession {
                FieldScreen(state: session,
                            captureEnabled: AudioPipeline.shared.permission == .granted) {
                    leave()
                }
                .transition(.opacity)
            } else {
                entry
            }
        }
        #if DEBUG
        // Development entry points — these let the Field be exercised without
        // a finger on the glass, which is the only way to verify blooms and
        // grounding from a headless simulator.
        //
        //   xcrun simctl launch <udid> com.dez.mycelium -field ink
        //   xcrun simctl launch <udid> com.dez.mycelium -form kaleidoscope -field reef
        //   xcrun simctl launch <udid> com.dez.mycelium -form mycelial -field spore -blooms
        //   xcrun simctl launch <udid> com.dez.mycelium -field ember -ground
        //   xcrun simctl launch <udid> com.dez.mycelium -field pearl -capture 8,5
        //   xcrun simctl launch <udid> com.dez.mycelium -field pearl -audiofake sine
        .onAppear {
            let args = ProcessInfo.processInfo.arguments

            var form = session.form
            if let i = args.firstIndex(of: "-form"), i + 1 < args.count,
               let f = Form.allCases.first(where: {
                   $0.title.lowercased() == args[i + 1].lowercased()
               }) {
                form = f
            }

            guard let i = args.firstIndex(of: "-field") else { return }
            var palette = 0
            if i + 1 < args.count,
               let p = form.palettes.firstIndex(where: {
                   $0.name.lowercased() == args[i + 1].lowercased()
               }) {
                palette = p
            }

            // Through the real entry path, so a headless session gets the
            // same log, mic pipeline and capture wiring a fingered one does.
            enter(form: form, paletteIndex: palette)

            // A headless simulator can't rest a finger on the glass either.
            if args.contains("-hold") {
                session.setHolding(true)
            }

            if args.contains("-ground") {
                session.setGrounding(true)
                Haptics.shared.startGroundingPulse()
            }

            // Mashing the screen — the case that used to blow the field out.
            if args.contains("-burst") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    for i in 0..<20 {
                        let a = Float(i) * 0.7
                        session.addBloom(x: cos(a) * (0.05 + Float(i) * 0.012),
                                         y: sin(a) * (0.05 + Float(i) * 0.018),
                                         strength: 1.0)
                        try? await Task.sleep(for: .milliseconds(90))
                    }
                }
            }

            if args.contains("-blooms") {
                // Fire after the field has settled so the blooms are mid-life
                // (young enough to be bright, old enough to have expanded)
                // when a screenshot lands a couple of seconds later.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    for (x, y) in [(Float(0), Float(0)),
                                   (-0.22, 0.34),
                                   (0.24, -0.30),
                                   (0.05, 0.62)] {
                        session.addBloom(x: x, y: y, strength: 1.0)
                    }
                }
            }

            // -capture 8,5 — press the circle at 8s, lift at 13s, through the
            // real controller, so the file-and-log path runs headlessly.
            if let ci = args.firstIndex(of: "-capture"), ci + 1 < args.count {
                let parts = args[ci + 1].split(separator: ",").compactMap { Float($0) }
                let start = Double(parts.first ?? 8)
                let dur = Double(parts.count > 1 ? parts[1] : 5)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(start))
                    AudioPipeline.shared.beginCapture()
                    try? await Task.sleep(for: .seconds(dur))
                    AudioPipeline.shared.endCapture()
                }
            }

            // -audiofake [sine|pulse] — drive audioLevel synthetically, for
            // eyeballing the uniform path with no microphone at all. It
            // writes over whatever the pipeline publishes, so use it on a
            // simulator that has NOT been granted the mic.
            if let ai = args.firstIndex(of: "-audiofake") {
                let kind = ai + 1 < args.count ? args[ai + 1] : "sine"
                let s = session
                Task { @MainActor in
                    var env = AudioEnvelope()
                    let started = CACurrentMediaTime()
                    var last = started
                    while true {
                        try? await Task.sleep(for: .milliseconds(33))
                        let now = CACurrentMediaTime()
                        let t = Float(now - started)
                        let dt = Float(now - last)
                        last = now
                        let target: SIMD4<Float>
                        if kind == "pulse" {
                            let ph = (t * 0.5).truncatingRemainder(dividingBy: 1)
                            let on: Float = ph < 0.25 ? 1 : 0
                            target = SIMD4(on, on, on, on)
                        } else {
                            let w = 0.5 + 0.5 * sin(2 * Float.pi * 0.2 * t)
                            target = SIMD4(w, w, w, 0)
                        }
                        env.advance(toward: target, dt: dt)
                        s.audioLevel = env.value
                    }
                }
            }
        }
        #endif
    }

    private var entry: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HomeGrowth()

            VStack(spacing: 0) {
                VStack(spacing: 7) {
                    Text("Mycelium")
                        .font(.system(size: 34, weight: .regular, design: .serif))
                        .foregroundStyle(.white.opacity(0.94))
                        .kerning(2.5)
                    Text("swipe to recolor · tap to enter")
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(.white.opacity(0.38))
                        .kerning(0.6)
                }
                .padding(.top, 18)
                .padding(.bottom, 16)

                // One row. It scrolled when there were four forms and two rows
                // with a third peeking; there are two now and they fit, so the
                // scroll view would only add a bounce with nowhere to go.
                //
                // `Form.pickable`, not `allCases` — mycelial is the background
                // growing behind this grid, not one of the things in it.
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12),
                              GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(Form.pickable) { form in
                        PreviewTile(
                            form: form,
                            paletteIndex: Binding(
                                get: { palettes[form] ?? 0 },
                                set: { palettes[form] = $0 })
                        ) {
                            enter(form: form,
                                  paletteIndex: palettes[form] ?? 0)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                Spacer(minLength: 0)

                VStack(spacing: 6) {
                    legend("tap", "pulse")
                    legend("press and rest", "glow and dim")
                    legend("hold the circle", "capture")
                    legend("two fingers, hold", "ground me")
                    legend("two fingers, pinch", "zoom")
                    legend("three fingers", "leave")
                }
                .padding(.top, 12)
                .padding(.bottom, 26)
            }
        }
        .statusBarHidden()
        // The one moment the app asks for anything: sober, on this screen,
        // never mid-session. A denial is honored silently — the field just
        // doesn't react to the room and the circle never appears.
        .onAppear { AudioPipeline.shared.requestPermissionIfNeeded() }
    }

    private func legend(_ gesture: String, _ effect: String) -> some View {
        HStack(spacing: 7) {
            Text(gesture).foregroundStyle(.white.opacity(0.32))
            Text("·").foregroundStyle(.white.opacity(0.18))
            Text(effect).foregroundStyle(.white.opacity(0.5))
        }
        .font(.system(size: 13, weight: .light))
    }
}
