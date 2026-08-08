//
//  LabControls.swift
//  The sidebar. Everything here answers "what am I looking at" or "change it
//  without rebuilding".
//

import AppKit
import Foundation
import SwiftUI

struct LabRootView: View {
    let engine: LabEngine

    var body: some View {
        HStack(spacing: 0) {
            FieldPane(engine: engine)
            Divider()
            ControlPane(engine: engine)
                .frame(width: 300)
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }
}

// MARK: - The field, and anything that must be said over the top of it

private struct FieldPane: View {
    let engine: LabEngine

    var body: some View {
        ZStack {
            Color.black
            aspected
            if let error = engine.settings.error {
                CompileError(text: error)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var aspected: some View {
        let a = engine.settings.aspect
        if a > 0 {
            LabFieldViewRepresentable(engine: engine)
                .aspectRatio(1 / a, contentMode: .fit)
                .padding(12)
        } else {
            LabFieldViewRepresentable(engine: engine)
        }
    }
}

/// Deliberately not fullscreen and deliberately not opaque. The previous good
/// frame is still rendering underneath, and being able to see it while reading
/// the error is most of the value — the question you are asking is "what did I
/// just break", against something you can still look at.
private struct CompileError: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 200)
            .background(Color(red: 0.30, green: 0.03, blue: 0.05).opacity(0.94))
        }
    }
}

// MARK: - Sidebar

private struct ControlPane: View {
    let engine: LabEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StatusBlock(engine: engine)
                FormBlock(engine: engine)
                TimeBlock(engine: engine)
                SliderBlock(engine: engine)
                GestureBlock(engine: engine)
                Text("""
                Click for a tap. Click and rest for the hold. Right-click and \
                hold to ground. Saving Field.metal reloads it — the last good \
                shader keeps running until the new one compiles.
                """)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }
}

private struct StatusBlock: View {
    let engine: LabEngine

    var body: some View {
        let s = engine.settings
        let colour: Color = s.error != nil ? .red : (s.compiling ? .yellow : .green)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(colour).frame(width: 8, height: 8)
                Text(s.error != nil ? "shader error"
                     : (s.compiling ? "compiling…" : "live"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(s.fps.rounded())) fps")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("\(s.compiles) compiles · last \(Int(s.lastCompileMS.rounded())) ms")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

private struct FormBlock: View {
    let engine: LabEngine

    var body: some View {
        let state = engine.state

        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Form", icon: "circle.grid.cross")

            Picker("", selection: Binding(
                get: { state.form },
                set: { state.form = $0 })) {
                ForEach(Form.allCases) { form in
                    Text(form.title).tag(form)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("", selection: Binding(
                get: { state.paletteIndex },
                set: { state.paletteIndex = $0 })) {
                ForEach(Array(state.form.palettes.enumerated()), id: \.offset) { i, p in
                    Text(p.name).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

private struct TimeBlock: View {
    let engine: LabEngine

    /// Log-scaled. The useful range is 0.1x–1x for watching a transition
    /// resolve and 2x–8x for finding out where a slow drift ends up, and on a
    /// linear slider everything below 1x is squeezed into the first ninth.
    private static let lo: Float = 0.1
    private static let hi: Float = 8.0

    var body: some View {
        let s = engine.settings

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Time", icon: "clock")
                Spacer()
                Text(String(format: "%.2fx", s.timeScale))
                    .font(.system(size: 11, design: .monospaced))
            }

            Slider(value: Binding(
                get: { Double(log(s.timeScale / Self.lo) / log(Self.hi / Self.lo)) },
                set: { s.timeScale = Self.lo * pow(Self.hi / Self.lo, Float($0)) }
            ), in: 0...1)

            HStack(spacing: 6) {
                Button(s.paused ? "Play" : "Pause") { s.paused.toggle() }
                Button("1x") { s.timeScale = 1 }
                Button("Restart") { engine.restart() }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Picker("", selection: Binding(
                get: { s.aspect },
                set: { s.aspect = $0 })) {
                Text("Phone").tag(CGFloat(19.5 / 9.0))
                Text("Square").tag(CGFloat(1))
                Text("Fill").tag(CGFloat(0))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

private struct SliderBlock: View {
    let engine: LabEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("u.lab", icon: "slider.horizontal.3")

            ForEach(engine.settings.sliders) { slider in
                LabSliderRow(engine: engine, index: slider.id)
            }

            Text("""
            Swap a constant for u.lab.x, find the number, then put the constant \
            back. Nothing committed should read u.lab.
            """)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LabSliderRow: View {
    let engine: LabEngine
    let index: Int

    var body: some View {
        let s = engine.settings
        let slider = s.sliders[index]
        let span = max(slider.hi - slider.lo, 1e-6)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(slider.channel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .frame(width: 12, alignment: .leading)

                Text(Self.format(slider.value))
                    .font(.system(size: 11, design: .monospaced))

                Spacer()

                // Straight to the clipboard, because the next thing you do with
                // this number is paste it into a constant.
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.format(slider.value),
                                                   forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help("Copy value")
            }

            // Normalised rather than ranged, so dragging the bounds underneath a
            // slider can't leave its value outside them.
            Slider(value: Binding(
                get: { Double((slider.value - slider.lo) / span) },
                set: { s.sliders[index].value = slider.lo + Float($0) * span }
            ), in: 0...1)

            HStack(spacing: 4) {
                Bound(label: "lo", get: { s.sliders[index].lo },
                      set: { s.sliders[index].lo = $0 })
                Bound(label: "hi", get: { s.sliders[index].hi },
                      set: { s.sliders[index].hi = $0 })
            }
        }
    }

    /// Four significant figures. Enough to transcribe a tuned value without
    /// pretending a slider gave you seven digits of intent.
    static func format(_ v: Float) -> String {
        let m = abs(v)
        if m == 0 { return "0" }
        if m >= 100 { return String(format: "%.1f", v) }
        if m >= 10  { return String(format: "%.2f", v) }
        if m >= 1   { return String(format: "%.3f", v) }
        return String(format: "%.4f", v)
    }
}

private struct Bound: View {
    let label: String
    let get: () -> Float
    let set: (Float) -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField("", value: Binding(get: get, set: set), format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 62)
        }
    }
}

private struct GestureBlock: View {
    let engine: LabEngine

    var body: some View {
        let state = engine.state

        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Gestures", icon: "hand.tap")

            HStack(spacing: 6) {
                Button("Tap") { state.addBloom(x: 0, y: 0, strength: 1.0) }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Burst") { engine.burst() }
                    .keyboardShortcut("b", modifiers: [])
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            // Bound to the *targets*, not the eased values. Reading back `hold`
            // would leave the switch showing off for the third of a second it
            // takes to ease in, which reads as the click not having registered.
            HStack(spacing: 10) {
                Toggle("Hold", isOn: Binding(
                    get: { state.holdTarget > 0.5 },
                    set: { state.setHolding($0) }))
                Toggle("Ground", isOn: Binding(
                    get: { state.groundingTarget > 0.5 },
                    set: { state.setGrounding($0) }))
                Spacer()
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11))
        }
    }
}

private struct SectionLabel: View {
    let title: String
    let icon: String

    init(_ title: String, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
