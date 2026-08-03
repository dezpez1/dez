//
//  RootView.swift
//  The Before screen, in its foundation form.
//
//  Per the plan this eventually takes a written intention and derives the
//  palette from it. For now it's direct mood selection — same seam, simpler
//  input. Whatever picks the Mood here is the only thing that changes.
//
//  This screen is used sober, so ordinary UX rules apply. It is the last
//  screen where that's true.
//

import SwiftUI

struct RootView: View {
    @State private var state = FieldState()
    @State private var inSession = false

    var body: some View {
        Group {
            if inSession {
                FieldScreen(state: state) { inSession = false }
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
        //   xcrun simctl launch <udid> com.dez.mycelium -field drift -blooms
        //   xcrun simctl launch <udid> com.dez.mycelium -field drift -ground
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-field") else { return }
            if i + 1 < args.count, let m = Mood(rawValue: args[i + 1]) {
                state.mood = m
            }
            inSession = true

            if args.contains("-ground") {
                state.setGrounding(true)
                Haptics.shared.startGroundingPulse()
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
                        state.addBloom(x: x, y: y, strength: 1.0)
                    }
                }
            }
        }
        #endif
    }

    private var entry: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 40) {
                VStack(spacing: 10) {
                    Text("Mycelium")
                        .font(.system(size: 40, weight: .light, design: .serif))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("choose a mood")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.top, 40)

                VStack(spacing: 16) {
                    ForEach(Mood.allCases) { mood in
                        Button {
                            state.mood = mood
                            withAnimation(.easeInOut(duration: 0.6)) { inSession = true }
                        } label: {
                            Text(mood.title)
                                .font(.system(size: 26, weight: .light))
                                .foregroundStyle(.white.opacity(0.9))
                                .frame(maxWidth: .infinity)
                                .frame(height: 74)      // deliberately huge targets
                                .background(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .fill(swatch(mood).opacity(0.30))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(swatch(mood).opacity(0.55), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 28)

                Spacer()

                VStack(spacing: 7) {
                    legend("one finger", "bloom")
                    legend("two fingers, hold", "ground me")
                    legend("three fingers", "leave")
                }
                .padding(.bottom, 34)
            }
        }
    }

    private func legend(_ gesture: String, _ effect: String) -> some View {
        HStack(spacing: 8) {
            Text(gesture)
                .foregroundStyle(.white.opacity(0.38))
            Text("·")
                .foregroundStyle(.white.opacity(0.22))
            Text(effect)
                .foregroundStyle(.white.opacity(0.55))
        }
        .font(.system(size: 14, weight: .light))
    }

    /// Rough on-screen stand-in for each palette — enough to tell them apart
    /// without evaluating the cosine palette on the CPU.
    private func swatch(_ mood: Mood) -> Color {
        switch mood {
        case .drift:   return Color(red: 0.35, green: 0.62, blue: 0.82)
        case .ember:   return Color(red: 0.86, green: 0.46, blue: 0.24)
        case .bloom:   return Color(red: 0.76, green: 0.40, blue: 0.78)
        case .verdant: return Color(red: 0.42, green: 0.76, blue: 0.48)
        case .aurora:  return Color(red: 0.55, green: 0.60, blue: 0.88)
        }
    }
}
