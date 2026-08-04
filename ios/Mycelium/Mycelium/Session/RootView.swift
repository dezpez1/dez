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

// MARK: - One tile

private struct PreviewTile: View {
    let form: Form
    @Binding var mood: Mood
    let onTap: () -> Void

    @State private var state: FieldState
    @State private var nudge: CGFloat = 0

    init(form: Form, mood: Binding<Mood>, onTap: @escaping () -> Void) {
        self.form = form
        self._mood = mood
        self.onTap = onTap
        let s = FieldState()
        s.form = form
        s.mood = mood.wrappedValue
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
                moodDots
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
        .onChange(of: mood) { _, new in state.mood = new }
    }

    private var moodDots: some View {
        HStack(spacing: 5) {
            ForEach(Mood.allCases) { m in
                Circle()
                    .fill(.white.opacity(m == mood ? 0.85 : 0.22))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private func cycle(forward: Bool) {
        let all = Mood.allCases
        guard let i = all.firstIndex(of: mood) else { return }
        let next = forward
            ? all[(i + 1) % all.count]
            : all[(i - 1 + all.count) % all.count]

        // A small shove in the swipe direction so the palette change reads as
        // a response to the gesture rather than a value quietly updating.
        withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) {
            nudge = forward ? -9 : 9
        }
        mood = next
        withAnimation(.spring(response: 0.42, dampingFraction: 0.7).delay(0.06)) {
            nudge = 0
        }
    }
}

// MARK: - Root

struct RootView: View {
    @State private var session = FieldState()
    @State private var inSession = false

    /// Each form remembers the palette you last left it on.
    @State private var moods: [Form: Mood] = Dictionary(
        uniqueKeysWithValues: Form.allCases.map { ($0, .drift) })

    var body: some View {
        Group {
            if inSession {
                FieldScreen(state: session) { inSession = false }
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
        //   xcrun simctl launch <udid> com.dez.mycelium -field bloom
        //   xcrun simctl launch <udid> com.dez.mycelium -form kaleidoscope -field aurora
        //   xcrun simctl launch <udid> com.dez.mycelium -field drift -blooms
        //   xcrun simctl launch <udid> com.dez.mycelium -field ember -ground
        .onAppear {
            let args = ProcessInfo.processInfo.arguments

            if let i = args.firstIndex(of: "-form"), i + 1 < args.count,
               let f = Form.allCases.first(where: {
                   $0.title.lowercased() == args[i + 1].lowercased()
               }) {
                session.form = f
            }

            guard let i = args.firstIndex(of: "-field") else { return }
            if i + 1 < args.count, let m = Mood(rawValue: args[i + 1]) {
                session.mood = m
            }
            inSession = true

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
        }
        #endif
    }

    private var entry: some View {
        ZStack {
            Color.black.ignoresSafeArea()

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
                .padding(.top, 28)

                Spacer(minLength: 20)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12),
                              GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(Form.allCases) { form in
                        PreviewTile(
                            form: form,
                            mood: Binding(
                                get: { moods[form] ?? .drift },
                                set: { moods[form] = $0 })
                        ) {
                            session.form = form
                            session.mood = moods[form] ?? .drift
                            withAnimation(.easeInOut(duration: 0.65)) {
                                inSession = true
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)

                Spacer(minLength: 20)

                VStack(spacing: 6) {
                    legend("tap", "pulse")
                    legend("press and rest", "glow and dim")
                    legend("two fingers, hold", "ground me")
                    legend("three fingers", "leave")
                }
                .padding(.bottom, 30)
            }
        }
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
